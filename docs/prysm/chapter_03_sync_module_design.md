# 第3章 同步模块与P2P的协同设计

## 3.1 架构关联概述

### 3.1.1 双层协作模型

```
┌─────────────────────────────────────────────────────────┐
│                  Beacon Node 架构                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌────────────────────────────────────────────────┐   │
│  │         Application Layer (Sync Module)         │   │
│  │  - Initial Sync Service                         │   │
│  │  - Regular Sync Service                         │   │
│  │  - Block Processing                             │   │
│  └────────────────┬───────────────────────────────┘   │
│                   │  使用P2P接口                      │
│                   ↓                                     │
│  ┌────────────────────────────────────────────────┐   │
│  │            P2P Network Layer                    │   │
│  │  - Req/Resp 协议 (主动拉取数据)                │   │
│  │  - Gossipsub 协议 (被动接收数据)               │   │
│  │  - Peer 管理                                    │   │
│  │  - 节点发现                                     │   │
│  └────────────────────────────────────────────────┘   │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

**关键点**:
- Sync模块**依赖**P2P层提供网络能力
- P2P层**服务**Sync模块的数据需求
- 两者通过明确的接口交互

---

## 3.2 P2P接口设计

### 3.2.1 P2P Interface定义

```go
// 来自prysm/beacon-chain/p2p/interfaces.go
type P2P interface {
    // Peer管理
    Peers() PeerManager
    
    // 广播能力
    Broadcast(context.Context, proto.Message) error
    BroadcastAttestation(context.Context, uint64, *ethpb.Attestation) error
    
    // 主题订阅
    Subscribe(proto.Message, validation.SubscriptionFilter) *pubsub.Subscription
    JoinTopic(string, ...pubsub.TopicOpt) (*pubsub.Topic, error)
    LeaveTopic(string) error
    
    // 流处理
    SetStreamHandler(string, network.StreamHandler)
    
    // RPC发送
    Send(context.Context, interface{}, string, peer.ID) (network.Stream, error)
    
    // 节点信息
    Host() host.Host
    ENR() *enr.Record
    PeerID() peer.ID
    Metadata() metadata.Metadata
    MetadataSeq() uint64
    
    // 连接管理
    AddConnectionHandler(f func(ctx context.Context, id peer.ID) error)
    AddDisconnectionHandler(f func(ctx context.Context, id peer.ID) error)
    AddPingMethod(reqFunc func(ctx context.Context, id peer.ID) error)
}
```

### 3.2.2 Sync模块如何使用P2P

```go
// 来自prysm/beacon-chain/sync/service.go
type Service struct {
    cfg *Config
}

type Config struct {
    // P2P依赖
    P2P p2p.P2P  // 核心P2P接口
    
    // 其他依赖
    Chain               blockchainService
    DB                  db.ReadOnlyDatabase
    InitialSync         Checker
    StateNotifier       statefeed.Notifier
    BlockNotifier       blockfeed.Notifier
    AttestationNotifier operation.Notifier
    // ...
}

// Sync服务使用P2P的典型模式
func (s *Service) Start() {
    // 1. 注册RPC处理器
    s.registerRPCHandlers()
    
    // 2. 订阅Gossipsub主题
    s.registerSubscribers()
    
    // 3. 注册peer连接回调
    s.cfg.P2P.AddConnectionHandler(s.sendRPCStatusRequest)
}
```

---

## 3.3 Initial Sync与P2P

### 3.3.1 Initial Sync依赖的P2P能力

```go
// 来自prysm/beacon-chain/sync/initial-sync/service.go
type Service struct {
    cfg *Config
}

type Config struct {
    P2P                 p2p.P2P  // 核心P2P接口
    DB                  db.NoHeadAccessDatabase
    Chain               blockchainService
    StateNotifier       statefeed.Notifier
    BlockNotifier       blockfeed.Notifier
    ClockWaiter         startup.ClockWaiter
    InitialSyncComplete chan struct{}
    BlobStorage         *filesystem.BlobStorage
    DataColumnStorage   *filesystem.DataColumnStorage
}

// Initial sync如何使用P2P
func (s *Service) Start() {
    // 1. 等待足够的peers
    peers, err := s.waitForMinimumPeers()
    if err != nil {
        return
    }
    
    // 2. 使用P2P拉取origin数据
    if err := s.fetchOriginSidecars(peers); err != nil {
        return
    }
    
    // 3. 执行round-robin同步
    if err := s.roundRobinSync(); err != nil {
        return
    }
}
```

### 3.3.2 等待Peers的实现

```go
// 来自prysm/beacon-chain/sync/initial-sync/service.go
func (s *Service) waitForMinimumPeers() ([]peer.ID, error) {
    // 获取配置的最小peer数
    required := min(flags.Get().MinimumSyncPeers, params.BeaconConfig().MaxPeersToSync)
    
    for {
        if s.ctx.Err() != nil {
            return nil, s.ctx.Err()
        }
        
        // 从P2P获取当前finalized checkpoint
        cp := s.cfg.Chain.FinalizedCheckpt()
        
        // 使用P2P的Peers接口查找合适的peers
        // BestNonFinalized返回最佳的未finalized的peers
        _, peers := s.cfg.P2P.Peers().BestNonFinalized(
            flags.Get().MinimumSyncPeers, 
            cp.Epoch,
        )
        
        if len(peers) >= required {
            return peers, nil
        }
        
        log.WithFields(logrus.Fields{
            "suitable": len(peers),
            "required": required,
        }).Info("Waiting for enough suitable peers before syncing")
        
        time.Sleep(handshakePollingInterval)
    }
}
```

### 3.3.3 使用P2P拉取数据

```go
// 来自prysm/beacon-chain/sync/initial-sync/service.go
func (s *Service) fetchOriginBlobSidecars(
    pids []peer.ID,
    rob blocks.ROBlock,
) error {
    r := rob.Root()
    
    // 1. 构造请求
    req, err := missingBlobRequest(rob, s.cfg.BlobStorage)
    if err != nil {
        return err
    }
    
    if len(req) == 0 {
        return nil
    }
    
    // 2. 随机化peer顺序
    shufflePeers(pids)
    
    // 3. 轮询peers获取数据
    for i := range pids {
        // 使用P2P的RPC能力发送请求
        blobSidecars, err := sync.SendBlobSidecarByRoot(
            s.ctx,
            s.clock,
            s.cfg.P2P,  // 传递P2P接口
            pids[i],
            s.ctxMap,
            &req,
            rob.Block().Slot(),
        )
        
        if err != nil {
            // 尝试下一个peer
            continue
        }
        
        if len(blobSidecars) != len(req) {
            continue
        }
        
        // 4. 验证和持久化数据
        bv := verification.NewBlobBatchVerifier(
            s.newBlobVerifier,
            verification.InitsyncBlobSidecarRequirements,
        )
        avs := das.NewLazilyPersistentStore(
            s.cfg.BlobStorage,
            bv,
            s.blobRetentionChecker,
        )
        
        current := s.clock.CurrentSlot()
        if err := avs.Persist(current, blobSidecars...); err != nil {
            return err
        }
        
        if err := avs.IsDataAvailable(s.ctx, current, rob); err != nil {
            log.WithField("peerID", pids[i]).Warn("Blobs from peer were unusable")
            continue
        }
        
        log.WithField("nBlobs", len(blobSidecars)).Info("Successfully downloaded blobs")
        return nil
    }
    
    return fmt.Errorf("no connected peer able to provide blobs for block %#x", r)
}
```

---

## 3.4 Regular Sync与P2P

### 3.4.1 Gossipsub订阅

```go
// 来自prysm/beacon-chain/sync/subscriber.go
func (s *Service) registerSubscribers() {
    // 订阅区块主题
    s.subscribe(
        p2p.GossipTypeMapping[p2p.GossipBlockMessage],
        s.validateBeaconBlockPubSub,
        s.beaconBlockSubscriber,
    )
    
    // 订阅attestation主题
    s.subscribe(
        p2p.GossipTypeMapping[p2p.GossipAttestationMessage],
        s.validateAggregateAndProof,
        s.beaconAggregateProofSubscriber,
    )
    
    // 订阅其他主题...
}

func (s *Service) subscribe(
    topic string,
    validator pubsub.ValidatorEx,
    handle subHandler,
) {
    // 1. 从P2P获取主题
    t, err := s.cfg.P2P.JoinTopic(topic)
    if err != nil {
        log.WithError(err).Errorf("Failed to join topic %s", topic)
        return
    }
    
    // 2. 注册验证器
    if err := t.RegisterTopicValidator(validator); err != nil {
        log.WithError(err).Errorf("Failed to register validator for topic %s", topic)
        return
    }
    
    // 3. 订阅主题
    sub, err := t.Subscribe()
    if err != nil {
        log.WithError(err).Errorf("Failed to subscribe to topic %s", topic)
        return
    }
    
    // 4. 启动消息处理循环
    go s.subscriptionHandler(sub, handle)
}
```

### 3.4.2 实时区块处理

```go
// 来自prysm/beacon-chain/sync/subscriber_beacon_blocks.go
func (s *Service) beaconBlockSubscriber(
    ctx context.Context,
    msg proto.Message,
) error {
    signed, ok := msg.(interfaces.SignedBeaconBlock)
    if !ok {
        return errors.New("message is not a beacon block")
    }
    
    blockRoot, err := signed.Block().HashTreeRoot()
    if err != nil {
        return err
    }
    
    // 检查是否已处理
    if s.hasSeenBlockRoot(blockRoot) {
        return nil
    }
    s.markSeenBlockRoot(blockRoot)
    
    // 检查父块
    if !s.hasParentBlock(signed) {
        // 父块缺失，使用P2P请求
        return s.requestParentBlock(signed.Block().ParentRoot())
    }
    
    // 处理区块
    return s.chain.ReceiveBlock(ctx, signed, blockRoot)
}
```

---

## 3.5 RPC请求发送

### 3.5.1 Status交换

```go
// 来自prysm/beacon-chain/sync/rpc_status.go
func (s *Service) sendRPCStatusRequest(
    ctx context.Context,
    id peer.ID,
) error {
    // 1. 构造status请求
    status := &pb.Status{
        ForkDigest:     s.currentForkDigest(),
        FinalizedRoot:  fRoot[:],
        FinalizedEpoch: fEpoch,
        HeadRoot:       headRoot[:],
        HeadSlot:       s.cfg.Chain.HeadSlot(),
    }
    
    // 2. 使用P2P发送
    stream, err := s.cfg.P2P.Send(
        ctx,
        status,
        p2ptypes.RPCStatusTopicV1,
        id,
    )
    if err != nil {
        return err
    }
    defer func() {
        if err := helpers.FullClose(stream); err != nil {
            log.WithError(err).Debug("Failed to close stream")
        }
    }()
    
    // 3. 读取响应
    code, errMsg, err := ReadStatusCode(stream, s.cfg.P2P.Encoding())
    if err != nil {
        return err
    }
    if code != 0 {
        return errors.New(errMsg)
    }
    
    msg := &pb.Status{}
    if err := s.cfg.P2P.Encoding().DecodeWithMaxLength(stream, msg); err != nil {
        return err
    }
    
    // 4. 处理响应
    return s.validateStatusMessage(ctx, msg, id)
}
```

### 3.5.2 BlocksByRange请求

```go
// 来自prysm/beacon-chain/sync/rpc_beacon_blocks_by_range.go
func (s *Service) sendRecentBeaconBlocksRequest(
    ctx context.Context,
    req *pb.BeaconBlocksByRangeRequest,
    pid peer.ID,
) ([]interfaces.SignedBeaconBlock, error) {
    // 1. 使用P2P发送请求
    stream, err := s.cfg.P2P.Send(
        ctx,
        req,
        p2ptypes.RPCBlocksByRangeTopicV2,
        pid,
    )
    if err != nil {
        return nil, err
    }
    defer func() {
        if err := helpers.FullClose(stream); err != nil {
            log.WithError(err).Debug("Failed to close stream")
        }
    }()
    
    // 2. 读取响应码
    code, errMsg, err := ReadStatusCode(stream, s.cfg.P2P.Encoding())
    if err != nil {
        return nil, err
    }
    if code != 0 {
        s.cfg.P2P.Peers().Scorers().BadResponsesScorer().Increment(pid)
        return nil, errors.New(errMsg)
    }
    
    // 3. 逐个读取区块
    blocks := make([]interfaces.SignedBeaconBlock, 0, req.Count)
    for i := uint64(0); i < req.Count; i++ {
        // 读取响应码
        code, errMsg, err := ReadStatusCode(stream, s.cfg.P2P.Encoding())
        if err != nil {
            return blocks, err
        }
        
        if code != 0 {
            return blocks, errors.New(errMsg)
        }
        
        // 解码区块
        blk, err := ReadChunkedBlock(stream, s.cfg.P2P, s.cfg.DB, false)
        if err != nil {
            return blocks, err
        }
        
        blocks = append(blocks, blk)
    }
    
    return blocks, nil
}
```

---

## 3.6 Peer评分与选择

### 3.6.1 Peer评分机制

```go
// Sync模块影响peer评分
func (s *Service) validateStatusMessage(
    ctx context.Context,
    msg *pb.Status,
    id peer.ID,
) error {
    // 1. 验证fork digest
    if !bytes.Equal(msg.ForkDigest, s.currentForkDigest()) {
        // 评分降低
        s.cfg.P2P.Peers().Scorers().BadResponsesScorer().Increment(id)
        return errors.New("fork digest mismatch")
    }
    
    // 2. 验证finalized epoch
    if msg.FinalizedEpoch < s.cfg.Chain.FinalizedCheckpt().Epoch {
        // peer落后太多
        s.cfg.P2P.Peers().Scorers().BadResponsesScorer().Increment(id)
        return errors.New("peer is too far behind")
    }
    
    // 3. 更新peer状态
    s.cfg.P2P.Peers().SetChainState(id, msg)
    
    return nil
}
```

### 3.6.2 选择最佳Peer

```go
// 来自prysm/beacon-chain/p2p/peers/peerdata.go
func (p *Status) BestNonFinalized(
    minPeers int,
    ourFinalizedEpoch primitives.Epoch,
) ([]peer.ID, []peer.ID) {
    p.RLock()
    defer p.RUnlock()
    
    // 1. 过滤finalized和active的peers
    var finalized []peer.ID
    var nonFinalized []peer.ID
    
    for pid, peerData := range p.peers {
        // 检查是否活跃
        if peerData.ConnectionState != PeerConnected {
            continue
        }
        
        // 检查chain state
        chainState := peerData.ChainState
        if chainState == nil {
            continue
        }
        
        // 根据finalized epoch分类
        if chainState.FinalizedEpoch >= ourFinalizedEpoch {
            finalized = append(finalized, pid)
        } else {
            nonFinalized = append(nonFinalized, pid)
        }
    }
    
    // 2. 按评分排序
    sort.Slice(finalized, func(i, j int) bool {
        return p.scorers.Score(finalized[i]) > p.scorers.Score(finalized[j])
    })
    
    sort.Slice(nonFinalized, func(i, j int) bool {
        return p.scorers.Score(nonFinalized[i]) > p.scorers.Score(nonFinalized[j])
    })
    
    return finalized, nonFinalized
}
```

---

## 3.7 连接生命周期管理

### 3.7.1 新连接处理

```go
// 来自prysm/beacon-chain/sync/service.go
func (s *Service) Start() {
    // 注册连接处理器
    s.cfg.P2P.AddConnectionHandler(s.sendRPCStatusRequest)
    s.cfg.P2P.AddDisconnectionHandler(s.handlePeerDisconnection)
}

func (s *Service) sendRPCStatusRequest(
    ctx context.Context,
    id peer.ID,
) error {
    // 新peer连接后立即交换status
    ctx, cancel := context.WithTimeout(ctx, respTimeout)
    defer cancel()
    
    return s.sendRPCStatusRequest(ctx, id)
}

func (s *Service) handlePeerDisconnection(
    ctx context.Context,
    id peer.ID,
) error {
    // peer断开时清理状态
    s.pendingQueueLock.Lock()
    defer s.pendingQueueLock.Unlock()
    
    // 清理该peer相关的pending blocks
    // ...
    
    return nil
}
```

### 3.7.2 定期Ping维持连接

```go
// P2P层提供ping机制
s.cfg.P2P.AddPingMethod(s.pingHandler)

func (s *Service) pingHandler(
    ctx context.Context,
    id peer.ID,
) error {
    // 构造ping请求
    req := &pb.Ping{
        SeqNumber: s.cfg.P2P.MetadataSeq(),
    }
    
    // 发送ping
    stream, err := s.cfg.P2P.Send(ctx, req, p2ptypes.RPCPingTopicV1, id)
    if err != nil {
        return err
    }
    defer stream.Close()
    
    // 读取响应
    resp := &pb.Ping{}
    if err := s.cfg.P2P.Encoding().DecodeWithMaxLength(stream, resp); err != nil {
        return err
    }
    
    // 如果peer的metadata序列号更新了，请求新的metadata
    if resp.SeqNumber > s.cfg.P2P.Peers().SeqNumber(id) {
        return s.sendMetadataRequest(ctx, id)
    }
    
    return nil
}
```

---

## 3.8 数据流向总览

### 3.8.1 Initial Sync数据流

```
┌─────────────────────────────────────────────────────────┐
│              Initial Sync 数据流                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. 发现Peers                                           │
│     Initial Sync ──┐                                    │
│                    │                                     │
│                    ├→ P2P.Peers().BestNonFinalized()   │
│                    │                                     │
│                    └← 返回peer列表                      │
│                                                          │
│  2. 请求Blocks                                          │
│     Initial Sync ──┐                                    │
│                    │                                     │
│                    ├→ P2P.Send(BlocksByRangeRequest)   │
│                    │                                     │
│                    ├→ P2P → Network → Remote Peer      │
│                    │                                     │
│                    ├← Remote Peer → Network → P2P      │
│                    │                                     │
│                    └← 返回blocks                        │
│                                                          │
│  3. 处理Blocks                                          │
│     Initial Sync → Chain.ReceiveBlock()                │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### 3.8.2 Regular Sync数据流

```
┌─────────────────────────────────────────────────────────┐
│              Regular Sync 数据流                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. 订阅Gossipsub主题                                   │
│     Regular Sync ──┐                                    │
│                    │                                     │
│                    ├→ P2P.JoinTopic("beacon_block")    │
│                    │                                     │
│                    └→ P2P.Subscribe()                   │
│                                                          │
│  2. 接收Gossip消息                                      │
│     Remote Peer → Gossipsub → P2P ──┐                 │
│                                      │                  │
│                                      ├→ 验证器          │
│                                      │                  │
│                                      └→ Regular Sync    │
│                                         beaconBlockSubscriber()
│                                                          │
│  3. 处理接收到的Block                                   │
│     Regular Sync ──┐                                    │
│                    │                                     │
│                    ├→ 验证block                        │
│                    │                                     │
│                    ├→ 检查父块                         │
│                    │                                     │
│                    └→ Chain.ReceiveBlock()             │
│                                                          │
│  4. 如果父块缺失                                        │
│     Regular Sync ──┐                                    │
│                    │                                     │
│                    ├→ 加入pending队列                  │
│                    │                                     │
│                    └→ P2P.Send(BlocksByRootRequest)    │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

---

## 3.9 设计原则

### 3.9.1 关注点分离

```
P2P层职责:
✅ 网络连接管理
✅ 协议协商
✅ 消息编解码
✅ Peer发现和评分
❌ 不关心业务逻辑

Sync层职责:
✅ 同步策略选择
✅ 区块验证
✅ 状态转换
✅ Fork choice更新
❌ 不关心网络细节
```

### 3.9.2 接口抽象

```go
// P2P提供清晰的接口
type P2P interface {
    Send(ctx, msg, protocol, peer)
    Broadcast(ctx, msg)
    Subscribe(msg, validator)
    Peers() PeerManager
}

// Sync只依赖接口，不依赖实现
type SyncService struct {
    p2p p2p.P2P  // 接口依赖
}
```

### 3.9.3 错误处理与重试

```go
// Sync层处理P2P错误并重试
func (s *Service) requestBlocks(
    ctx context.Context,
    start, count uint64,
) ([]interfaces.SignedBeaconBlock, error) {
    // 1. 获取合适的peers
    peers := s.cfg.P2P.Peers().Connected()
    
    // 2. 随机化顺序
    rand.Shuffle(len(peers), func(i, j int) {
        peers[i], peers[j] = peers[j], peers[i]
    })
    
    // 3. 逐个尝试
    req := &pb.BeaconBlocksByRangeRequest{
        StartSlot: primitives.Slot(start),
        Count:     count,
        Step:      1,
    }
    
    for _, pid := range peers {
        blocks, err := s.sendBlocksByRangeRequest(ctx, req, pid)
        if err == nil && len(blocks) > 0 {
            return blocks, nil
        }
        
        // 记录失败，尝试下一个peer
        log.WithError(err).WithField("peer", pid).Debug("Failed to get blocks")
    }
    
    return nil, errors.New("no peers could provide blocks")
}
```

---

## 3.10 性能优化协同

### 3.10.1 并发控制

```go
// Sync控制并发请求数
const (
    maxConcurrentBlockRequests = 16
    maxConcurrentBlobRequests  = 8
)

func (s *Service) fetchBlocksBatch(
    ctx context.Context,
    requests []*blockRequest,
) {
    sem := make(chan struct{}, maxConcurrentBlockRequests)
    var wg sync.WaitGroup
    
    for _, req := range requests {
        sem <- struct{}{}
        wg.Add(1)
        
        go func(r *blockRequest) {
            defer wg.Done()
            defer func() { <-sem }()
            
            // 使用P2P请求
            blocks, err := s.requestBlocks(ctx, r.start, r.count)
            if err != nil {
                return
            }
            r.blocks = blocks
        }(req)
    }
    
    wg.Wait()
}
```

### 3.10.2 批量处理

```go
// Sync批量验证从P2P收到的数据
func (s *Service) processBatch(blocks []interfaces.SignedBeaconBlock) error {
    // 1. 批量签名验证
    sigs := make([]*bls.Signature, len(blocks))
    pubkeys := make([]*bls.PublicKey, len(blocks))
    messages := make([][32]byte, len(blocks))
    
    for i, block := range blocks {
        sigs[i] = block.Signature()
        pubkeys[i] = // ... 获取proposer公钥
        messages[i] = // ... 构造签名消息
    }
    
    // 批量验证所有签名
    if !bls.VerifyMultipleSignatures(sigs, messages, pubkeys) {
        return errors.New("batch signature verification failed")
    }
    
    // 2. 批量处理
    for _, block := range blocks {
        if err := s.processBlock(block); err != nil {
            return err
        }
    }
    
    return nil
}
```

---

## 3.11 监控与调试

### 3.11.1 关键指标

```go
// P2P指标
var (
    p2pPeerCount         = promauto.NewGauge(...)
    p2pMessagesSent      = promauto.NewCounterVec(...)
    p2pMessagesReceived  = promauto.NewCounterVec(...)
    p2pBytesReceived     = promauto.NewCounterVec(...)
)

// Sync指标
var (
    syncStatus           = promauto.NewGauge(...)      // 0=syncing, 1=synced
    syncPeerCount        = promauto.NewGauge(...)      // 可用的sync peers
    blocksProcessed      = promauto.NewCounter(...)
    blocksFetched        = promauto.NewCounter(...)
    syncErrors           = promauto.NewCounterVec(...) // 按错误类型
)

// 联合指标
func (s *Service) updateMetrics() {
    // 同步状态
    if s.initialSync.Syncing() {
        syncStatus.Set(0)
    } else {
        syncStatus.Set(1)
    }
    
    // 可用peers
    peers := s.cfg.P2P.Peers().Connected()
    syncPeerCount.Set(float64(len(peers)))
    
    // P2P连接数
    p2pPeerCount.Set(float64(len(s.cfg.P2P.Host().Network().Peers())))
}
```

### 3.11.2 日志关联

```go
// 使用统一的日志字段关联P2P和Sync
log.WithFields(logrus.Fields{
    // P2P相关
    "peer":       pid,
    "protocol":   protocolID,
    "direction":  "inbound",
    
    // Sync相关
    "syncMode":   "initial",
    "slot":       slot,
    "blockRoot":  fmt.Sprintf("%#x", root),
    
    // 共同
    "latency":    duration,
}).Info("Processed block from peer")
```

---

## 3.12 小结

本章详细介绍了P2P与同步模块的协同设计：

✅ **清晰的职责划分**: P2P管网络，Sync管业务
✅ **接口抽象**: 通过接口解耦
✅ **双向交互**: Sync使用P2P，P2P为Sync服务
✅ **错误处理**: 完善的重试和降级机制
✅ **性能优化**: 并发控制和批量处理
✅ **可观测性**: 统一的指标和日志

这种设计使得：
- Sync模块可以专注于同步逻辑
- P2P模块可以独立演进
- 两者通过明确的接口协作
- 便于测试和维护

---

**下一章预告**: 第4章将深入libp2p网络栈的实现细节。
