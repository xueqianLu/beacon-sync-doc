# 第22章 Block Processing Pipeline

## 22.1 区块接收流程

### 22.1.1 多源输入

```
区块来源：
┌─────────────────┐     ┌─────────────────┐
│   Gossipsub     │     │   Req/Resp      │
│  (实时广播)     │     │  (主动请求)     │
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     ↓
            ┌────────────────┐
            │  Block Router  │
            └────────┬───────┘
                     ↓
            ┌────────────────┐
            │ Validation     │
            │ Pipeline       │
            └────────────────┘
```

### 22.1.2 从Gossipsub接收

```go
// 来自prysm/beacon-chain/sync/subscriber_beacon_blocks.go
func (s *Service) beaconBlockSubscriber(
    ctx context.Context,
    msg proto.Message,
) error {
    signed, ok := msg.(interfaces.SignedBeaconBlock)
    if !ok {
        return errors.New("invalid block type")
    }
    
    blockRoot, err := signed.Block().HashTreeRoot()
    if err != nil {
        return err
    }
    
    // 去重检查
    if s.hasSeenBlockRoot(blockRoot) {
        return nil
    }
    s.markSeenBlockRoot(blockRoot)
    
    // 路由到处理pipeline
    return s.receiveBlock(ctx, signed, blockRoot)
}
```

### 22.1.3 从Req/Resp接收

```go
// 主动请求的blocks直接进入pipeline
func (s *Service) processRequestedBlock(
    ctx context.Context,
    signed interfaces.SignedBeaconBlock,
) error {
    blockRoot, err := signed.Block().HashTreeRoot()
    if err != nil {
        return err
    }
    
    return s.receiveBlock(ctx, signed, blockRoot)
}
```

---

## 22.2 区块验证阶段

### 22.2.1 验证层次

```
┌─────────────────────────────────────┐
│  Level 1: 基本格式验证 (快速)       │
│  - SSZ解码                          │
│  - 字段范围检查                     │
│  - Slot时间有效性                   │
└───────────────┬─────────────────────┘
                ↓
┌─────────────────────────────────────┐
│  Level 2: 签名验证 (中速)           │
│  - 提议者签名                       │
│  - RANDAO签名                       │
│  - Attestation签名(批量)            │
└───────────────┬─────────────────────┘
                ↓
┌─────────────────────────────────────┐
│  Level 3: 状态转换验证 (慢速)      │
│  - 获取父状态                       │
│  - 执行状态转换                     │
│  - 验证状态root                     │
└─────────────────────────────────────┘
```

### 22.2.2 基本格式验证

```go
// 来自prysm/beacon-chain/sync/validate_beacon_blocks.go
func (s *Service) validateBasicBlock(
    block interfaces.SignedBeaconBlock,
) error {
    // 1. Slot检查
    if block.Block().Slot() == 0 {
        return errors.New("genesis block")
    }
    
    // 2. 时间检查
    if err := s.validateBlockTime(block); err != nil {
        return err
    }
    
    // 3. 提议者索引检查
    proposerIndex := block.Block().ProposerIndex()
    if proposerIndex >= primitives.ValidatorIndex(len(s.cfg.Chain.HeadValidatorsIndices())) {
        return errors.New("invalid proposer index")
    }
    
    return nil
}
```

### 22.2.3 签名验证

```go
func (s *Service) validateBlockSignatures(
    ctx context.Context,
    block interfaces.SignedBeaconBlock,
) error {
    // 1. 提议者签名
    if err := s.verifyProposerSignature(block); err != nil {
        return errors.Wrap(err, "proposer signature invalid")
    }
    
    // 2. RANDAO reveal签名
    if err := s.verifyRandaoReveal(block); err != nil {
        return errors.Wrap(err, "randao reveal invalid")
    }
    
    // 3. Attestation签名（批量验证）
    if err := s.batchVerifyAttestations(block.Block().Body().Attestations()); err != nil {
        return errors.Wrap(err, "attestation signatures invalid")
    }
    
    return nil
}
```

### 22.2.4 状态转换验证

```go
func (s *Service) validateStateTransition(
    ctx context.Context,
    block interfaces.SignedBeaconBlock,
) error {
    // 1. 获取父状态
    parentRoot := block.Block().ParentRoot()
    preState, err := s.cfg.StateGen.StateByRoot(ctx, parentRoot)
    if err != nil {
        return errors.Wrap(err, "could not get pre state")
    }
    
    // 2. 执行状态转换
    postState, err := transition.ExecuteStateTransition(
        ctx,
        preState,
        block,
    )
    if err != nil {
        return errors.Wrap(err, "state transition failed")
    }
    
    // 3. 验证状态root
    stateRoot, err := postState.HashTreeRoot(ctx)
    if err != nil {
        return err
    }
    
    if stateRoot != block.Block().StateRoot() {
        return errors.New("state root mismatch")
    }
    
    return nil
}
```

---

## 22.3 Pending Blocks队列

### 22.3.1 队列必要性

父块未到达时，子块需要暂存：

```
时间线：
t0: 收到Block N+2 (父块缺失)
    └─> 加入Pending队列

t1: 收到Block N+1 (父块缺失)
    └─> 加入Pending队列

t2: 收到Block N (可以处理)
    └─> 处理Block N
    └─> 触发处理Block N+1
    └─> 触发处理Block N+2
```

### 22.3.2 队列数据结构

```go
// 来自prysm/beacon-chain/sync/pending_blocks_queue.go
type pendingQueueBlock struct {
    block      interfaces.SignedBeaconBlock
    blockRoot  [32]byte
    parentRoot [32]byte
}

type Service struct {
    // Pending队列
    slotToPendingBlocks  map[primitives.Slot]*pendingQueueBlock
    seenPendingBlocks    map[[32]byte]bool
    pendingQueueLock     sync.RWMutex
}
```

### 22.3.3 加入队列

```go
func (s *Service) addToPendingQueue(
    block interfaces.SignedBeaconBlock,
    blockRoot [32]byte,
) error {
    s.pendingQueueLock.Lock()
    defer s.pendingQueueLock.Unlock()
    
    // 1. 去重检查
    if s.seenPendingBlocks[blockRoot] {
        return nil
    }
    
    // 2. 检查队列大小
    if len(s.slotToPendingBlocks) >= maxPendingBlocks {
        return errors.New("pending queue full")
    }
    
    // 3. 加入队列
    slot := block.Block().Slot()
    s.slotToPendingBlocks[slot] = &pendingQueueBlock{
        block:      block,
        blockRoot:  blockRoot,
        parentRoot: block.Block().ParentRoot(),
    }
    s.seenPendingBlocks[blockRoot] = true
    
    log.WithFields(logrus.Fields{
        "slot":       slot,
        "blockRoot":  fmt.Sprintf("%#x", blockRoot),
        "parentRoot": fmt.Sprintf("%#x", block.Block().ParentRoot()),
    }).Debug("Added block to pending queue")
    
    // 4. 请求缺失父块
    go s.requestParentBlock(block.Block().ParentRoot())
    
    return nil
}
```

### 22.3.4 处理队列

```go
func (s *Service) processPendingBlocks(
    ctx context.Context,
    parentRoot [32]byte,
) error {
    s.pendingQueueLock.Lock()
    defer s.pendingQueueLock.Unlock()
    
    // 查找所有以parentRoot为父的blocks
    var childBlocks []*pendingQueueBlock
    for slot, pendingBlk := range s.slotToPendingBlocks {
        if pendingBlk.parentRoot == parentRoot {
            childBlocks = append(childBlocks, pendingBlk)
            delete(s.slotToPendingBlocks, slot)
        }
    }
    
    // 按slot排序
    sort.Slice(childBlocks, func(i, j int) bool {
        return childBlocks[i].block.Block().Slot() < childBlocks[j].block.Block().Slot()
    })
    
    // 递归处理
    for _, childBlk := range childBlocks {
        if err := s.receiveBlock(ctx, childBlk.block, childBlk.blockRoot); err != nil {
            log.WithError(err).Error("Failed to process pending block")
            continue
        }
        
        // 处理完后，检查是否有更多子块
        go s.processPendingBlocks(ctx, childBlk.blockRoot)
    }
    
    return nil
}
```

### 22.3.5 超时与清理

```go
func (s *Service) cleanupPendingQueue() {
    ticker := time.NewTicker(time.Minute)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            s.pendingQueueLock.Lock()
            
            currentSlot := s.cfg.Chain.CurrentSlot()
            for slot, pendingBlk := range s.slotToPendingBlocks {
                // 超过32个slot还未处理，清除
                if currentSlot-slot > 32 {
                    delete(s.slotToPendingBlocks, slot)
                    delete(s.seenPendingBlocks, pendingBlk.blockRoot)
                    log.WithField("slot", slot).Debug("Removed stale pending block")
                }
            }
            
            s.pendingQueueLock.Unlock()
            
        case <-s.ctx.Done():
            return
        }
    }
}
```

---

## 22.4 完整Pipeline代码

```go
func (s *Service) receiveBlock(
    ctx context.Context,
    block interfaces.SignedBeaconBlock,
    blockRoot [32]byte,
) error {
    // Stage 1: 基本验证
    if err := s.validateBasicBlock(block); err != nil {
        return errors.Wrap(err, "basic validation failed")
    }
    
    // Stage 2: 检查父块
    parentRoot := block.Block().ParentRoot()
    if !s.hasBlock(parentRoot) {
        // 父块缺失，加入pending队列
        return s.addToPendingQueue(block, blockRoot)
    }
    
    // Stage 3: 签名验证
    if err := s.validateBlockSignatures(ctx, block); err != nil {
        return errors.Wrap(err, "signature validation failed")
    }
    
    // Stage 4: 状态转换
    if err := s.validateStateTransition(ctx, block); err != nil {
        return errors.Wrap(err, "state transition failed")
    }
    
    // Stage 5: 提交给blockchain service
    if err := s.cfg.Chain.ReceiveBlock(ctx, block, blockRoot); err != nil {
        return errors.Wrap(err, "blockchain service rejected block")
    }
    
    // Stage 6: 处理pending子块
    go s.processPendingBlocks(ctx, blockRoot)
    
    log.WithFields(logrus.Fields{
        "slot":      block.Block().Slot(),
        "blockRoot": fmt.Sprintf("%#x", blockRoot),
    }).Info("Block processed successfully")
    
    return nil
}
```

---

**下一章**: 第23章 缺失父块处理机制
