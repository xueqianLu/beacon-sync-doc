# 第9章 BeaconBlocksByRange协议

## 9.1 协议定义

### 9.1.1 协议概述

**BeaconBlocksByRange** 是Initial Sync期间最重要的协议，用于批量获取指定范围内的区块。

**协议标识符**：
```
v1: /eth2/beacon_chain/req/beacon_blocks_by_range/1/ssz_snappy
v2: /eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy
```

**主要用途**：
- Initial Sync：从创世块到当前头部
- Backfill：补充历史区块
- Fork选择：获取分叉点后的区块

**特点**：
- 批量请求：一次可请求多个区块
- 流式响应：分块返回，节省内存
- 按slot顺序：保证区块顺序性
- 跳过空slot：不返回空slot数据

### 9.1.2 请求消息

```go
// proto/prysm/v1alpha1/p2p.proto
message BeaconBlocksByRangeRequest {
    // 起始slot（包含）
    uint64 start_slot = 1;
    
    // 请求数量
    uint64 count = 2;
    
    // 步长（通常为1）
    uint64 step = 3;
}
```

**参数说明**：

| 字段 | 类型 | 说明 | 限制 |
|------|------|------|------|
| start_slot | uint64 | 起始slot号 | ≥ 0 |
| count | uint64 | 请求区块数量 | ≤ MAX_REQUEST_BLOCKS (1024) |
| step | uint64 | slot步长 | 通常为1 |

**slot范围计算**：
```
请求的slot范围：
[start_slot, start_slot + count * step)

示例：
start_slot=100, count=5, step=1
→ 请求 slots: 100, 101, 102, 103, 104

start_slot=100, count=5, step=2
→ 请求 slots: 100, 102, 104, 106, 108
```

### 9.1.3 响应消息

**响应格式**：流式返回多个区块

```go
// v2版本支持所有分叉
type SignedBeaconBlock interface {
    Block() BeaconBlock
    Signature() []byte
}

响应序列：
┌──────────────────┐
│  区块1 (SSZ)     │
├──────────────────┤
│  区块2 (SSZ)     │
├──────────────────┤
│  区块3 (SSZ)     │
├──────────────────┤
│  ...             │
└──────────────────┘
每个区块单独编码（SSZ+Snappy+长度前缀）
```

**响应规则**：
```
1. 只返回非空slot的区块
2. 按slot升序返回
3. 最多返回count个区块
4. 如果某个slot不存在，跳过
5. 所有区块发送完毕后关闭stream
```

---

## 9.2 请求参数验证

### 9.2.1 验证规则

```go
// beacon-chain/sync/rpc_beacon_blocks_by_range.go

const (
    // 最大请求数量
    maxRequestBlocks = 1024
    
    // 最小步长
    minStep = 1
)

// validateRangeRequest 验证请求参数
func (s *Service) validateRangeRequest(
    req *pb.BeaconBlocksByRangeRequest,
) error {
    // 1. 检查count
    if req.Count == 0 {
        return errors.New("count must be greater than 0")
    }
    if req.Count > maxRequestBlocks {
        return fmt.Errorf(
            "count %d exceeds maximum %d",
            req.Count,
            maxRequestBlocks,
        )
    }
    
    // 2. 检查step
    if req.Step == 0 {
        return errors.New("step must be greater than 0")
    }
    if req.Step < minStep {
        return fmt.Errorf(
            "step %d is less than minimum %d",
            req.Step,
            minStep,
        )
    }
    
    // 3. 检查slot范围
    endSlot := req.StartSlot + (req.Count-1)*req.Step
    currentSlot := s.chain.CurrentSlot()
    if endSlot > currentSlot {
        return fmt.Errorf(
            "end slot %d exceeds current slot %d",
            endSlot,
            currentSlot,
        )
    }
    
    // 4. 检查是否超过weak subjectivity period
    // （防止长距离攻击）
    if s.cfg.P2P.EnableWeakSubjectivityCheck {
        finalizedEpoch := s.chain.FinalizedCheckpt().Epoch
        wsCheckpoint := s.weakSubjectivityCheckpoint()
        
        startEpoch := slots.ToEpoch(req.StartSlot)
        if startEpoch < wsCheckpoint.Epoch && 
           startEpoch < finalizedEpoch-params.BeaconConfig().WeakSubjectivityPeriod {
            return errors.New("request before weak subjectivity period")
        }
    }
    
    return nil
}
```

### 9.2.2 速率限制

```go
// beacon-chain/p2p/ratelimiter.go

// RateLimiter 速率限制器
type RateLimiter struct {
    limiter *leakybucket.Limiter
}

// 每个peer的速率限制
const (
    // 每秒最多的请求数
    requestsPerSecond = 5
    
    // burst大小
    burstSize = 10
    
    // 惩罚时间
    penaltyDuration = 1 * time.Minute
)

// allowRequest 检查是否允许请求
func (r *RateLimiter) allowRequest(
    peerID peer.ID,
    protocol string,
) bool {
    key := peerID.String() + ":" + protocol
    
    // 检查速率
    return r.limiter.Allow(key, requestsPerSecond, burstSize)
}

// penalize 惩罚peer
func (r *RateLimiter) penalize(peerID peer.ID) {
    // 暂时禁止该peer的所有请求
    r.limiter.Block(peerID.String(), penaltyDuration)
}
```

---

## 9.3 响应处理

### 9.3.1 请求处理器

```go
// beacon-chain/sync/rpc_beacon_blocks_by_range.go

// beaconBlocksByRangeRPCHandler 处理BeaconBlocksByRange请求
func (s *Service) beaconBlocksByRangeRPCHandler(
    ctx context.Context,
    msg interface{},
    stream libp2pcore.Stream,
) error {
    ctx, cancel := context.WithTimeout(ctx, respTimeout)
    defer cancel()
    
    peerID := stream.Conn().RemotePeer()
    
    // 1. 解析请求
    req, ok := msg.(*pb.BeaconBlocksByRangeRequest)
    if !ok {
        return WriteErrorResponseToStream(
            ResponseCodeInvalidRequest,
            "invalid request type",
            stream,
        )
    }
    
    // 2. 验证请求
    if err := s.validateRangeRequest(req); err != nil {
        return WriteErrorResponseToStream(
            ResponseCodeInvalidRequest,
            err.Error(),
            stream,
        )
    }
    
    // 3. 速率限制
    if !s.rateLimiter.allowRequest(
        peerID,
        stream.Protocol(),
    ) {
        return WriteErrorResponseToStream(
            ResponseCodeRateLimited,
            "rate limit exceeded",
            stream,
        )
    }
    
    // 4. 获取并发送区块
    return s.sendBlocksByRange(ctx, req, stream)
}
```

### 9.3.2 区块获取和发送

```go
// sendBlocksByRange 发送指定范围的区块
func (s *Service) sendBlocksByRange(
    ctx context.Context,
    req *pb.BeaconBlocksByRangeRequest,
    stream network.Stream,
) error {
    // 计算结束slot
    endSlot := req.StartSlot + (req.Count-1)*req.Step
    
    // 记录日志
    log.WithFields(logrus.Fields{
        "peer":      stream.Conn().RemotePeer().String(),
        "startSlot": req.StartSlot,
        "count":     req.Count,
        "step":      req.Step,
        "endSlot":   endSlot,
    }).Debug("Processing blocks by range request")
    
    // 计数器
    sentCount := uint64(0)
    
    // 遍历slot范围
    for slot := req.StartSlot; slot <= endSlot; slot += req.Step {
        // 检查上下文
        if err := ctx.Err(); err != nil {
            return err
        }
        
        // 检查是否已发送足够数量
        if sentCount >= req.Count {
            break
        }
        
        // 获取区块
        block, err := s.chain.BlockBySlot(ctx, primitives.Slot(slot))
        if err != nil {
            if errors.Is(err, db.ErrNotFound) {
                // 空slot，跳过
                continue
            }
            // 其他错误
            log.WithError(err).Error("Failed to get block")
            return WriteErrorResponseToStream(
                ResponseCodeServerError,
                "failed to retrieve block",
                stream,
            )
        }
        
        // 发送区块
        if err := s.sendBlock(ctx, block, stream); err != nil {
            return err
        }
        
        sentCount++
    }
    
    log.WithFields(logrus.Fields{
        "peer":      stream.Conn().RemotePeer().String(),
        "sentCount": sentCount,
    }).Debug("Completed blocks by range request")
    
    return nil
}

// sendBlock 发送单个区块
func (s *Service) sendBlock(
    ctx context.Context,
    block interfaces.ReadOnlySignedBeaconBlock,
    stream network.Stream,
) error {
    // 编码并发送
    if _, err := s.cfg.P2P.Encoding().EncodeWithMaxLength(
        stream,
        block,
    ); err != nil {
        return err
    }
    
    return nil
}
```

### 9.3.3 接收响应

```go
// beacon-chain/sync/rpc_send_request.go

// sendBeaconBlocksByRangeRequest 发送请求并处理响应
func (s *Service) sendBeaconBlocksByRangeRequest(
    ctx context.Context,
    req *pb.BeaconBlocksByRangeRequest,
    peerID peer.ID,
) ([]interfaces.ReadOnlySignedBeaconBlock, error) {
    
    // 1. 打开stream
    stream, err := s.cfg.P2P.Host().NewStream(
        ctx,
        peerID,
        s.blocksByRangeProtocol(),
    )
    if err != nil {
        return nil, err
    }
    defer stream.Close()
    
    // 2. 设置超时
    deadline := time.Now().Add(respTimeout)
    if err := stream.SetDeadline(deadline); err != nil {
        return nil, err
    }
    
    // 3. 发送请求
    if _, err := s.cfg.P2P.Encoding().EncodeWithMaxLength(
        stream,
        req,
    ); err != nil {
        return nil, err
    }
    
    // 4. 关闭写端
    if err := stream.CloseWrite(); err != nil {
        return nil, err
    }
    
    // 5. 接收响应
    blocks, err := s.readBlocksByRangeResponse(ctx, stream, req)
    if err != nil {
        return nil, err
    }
    
    return blocks, nil
}

// readBlocksByRangeResponse 读取响应区块
func (s *Service) readBlocksByRangeResponse(
    ctx context.Context,
    stream network.Stream,
    req *pb.BeaconBlocksByRangeRequest,
) ([]interfaces.ReadOnlySignedBeaconBlock, error) {
    
    var blocks []interfaces.ReadOnlySignedBeaconBlock
    
    // 流式读取区块
    for {
        // 检查上下文
        if err := ctx.Err(); err != nil {
            return nil, err
        }
        
        // 检查数量限制
        if uint64(len(blocks)) >= req.Count {
            break
        }
        
        // 读取一个区块
        block, err := s.readBlock(stream)
        if err != nil {
            if errors.Is(err, io.EOF) {
                // 正常结束
                break
            }
            return nil, err
        }
        
        // 验证区块
        if err := s.validateReceivedBlock(block, req, blocks); err != nil {
            return nil, err
        }
        
        blocks = append(blocks, block)
    }
    
    return blocks, nil
}

// readBlock 从stream读取一个区块
func (s *Service) readBlock(
    stream network.Stream,
) (interfaces.ReadOnlySignedBeaconBlock, error) {
    
    // 根据分叉版本选择正确的区块类型
    forkDigest, err := s.currentForkDigest()
    if err != nil {
        return nil, err
    }
    
    // 创建对应版本的区块
    block := s.blockForFork(forkDigest)
    
    // 解码
    if err := s.cfg.P2P.Encoding().DecodeWithMaxLength(
        stream,
        block,
    ); err != nil {
        return nil, err
    }
    
    return block, nil
}
```

---

## 9.4 使用场景

### 9.4.1 Initial Sync场景

```go
// beacon-chain/sync/initial-sync/blocks_fetcher.go

// fetchBlocksInRange 批量获取区块
func (f *blocksFetcher) fetchBlocksInRange(
    ctx context.Context,
    startSlot, endSlot primitives.Slot,
) error {
    
    // 选择peers
    peers := f.selectSyncPeers(maxPeersToSync)
    if len(peers) == 0 {
        return errors.New("no peers available")
    }
    
    // 计算每个peer负责的范围
    slotsPerPeer := (endSlot - startSlot + 1) / primitives.Slot(len(peers))
    
    // 并发从多个peers获取
    var wg sync.WaitGroup
    errChan := make(chan error, len(peers))
    blocksChan := make(chan []interfaces.ReadOnlySignedBeaconBlock, len(peers))
    
    for i, pid := range peers {
        wg.Add(1)
        
        // 计算该peer的范围
        peerStart := startSlot + primitives.Slot(i)*slotsPerPeer
        var peerEnd primitives.Slot
        if i == len(peers)-1 {
            peerEnd = endSlot // 最后一个peer处理剩余部分
        } else {
            peerEnd = peerStart + slotsPerPeer - 1
        }
        
        go func(p peer.ID, start, end primitives.Slot) {
            defer wg.Done()
            
            // 构造请求
            req := &pb.BeaconBlocksByRangeRequest{
                StartSlot: uint64(start),
                Count:     uint64(end - start + 1),
                Step:      1,
            }
            
            // 发送请求
            blocks, err := f.requestBlocks(ctx, req, p)
            if err != nil {
                errChan <- err
                return
            }
            
            blocksChan <- blocks
        }(pid, peerStart, peerEnd)
    }
    
    // 等待所有goroutine完成
    wg.Wait()
    close(errChan)
    close(blocksChan)
    
    // 检查错误
    for err := range errChan {
        if err != nil {
            return err
        }
    }
    
    // 收集所有区块
    var allBlocks []interfaces.ReadOnlySignedBeaconBlock
    for blocks := range blocksChan {
        allBlocks = append(allBlocks, blocks...)
    }
    
    // 按slot排序
    sort.Slice(allBlocks, func(i, j int) bool {
        return allBlocks[i].Block().Slot() < allBlocks[j].Block().Slot()
    })
    
    // 处理区块
    return f.processBlocks(ctx, allBlocks)
}
```

### 9.4.2 Backfill场景

```go
// beacon-chain/sync/backfill/backfill.go

// backfillBlocks 回填历史区块
func (b *Service) backfillBlocks(
    ctx context.Context,
) error {
    // 1. 确定回填范围
    oldestSlot := b.db.OldestSlot()
    targetSlot := primitives.Slot(0) // 回填到创世
    
    log.WithFields(logrus.Fields{
        "oldestSlot": oldestSlot,
        "targetSlot": targetSlot,
    }).Info("Starting backfill")
    
    // 2. 分批回填
    batchSize := primitives.Slot(maxRequestBlocks)
    
    for currentSlot := oldestSlot; currentSlot > targetSlot; {
        // 计算批次范围
        batchStart := currentSlot - batchSize
        if batchStart < targetSlot {
            batchStart = targetSlot
        }
        
        // 选择peer
        peer := b.selectBackfillPeer()
        if peer == "" {
            return errors.New("no backfill peer available")
        }
        
        // 请求区块
        req := &pb.BeaconBlocksByRangeRequest{
            StartSlot: uint64(batchStart),
            Count:     uint64(currentSlot - batchStart),
            Step:      1,
        }
        
        blocks, err := b.requestBlocks(ctx, req, peer)
        if err != nil {
            log.WithError(err).Error("Backfill request failed")
            continue
        }
        
        // 存储区块（逆序）
        for i := len(blocks) - 1; i >= 0; i-- {
            if err := b.db.SaveBlock(ctx, blocks[i]); err != nil {
                return err
            }
        }
        
        currentSlot = batchStart
        
        log.WithField("slot", currentSlot).Info("Backfill progress")
    }
    
    log.Info("Backfill completed")
    return nil
}
```

### 9.4.3 Fork处理场景

```go
// beacon-chain/sync/rpc_blocks_by_range.go

// fetchForkBlocks 获取分叉区块
func (s *Service) fetchForkBlocks(
    ctx context.Context,
    forkRoot [32]byte,
) error {
    // 1. 找到分叉点
    commonAncestor, err := s.findCommonAncestor(ctx, forkRoot)
    if err != nil {
        return err
    }
    
    // 2. 获取当前链头
    headSlot := s.chain.HeadSlot()
    
    // 3. 请求分叉点之后的区块
    req := &pb.BeaconBlocksByRangeRequest{
        StartSlot: uint64(commonAncestor.Slot + 1),
        Count:     uint64(headSlot - commonAncestor.Slot),
        Step:      1,
    }
    
    // 4. 从多个peers获取（验证一致性）
    peers := s.selectForkPeers(forkRoot)
    
    var validBlocks []interfaces.ReadOnlySignedBeaconBlock
    for _, peer := range peers {
        blocks, err := s.sendBeaconBlocksByRangeRequest(
            ctx,
            req,
            peer,
        )
        if err != nil {
            continue
        }
        
        // 验证区块链
        if s.validateBlockChain(blocks, commonAncestor) {
            validBlocks = blocks
            break
        }
    }
    
    if validBlocks == nil {
        return errors.New("failed to fetch valid fork blocks")
    }
    
    // 5. 处理分叉区块
    return s.processForkBlocks(ctx, validBlocks)
}
```

---

## 9.5 性能优化

### 9.5.1 批量大小调优

```go
// 动态调整批量大小
func (f *blocksFetcher) calculateOptimalBatchSize(
    peerID peer.ID,
) uint64 {
    // 获取peer的历史性能
    stats := f.peerStats(peerID)
    
    // 基准批量大小
    batchSize := uint64(512)
    
    // 根据带宽调整
    if stats.AvgResponseTime < 1*time.Second {
        // 响应快，增加批量
        batchSize = 1024
    } else if stats.AvgResponseTime > 5*time.Second {
        // 响应慢，减少批量
        batchSize = 256
    }
    
    // 根据错误率调整
    if stats.ErrorRate > 0.1 { // 错误率超过10%
        batchSize /= 2
    }
    
    // 不超过最大限制
    if batchSize > maxRequestBlocks {
        batchSize = maxRequestBlocks
    }
    
    return batchSize
}
```

### 9.5.2 并发控制

```go
// beacon-chain/sync/initial-sync/service.go

const (
    // 最大并发peer数
    maxConcurrentPeers = 8
    
    // 每个peer的最大并发请求
    maxConcurrentRequestsPerPeer = 2
)

// parallelFetch 并行获取区块
func (s *Service) parallelFetch(
    ctx context.Context,
    startSlot, endSlot primitives.Slot,
) error {
    // 信号量限制并发数
    sem := make(chan struct{}, maxConcurrentPeers)
    
    // 区块缓冲channel
    blocksChan := make(chan blockBatch, 100)
    
    // 错误channel
    errChan := make(chan error, 1)
    
    // 启动处理goroutine
    go s.processBlockBatches(ctx, blocksChan, errChan)
    
    // 分批请求
    batchSize := primitives.Slot(512)
    for slot := startSlot; slot <= endSlot; slot += batchSize {
        // 获取信号量
        select {
        case sem <- struct{}{}:
        case <-ctx.Done():
            return ctx.Err()
        case err := <-errChan:
            return err
        }
        
        // 计算批次范围
        batchEnd := slot + batchSize - 1
        if batchEnd > endSlot {
            batchEnd = endSlot
        }
        
        // 并发请求
        go func(start, end primitives.Slot) {
            defer func() { <-sem }() // 释放信号量
            
            // 选择peer
            peer := s.selectPeer()
            
            // 请求区块
            req := &pb.BeaconBlocksByRangeRequest{
                StartSlot: uint64(start),
                Count:     uint64(end - start + 1),
                Step:      1,
            }
            
            blocks, err := s.requestBlocks(ctx, req, peer)
            if err != nil {
                select {
                case errChan <- err:
                default:
                }
                return
            }
            
            // 发送到处理channel
            select {
            case blocksChan <- blockBatch{
                blocks: blocks,
                start:  start,
            }:
            case <-ctx.Done():
            }
        }(slot, batchEnd)
    }
    
    // 等待所有请求完成
    for i := 0; i < maxConcurrentPeers; i++ {
        sem <- struct{}{}
    }
    
    close(blocksChan)
    
    // 检查错误
    select {
    case err := <-errChan:
        return err
    default:
        return nil
    }
}
```

### 9.5.3 缓存优化

```go
// beacon-chain/blockchain/cache.go

// BlockCache 区块缓存
type BlockCache struct {
    cache *lru.Cache
    mu    sync.RWMutex
}

// NewBlockCache 创建区块缓存
func NewBlockCache(size int) *BlockCache {
    cache, _ := lru.New(size)
    return &BlockCache{
        cache: cache,
    }
}

// Get 获取缓存的区块
func (c *BlockCache) Get(
    slot primitives.Slot,
) (interfaces.ReadOnlySignedBeaconBlock, bool) {
    c.mu.RLock()
    defer c.mu.RUnlock()
    
    val, ok := c.cache.Get(slot)
    if !ok {
        return nil, false
    }
    
    return val.(interfaces.ReadOnlySignedBeaconBlock), true
}

// Put 添加区块到缓存
func (c *BlockCache) Put(
    block interfaces.ReadOnlySignedBeaconBlock,
) {
    c.mu.Lock()
    defer c.mu.Unlock()
    
    c.cache.Add(block.Block().Slot(), block)
}

// 使用缓存优化区块获取
func (s *Service) BlockBySlot(
    ctx context.Context,
    slot primitives.Slot,
) (interfaces.ReadOnlySignedBeaconBlock, error) {
    // 先查缓存
    if block, ok := s.blockCache.Get(slot); ok {
        return block, nil
    }
    
    // 从数据库加载
    block, err := s.db.Block(ctx, slot)
    if err != nil {
        return nil, err
    }
    
    // 加入缓存
    s.blockCache.Put(block)
    
    return block, nil
}
```

### 9.5.4 压缩和编码优化

```go
// beacon-chain/p2p/encoder/ssz.go

// 使用缓冲池减少内存分配
var bufferPool = sync.Pool{
    New: func() interface{} {
        return new(bytes.Buffer)
    },
}

// EncodeWithMaxLength 优化的编码
func (e SszNetworkEncoder) EncodeWithMaxLength(
    w io.Writer,
    msg interface{},
) error {
    // 从池中获取buffer
    buf := bufferPool.Get().(*bytes.Buffer)
    buf.Reset()
    defer bufferPool.Put(buf)
    
    // SSZ编码到buffer
    if err := ssz.Encode(buf, msg); err != nil {
        return err
    }
    
    // 检查大小
    if buf.Len() > maxChunkSize {
        return errors.New("message too large")
    }
    
    // Snappy压缩（直接写入writer，避免中间buffer）
    sw := snappy.NewBufferedWriter(w)
    defer sw.Close()
    
    // 写入长度
    if err := writeVarint(sw, uint64(buf.Len())); err != nil {
        return err
    }
    
    // 写入数据
    _, err := sw.Write(buf.Bytes())
    return err
}
```

---

## 本章小结

本章深入介绍了BeaconBlocksByRange协议：

✅ **协议定义** - 请求/响应格式和参数说明
✅ **参数验证** - 完整的验证规则和速率限制
✅ **响应处理** - 流式发送和接收机制
✅ **使用场景** - Initial Sync、Backfill、Fork处理
✅ **性能优化** - 批量调优、并发控制、缓存策略

BeaconBlocksByRange是Initial Sync的核心协议，理解其实现对优化同步性能至关重要。

---

**相关章节**：
- [第7章：Req/Resp协议基础](./chapter_07_reqresp_basics.md)
- [第8章：Status协议](./chapter_08_status_protocol.md)
- [第10章：BeaconBlocksByRoot](./chapter_10_blocks_by_root.md)
- [第18章：Full Sync实现](./chapter_18_full_sync.md)
