# 第18章 Full Sync实现

## 18.1 同步流程详解

### 18.1.1 整体架构

Full Sync通过Initial Sync Service实现，核心流程包括：

```
┌─────────────────────────────────────────────────────────┐
│              Initial Sync Service                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. 查找同步Peers         ┌──────────────┐             │
│  ┌──────────────────┐    │              │             │
│  │ findBestPeers()  │───>│  Peer Pool   │             │
│  └──────────────────┘    └──────────────┘             │
│           │                                              │
│           ↓                                              │
│  2. 批量下载区块          ┌──────────────┐             │
│  ┌──────────────────┐    │   Fetcher    │             │
│  │ fetchBlocks()    │───>│   (Batch)    │             │
│  └──────────────────┘    └──────────────┘             │
│           │                                              │
│           ↓                                              │
│  3. 验证处理              ┌──────────────┐             │
│  ┌──────────────────┐    │   Verifier   │             │
│  │ processBlocks()  │───>│  (Pipeline)  │             │
│  └──────────────────┘    └──────────────┘             │
│           │                                              │
│           ↓                                              │
│  4. 状态更新              ┌──────────────┐             │
│  ┌──────────────────┐    │  Blockchain  │             │
│  │ updateState()    │───>│   Service    │             │
│  └──────────────────┘    └──────────────┘             │
└─────────────────────────────────────────────────────────┘
```

### 18.1.2 查找同步Peers

```go
// 来自prysm/beacon-chain/sync/initial-sync/service.go
func (s *Service) findBestPeers() []peer.ID {
    // 1. 获取所有已连接peers
    connectedPeers := s.p2p.Peers().Connected()
    
    // 2. 过滤出状态合适的peers
    suitablePeers := make([]peer.ID, 0)
    for _, pid := range connectedPeers {
        peerChainState, err := s.p2p.Peers().ChainState(pid)
        if err != nil {
            continue
        }
        
        // Peer的finalized epoch必须高于本地
        if peerChainState.FinalizedEpoch > s.chain.FinalizedCheckpt().Epoch {
            suitablePeers = append(suitablePeers, pid)
        }
    }
    
    // 3. 按finalized epoch排序，选择最好的peers
    sort.Slice(suitablePeers, func(i, j int) bool {
        stateI, _ := s.p2p.Peers().ChainState(suitablePeers[i])
        stateJ, _ := s.p2p.Peers().ChainState(suitablePeers[j])
        return stateI.FinalizedEpoch > stateJ.FinalizedEpoch
    })
    
    // 4. 返回top N个peers
    if len(suitablePeers) > params.BeaconConfig().MaxPeersToSync {
        suitablePeers = suitablePeers[:params.BeaconConfig().MaxPeersToSync]
    }
    
    return suitablePeers
}
```

### 18.1.3 确定同步起始点

```go
func (s *Service) determineStartSlot() primitives.Slot {
    // 1. 获取本地head slot
    headSlot := s.chain.HeadSlot()
    
    // 2. 如果是全新节点，从创世块开始
    if headSlot == 0 {
        return primitives.Slot(0)
    }
    
    // 3. 如果有数据，从head的下一个slot开始
    return headSlot + 1
}
```

### 18.1.4 批量下载区块

```go
func (s *Service) fetchBlocksInBatch(
    ctx context.Context,
    startSlot primitives.Slot,
    count uint64,
    peers []peer.ID,
) ([]interfaces.SignedBeaconBlock, error) {
    // 构造请求
    req := &pb.BeaconBlocksByRangeRequest{
        StartSlot: startSlot,
        Count:     count,
        Step:      1, // 必须为1
    }
    
    // 轮询peers请求
    for _, pid := range peers {
        blocks, err := s.requestBlocksFromPeer(ctx, pid, req)
        if err != nil {
            log.WithError(err).WithField("peer", pid).Warn("Failed to fetch blocks")
            continue
        }
        
        // 验证block顺序
        if err := s.validateBlockSequence(blocks, startSlot); err != nil {
            log.WithError(err).Warn("Invalid block sequence")
            continue
        }
        
        return blocks, nil
    }
    
    return nil, errors.New("failed to fetch blocks from any peer")
}
```

### 18.1.5 区块验证与处理

```go
func (s *Service) processBlocks(
    ctx context.Context,
    blocks []interfaces.SignedBeaconBlock,
) error {
    for _, block := range blocks {
        // 1. 基本验证
        if err := s.validateBlock(block); err != nil {
            return errors.Wrap(err, "block validation failed")
        }
        
        // 2. 签名验证（可选择性跳过以提速）
        if !s.cfg.SkipBLSVerify {
            if err := s.verifyBlockSignature(block); err != nil {
                return errors.Wrap(err, "signature verification failed")
            }
        }
        
        // 3. 提交给blockchain service处理
        blockRoot, err := block.Block().HashTreeRoot()
        if err != nil {
            return err
        }
        
        if err := s.chain.ReceiveBlock(ctx, block, blockRoot); err != nil {
            return errors.Wrap(err, "failed to process block")
        }
        
        // 4. 更新进度
        s.updateSyncProgress(block.Block().Slot())
    }
    
    return nil
}
```

### 18.1.6 状态转换

```go
// Blockchain service中的状态转换
func (s *Service) onBlock(
    ctx context.Context,
    signed interfaces.SignedBeaconBlock,
) error {
    // 1. 获取父状态
    parentRoot := signed.Block().ParentRoot()
    preState, err := s.cfg.StateGen.StateByRoot(ctx, parentRoot)
    if err != nil {
        return err
    }
    
    // 2. 执行状态转换
    postState, err := transition.ExecuteStateTransition(
        ctx,
        preState,
        signed,
    )
    if err != nil {
        return err
    }
    
    // 3. 保存状态
    blockRoot, err := signed.Block().HashTreeRoot()
    if err != nil {
        return err
    }
    
    if err := s.cfg.StateGen.SaveState(ctx, blockRoot, postState); err != nil {
        return err
    }
    
    // 4. 更新fork choice
    return s.updateForkChoice(ctx, signed, postState)
}
```

---

## 18.2 Round-Robin策略

### 18.2.1 策略原理

Round-Robin策略将同步任务分配给多个peers，避免单个peer成为瓶颈：

```
Batch 1: Peer A (slots 1000-1063)
Batch 2: Peer B (slots 1064-1127)
Batch 3: Peer C (slots 1128-1191)
Batch 4: Peer A (slots 1192-1255)  <-- 轮回到Peer A
Batch 5: Peer B (slots 1256-1319)
...
```

### 18.2.2 实现代码

```go
// 来自prysm/beacon-chain/sync/initial-sync/round_robin.go
type roundRobinSync struct {
    ctx          context.Context
    cfg          *config
    peers        []peer.ID
    currentIndex int
    batchSize    uint64
}

func (r *roundRobinSync) sync(startSlot primitives.Slot) error {
    currentSlot := startSlot
    targetSlot := r.cfg.Chain.CurrentSlot()
    
    for currentSlot < targetSlot {
        // 1. 选择下一个peer（round-robin）
        peer := r.getNextPeer()
        
        // 2. 计算这一批要同步的slot范围
        remainingSlots := uint64(targetSlot - currentSlot)
        count := r.batchSize
        if count > remainingSlots {
            count = remainingSlots
        }
        
        // 3. 从peer获取blocks
        blocks, err := r.fetchBatch(peer, currentSlot, count)
        if err != nil {
            log.WithError(err).WithField("peer", peer).Warn("Batch fetch failed")
            r.handlePeerFailure(peer)
            continue
        }
        
        // 4. 处理blocks
        if err := r.processBlocks(blocks); err != nil {
            return err
        }
        
        // 5. 更新进度
        currentSlot += primitives.Slot(len(blocks))
        r.reportProgress(currentSlot, targetSlot)
    }
    
    return nil
}

func (r *roundRobinSync) getNextPeer() peer.ID {
    peer := r.peers[r.currentIndex]
    r.currentIndex = (r.currentIndex + 1) % len(r.peers)
    return peer
}
```

### 18.2.3 Peer故障处理

```go
func (r *roundRobinSync) handlePeerFailure(pid peer.ID) {
    // 1. 记录失败次数
    failures := r.peerFailures[pid]
    failures++
    r.peerFailures[pid] = failures
    
    // 2. 如果失败次数过多，移除该peer
    if failures >= maxPeerFailures {
        r.removePeer(pid)
        log.WithField("peer", pid).Warn("Peer removed due to repeated failures")
    }
    
    // 3. 如果peers太少，重新查找
    if len(r.peers) < minPeersForSync {
        r.refreshPeerList()
    }
}

func (r *roundRobinSync) removePeer(pid peer.ID) {
    newPeers := make([]peer.ID, 0)
    for _, p := range r.peers {
        if p != pid {
            newPeers = append(newPeers, p)
        }
    }
    r.peers = newPeers
    
    // 调整当前索引
    if r.currentIndex >= len(r.peers) {
        r.currentIndex = 0
    }
}
```

---

## 18.3 性能优化

### 18.3.1 批量大小调优

```go
// 批量大小的权衡
const (
    // 太小：频繁的网络请求，开销大
    minBatchSize = 32
    
    // 太大：单个peer压力大，失败代价高
    maxBatchSize = 256
    
    // 推荐值：在P2P规范限制内的较大值
    defaultBatchSize = 64  // ~12.8分钟的blocks
)

func (s *Service) calculateOptimalBatchSize() uint64 {
    // 根据网络条件动态调整
    avgLatency := s.getAveragePeerLatency()
    
    if avgLatency > 500*time.Millisecond {
        // 高延迟网络，使用较大批量
        return 128
    } else if avgLatency < 100*time.Millisecond {
        // 低延迟网络，可以使用较小批量，更快反馈
        return 32
    }
    
    return defaultBatchSize
}
```

### 18.3.2 并行下载

```go
func (s *Service) parallelFetch(
    startSlot primitives.Slot,
    totalCount uint64,
    peers []peer.ID,
) ([]interfaces.SignedBeaconBlock, error) {
    // 1. 将任务分割给不同peers
    chunkSize := totalCount / uint64(len(peers))
    var wg sync.WaitGroup
    blocksChan := make(chan []interfaces.SignedBeaconBlock, len(peers))
    errChan := make(chan error, len(peers))
    
    // 2. 并发请求
    for i, pid := range peers {
        wg.Add(1)
        go func(index int, peer peer.ID) {
            defer wg.Done()
            
            start := startSlot + primitives.Slot(index*int(chunkSize))
            count := chunkSize
            if index == len(peers)-1 {
                // 最后一个peer处理剩余的
                count = totalCount - uint64(index)*chunkSize
            }
            
            blocks, err := s.fetchBatch(peer, start, count)
            if err != nil {
                errChan <- err
                return
            }
            blocksChan <- blocks
        }(i, pid)
    }
    
    wg.Wait()
    close(blocksChan)
    close(errChan)
    
    // 3. 收集结果
    var allBlocks []interfaces.SignedBeaconBlock
    for blocks := range blocksChan {
        allBlocks = append(allBlocks, blocks...)
    }
    
    // 4. 排序（因为并发可能乱序）
    sort.Slice(allBlocks, func(i, j int) bool {
        return allBlocks[i].Block().Slot() < allBlocks[j].Block().Slot()
    })
    
    return allBlocks, nil
}
```

### 18.3.3 管道处理(Pipelining)

```go
type syncPipeline struct {
    fetchChan   chan *fetchTask
    verifyChan  chan []interfaces.SignedBeaconBlock
    processChan chan []interfaces.SignedBeaconBlock
}

func (s *Service) pipelinedSync(startSlot primitives.Slot) error {
    pipeline := &syncPipeline{
        fetchChan:   make(chan *fetchTask, 10),
        verifyChan:  make(chan []interfaces.SignedBeaconBlock, 10),
        processChan: make(chan []interfaces.SignedBeaconBlock, 10),
    }
    
    // 启动pipeline stages
    go s.fetchStage(pipeline.fetchChan, pipeline.verifyChan)
    go s.verifyStage(pipeline.verifyChan, pipeline.processChan)
    go s.processStage(pipeline.processChan)
    
    // 生成fetch任务
    currentSlot := startSlot
    targetSlot := s.chain.CurrentSlot()
    
    for currentSlot < targetSlot {
        task := &fetchTask{
            startSlot: currentSlot,
            count:     64,
        }
        pipeline.fetchChan <- task
        currentSlot += 64
    }
    
    close(pipeline.fetchChan)
    return nil
}

func (s *Service) fetchStage(
    in <-chan *fetchTask,
    out chan<- []interfaces.SignedBeaconBlock,
) {
    for task := range in {
        blocks, err := s.fetchBatch(task.peer, task.startSlot, task.count)
        if err != nil {
            log.Error(err)
            continue
        }
        out <- blocks
    }
    close(out)
}

func (s *Service) verifyStage(
    in <-chan []interfaces.SignedBeaconBlock,
    out chan<- []interfaces.SignedBeaconBlock,
) {
    for blocks := range in {
        // 批量验证签名
        if err := s.batchVerifySignatures(blocks); err != nil {
            log.Error(err)
            continue
        }
        out <- blocks
    }
    close(out)
}

func (s *Service) processStage(
    in <-chan []interfaces.SignedBeaconBlock,
) {
    for blocks := range in {
        if err := s.processBlocks(context.Background(), blocks); err != nil {
            log.Error(err)
        }
    }
}
```

### 18.3.4 跳过BLS验证（慎用）

```go
// 在initial sync期间可选择性跳过BLS验证以提速
// 注意：只应在从可信peers同步时使用
func (s *Service) fastSync(startSlot primitives.Slot) error {
    // 临时禁用BLS验证
    originalSkipBLS := s.cfg.SkipBLSVerify
    s.cfg.SkipBLSVerify = true
    defer func() {
        s.cfg.SkipBLSVerify = originalSkipBLS
    }()
    
    // 执行快速同步
    return s.sync(startSlot)
}

// 性能对比：
// 启用BLS验证: ~100 blocks/sec
// 跳过BLS验证: ~500-1000 blocks/sec
// 提速: 5-10倍
```

---

## 18.4 代码实现

### 18.4.1 Service结构

```go
// 来自prysm/beacon-chain/sync/initial-sync/service.go
type Service struct {
    ctx    context.Context
    cancel context.CancelFunc
    cfg    *config
    
    // 同步状态
    synced       bool
    syncedLock   sync.RWMutex
    chainStarted bool
    
    // Peer管理
    peers           []peer.ID
    peerLock        sync.RWMutex
    peerFailures    map[peer.ID]int
    
    // 批量配置
    batchSize       uint64
    concurrentPeers int
    
    // 进度跟踪
    startSlot       primitives.Slot
    lastReportedSlot primitives.Slot
    blocksProcessed uint64
}

type config struct {
    P2P                p2p.P2P
    Chain              blockchain.ChainInfoFetcher
    DB                 db.ReadOnlyDatabase
    StateNotifier      statefeed.Notifier
    BlockNotifier      blockfeed.Notifier
    
    // 性能配置
    SkipBLSVerify      bool
    InitialSyncBatchSize uint64
    MaxConcurrentPeers int
}
```

### 18.4.2 主同步循环

```go
func (s *Service) initialSync() error {
    // 1. 初始化
    startSlot := s.determineStartSlot()
    s.startSlot = startSlot
    
    log.WithField("startSlot", startSlot).Info("Starting initial sync")
    
    // 2. 查找peers
    peers := s.findBestPeers()
    if len(peers) == 0 {
        return errors.New("no suitable peers found")
    }
    s.peers = peers
    
    log.WithField("peerCount", len(peers)).Info("Found sync peers")
    
    // 3. 执行round-robin同步
    rr := &roundRobinSync{
        ctx:       s.ctx,
        cfg:       s.cfg,
        peers:     peers,
        batchSize: s.cfg.InitialSyncBatchSize,
    }
    
    if err := rr.sync(startSlot); err != nil {
        return errors.Wrap(err, "round-robin sync failed")
    }
    
    // 4. 标记同步完成
    s.setSynced(true)
    log.Info("Initial sync completed")
    
    return nil
}
```

### 18.4.3 进度报告

```go
func (s *Service) reportProgress(currentSlot, targetSlot primitives.Slot) {
    // 只在达到一定间隔时报告
    if currentSlot-s.lastReportedSlot < 32 {
        return
    }
    
    // 计算进度百分比
    progress := float64(currentSlot-s.startSlot) / float64(targetSlot-s.startSlot) * 100
    
    // 计算ETA
    elapsed := time.Since(s.syncStartTime)
    remaining := time.Duration(float64(elapsed) / progress * (100 - progress))
    
    // 计算速度
    blocksProcessed := currentSlot - s.startSlot
    speed := float64(blocksProcessed) / elapsed.Seconds()
    
    log.WithFields(logrus.Fields{
        "currentSlot":  currentSlot,
        "targetSlot":   targetSlot,
        "progress":     fmt.Sprintf("%.2f%%", progress),
        "speed":        fmt.Sprintf("%.2f blocks/sec", speed),
        "eta":          remaining.Round(time.Second),
    }).Info("Sync progress")
    
    // 更新metrics
    syncEth2FallBehind.Set(float64(targetSlot - currentSlot))
    syncBlocksPerSecond.Set(speed)
    
    s.lastReportedSlot = currentSlot
}
```

---

## 18.5 小结

本章详细分析了Full Sync的实现：

✅ **同步流程**: 从peer发现到区块处理的完整流程
✅ **Round-Robin策略**: 负载均衡的多peer同步
✅ **性能优化**: 批量大小、并行下载、管道处理
✅ **错误处理**: Peer故障检测和恢复机制
✅ **进度跟踪**: 实时监控和报告

Full Sync虽然耗时较长，但提供了最高的安全性和完整性。下一章将介绍更快的Checkpoint Sync。

---

**下一章预告**: 第19章将详细讲解Checkpoint Sync的实现和Backfill机制。
