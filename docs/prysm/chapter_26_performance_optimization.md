# 第26章：性能优化策略

## 26.1 批量处理优化

### 26.1.1 区块批量处理

```go
// beacon-chain/blockchain/process_block_helpers.go
type batchProcessor struct {
    chain         *Service
    batchSize     int
    batchTimeout  time.Duration
    pendingBlocks chan interfaces.ReadOnlySignedBeaconBlock
    batchBuffer   []interfaces.ReadOnlySignedBeaconBlock
}

func newBatchProcessor(chain *Service) *batchProcessor {
    return &batchProcessor{
        chain:         chain,
        batchSize:     64,  // 批量大小
        batchTimeout:  500 * time.Millisecond,
        pendingBlocks: make(chan interfaces.ReadOnlySignedBeaconBlock, 1024),
        batchBuffer:   make([]interfaces.ReadOnlySignedBeaconBlock, 0, 64),
    }
}

func (b *batchProcessor) Start(ctx context.Context) {
    ticker := time.NewTicker(b.batchTimeout)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            // 处理剩余的区块
            if len(b.batchBuffer) > 0 {
                b.processBatch(ctx, b.batchBuffer)
            }
            return
            
        case block := <-b.pendingBlocks:
            b.batchBuffer = append(b.batchBuffer, block)
            
            // 达到批量大小，立即处理
            if len(b.batchBuffer) >= b.batchSize {
                b.processBatch(ctx, b.batchBuffer)
                b.batchBuffer = b.batchBuffer[:0]
            }
            
        case <-ticker.C:
            // 超时，处理当前批次
            if len(b.batchBuffer) > 0 {
                b.processBatch(ctx, b.batchBuffer)
                b.batchBuffer = b.batchBuffer[:0]
            }
        }
    }
}

func (b *batchProcessor) processBatch(ctx context.Context, blocks []interfaces.ReadOnlySignedBeaconBlock) error {
    if len(blocks) == 0 {
        return nil
    }
    
    log.WithField("count", len(blocks)).Debug("Processing block batch")
    
    // 1. 批量验证签名
    if err := b.batchVerifySignatures(ctx, blocks); err != nil {
        return errors.Wrap(err, "batch signature verification failed")
    }
    
    // 2. 批量执行状态转换
    for _, block := range blocks {
        if err := b.chain.onBlock(ctx, block, [32]byte{}); err != nil {
            log.WithError(err).Error("Failed to process block in batch")
            continue
        }
    }
    
    return nil
}

func (b *batchProcessor) batchVerifySignatures(ctx context.Context, blocks []interfaces.ReadOnlySignedBeaconBlock) error {
    // 收集所有签名和消息
    sigs := make([]bls.Signature, 0, len(blocks))
    messages := make([][32]byte, 0, len(blocks))
    pubKeys := make([]bls.PublicKey, 0, len(blocks))
    
    for _, block := range blocks {
        sig, err := bls.SignatureFromBytes(block.Signature())
        if err != nil {
            return err
        }
        sigs = append(sigs, sig)
        
        root, err := block.Block().HashTreeRoot()
        if err != nil {
            return err
        }
        messages = append(messages, root)
        
        proposerIndex := block.Block().ProposerIndex()
        pubKey, err := b.chain.getValidatorPubKey(proposerIndex)
        if err != nil {
            return err
        }
        pubKeys = append(pubKeys, pubKey)
    }
    
    // 批量验证
    verify, err := bls.VerifyMultipleSignatures(sigs, messages, pubKeys)
    if err != nil {
        return err
    }
    if !verify {
        return errors.New("batch signature verification failed")
    }
    
    return nil
}
```

### 26.1.2 数据库批量写入

```go
// beacon-chain/db/kv/batch.go
type Batch struct {
    db      *Store
    batches map[string]*leveldb.Batch
    size    int
    mu      sync.Mutex
}

func (s *Store) NewBatch() *Batch {
    return &Batch{
        db:      s,
        batches: make(map[string]*leveldb.Batch),
    }
}

func (b *Batch) SaveBlock(ctx context.Context, signed interfaces.ReadOnlySignedBeaconBlock) error {
    b.mu.Lock()
    defer b.mu.Unlock()
    
    root, err := signed.Block().HashTreeRoot()
    if err != nil {
        return err
    }
    
    // 编码区块
    enc, err := encode(ctx, signed)
    if err != nil {
        return err
    }
    
    // 添加到批处理
    batch := b.getBatch("blocks")
    batch.Put(root[:], enc)
    b.size += len(enc)
    
    // 如果批处理过大，自动提交
    if b.size > 16*1024*1024 { // 16MB
        return b.Commit()
    }
    
    return nil
}

func (b *Batch) SaveState(ctx context.Context, state state.BeaconState, root [32]byte) error {
    b.mu.Lock()
    defer b.mu.Unlock()
    
    // 编码状态
    enc, err := encode(ctx, state)
    if err != nil {
        return err
    }
    
    // 添加到批处理
    batch := b.getBatch("states")
    batch.Put(root[:], enc)
    b.size += len(enc)
    
    if b.size > 16*1024*1024 {
        return b.Commit()
    }
    
    return nil
}

func (b *Batch) Commit() error {
    b.mu.Lock()
    defer b.mu.Unlock()
    
    // 提交所有批处理
    for name, batch := range b.batches {
        db := b.db.getDB(name)
        if err := db.Write(batch, nil); err != nil {
            return errors.Wrapf(err, "failed to commit batch %s", name)
        }
    }
    
    // 重置
    b.batches = make(map[string]*leveldb.Batch)
    b.size = 0
    
    return nil
}

func (b *Batch) getBatch(name string) *leveldb.Batch {
    batch, exists := b.batches[name]
    if !exists {
        batch = new(leveldb.Batch)
        b.batches[name] = batch
    }
    return batch
}
```

## 26.2 并发处理

### 26.2.1 并行验证

```go
// beacon-chain/sync/validate_aggregate_proof.go
type aggregatePool struct {
    ctx         context.Context
    workers     int
    inputChan   chan *ethpb.SignedAggregateAttestationAndProof
    outputChan  chan *validatedAggregate
    workerPool  *sync.WaitGroup
}

type validatedAggregate struct {
    aggregate *ethpb.SignedAggregateAttestationAndProof
    valid     bool
    err       error
}

func newAggregatePool(ctx context.Context, workers int) *aggregatePool {
    pool := &aggregatePool{
        ctx:        ctx,
        workers:    workers,
        inputChan:  make(chan *ethpb.SignedAggregateAttestationAndProof, workers*2),
        outputChan: make(chan *validatedAggregate, workers*2),
        workerPool: &sync.WaitGroup{},
    }
    
    // 启动工作协程
    for i := 0; i < workers; i++ {
        pool.workerPool.Add(1)
        go pool.worker()
    }
    
    return pool
}

func (p *aggregatePool) worker() {
    defer p.workerPool.Done()
    
    for {
        select {
        case <-p.ctx.Done():
            return
        case agg, ok := <-p.inputChan:
            if !ok {
                return
            }
            
            // 验证聚合证明
            result := &validatedAggregate{
                aggregate: agg,
            }
            
            // 1. 验证签名
            if err := p.verifySignature(agg); err != nil {
                result.valid = false
                result.err = err
            } else {
                result.valid = true
            }
            
            // 发送结果
            select {
            case p.outputChan <- result:
            case <-p.ctx.Done():
                return
            }
        }
    }
}

func (p *aggregatePool) Submit(agg *ethpb.SignedAggregateAttestationAndProof) {
    select {
    case p.inputChan <- agg:
    case <-p.ctx.Done():
    }
}

func (p *aggregatePool) Results() <-chan *validatedAggregate {
    return p.outputChan
}

func (p *aggregatePool) Close() {
    close(p.inputChan)
    p.workerPool.Wait()
    close(p.outputChan)
}
```

### 26.2.2 并发下载

```go
// beacon-chain/sync/initial-sync/blocks_fetcher.go
func (f *blocksFetcher) fetchBlocksInParallel(
    ctx context.Context,
    start, end types.Slot) ([]*ethpb.SignedBeaconBlock, error) {
    
    // 计算每个worker的范围
    const maxWorkers = 8
    const blocksPerWorker = 128
    
    rangeSize := end - start + 1
    numWorkers := int(rangeSize / blocksPerWorker)
    if numWorkers > maxWorkers {
        numWorkers = maxWorkers
    }
    if numWorkers == 0 {
        numWorkers = 1
    }
    
    // 创建工作通道
    type workItem struct {
        start types.Slot
        end   types.Slot
    }
    
    type result struct {
        blocks []*ethpb.SignedBeaconBlock
        err    error
    }
    
    workChan := make(chan workItem, numWorkers)
    resultChan := make(chan result, numWorkers)
    
    // 启动workers
    var wg sync.WaitGroup
    for i := 0; i < numWorkers; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            
            for work := range workChan {
                // 选择peer
                pid, err := f.selectBestPeer(ctx)
                if err != nil {
                    resultChan <- result{err: err}
                    continue
                }
                
                // 请求区块
                req := &p2ppb.BeaconBlocksByRangeRequest{
                    StartSlot: uint64(work.start),
                    Count:     uint64(work.end - work.start + 1),
                    Step:      1,
                }
                
                blocks, err := f.requestBlocks(ctx, req, pid)
                resultChan <- result{blocks: blocks, err: err}
            }
        }()
    }
    
    // 分配工作
    go func() {
        blocksPerRange := rangeSize / types.Slot(numWorkers)
        for i := 0; i < numWorkers; i++ {
            rangeStart := start + types.Slot(i)*blocksPerRange
            rangeEnd := rangeStart + blocksPerRange - 1
            if i == numWorkers-1 {
                rangeEnd = end
            }
            
            workChan <- workItem{
                start: rangeStart,
                end:   rangeEnd,
            }
        }
        close(workChan)
    }()
    
    // 等待结果
    go func() {
        wg.Wait()
        close(resultChan)
    }()
    
    // 收集结果
    allBlocks := make([]*ethpb.SignedBeaconBlock, 0, rangeSize)
    for res := range resultChan {
        if res.err != nil {
            return nil, res.err
        }
        allBlocks = append(allBlocks, res.blocks...)
    }
    
    // 按slot排序
    sort.Slice(allBlocks, func(i, j int) bool {
        return allBlocks[i].Block().Slot() < allBlocks[j].Block().Slot()
    })
    
    return allBlocks, nil
}
```

## 26.3 缓存策略

### 26.3.1 LRU缓存实现

```go
// beacon-chain/cache/lru_cache.go
type LRUCache struct {
    capacity int
    cache    map[interface{}]*list.Element
    lruList  *list.List
    mu       sync.RWMutex
}

type cacheEntry struct {
    key   interface{}
    value interface{}
}

func NewLRUCache(capacity int) *LRUCache {
    return &LRUCache{
        capacity: capacity,
        cache:    make(map[interface{}]*list.Element),
        lruList:  list.New(),
    }
}

func (c *LRUCache) Get(key interface{}) (interface{}, bool) {
    c.mu.Lock()
    defer c.mu.Unlock()
    
    if elem, exists := c.cache[key]; exists {
        // 移动到前面（最近使用）
        c.lruList.MoveToFront(elem)
        return elem.Value.(*cacheEntry).value, true
    }
    
    return nil, false
}

func (c *LRUCache) Put(key, value interface{}) {
    c.mu.Lock()
    defer c.mu.Unlock()
    
    // 检查是否已存在
    if elem, exists := c.cache[key]; exists {
        c.lruList.MoveToFront(elem)
        elem.Value.(*cacheEntry).value = value
        return
    }
    
    // 检查容量
    if c.lruList.Len() >= c.capacity {
        // 移除最旧的元素
        oldest := c.lruList.Back()
        if oldest != nil {
            c.lruList.Remove(oldest)
            delete(c.cache, oldest.Value.(*cacheEntry).key)
        }
    }
    
    // 添加新元素
    entry := &cacheEntry{key: key, value: value}
    elem := c.lruList.PushFront(entry)
    c.cache[key] = elem
}

func (c *LRUCache) Len() int {
    c.mu.RLock()
    defer c.mu.RUnlock()
    return c.lruList.Len()
}
```

### 26.3.2 多层缓存

```go
// beacon-chain/cache/checkpoint_state.go
type checkpointStateCache struct {
    // L1: 内存缓存 (快速访问)
    memCache *LRUCache
    
    // L2: 磁盘缓存 (容量更大)
    diskCache *diskStateCache
    
    // L3: 数据库 (持久化)
    db db.ReadOnlyDatabase
    
    mu sync.RWMutex
}

func newCheckpointStateCache(db db.ReadOnlyDatabase) *checkpointStateCache {
    return &checkpointStateCache{
        memCache:  NewLRUCache(4), // 只保存4个最近的checkpoint state
        diskCache: newDiskStateCache(16), // 磁盘保存16个
        db:        db,
    }
}

func (c *checkpointStateCache) Get(ctx context.Context, checkpoint *ethpb.Checkpoint) (state.BeaconState, error) {
    key := bytesutil.ToBytes32(checkpoint.Root)
    
    // 1. 尝试从内存缓存获取
    if val, exists := c.memCache.Get(key); exists {
        return val.(state.BeaconState), nil
    }
    
    // 2. 尝试从磁盘缓存获取
    if st, err := c.diskCache.Get(key); err == nil {
        // 提升到内存缓存
        c.memCache.Put(key, st)
        return st, nil
    }
    
    // 3. 从数据库加载
    st, err := c.db.State(ctx, key)
    if err != nil {
        return nil, err
    }
    
    // 填充缓存
    c.memCache.Put(key, st)
    c.diskCache.Put(key, st)
    
    return st, nil
}

func (c *checkpointStateCache) Put(checkpoint *ethpb.Checkpoint, st state.BeaconState) {
    key := bytesutil.ToBytes32(checkpoint.Root)
    
    // 写入所有层级
    c.memCache.Put(key, st)
    c.diskCache.Put(key, st)
}
```

### 26.3.3 预加载策略

```go
// beacon-chain/blockchain/state_cache.go
type stateCachePreloader struct {
    chain     *Service
    cache     *checkpointStateCache
    preloadCh chan types.Epoch
}

func (p *stateCachePreloader) Start(ctx context.Context) {
    go p.preloadLoop(ctx)
}

func (p *stateCachePreloader) preloadLoop(ctx context.Context) {
    ticker := time.NewTicker(12 * time.Second) // 每个slot
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            p.preloadNextEpochs(ctx)
        }
    }
}

func (p *stateCachePreloader) preloadNextEpochs(ctx context.Context) {
    currentEpoch := slots.ToEpoch(p.chain.HeadSlot())
    
    // 预加载接下来的2个epoch的checkpoint states
    for i := types.Epoch(0); i < 2; i++ {
        targetEpoch := currentEpoch + i + 1
        checkpoint := &ethpb.Checkpoint{
            Epoch: targetEpoch,
            Root:  p.chain.GetCheckpointRoot(targetEpoch),
        }
        
        // 异步加载
        go func(cp *ethpb.Checkpoint) {
            if _, err := p.cache.Get(ctx, cp); err != nil {
                log.WithError(err).Debug("Failed to preload checkpoint state")
            }
        }(checkpoint)
    }
}
```

## 26.4 内存优化

### 26.4.1 对象池

```go
// beacon-chain/sync/pool.go
var (
    // 区块对象池
    blockPool = sync.Pool{
        New: func() interface{} {
            return &ethpb.SignedBeaconBlock{}
        },
    }
    
    // 状态对象池
    statePool = sync.Pool{
        New: func() interface{} {
            return &ethpb.BeaconState{}
        },
    }
    
    // 缓冲区池
    bufferPool = sync.Pool{
        New: func() interface{} {
            return new(bytes.Buffer)
        },
    }
)

func getBlock() *ethpb.SignedBeaconBlock {
    return blockPool.Get().(*ethpb.SignedBeaconBlock)
}

func putBlock(block *ethpb.SignedBeaconBlock) {
    // 重置对象以避免内存泄漏
    block.Reset()
    blockPool.Put(block)
}

func getBuffer() *bytes.Buffer {
    buf := bufferPool.Get().(*bytes.Buffer)
    buf.Reset()
    return buf
}

func putBuffer(buf *bytes.Buffer) {
    // 如果buffer太大，不放回池中
    if buf.Cap() > 64*1024 {
        return
    }
    bufferPool.Put(buf)
}
```

### 26.4.2 零拷贝优化

```go
// beacon-chain/p2p/encoder/ssz.go
type SszNetworkEncoder struct {
    buf []byte
}

func (e *SszNetworkEncoder) DecodeWithMaxLength(r io.Reader, to interface{}, maxSize uint64) error {
    // 读取长度前缀
    var msgLen uint64
    if err := binary.Read(r, binary.LittleEndian, &msgLen); err != nil {
        return err
    }
    
    if msgLen > maxSize {
        return errors.New("message too large")
    }
    
    // 复用缓冲区，避免重复分配
    if uint64(cap(e.buf)) < msgLen {
        e.buf = make([]byte, msgLen)
    } else {
        e.buf = e.buf[:msgLen]
    }
    
    // 直接读取到缓冲区
    if _, err := io.ReadFull(r, e.buf); err != nil {
        return err
    }
    
    // 使用零拷贝反序列化
    return to.(interface {
        UnmarshalSSZ([]byte) error
    }).UnmarshalSSZ(e.buf)
}
```

### 26.4.3 内存回收策略

```go
// beacon-chain/db/kv/state_summary.go
type stateSummaryCache struct {
    cache           *LRUCache
    maxMemoryUsage  uint64
    currentUsage    uint64
    mu              sync.RWMutex
    gcTicker        *time.Ticker
}

func newStateSummaryCache(maxMemoryMB uint64) *stateSummaryCache {
    c := &stateSummaryCache{
        cache:          NewLRUCache(1000),
        maxMemoryUsage: maxMemoryMB * 1024 * 1024,
        gcTicker:       time.NewTicker(30 * time.Second),
    }
    
    go c.gcLoop()
    return c
}

func (c *stateSummaryCache) gcLoop() {
    for range c.gcTicker.C {
        c.collectGarbage()
    }
}

func (c *stateSummaryCache) collectGarbage() {
    c.mu.Lock()
    defer c.mu.Unlock()
    
    // 检查内存使用
    if c.currentUsage < c.maxMemoryUsage {
        return
    }
    
    // 强制GC
    runtime.GC()
    
    // 清理一半的缓存
    targetSize := c.cache.Len() / 2
    for c.cache.Len() > targetSize {
        // LRU会自动移除最旧的条目
        c.cache.RemoveOldest()
    }
    
    // 更新内存使用统计
    var m runtime.MemStats
    runtime.ReadMemStats(&m)
    c.currentUsage = m.Alloc
    
    log.WithFields(logrus.Fields{
        "alloc":      m.Alloc / 1024 / 1024,
        "totalAlloc": m.TotalAlloc / 1024 / 1024,
        "sys":        m.Sys / 1024 / 1024,
        "numGC":      m.NumGC,
    }).Debug("Memory stats after GC")
}
```

这一章详细介绍了Prysm中的各种性能优化策略，包括批量处理、并发处理、缓存策略和内存优化。这些优化技术对于构建高性能的beacon节点至关重要。
