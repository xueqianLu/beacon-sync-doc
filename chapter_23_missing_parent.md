# 第23章 缺失父块处理

## 23.1 检测缺失父块

### 23.1.1 触发场景

```
场景1: 网络延迟
Block N+1到达 -> 但Block N还在网络中

场景2: Peer发送顺序
Peer先发送子块，后发送父块

场景3: 网络分区
部分区块未能传播到本节点
```

### 23.1.2 检测机制

```go
func (s *Service) hasParentBlock(block interfaces.SignedBeaconBlock) bool {
    parentRoot := block.Block().ParentRoot()
    
    // 1. 检查数据库
    if s.cfg.BeaconDB.HasBlock(s.ctx, parentRoot) {
        return true
    }
    
    // 2. 检查fork choice store
    if s.cfg.ForkChoiceStore.HasNode(parentRoot) {
        return true
    }
    
    // 3. 检查pending queue
    s.pendingQueueLock.RLock()
    defer s.pendingQueueLock.RUnlock()
    
    for _, pendingBlk := range s.slotToPendingBlocks {
        if pendingBlk.blockRoot == parentRoot {
            return true
        }
    }
    
    return false
}
```

---

## 23.2 请求策略

### 23.2.1 使用BeaconBlocksByRoot

```go
// 单个或少量缺失块，使用BlocksByRoot
func (s *Service) requestParentBlock(parentRoot [32]byte) error {
    // 1. 选择最佳peer
    peers := s.findPeersWithBlock(parentRoot)
    if len(peers) == 0 {
        return errors.New("no peers have the block")
    }
    
    // 2. 构造请求
    req := &pb.BeaconBlocksByRootRequest{
        BlockRoots: [][]byte{parentRoot[:]},
    }
    
    // 3. 发送请求
    for _, pid := range peers {
        blocks, err := s.sendBlocksByRootRequest(s.ctx, pid, req)
        if err != nil {
            continue
        }
        
        if len(blocks) > 0 {
            return s.receiveBlock(s.ctx, blocks[0], parentRoot)
        }
    }
    
    return errors.New("failed to fetch parent block")
}
```

### 23.2.2 使用BeaconBlocksByRange

```go
// 连续多个块缺失，使用BlocksByRange
func (s *Service) requestBlockRange(
    startSlot primitives.Slot,
    count uint64,
) error {
    req := &pb.BeaconBlocksByRangeRequest{
        StartSlot: startSlot,
        Count:     count,
        Step:      1,
    }
    
    peers := s.cfg.P2P.Peers().Connected()
    if len(peers) == 0 {
        return errors.New("no connected peers")
    }
    
    for _, pid := range peers {
        blocks, err := s.sendBlocksByRangeRequest(s.ctx, pid, req)
        if err != nil {
            continue
        }
        
        // 处理返回的blocks
        for _, block := range blocks {
            blockRoot, _ := block.Block().HashTreeRoot()
            if err := s.receiveBlock(s.ctx, block, blockRoot); err != nil {
                log.WithError(err).Warn("Failed to process block from range")
            }
        }
        
        return nil
    }
    
    return errors.New("failed to fetch block range")
}
```

---

## 23.3 最大回溯深度

### 23.3.1 限制原因

```
防止：
1. 恶意peer导致无限回溯
2. 资源耗尽攻击
3. 同步陷入死循环
```

### 23.3.2 实现限制

```go
const (
    // 最大回溯深度：约1 epoch
    maxParentLookback = 32
)

func (s *Service) requestMissingParent(
    block interfaces.SignedBeaconBlock,
    depth int,
) error {
    // 检查深度限制
    if depth >= maxParentLookback {
        return errors.New("exceeded max parent lookback")
    }
    
    parentRoot := block.Block().ParentRoot()
    
    // 请求父块
    parentBlock, err := s.fetchBlockByRoot(parentRoot)
    if err != nil {
        return err
    }
    
    // 递归检查父块的父块
    if !s.hasParentBlock(parentBlock) {
        return s.requestMissingParent(parentBlock, depth+1)
    }
    
    return s.receiveBlock(s.ctx, parentBlock, parentRoot)
}
```

---

## 23.4 代码示例

### 23.4.1 完整的缺失块处理

```go
// 来自prysm/beacon-chain/sync/pending_blocks_queue.go
func (s *Service) handleBlockWithMissingParent(
    ctx context.Context,
    block interfaces.SignedBeaconBlock,
    blockRoot [32]byte,
) error {
    // 1. 加入pending队列
    if err := s.addToPendingQueue(block, blockRoot); err != nil {
        return err
    }
    
    // 2. 查找缺失的父块链
    missingRoots := s.findMissingAncestors(block.Block().ParentRoot())
    
    log.WithFields(logrus.Fields{
        "blockSlot":    block.Block().Slot(),
        "missingCount": len(missingRoots),
    }).Debug("Found missing ancestors")
    
    // 3. 批量请求
    if len(missingRoots) > 5 {
        // 多个缺失，使用range请求
        startSlot := block.Block().Slot() - primitives.Slot(len(missingRoots))
        return s.requestBlockRange(startSlot, uint64(len(missingRoots)))
    } else {
        // 少量缺失，使用root请求
        return s.requestBlocksByRoots(missingRoots)
    }
}

func (s *Service) findMissingAncestors(root [32]byte) [][32]byte {
    var missing [][32]byte
    current := root
    
    for i := 0; i < maxParentLookback; i++ {
        if s.hasBlock(current) {
            break
        }
        
        missing = append(missing, current)
        
        // 检查pending队列中是否有parent信息
        parent, found := s.getParentFromPending(current)
        if !found {
            break
        }
        current = parent
    }
    
    return missing
}
```

### 23.4.2 防御性编程

```go
func (s *Service) safelyRequestParent(parentRoot [32]byte) {
    // 使用goroutine异步请求，避免阻塞
    go func() {
        ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
        defer cancel()
        
        // 带超时的请求
        if err := s.requestParentBlock(parentRoot); err != nil {
            log.WithError(err).WithField(
                "parentRoot", fmt.Sprintf("%#x", parentRoot),
            ).Warn("Failed to request parent block")
        }
    }()
}
```

---

**下一章**: 第24章 Fork选择与同步
