# 第10章 BeaconBlocksByRoot协议

## 10.1 协议定义

### 10.1.1 协议概述

**BeaconBlocksByRoot** 用于根据区块根哈希获取特定区块，主要用于填补缺失的区块。

**协议标识符**：
```
v1: /eth2/beacon_chain/req/beacon_blocks_by_root/1/ssz_snappy
v2: /eth2/beacon_chain/req/beacon_blocks_by_root/2/ssz_snappy
```

**与BeaconBlocksByRange的区别**：

| 特性 | BeaconBlocksByRange | BeaconBlocksByRoot |
|------|---------------------|-------------------|
| 查询方式 | 按slot范围 | 按根哈希 |
| 主要用途 | Initial Sync | 填补缺失区块 |
| 响应顺序 | 按slot升序 | 任意顺序 |
| 典型数量 | 大批量(最多1024) | 小批量(通常<128) |

### 10.1.2 请求消息

```go
// proto/prysm/v1alpha1/p2p.proto
message BeaconBlocksByRootRequest {
    // 区块根哈希列表
    repeated bytes block_roots = 1 [(ssz_size) = "?,32", (ssz_max) = "128"];
}
```

**Go结构体**：
```go
type BeaconBlocksByRootRequest struct {
    BlockRoots [][32]byte `ssz-size:"?,32" ssz-max:"128"`
}
```

**限制**：
```
- 单个root大小: 32字节
- 最多请求数量: 128个区块
- 总请求大小: ≤ 4KB
```

### 10.1.3 响应消息

```go
响应格式：
┌──────────────────┐
│  区块1 (SSZ)     │  ← 对应 block_roots[i]
├──────────────────┤
│  区块2 (SSZ)     │  ← 对应 block_roots[j]  
├──────────────────┤
│  ...             │
└──────────────────┘

注意：
1. 响应顺序可以与请求不同
2. 如果某个root不存在，直接跳过（不返回error）
3. 每个区块单独编码
```

---

## 10.2 使用场景

### 10.2.1 缺失父块处理

**最常见的使用场景**：当收到一个区块但缺少其父块时。

```go
// beacon-chain/sync/pending_blocks_queue.go

// 场景：收到slot 105的区块，但缺少slot 104
func (s *Service) handleMissingParent(
    ctx context.Context,
    block interfaces.ReadOnlySignedBeaconBlock,
) error {
    parentRoot := block.Block().ParentRoot()
    
    // 检查父块是否存在
    if s.cfg.BeaconDB.HasBlock(ctx, parentRoot) {
        return nil // 父块已存在
    }
    
    log.WithFields(logrus.Fields{
        "slot":       block.Block().Slot(),
        "parentRoot": fmt.Sprintf("%#x", parentRoot),
    }).Debug("Missing parent block")
    
    // 请求缺失的父块
    return s.requestBlocksByRoot(ctx, [][32]byte{parentRoot})
}
```

**级联请求**：
```
收到区块 slot 110
    ↓
发现缺失父块 slot 109
    ↓
请求 slot 109
    ↓
收到 slot 109，发现又缺失父块 slot 108
    ↓
请求 slot 108
    ↓
...继续直到找到已有的区块
```

### 10.2.2 Fork选择更新

```go
// beacon-chain/sync/rpc_blocks_by_root.go

// 场景：Fork Choice通知有新的链头，但缺少中间区块
func (s *Service) updateForkChoice(
    ctx context.Context,
    headRoot [32]byte,
) error {
    // 1. 检查新链头是否已有
    if s.cfg.BeaconDB.HasBlock(ctx, headRoot) {
        return s.cfg.ForkChoiceStore.ProcessBlock(ctx, headRoot)
    }
    
    // 2. 追踪缺失的区块链
    missingRoots := s.traceMissingAncestors(ctx, headRoot)
    
    if len(missingRoots) == 0 {
        return nil
    }
    
    log.WithField("count", len(missingRoots)).
        Debug("Requesting missing fork blocks")
    
    // 3. 批量请求缺失区块
    return s.requestBlocksByRoot(ctx, missingRoots)
}

// traceMissingAncestors 追踪缺失的祖先区块
func (s *Service) traceMissingAncestors(
    ctx context.Context,
    headRoot [32]byte,
) [][32]byte {
    var missing [][32]byte
    currentRoot := headRoot
    
    // 最多追溯128个区块
    for i := 0; i < 128; i++ {
        // 检查是否已有
        if s.cfg.BeaconDB.HasBlock(ctx, currentRoot) {
            break // 找到已有区块，停止
        }
        
        missing = append(missing, currentRoot)
        
        // 尝试从pending queue获取父root
        block := s.pendingBlocks.Get(currentRoot)
        if block == nil {
            break // 无法继续追溯
        }
        
        currentRoot = block.Block().ParentRoot()
    }
    
    return missing
}
```

### 10.2.3 Gossip区块验证

```go
// beacon-chain/sync/validate_beacon_blocks.go

// 场景：通过gossip收到区块，需要验证其父块已处理
func (s *Service) validateGossipBlock(
    ctx context.Context,
    block interfaces.ReadOnlySignedBeaconBlock,
) error {
    parentRoot := block.Block().ParentRoot()
    
    // 检查父块是否已处理
    if !s.cfg.Chain.HasBlock(ctx, parentRoot) {
        // 父块未处理，请求它
        if err := s.requestBlocksByRoot(
            ctx,
            [][32]byte{parentRoot},
        ); err != nil {
            return err
        }
        
        // 将当前区块放入pending queue
        s.pendingBlocks.Add(block)
        
        return errors.New("parent block not processed")
    }
    
    // 父块已存在，继续验证
    return s.validateBlock(ctx, block)
}
```

### 10.2.4 Attestation目标区块

```go
// beacon-chain/sync/rpc_attestation.go

// 场景：收到attestation，需要验证其target区块
func (s *Service) handleAttestation(
    ctx context.Context,
    att ethpb.Att,
) error {
    targetRoot := att.Data.Target.Root
    
    // 检查target区块是否存在
    if !s.cfg.BeaconDB.HasBlock(ctx, targetRoot) {
        log.WithField("targetRoot", fmt.Sprintf("%#x", targetRoot)).
            Debug("Attestation target block missing")
        
        // 请求target区块
        if err := s.requestBlocksByRoot(
            ctx,
            [][32]byte{targetRoot},
        ); err != nil {
            return err
        }
    }
    
    // 处理attestation
    return s.processAttestation(ctx, att)
}
```

---

## 10.3 实现细节

### 10.3.1 请求发送

```go
// beacon-chain/sync/rpc_blocks_by_root.go

// requestBlocksByRoot 请求指定根哈希的区块
func (s *Service) requestBlocksByRoot(
    ctx context.Context,
    blockRoots [][32]byte,
) error {
    if len(blockRoots) == 0 {
        return nil
    }
    
    // 限制数量
    if len(blockRoots) > maxBlocksPerRequest {
        return fmt.Errorf(
            "too many blocks requested: %d",
            len(blockRoots),
        )
    }
    
    // 选择peer
    peer := s.selectBestPeer()
    if peer == "" {
        return errors.New("no suitable peer available")
    }
    
    log.WithFields(logrus.Fields{
        "peer":  peer.String(),
        "count": len(blockRoots),
    }).Debug("Requesting blocks by root")
    
    // 构造请求
    req := &pb.BeaconBlocksByRootRequest{
        BlockRoots: blockRoots,
    }
    
    // 发送请求
    blocks, err := s.sendBlocksByRootRequest(ctx, req, peer)
    if err != nil {
        return err
    }
    
    // 处理响应
    return s.processBlocksByRoot(ctx, blocks, blockRoots)
}

const (
    // 单次请求最大区块数
    maxBlocksPerRequest = 128
    
    // 响应超时
    blocksByRootTimeout = 10 * time.Second
)

// sendBlocksByRootRequest 发送请求
func (s *Service) sendBlocksByRootRequest(
    ctx context.Context,
    req *pb.BeaconBlocksByRootRequest,
    peerID peer.ID,
) ([]interfaces.ReadOnlySignedBeaconBlock, error) {
    
    ctx, cancel := context.WithTimeout(ctx, blocksByRootTimeout)
    defer cancel()
    
    // 1. 打开stream
    stream, err := s.cfg.P2P.Host().NewStream(
        ctx,
        peerID,
        s.blocksByRootProtocol(),
    )
    if err != nil {
        return nil, err
    }
    defer stream.Close()
    
    // 2. 设置deadline
    deadline := time.Now().Add(blocksByRootTimeout)
    if err := stream.SetDeadline(deadline); err != nil {
        return nil, err
    }
    
    // 3. 编码发送请求
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
    
    // 5. 读取响应
    return s.readBlocksByRootResponse(ctx, stream, len(req.BlockRoots))
}
```

### 10.3.2 响应处理

```go
// readBlocksByRootResponse 读取响应区块
func (s *Service) readBlocksByRootResponse(
    ctx context.Context,
    stream network.Stream,
    expectedCount int,
) ([]interfaces.ReadOnlySignedBeaconBlock, error) {
    
    var blocks []interfaces.ReadOnlySignedBeaconBlock
    
    // 流式读取
    for {
        // 检查上下文
        if err := ctx.Err(); err != nil {
            return nil, err
        }
        
        // 检查是否已收到足够区块
        if len(blocks) >= expectedCount {
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
        
        blocks = append(blocks, block)
    }
    
    return blocks, nil
}

// processBlocksByRoot 处理收到的区块
func (s *Service) processBlocksByRoot(
    ctx context.Context,
    blocks []interfaces.ReadOnlySignedBeaconBlock,
    requestedRoots [][32]byte,
) error {
    
    // 记录收到的区块
    receivedRoots := make(map[[32]byte]bool)
    for _, block := range blocks {
        root, err := block.Block().HashTreeRoot()
        if err != nil {
            return err
        }
        receivedRoots[root] = true
    }
    
    // 检查缺失
    var missingRoots [][32]byte
    for _, root := range requestedRoots {
        if !receivedRoots[root] {
            missingRoots = append(missingRoots, root)
        }
    }
    
    if len(missingRoots) > 0 {
        log.WithField("count", len(missingRoots)).
            Debug("Some blocks not received")
    }
    
    // 验证并处理区块
    for _, block := range blocks {
        if err := s.validateAndProcessBlock(ctx, block); err != nil {
            log.WithError(err).Error("Failed to process block")
            continue
        }
    }
    
    return nil
}
```

### 10.3.3 请求处理器

```go
// beaconBlocksByRootRPCHandler 处理BeaconBlocksByRoot请求
func (s *Service) beaconBlocksByRootRPCHandler(
    ctx context.Context,
    msg interface{},
    stream libp2pcore.Stream,
) error {
    
    ctx, cancel := context.WithTimeout(ctx, respTimeout)
    defer cancel()
    
    peerID := stream.Conn().RemotePeer()
    
    // 1. 解析请求
    req, ok := msg.(*pb.BeaconBlocksByRootRequest)
    if !ok {
        return WriteErrorResponseToStream(
            ResponseCodeInvalidRequest,
            "invalid request type",
            stream,
        )
    }
    
    // 2. 验证请求
    if err := s.validateBlocksByRootRequest(req); err != nil {
        return WriteErrorResponseToStream(
            ResponseCodeInvalidRequest,
            err.Error(),
            stream,
        )
    }
    
    // 3. 速率限制
    if !s.rateLimiter.allowRequest(peerID, stream.Protocol()) {
        return WriteErrorResponseToStream(
            ResponseCodeRateLimited,
            "rate limit exceeded",
            stream,
        )
    }
    
    // 4. 发送区块
    return s.sendBlocksByRoot(ctx, req, stream)
}

// validateBlocksByRootRequest 验证请求
func (s *Service) validateBlocksByRootRequest(
    req *pb.BeaconBlocksByRootRequest,
) error {
    // 检查数量
    if len(req.BlockRoots) == 0 {
        return errors.New("empty request")
    }
    
    if len(req.BlockRoots) > maxBlocksPerRequest {
        return fmt.Errorf(
            "too many blocks: %d > %d",
            len(req.BlockRoots),
            maxBlocksPerRequest,
        )
    }
    
    // 检查root格式
    for i, root := range req.BlockRoots {
        if len(root) != 32 {
            return fmt.Errorf(
                "invalid root at index %d: length %d",
                i,
                len(root),
            )
        }
    }
    
    return nil
}

// sendBlocksByRoot 发送请求的区块
func (s *Service) sendBlocksByRoot(
    ctx context.Context,
    req *pb.BeaconBlocksByRootRequest,
    stream network.Stream,
) error {
    
    sentCount := 0
    
    for _, root := range req.BlockRoots {
        // 检查上下文
        if err := ctx.Err(); err != nil {
            return err
        }
        
        // 转换root格式
        r := bytesutil.ToBytes32(root)
        
        // 获取区块
        block, err := s.cfg.BeaconDB.Block(ctx, r)
        if err != nil {
            if errors.Is(err, db.ErrNotFound) {
                // 区块不存在，跳过
                log.WithField("root", fmt.Sprintf("%#x", r)).
                    Debug("Block not found")
                continue
            }
            // 其他错误
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
        "requested": len(req.BlockRoots),
        "sent":      sentCount,
    }).Debug("Completed blocks by root request")
    
    return nil
}
```

---

## 10.4 批处理优化

### 10.4.1 请求合并

```go
// beacon-chain/sync/pending_blocks_queue.go

// 合并多个小请求为批量请求
type blockRequestBatcher struct {
    mu            sync.Mutex
    pending       map[[32]byte][]chan result
    batchSize     int
    batchInterval time.Duration
}

type result struct {
    block interfaces.ReadOnlySignedBeaconBlock
    err   error
}

func newBlockRequestBatcher() *blockRequestBatcher {
    return &blockRequestBatcher{
        pending:       make(map[[32]byte][]chan result),
        batchSize:     64,
        batchInterval: 100 * time.Millisecond,
    }
}

// Request 请求区块（自动批处理）
func (b *blockRequestBatcher) Request(
    ctx context.Context,
    root [32]byte,
) (interfaces.ReadOnlySignedBeaconBlock, error) {
    
    // 创建结果channel
    resChan := make(chan result, 1)
    
    b.mu.Lock()
    // 添加到pending列表
    b.pending[root] = append(b.pending[root], resChan)
    
    // 检查是否达到批量大小
    shouldFlush := len(b.pending) >= b.batchSize
    b.mu.Unlock()
    
    // 如果达到批量大小，立即flush
    if shouldFlush {
        b.flush()
    }
    
    // 等待结果
    select {
    case res := <-resChan:
        return res.block, res.err
    case <-ctx.Done():
        return nil, ctx.Err()
    }
}

// 启动定时flush
func (b *blockRequestBatcher) Start() {
    ticker := time.NewTicker(b.batchInterval)
    go func() {
        for range ticker.C {
            b.flush()
        }
    }()
}

// flush 执行批量请求
func (b *blockRequestBatcher) flush() {
    b.mu.Lock()
    if len(b.pending) == 0 {
        b.mu.Unlock()
        return
    }
    
    // 获取所有pending roots
    var roots [][32]byte
    callbacks := make(map[[32]byte][]chan result)
    
    for root, chans := range b.pending {
        roots = append(roots, root)
        callbacks[root] = chans
    }
    
    // 清空pending
    b.pending = make(map[[32]byte][]chan result)
    b.mu.Unlock()
    
    // 执行批量请求
    go func() {
        blocks, err := b.requestBlocks(context.Background(), roots)
        
        // 构建结果映射
        blockMap := make(map[[32]byte]interfaces.ReadOnlySignedBeaconBlock)
        if err == nil {
            for _, block := range blocks {
                root, _ := block.Block().HashTreeRoot()
                blockMap[root] = block
            }
        }
        
        // 分发结果
        for root, chans := range callbacks {
            block := blockMap[root]
            res := result{block: block, err: err}
            
            for _, ch := range chans {
                ch <- res
            }
        }
    }()
}
```

### 10.4.2 重复请求去重

```go
// 避免同时向多个peer请求相同的区块
type requestDeduplicator struct {
    mu       sync.Mutex
    inflight map[[32]byte]*inflightRequest
}

type inflightRequest struct {
    mu      sync.Mutex
    done    bool
    block   interfaces.ReadOnlySignedBeaconBlock
    err     error
    waiters []chan struct{}
}

func newRequestDeduplicator() *requestDeduplicator {
    return &requestDeduplicator{
        inflight: make(map[[32]byte]*inflightRequest),
    }
}

// Request 请求区块（自动去重）
func (d *requestDeduplicator) Request(
    ctx context.Context,
    root [32]byte,
    fetcher func() (interfaces.ReadOnlySignedBeaconBlock, error),
) (interfaces.ReadOnlySignedBeaconBlock, error) {
    
    d.mu.Lock()
    
    // 检查是否已有请求在进行
    if req, exists := d.inflight[root]; exists {
        // 已有请求，等待其完成
        waiter := make(chan struct{})
        req.mu.Lock()
        if req.done {
            // 已完成
            block, err := req.block, req.err
            req.mu.Unlock()
            d.mu.Unlock()
            return block, err
        }
        req.waiters = append(req.waiters, waiter)
        req.mu.Unlock()
        d.mu.Unlock()
        
        // 等待完成信号
        select {
        case <-waiter:
            req.mu.Lock()
            block, err := req.block, req.err
            req.mu.Unlock()
            return block, err
        case <-ctx.Done():
            return nil, ctx.Err()
        }
    }
    
    // 创建新请求
    req := &inflightRequest{}
    d.inflight[root] = req
    d.mu.Unlock()
    
    // 执行请求
    block, err := fetcher()
    
    // 标记完成并通知waiters
    req.mu.Lock()
    req.done = true
    req.block = block
    req.err = err
    waiters := req.waiters
    req.mu.Unlock()
    
    // 通知所有waiters
    for _, waiter := range waiters {
        close(waiter)
    }
    
    // 清理
    d.mu.Lock()
    delete(d.inflight, root)
    d.mu.Unlock()
    
    return block, err
}
```

---

## 10.5 错误处理和重试

### 10.5.1 智能重试策略

```go
// beacon-chain/sync/rpc_blocks_by_root.go

// requestWithRetry 带重试的请求
func (s *Service) requestWithRetry(
    ctx context.Context,
    blockRoots [][32]byte,
) ([]interfaces.ReadOnlySignedBeaconBlock, error) {
    
    maxRetries := 3
    var lastErr error
    
    // 获取多个候选peers
    peers := s.selectMultiplePeers(3)
    
    for attempt := 0; attempt < maxRetries; attempt++ {
        if len(peers) == 0 {
            return nil, errors.New("no peers available")
        }
        
        // 选择peer（轮询）
        peer := peers[attempt%len(peers)]
        
        // 尝试请求
        blocks, err := s.sendBlocksByRootRequest(
            ctx,
            &pb.BeaconBlocksByRootRequest{
                BlockRoots: blockRoots,
            },
            peer,
        )
        
        if err == nil {
            return blocks, nil
        }
        
        lastErr = err
        
        log.WithFields(logrus.Fields{
            "attempt": attempt + 1,
            "peer":    peer.String(),
            "error":   err,
        }).Debug("Request failed, retrying")
        
        // 如果peer表现不好，移除它
        if isUnrecoverableError(err) {
            s.removePeer(peer)
            peers = removeFromSlice(peers, peer)
        }
        
        // 指数退避
        if attempt < maxRetries-1 {
            backoff := time.Duration(1<<uint(attempt)) * time.Second
            select {
            case <-time.After(backoff):
            case <-ctx.Done():
                return nil, ctx.Err()
            }
        }
    }
    
    return nil, fmt.Errorf("failed after %d attempts: %w", maxRetries, lastErr)
}

func isUnrecoverableError(err error) bool {
    // 网络错误可以重试其他peer
    if errors.Is(err, network.ErrReset) {
        return true
    }
    // 超时可以重试其他peer
    if os.IsTimeout(err) {
        return true
    }
    // 协议错误不应重试该peer
    if errors.Is(err, ErrInvalidResponse) {
        return true
    }
    return false
}
```

### 10.5.2 部分成功处理

```go
// 处理部分成功的情况
func (s *Service) handlePartialSuccess(
    ctx context.Context,
    requested [][32]byte,
    received []interfaces.ReadOnlySignedBeaconBlock,
) error {
    
    // 构建已收到的映射
    receivedMap := make(map[[32]byte]bool)
    for _, block := range received {
        root, _ := block.Block().HashTreeRoot()
        receivedMap[root] = true
    }
    
    // 找出缺失的
    var missing [][32]byte
    for _, root := range requested {
        if !receivedMap[root] {
            missing = append(missing, root)
        }
    }
    
    if len(missing) == 0 {
        return nil // 全部收到
    }
    
    log.WithField("missing", len(missing)).
        Debug("Some blocks still missing")
    
    // 从其他peers重试缺失的区块
    if len(missing) <= 10 { // 只有少量缺失，值得重试
        return s.requestFromDifferentPeers(ctx, missing)
    }
    
    // 缺失太多，可能peer没有这些区块
    return fmt.Errorf("too many missing blocks: %d", len(missing))
}

// requestFromDifferentPeers 从不同peers请求
func (s *Service) requestFromDifferentPeers(
    ctx context.Context,
    roots [][32]byte,
) error {
    // 获取多个peers
    peers := s.selectMultiplePeers(len(roots))
    
    // 分配给不同peers
    for i, root := range roots {
        peer := peers[i%len(peers)]
        
        go func(r [32]byte, p peer.ID) {
            _, err := s.sendBlocksByRootRequest(
                ctx,
                &pb.BeaconBlocksByRootRequest{
                    BlockRoots: [][32]byte{r},
                },
                p,
            )
            if err != nil {
                log.WithError(err).Debug("Retry failed")
            }
        }(root, peer)
    }
    
    return nil
}
```

---

## 本章小结

本章介绍了BeaconBlocksByRoot协议：

✅ **协议定义** - 按根哈希请求区块
✅ **使用场景** - 缺失父块、Fork选择、Gossip验证
✅ **实现细节** - 请求发送和响应处理
✅ **批处理优化** - 请求合并和去重
✅ **错误处理** - 智能重试和部分成功处理

BeaconBlocksByRoot是填补区块空隙的关键协议，与BeaconBlocksByRange配合实现完整的同步功能。

---

**相关章节**：
- [第7章：Req/Resp协议基础](./chapter_07_reqresp_basics.md)
- [第9章：BeaconBlocksByRange](./chapter_09_blocks_by_range.md)
- [第23章：缺失父块处理](./chapter_23_missing_parent.md)
