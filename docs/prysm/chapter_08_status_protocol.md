# 第8章 Status协议

## 8.1 握手流程

### 8.1.1 Status协议概述

**Status** 是Beacon Chain中最重要的握手协议，用于节点间建立连接时交换状态信息。

**核心功能**：
- 验证对方节点是否在同一网络（通过ForkDigest）
- 交换链头和最终确定状态
- 判断节点是否需要同步
- 决定是否保持连接

**协议标识符**：
```
/eth2/beacon_chain/req/status/1/ssz_snappy
```

### 8.1.2 握手时机

Status握手发生在以下场景：

```
场景1：主动连接
节点A → 连接节点B → 双向Status交换 → 建立会话

场景2：被动接受
节点A ← 节点B连接 → 双向Status交换 → 建立会话

场景3：重新握手
节点A ↔ 节点B → 定期Status更新 → 维持同步状态
```

**交互流程**：
```
节点A (发起方)                    节点B (响应方)
    │                                │
    │  1. 建立libp2p连接              │
    ├───────────────────────────────>│
    │                                │
    │  2. 打开Status stream          │
    ├───────────────────────────────>│
    │                                │
    │  3. 发送Status请求              │
    │  (A的链状态)                    │
    ├───────────────────────────────>│
    │                                │
    │                         4. 验证请求
    │                         5. 检查兼容性
    │                                │
    │  6. 返回Status响应              │
    │  (B的链状态)                    │
    │<───────────────────────────────┤
    │                                │
7. 验证响应                          │
8. 检查兼容性                        │
    │                                │
    │  9. 建立会话                    │
    │<──────────────────────────────>│
    │                                │
```

### 8.1.3 握手成功条件

```go
握手成功需要满足：
1. ForkDigest匹配（同一网络）
2. 消息格式正确（SSZ解码成功）
3. 在超时时间内完成
4. 无协议级错误

握手失败导致：
- 断开连接
- 标记peer为不良
- 可能进入黑名单
```

---

## 8.2 消息结构

### 8.2.1 Status消息定义

```go
// proto/prysm/v1alpha1/p2p.proto
message Status {
    // Fork摘要，标识网络和分叉版本
    bytes fork_digest = 1 [(ssz_size) = "4"];
    
    // 最终确定的根哈希
    bytes finalized_root = 2 [(ssz_size) = "32"];
    
    // 最终确定的epoch
    uint64 finalized_epoch = 3;
    
    // 链头根哈希
    bytes head_root = 4 [(ssz_size) = "32"];
    
    // 链头slot
    uint64 head_slot = 5;
}
```

**Go结构体**：
```go
// beacon-chain/p2p/types/types.go
type Status struct {
    ForkDigest     [4]byte          `ssz-size:"4"`
    FinalizedRoot  [32]byte         `ssz-size:"32"`
    FinalizedEpoch primitives.Epoch
    HeadRoot       [32]byte         `ssz-size:"32"`
    HeadSlot       primitives.Slot
}
```

### 8.2.2 字段详解

#### ForkDigest（分叉摘要）

**定义**：
```go
ForkDigest = hash(current_version || genesis_validators_root)[:4]

其中：
- current_version: 当前分叉版本
- genesis_validators_root: 创世验证者根
- hash: SHA256
- [:4]: 取前4字节
```

**作用**：
- 唯一标识一个网络和分叉版本
- 防止不同网络节点互联
- 支持多网络共存（主网、测试网等）

**计算实现**：
```go
// beacon-chain/p2p/fork.go
func CreateForkDigest(
    currentVersion []byte,
    genesisValidatorsRoot []byte,
) ([4]byte, error) {
    var forkDigest [4]byte
    
    // 构造数据: current_version || genesis_validators_root
    dataRoot := append(currentVersion, genesisValidatorsRoot...)
    
    // SHA256哈希
    hash := sha256.Sum256(dataRoot)
    
    // 取前4字节
    copy(forkDigest[:], hash[:4])
    
    return forkDigest, nil
}
```

#### FinalizedRoot & FinalizedEpoch

**最终确定检查点**：
```go
// 表示节点已经最终确定的链状态
type Checkpoint struct {
    Epoch primitives.Epoch  // 最终确定的epoch
    Root  [32]byte          // 该epoch的根哈希
}

用途：
1. 判断节点同步进度
2. 检测长距离分叉
3. 优化同步策略
```

#### HeadRoot & HeadSlot

**链头状态**：
```go
// 表示节点当前的链头
HeadRoot: 当前最新区块的根哈希
HeadSlot: 当前最新区块的slot号

用途：
1. 判断节点是否在同一条链上
2. 计算需要同步的区块数量
3. 选择最佳同步源
```

### 8.2.3 消息大小

```
固定大小SSZ编码：
- ForkDigest:     4 字节
- FinalizedRoot:  32 字节
- FinalizedEpoch: 8 字节
- HeadRoot:       32 字节
- HeadSlot:       8 字节
────────────────────────
总计:             84 字节

加上Snappy压缩和长度前缀：
约 90-100 字节
```

---

## 8.3 验证与断开

### 8.3.1 Status验证流程

```go
// beacon-chain/p2p/rpc_status.go

// validateStatusMessage 验证Status消息
func (s *Service) validateStatusMessage(
    ctx context.Context,
    status *pb.Status,
) error {
    
    // 1. 验证ForkDigest
    if err := s.validateForkDigest(status.ForkDigest); err != nil {
        return err
    }
    
    // 2. 验证Finalized状态
    if err := s.validateFinalized(
        status.FinalizedRoot,
        status.FinalizedEpoch,
    ); err != nil {
        return err
    }
    
    // 3. 验证Head状态
    if err := s.validateHead(
        status.HeadRoot,
        status.HeadSlot,
    ); err != nil {
        return err
    }
    
    // 4. 验证一致性
    if status.HeadSlot < status.FinalizedEpoch * SlotsPerEpoch {
        return errors.New("head slot before finalized epoch")
    }
    
    return nil
}
```

### 8.3.2 ForkDigest验证

```go
// validateForkDigest 验证分叉摘要
func (s *Service) validateForkDigest(
    remoteForkDigest []byte,
) error {
    // 获取本地ForkDigest
    localForkDigest, err := s.currentForkDigest()
    if err != nil {
        return err
    }
    
    // 比较
    if !bytes.Equal(localForkDigest[:], remoteForkDigest) {
        return &ErrWrongForkDigest{
            Local:  localForkDigest,
            Remote: remoteForkDigest,
        }
    }
    
    return nil
}

// 支持的ForkDigest列表（考虑分叉过渡期）
func (s *Service) supportedForkDigests() [][4]byte {
    var digests [][4]byte
    
    currentEpoch := s.chainService.CurrentSlot() / SlotsPerEpoch
    
    // 当前分叉的digest
    current, _ := s.forkDigestAtEpoch(currentEpoch)
    digests = append(digests, current)
    
    // 如果接近分叉，也接受下一个版本
    nextForkEpoch := s.nextForkEpoch()
    if nextForkEpoch-currentEpoch < 2 { // 2个epoch的缓冲期
        next, _ := s.forkDigestAtEpoch(nextForkEpoch)
        digests = append(digests, next)
    }
    
    return digests
}
```

### 8.3.3 断开连接原因

```go
// beacon-chain/p2p/types/goodbye.go
const (
    // 客户端主动关闭
    GoodbyeCodeClientShutdown = 1
    
    // 无关的网络
    GoodbyeCodeWrongNetwork = 2
    
    // 协议错误
    GoodbyeCodeProtocolError = 3
    
    // 速率限制
    GoodbyeCodeRateLimited = 4
    
    // 不可用
    GoodbyeCodeUnavailable = 5
)

type GoodbyeReason uint64

func (r GoodbyeReason) String() string {
    switch r {
    case GoodbyeCodeClientShutdown:
        return "Client Shutdown"
    case GoodbyeCodeWrongNetwork:
        return "Wrong Network"
    case GoodbyeCodeProtocolError:
        return "Protocol Error"
    case GoodbyeCodeRateLimited:
        return "Rate Limited"
    case GoodbyeCodeUnavailable:
        return "Unavailable"
    default:
        return "Unknown"
    }
}
```

### 8.3.4 断开连接实现

```go
// beacon-chain/p2p/peers/scorers.go

// handleInvalidStatus 处理无效的Status
func (s *Service) handleInvalidStatus(
    ctx context.Context,
    peerID peer.ID,
    err error,
) {
    log.WithFields(logrus.Fields{
        "peer":  peerID.String(),
        "error": err,
    }).Debug("Invalid status message")
    
    // 发送Goodbye消息
    reason := GoodbyeCodeWrongNetwork
    if errors.Is(err, ErrProtocolError) {
        reason = GoodbyeCodeProtocolError
    }
    
    if err := s.sendGoodbye(ctx, peerID, reason); err != nil {
        log.WithError(err).Debug("Failed to send goodbye")
    }
    
    // 断开连接
    if err := s.host.Network().ClosePeer(peerID); err != nil {
        log.WithError(err).Debug("Failed to close peer")
    }
    
    // 降低peer分数
    s.peers.Scorers().BadResponsesScorer().Increment(peerID)
}
```

---

## 8.4 代码实现

### 8.4.1 发送Status请求

```go
// beacon-chain/p2p/rpc_status.go

// SendStatusRequest 向peer发送Status请求
func (s *Service) SendStatusRequest(
    ctx context.Context,
    peerID peer.ID,
) error {
    ctx, cancel := context.WithTimeout(ctx, respTimeout)
    defer cancel()
    
    // 1. 构造请求消息
    req, err := s.createStatusMessage()
    if err != nil {
        return err
    }
    
    // 2. 打开stream
    stream, err := s.host.NewStream(
        ctx,
        peerID,
        RPCStatusTopicV1,
    )
    if err != nil {
        return err
    }
    defer stream.Close()
    
    // 3. 设置超时
    deadline := time.Now().Add(respTimeout)
    if err := stream.SetDeadline(deadline); err != nil {
        return err
    }
    
    // 4. 发送请求
    if _, err := s.encoding.EncodeWithMaxLength(
        stream,
        req,
    ); err != nil {
        return err
    }
    
    // 5. 接收响应
    resp := new(pb.Status)
    if err := s.encoding.DecodeWithMaxLength(
        stream,
        resp,
    ); err != nil {
        return err
    }
    
    // 6. 验证响应
    if err := s.validateStatusMessage(ctx, resp); err != nil {
        s.handleInvalidStatus(ctx, peerID, err)
        return err
    }
    
    // 7. 更新peer状态
    s.peers.SetChainState(peerID, &pb.Status{
        ForkDigest:     resp.ForkDigest,
        FinalizedRoot:  resp.FinalizedRoot,
        FinalizedEpoch: resp.FinalizedEpoch,
        HeadRoot:       resp.HeadRoot,
        HeadSlot:       resp.HeadSlot,
    })
    
    return nil
}
```

### 8.4.2 创建Status消息

```go
// createStatusMessage 创建当前节点的Status消息
func (s *Service) createStatusMessage() (*pb.Status, error) {
    // 获取链头状态
    headRoot, headSlot := s.chain.HeadRoot(), s.chain.HeadSlot()
    
    // 获取最终确定状态
    finalizedCheckpoint := s.chain.FinalizedCheckpt()
    
    // 获取当前ForkDigest
    forkDigest, err := s.currentForkDigest()
    if err != nil {
        return nil, err
    }
    
    return &pb.Status{
        ForkDigest:     forkDigest[:],
        FinalizedRoot:  finalizedCheckpoint.Root[:],
        FinalizedEpoch: finalizedCheckpoint.Epoch,
        HeadRoot:       headRoot[:],
        HeadSlot:       headSlot,
    }, nil
}
```

### 8.4.3 处理Status请求

```go
// statusRPCHandler 处理收到的Status请求
func (s *Service) statusRPCHandler(
    ctx context.Context,
    msg interface{},
    stream libp2pcore.Stream,
) error {
    ctx, cancel := context.WithTimeout(ctx, respTimeout)
    defer cancel()
    
    peerID := stream.Conn().RemotePeer()
    
    // 1. 解析请求
    req, ok := msg.(*pb.Status)
    if !ok {
        return errors.New("invalid message type")
    }
    
    // 2. 验证请求
    if err := s.validateStatusMessage(ctx, req); err != nil {
        s.handleInvalidStatus(ctx, peerID, err)
        return err
    }
    
    // 3. 记录peer状态
    s.peers.SetChainState(peerID, req)
    
    // 4. 创建响应
    resp, err := s.createStatusMessage()
    if err != nil {
        return err
    }
    
    // 5. 发送响应
    if _, err := s.encoding.EncodeWithMaxLength(
        stream,
        resp,
    ); err != nil {
        return err
    }
    
    // 6. 关闭stream
    return stream.Close()
}
```

### 8.4.4 Peer状态管理

```go
// beacon-chain/p2p/peers/status.go

// Status peer管理器
type Status struct {
    store     *peerstore.Store
    chainInfo chainInfoFetcher
}

// SetChainState 设置peer的链状态
func (s *Status) SetChainState(
    pid peer.ID,
    state *pb.Status,
) {
    s.store.SetChainState(pid, &ChainState{
        ForkDigest:     bytesutil.ToBytes4(state.ForkDigest),
        FinalizedRoot:  bytesutil.ToBytes32(state.FinalizedRoot),
        FinalizedEpoch: state.FinalizedEpoch,
        HeadRoot:       bytesutil.ToBytes32(state.HeadRoot),
        HeadSlot:       state.HeadSlot,
    })
}

// ChainState peer的链状态
type ChainState struct {
    ForkDigest     [4]byte
    FinalizedRoot  [32]byte
    FinalizedEpoch primitives.Epoch
    HeadRoot       [32]byte
    HeadSlot       primitives.Slot
}

// IsBehind 判断peer是否落后
func (s *Status) IsBehind(pid peer.ID) bool {
    state, err := s.store.ChainState(pid)
    if err != nil {
        return false
    }
    
    // 比较finalized epoch
    localFinalized := s.chainInfo.FinalizedCheckpt().Epoch
    return state.FinalizedEpoch < localFinalized
}

// IsAhead 判断peer是否领先
func (s *Status) IsAhead(pid peer.ID) bool {
    state, err := s.store.ChainState(pid)
    if err != nil {
        return false
    }
    
    // 比较head slot
    localHead := s.chainInfo.HeadSlot()
    return state.HeadSlot > localHead
}

// BestFinalized 找到finalized最高的peers
func (s *Status) BestFinalized(
    maxPeers int,
) []peer.ID {
    var peers []peer.ID
    
    allPeers := s.store.Peers()
    
    // 按finalized epoch排序
    sort.Slice(allPeers, func(i, j int) bool {
        stateI, _ := s.store.ChainState(allPeers[i])
        stateJ, _ := s.store.ChainState(allPeers[j])
        return stateI.FinalizedEpoch > stateJ.FinalizedEpoch
    })
    
    // 取前maxPeers个
    if len(allPeers) > maxPeers {
        peers = allPeers[:maxPeers]
    } else {
        peers = allPeers
    }
    
    return peers
}
```

---

## 8.5 Status与同步决策

### 8.5.1 同步模式判断

```go
// beacon-chain/sync/initial-sync/service.go

// shouldStartInitialSync 判断是否需要启动初始同步
func (s *Service) shouldStartInitialSync(
    peerStatus *pb.Status,
) bool {
    // 本地状态
    localHead := s.chain.HeadSlot()
    localFinalized := s.chain.FinalizedCheckpt().Epoch
    
    // peer状态
    peerHead := peerStatus.HeadSlot
    peerFinalized := peerStatus.FinalizedEpoch
    
    // 判断1：finalized差距
    finalizedDiff := int64(peerFinalized) - int64(localFinalized)
    if finalizedDiff > 4 { // 落后4个epoch以上
        return true
    }
    
    // 判断2：head差距
    headDiff := int64(peerHead) - int64(localHead)
    slotsPerEpoch := params.BeaconConfig().SlotsPerEpoch
    if headDiff > int64(slotsPerEpoch)*2 { // 落后2个epoch的slots
        return true
    }
    
    return false
}
```

### 8.5.2 Peer选择策略

```go
// selectBestSyncPeers 选择最佳同步peer
func (s *Service) selectBestSyncPeers(
    numPeers int,
) []peer.ID {
    // 1. 获取所有connected peers
    connectedPeers := s.p2p.Peers().Connected()
    
    // 2. 过滤出可用的peers
    var candidates []peerWithScore
    for _, pid := range connectedPeers {
        state, err := s.p2p.Peers().ChainState(pid)
        if err != nil {
            continue
        }
        
        // 过滤条件
        if !s.isPeerSyncCandidate(state) {
            continue
        }
        
        // 计算分数
        score := s.calculatePeerScore(pid, state)
        candidates = append(candidates, peerWithScore{
            id:    pid,
            score: score,
        })
    }
    
    // 3. 按分数排序
    sort.Slice(candidates, func(i, j int) bool {
        return candidates[i].score > candidates[j].score
    })
    
    // 4. 返回top N
    var result []peer.ID
    for i := 0; i < numPeers && i < len(candidates); i++ {
        result = append(result, candidates[i].id)
    }
    
    return result
}

// isPeerSyncCandidate 判断peer是否可作为同步源
func (s *Service) isPeerSyncCandidate(state *ChainState) bool {
    localFinalized := s.chain.FinalizedCheckpt().Epoch
    
    // peer必须至少和本地一样新
    return state.FinalizedEpoch >= localFinalized
}

// calculatePeerScore 计算peer分数
func (s *Service) calculatePeerScore(
    pid peer.ID,
    state *ChainState,
) float64 {
    score := 0.0
    
    // 1. Finalized epoch越高越好
    localFinalized := s.chain.FinalizedCheckpt().Epoch
    finalizedDiff := float64(state.FinalizedEpoch - localFinalized)
    score += finalizedDiff * 10.0
    
    // 2. Head slot越新越好
    localHead := s.chain.HeadSlot()
    headDiff := float64(state.HeadSlot - localHead)
    score += headDiff
    
    // 3. 历史表现（响应速度、可靠性等）
    peerScore := s.p2p.Peers().Scorers().Score(pid)
    score += peerScore
    
    return score
}
```

### 8.5.3 重新握手机制

```go
// beacon-chain/sync/rpc_status.go

const (
    // 重新握手间隔
    reStatusInterval = 5 * time.Minute
)

// startReStatusPolling 启动定期重新握手
func (s *Service) startReStatusPolling() {
    ticker := time.NewTicker(reStatusInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            s.reStatusPeers()
        case <-s.ctx.Done():
            return
        }
    }
}

// reStatusPeers 对所有peers重新发送Status
func (s *Service) reStatusPeers() {
    peers := s.p2p.Peers().Connected()
    
    for _, pid := range peers {
        go func(p peer.ID) {
            ctx, cancel := context.WithTimeout(
                context.Background(),
                respTimeout,
            )
            defer cancel()
            
            if err := s.p2p.SendStatusRequest(ctx, p); err != nil {
                log.WithError(err).WithField(
                    "peer", p.String(),
                ).Debug("ReStatus failed")
            }
        }(pid)
    }
}
```

---

## 8.6 完整示例

### 8.6.1 节点启动时的Status交换

```go
// beacon-chain/sync/service.go

func (s *Service) Start() {
    // 启动Status轮询
    go s.startReStatusPolling()
    
    // 对已连接的peers发送Status
    s.initialStatusExchange()
}

func (s *Service) initialStatusExchange() {
    peers := s.p2p.Peers().Connected()
    
    log.WithField("peers", len(peers)).
        Info("Starting initial status exchange")
    
    for _, pid := range peers {
        go func(p peer.ID) {
            ctx, cancel := context.WithTimeout(
                context.Background(),
                respTimeout,
            )
            defer cancel()
            
            if err := s.p2p.SendStatusRequest(ctx, p); err != nil {
                log.WithError(err).
                    WithField("peer", p.String()).
                    Debug("Initial status failed")
                return
            }
            
            // 根据peer状态决定是否同步
            state, err := s.p2p.Peers().ChainState(p)
            if err != nil {
                return
            }
            
            if s.shouldStartInitialSync(state) {
                s.initialSync.Resync()
            }
        }(pid)
    }
}
```

### 8.6.2 新peer连接时的处理

```go
// beacon-chain/p2p/service.go

// 监听新连接
func (s *Service) connectivityHandler(
    ctx context.Context,
) {
    // 订阅连接事件
    notifee := &network.NotifyBundle{
        ConnectedF: func(net network.Network, conn network.Conn) {
            // 新peer连接
            peerID := conn.RemotePeer()
            
            // 异步发送Status
            go func() {
                ctx, cancel := context.WithTimeout(
                    context.Background(),
                    respTimeout,
                )
                defer cancel()
                
                if err := s.SendStatusRequest(ctx, peerID); err != nil {
                    log.WithError(err).
                        Debug("Status exchange failed")
                    
                    // 握手失败，断开连接
                    s.host.Network().ClosePeer(peerID)
                }
            }()
        },
    }
    
    s.host.Network().Notify(notifee)
}
```

---

## 本章小结

本章详细介绍了Status协议：

✅ **握手流程** - 双向Status交换机制
✅ **消息结构** - ForkDigest、Finalized、Head状态
✅ **验证断开** - 验证规则和断开原因
✅ **代码实现** - 完整的发送和处理逻辑
✅ **同步决策** - 基于Status的同步策略
✅ **Peer管理** - 状态存储和Peer选择

Status协议是Beacon Chain P2P通信的基础，正确实现Status握手对节点互操作性至关重要。

---

**相关章节**：
- [第7章：Req/Resp协议基础](./chapter_07_reqresp_basics.md)
- [第9章：BeaconBlocksByRange](./chapter_09_blocks_by_range.md)
- [第12章：其他Req/Resp协议](./chapter_12_other_reqresp.md)
