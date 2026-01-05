# 第25章：错误处理与重试机制

## 25.1 错误分类

在Prysm的同步模块中，错误被分为多种类型，每种类型有不同的处理策略。

### 25.1.1 网络错误

```go
// beacon-chain/sync/rpc_status.go
func (s *Service) reValidatePeer(ctx context.Context, pid peer.ID) error {
    if err := s.sendRPCStatusRequest(ctx, pid); err != nil {
        // 网络错误处理
        if errors.Is(err, context.DeadlineExceeded) {
            log.WithError(err).Debug("Context deadline exceeded")
            s.peers.Scorers().BadResponsesScorer().Increment(pid)
            return err
        }
        if errors.Is(err, io.EOF) {
            log.WithError(err).Debug("EOF from peer")
            s.peers.Scorers().BadResponsesScorer().Increment(pid)
            return err
        }
        return err
    }
    return nil
}
```

### 25.1.2 协议错误

```go
// beacon-chain/sync/validate_beacon_blocks.go
func (s *Service) validateBeaconBlockPubSub(ctx context.Context, pid peer.ID, msg *pubsub.Message) pubsub.ValidationResult {
    // 解码错误
    m, err := s.decodePubsubMessage(msg)
    if err != nil {
        log.WithError(err).Debug("Could not decode message")
        return pubsub.ValidationReject
    }
    
    // 协议验证错误
    if err := s.validateBeaconBlock(ctx, m, pid); err != nil {
        if errors.Is(err, errBlockAlreadyExists) {
            return pubsub.ValidationIgnore
        }
        if errors.Is(err, errInvalidBlock) {
            return pubsub.ValidationReject
        }
        return pubsub.ValidationIgnore
    }
    
    return pubsub.ValidationAccept
}
```

### 25.1.3 数据验证错误

```go
// beacon-chain/blockchain/process_block.go
func (s *Service) onBlock(ctx context.Context, signed interfaces.ReadOnlySignedBeaconBlock, blockRoot [32]byte) error {
    // 状态转换错误
    preState, err := s.getBlockPreState(ctx, signed.Block())
    if err != nil {
        return errors.Wrap(err, "could not get pre state")
    }
    
    // 执行状态转换
    postState, err := transition.ExecuteStateTransition(ctx, preState, signed)
    if err != nil {
        // 记录验证失败
        s.setBadBlock(ctx, blockRoot)
        return errors.Wrap(err, "could not execute state transition")
    }
    
    return nil
}
```

## 25.2 重试策略

### 25.2.1 指数退避重试

```go
// beacon-chain/sync/initial-sync/blocks_fetcher.go
type blocksFetcher struct {
    ctx               context.Context
    p2p               p2p.P2P
    chain             blockchainService
    db                db.ReadOnlyDatabase
    peerFilterCapacity int
    mode              syncMode
}

func (f *blocksFetcher) requestBlocks(ctx context.Context, req *p2ppb.BeaconBlocksByRangeRequest, pid peer.ID) ([]*ethpb.SignedBeaconBlock, error) {
    // 重试配置
    const (
        maxRetries = 5
        baseDelay  = 100 * time.Millisecond
        maxDelay   = 5 * time.Second
    )
    
    var lastErr error
    for attempt := 0; attempt < maxRetries; attempt++ {
        // 计算退避时间
        delay := baseDelay * time.Duration(1<<uint(attempt))
        if delay > maxDelay {
            delay = maxDelay
        }
        
        // 执行请求
        blocks, err := f.p2p.Sender().SendBeaconBlocksByRangeRequest(ctx, req, pid)
        if err == nil {
            return blocks, nil
        }
        
        lastErr = err
        
        // 判断是否应该重试
        if !shouldRetry(err) {
            break
        }
        
        // 等待后重试
        if attempt < maxRetries-1 {
            time.Sleep(delay)
        }
    }
    
    return nil, lastErr
}

func shouldRetry(err error) bool {
    // 判断错误类型是否应该重试
    if errors.Is(err, context.Canceled) {
        return false
    }
    if errors.Is(err, context.DeadlineExceeded) {
        return true
    }
    if isNetworkError(err) {
        return true
    }
    return false
}
```

### 25.2.2 请求超时处理

```go
// beacon-chain/sync/rpc_beacon_blocks_by_range.go
const (
    // 请求超时配置
    ttfbTimeout         = 5 * time.Second  // Time to first byte
    respTimeout         = 10 * time.Second // Response timeout
    maxRequestBlocks    = 1024             // 最大请求块数
)

func (s *Service) sendBeaconBlocksByRangeRequest(
    ctx context.Context,
    pid peer.ID,
    req *p2ppb.BeaconBlocksByRangeRequest) ([]*ethpb.SignedBeaconBlock, error) {
    
    // 创建带超时的上下文
    ctx, cancel := context.WithTimeout(ctx, respTimeout)
    defer cancel()
    
    // 发送请求
    stream, err := s.p2p.Send(ctx, req, p2p.RPCBlocksByRangeTopic, pid)
    if err != nil {
        return nil, err
    }
    defer stream.Close()
    
    // 设置读取超时
    stream.SetReadDeadline(time.Now().Add(ttfbTimeout))
    
    blocks := make([]*ethpb.SignedBeaconBlock, 0, req.Count)
    
    for i := uint64(0); i < req.Count; i++ {
        // 重置超时时间
        stream.SetReadDeadline(time.Now().Add(respTimeout))
        
        // 读取响应
        blk := &ethpb.SignedBeaconBlock{}
        if err := stream.ReadMsg(blk); err != nil {
            if err == io.EOF {
                break
            }
            return nil, err
        }
        
        blocks = append(blocks, blk)
    }
    
    return blocks, nil
}
```

## 25.3 Peer惩罚机制

### 25.3.1 评分系统

```go
// beacon-chain/p2p/peers/scorers/bad_responses.go
type BadResponsesScorer struct {
    ctx    context.Context
    store  *peerDataStore
    params *BadResponsesScorerConfig
}

type BadResponsesScorerConfig struct {
    // 阈值配置
    Threshold     float64       // 被断开连接的阈值
    DecayInterval time.Duration // 衰减间隔
    DecayFactor   float64       // 衰减因子
}

func (s *BadResponsesScorer) Score(pid peer.ID) float64 {
    s.store.RLock()
    defer s.store.RUnlock()
    
    peerData, ok := s.store.PeerData(pid)
    if !ok {
        return 0
    }
    
    // 计算时间衰减
    elapsed := time.Since(peerData.BadResponsesLastUpdate)
    decayPeriods := int(elapsed / s.params.DecayInterval)
    
    score := peerData.BadResponses
    for i := 0; i < decayPeriods; i++ {
        score *= s.params.DecayFactor
    }
    
    return score
}

func (s *BadResponsesScorer) Increment(pid peer.ID) {
    s.store.Lock()
    defer s.store.Unlock()
    
    peerData := s.store.PeerData(pid)
    peerData.BadResponses++
    peerData.BadResponsesLastUpdate = time.Now()
    
    // 检查是否超过阈值
    if s.Score(pid) >= s.params.Threshold {
        s.store.SetConnectionState(pid, peers.PeerDisconnecting)
        log.WithField("peer", pid).Debug("Peer score exceeded threshold, disconnecting")
    }
}
```

### 25.3.2 Peer黑名单

```go
// beacon-chain/p2p/peers/status.go
type Status struct {
    ctx   context.Context
    store *peerDataStore
    ipTracker *ipTracker
}

func (p *Status) Add(
    pid peer.ID,
    chainState *p2ppb.Status,
    direction network.Direction) {
    
    p.store.Lock()
    defer p.store.Unlock()
    
    // 检查IP黑名单
    addr := p.store.Address(pid)
    if p.ipTracker.IsBanned(addr) {
        log.WithField("peer", pid).Debug("Peer is banned by IP")
        p.store.SetConnectionState(pid, peers.PeerDisconnected)
        return
    }
    
    // 更新peer状态
    peerData := p.store.PeerData(pid)
    peerData.ChainState = chainState
    peerData.ChainStateLastUpdated = time.Now()
    peerData.Direction = direction
}

// IP追踪器
type ipTracker struct {
    bannedIPs map[string]time.Time
    mu        sync.RWMutex
}

func (t *ipTracker) BanIP(ip string, duration time.Duration) {
    t.mu.Lock()
    defer t.mu.Unlock()
    
    t.bannedIPs[ip] = time.Now().Add(duration)
}

func (t *ipTracker) IsBanned(ip string) bool {
    t.mu.RLock()
    defer t.mu.RUnlock()
    
    banTime, exists := t.bannedIPs[ip]
    if !exists {
        return false
    }
    
    if time.Now().After(banTime) {
        delete(t.bannedIPs, ip)
        return false
    }
    
    return true
}
```

## 25.4 数据恢复机制

### 25.4.1 缺失区块恢复

```go
// beacon-chain/sync/pending_blocks_queue.go
type pendingBlocksQueue struct {
    ctx             context.Context
    chain           blockchainService
    pendingSlots    map[types.Slot][32]byte
    seenPendingBlocks map[[32]byte]bool
    slotMap         map[[32]byte]types.Slot
    chainStarted    bool
}

func (q *pendingBlocksQueue) handlePendingBlocks(ctx context.Context) {
    ticker := time.NewTicker(1 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            // 检查待处理的区块
            q.processPendingBlocks(ctx)
        }
    }
}

func (q *pendingBlocksQueue) processPendingBlocks(ctx context.Context) {
    headSlot := q.chain.HeadSlot()
    
    for slot := headSlot + 1; slot <= headSlot+64; slot++ {
        root, exists := q.pendingSlots[slot]
        if !exists {
            continue
        }
        
        // 检查是否已处理
        if q.seenPendingBlocks[root] {
            continue
        }
        
        // 尝试从数据库加载
        if q.chain.HasBlock(ctx, root) {
            block, err := q.chain.GetBlock(ctx, root)
            if err != nil {
                log.WithError(err).Debug("Could not retrieve pending block")
                continue
            }
            
            // 处理区块
            if err := q.chain.ReceiveBlock(ctx, block, root); err != nil {
                log.WithError(err).Debug("Could not process pending block")
                continue
            }
            
            q.seenPendingBlocks[root] = true
            delete(q.pendingSlots, slot)
        }
    }
}
```

### 25.4.2 状态重建

```go
// beacon-chain/db/kv/state.go
func (s *Store) RecoverState(ctx context.Context, slot types.Slot) (state.BeaconState, error) {
    // 1. 查找最近的检查点状态
    checkpointSlot := slot - (slot % params.BeaconConfig().SlotsPerEpoch)
    st, err := s.State(ctx, bytesutil.ToBytes32([]byte{byte(checkpointSlot)}))
    if err != nil {
        return nil, errors.Wrap(err, "could not get checkpoint state")
    }
    
    // 2. 加载从检查点到目标slot的所有区块
    blocks := make([]interfaces.ReadOnlySignedBeaconBlock, 0)
    for i := checkpointSlot; i <= slot; i++ {
        roots, err := s.BlockRootsBySlot(ctx, i)
        if err != nil {
            return nil, err
        }
        
        for _, root := range roots {
            block, err := s.Block(ctx, root)
            if err != nil {
                return nil, err
            }
            blocks = append(blocks, block)
        }
    }
    
    // 3. 重放区块以重建状态
    for _, block := range blocks {
        st, err = transition.ExecuteStateTransition(ctx, st, block)
        if err != nil {
            return nil, errors.Wrap(err, "could not execute state transition")
        }
    }
    
    return st, nil
}
```

## 25.5 故障检测

### 25.5.1 同步卡死检测

```go
// beacon-chain/sync/initial-sync/service.go
type Service struct {
    ctx                 context.Context
    chain               blockchainService
    blockNotifier       blockchainService
    p2p                 p2p.P2P
    db                  db.ReadOnlyDatabase
    stateGen            *stategen.State
    blocksFetcher       *blocksFetcher
    lastProcessedSlot   types.Slot
    lastProgressTime    time.Time
    stuckThreshold      time.Duration
}

func (s *Service) monitorSyncProgress(ctx context.Context) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            currentSlot := s.chain.HeadSlot()
            
            // 检查进度
            if currentSlot == s.lastProcessedSlot {
                // 没有进度
                elapsed := time.Since(s.lastProgressTime)
                if elapsed > s.stuckThreshold {
                    log.WithFields(logrus.Fields{
                        "slot":    currentSlot,
                        "elapsed": elapsed,
                    }).Warn("Sync appears to be stuck")
                    
                    // 采取恢复措施
                    s.handleStuckSync(ctx)
                }
            } else {
                // 有进度，更新记录
                s.lastProcessedSlot = currentSlot
                s.lastProgressTime = time.Now()
            }
        }
    }
}

func (s *Service) handleStuckSync(ctx context.Context) {
    // 1. 清理错误的peer连接
    s.p2p.Peers().Prune()
    
    // 2. 重置同步状态
    s.blocksFetcher.reset()
    
    // 3. 尝试连接新的peer
    s.p2p.FindPeersWithSubnet(ctx, "", 0, 10)
    
    log.Info("Attempted to recover from stuck sync")
}
```

### 25.5.2 网络分区检测

```go
// beacon-chain/sync/subscriber.go
func (s *Service) detectNetworkPartition(ctx context.Context) {
    ticker := time.NewTicker(5 * time.Minute)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            // 检查peer数量
            peerCount := s.p2p.Peers().Connected().Len()
            if peerCount < minPeerThreshold {
                log.WithField("peers", peerCount).Warn("Low peer count, possible network partition")
            }
            
            // 检查链是否在增长
            headSlot := s.chain.HeadSlot()
            currentTime := time.Now()
            expectedSlot := slots.Since(s.chain.GenesisTime())
            
            slotDiff := expectedSlot - headSlot
            if slotDiff > 10 {
                log.WithFields(logrus.Fields{
                    "headSlot":     headSlot,
                    "expectedSlot": expectedSlot,
                    "difference":   slotDiff,
                }).Warn("Chain not advancing, possible network partition")
                
                // 尝试重新连接peers
                s.reconnectPeers(ctx)
            }
        }
    }
}

func (s *Service) reconnectPeers(ctx context.Context) {
    // 断开表现不好的peers
    for _, pid := range s.p2p.Peers().Connected() {
        score := s.p2p.Peers().Scorers().Score(pid)
        if score < -50 {
            s.p2p.Peers().SetConnectionState(pid, peers.PeerDisconnecting)
        }
    }
    
    // 尝试连接新的peers
    s.p2p.FindPeersWithSubnet(ctx, "", 0, 20)
}
```

## 25.6 降级策略

### 25.6.1 同步模式降级

```go
// beacon-chain/sync/initial-sync/service.go
func (s *Service) handleSyncModeDowngrade(ctx context.Context) error {
    // 检查当前同步模式
    if s.mode == modeCheckpoint {
        // Checkpoint sync失败，降级到full sync
        log.Warn("Checkpoint sync failed, downgrading to full sync")
        s.mode = modeFull
        return s.startFullSync(ctx)
    }
    
    if s.mode == modeFull {
        // Full sync遇到问题，尝试重新获取checkpoint
        log.Warn("Full sync having issues, attempting checkpoint sync")
        if checkpoint := s.getCheckpointFromPeers(ctx); checkpoint != nil {
            s.mode = modeCheckpoint
            return s.startCheckpointSync(ctx, checkpoint)
        }
    }
    
    return nil
}
```

### 25.6.2 资源限制降级

```go
// beacon-chain/sync/rate_limiter.go
type rateLimiter struct {
    globalQuota    int64
    perPeerQuota   int64
    currentUsage   int64
    peerUsage      map[peer.ID]int64
    mu             sync.RWMutex
    degraded       bool
}

func (r *rateLimiter) checkResourcePressure() {
    r.mu.Lock()
    defer r.mu.Unlock()
    
    usagePercent := float64(r.currentUsage) / float64(r.globalQuota) * 100
    
    if usagePercent > 80 && !r.degraded {
        // 进入降级模式
        r.degraded = true
        r.perPeerQuota = r.perPeerQuota / 2
        log.Warn("Entering degraded mode due to resource pressure")
    } else if usagePercent < 50 && r.degraded {
        // 恢复正常模式
        r.degraded = false
        r.perPeerQuota = r.perPeerQuota * 2
        log.Info("Exiting degraded mode")
    }
}
```

这一章详细介绍了Prysm中的错误处理、重试机制、peer惩罚、数据恢复、故障检测和降级策略。每个部分都包含了实际的代码实现，展示了如何构建一个健壮的同步系统。
