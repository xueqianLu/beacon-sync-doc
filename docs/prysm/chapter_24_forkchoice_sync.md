# 第 24 章 Fork 选择与同步

## 24.1 LMD-GHOST 算法回顾

### 24.1.1 基本原理

Latest Message Driven GHOST (Greedy Heaviest Observed SubTree):

```
        Root
       /    \
      A(8)  B(12)
     /  \    /  \
   C(3) D(5) E(7) F(5)

权重 = 该子树中所有验证者的最新投票
选择: Root -> B -> E (最重路径)
```

### 24.1.2 在同步中的作用

```go
// 每次接收新区块或attestation后更新fork choice
func (s *Service) onBlock(
    ctx context.Context,
    block interfaces.SignedBeaconBlock,
) error {
    // 1. 处理区块
    if err := s.processBlock(ctx, block); err != nil {
        return err
    }

    // 2. 更新fork choice
    blockRoot, _ := block.Block().HashTreeRoot()
    if err := s.updateForkChoice(ctx, blockRoot); err != nil {
        return err
    }

    // 3. 检查是否需要更新head
    newHead, err := s.cfg.ForkChoiceStore.Head(ctx)
    if err != nil {
        return err
    }

    if newHead != s.headRoot() {
        return s.updateHead(ctx, newHead)
    }

    return nil
}
```

---

## 24.2 Fork Choice 更新触发

### 24.2.1 触发时机

```
触发Fork Choice更新的事件：

1. 新区块到达
   block_received ──> update_fork_choice()

2. 新attestation到达
   attestation_received ──> update_weights() ──> recompute_head()

3. Slot tick
   on_tick() ──> update_time() ──> recompute_head()

4. Finality更新
   checkpoint_finalized ──> prune_forks() ──> recompute_head()
```

### 24.2.2 实现代码

```go
// 来自prysm/beacon-chain/forkchoice/doubly-linked-tree/forkchoice.go
func (f *ForkChoice) ProcessBlock(
    ctx context.Context,
    slot primitives.Slot,
    blockRoot [32]byte,
    parentRoot [32]byte,
    justifiedEpoch primitives.Epoch,
    finalizedEpoch primitives.Epoch,
) error {
    f.Lock()
    defer f.Unlock()

    // 1. 添加新节点到fork choice树
    if err := f.insertNode(ctx, slot, blockRoot, parentRoot); err != nil {
        return err
    }

    // 2. 更新justified/finalized信息
    if err := f.updateCheckpoints(justifiedEpoch, finalizedEpoch); err != nil {
        return err
    }

    // 3. 修剪已finalized之前的分支
    if err := f.prune(finalizedEpoch); err != nil {
        return err
    }

    return nil
}

func (f *ForkChoice) ProcessAttestation(
    ctx context.Context,
    validatorIndices []uint64,
    blockRoot [32]byte,
    targetEpoch primitives.Epoch,
) error {
    f.Lock()
    defer f.Unlock()

    // 更新验证者的最新投票
    for _, index := range validatorIndices {
        f.store.latestMessages[index] = &latestMessage{
            epoch:  targetEpoch,
            root:   blockRoot,
            weight: f.balanceByValidatorIndex(index),
        }
    }

    // 重新计算权重
    return f.updateWeights(ctx)
}
```

---

## 24.3 Head 更新与同步状态

### 24.3.1 Head 更新流程

```go
func (s *Service) updateHead(ctx context.Context, newHeadRoot [32]byte) error {
    // 1. 获取新head的block和state
    newHeadBlock, err := s.cfg.BeaconDB.Block(ctx, newHeadRoot)
    if err != nil {
        return err
    }

    newHeadState, err := s.cfg.StateGen.StateByRoot(ctx, newHeadRoot)
    if err != nil {
        return err
    }

    // 2. 更新head
    s.headLock.Lock()
    s.headRoot = newHeadRoot
    s.headBlock = newHeadBlock
    s.headState = newHeadState
    s.headLock.Unlock()

    // 3. 广播head更新事件
    s.cfg.StateNotifier.StateFeed().Send(&feed.Event{
        Type: statefeed.NewHead,
        Data: &statefeed.BlockProcessedData{
            Slot:      newHeadBlock.Block().Slot(),
            BlockRoot: newHeadRoot,
            Optimistic: s.isOptimistic(newHeadRoot),
        },
    })

    log.WithFields(logrus.Fields{
        "slot":     newHeadBlock.Block().Slot(),
        "headRoot": fmt.Sprintf("%#x", newHeadRoot),
    }).Info("Head updated")

    return nil
}
```

### 24.3.2 同步状态判断

```go
func (s *Service) IsSynced() bool {
    currentSlot := s.CurrentSlot()
    headSlot := s.HeadSlot()

    // 落后不超过1个epoch认为是synced
    return currentSlot-headSlot <= params.BeaconConfig().SlotsPerEpoch
}

func (s *Service) SyncStatus() *ethpb.SyncStatus {
    currentSlot := s.CurrentSlot()
    headSlot := s.HeadSlot()

    return &ethpb.SyncStatus{
        CurrentSlot: uint64(currentSlot),
        HeadSlot:    uint64(headSlot),
        IsSyncing:   !s.IsSynced(),
        IsOptimistic: s.IsOptimistic(),
    }
}
```

---

## 24.4 Reorg 处理

### 24.4.1 Reorg 检测

```go
func (s *Service) isReorg(
    oldHeadRoot [32]byte,
    newHeadRoot [32]byte,
) bool {
    // 如果新head不是旧head的后代，则发生了reorg
    return !s.isDescendant(oldHeadRoot, newHeadRoot)
}

func (s *Service) isDescendant(ancestor, descendant [32]byte) bool {
    current := descendant

    // 向上查找直到找到ancestor或到达finalized checkpoint
    for {
        if current == ancestor {
            return true
        }

        block, err := s.cfg.BeaconDB.Block(s.ctx, current)
        if err != nil {
            return false
        }

        // 到达finalized checkpoint，停止
        if block.Block().Slot() <= s.FinalizedCheckpoint().Epoch*params.BeaconConfig().SlotsPerEpoch {
            return false
        }

        current = block.Block().ParentRoot()
    }
}
```

### 24.4.2 Reorg 处理

```go
func (s *Service) handleReorg(
    ctx context.Context,
    oldHeadRoot [32]byte,
    newHeadRoot [32]byte,
) error {
    oldBlock, _ := s.cfg.BeaconDB.Block(ctx, oldHeadRoot)
    newBlock, _ := s.cfg.BeaconDB.Block(ctx, newHeadRoot)

    reorgDistance := oldBlock.Block().Slot() - newBlock.Block().Slot()

    log.WithFields(logrus.Fields{
        "oldSlot":       oldBlock.Block().Slot(),
        "newSlot":       newBlock.Block().Slot(),
        "reorgDistance": reorgDistance,
    }).Warn("Chain reorg detected")

    // 1. 广播reorg事件
    s.cfg.StateNotifier.StateFeed().Send(&feed.Event{
        Type: statefeed.Reorg,
        Data: &statefeed.ReorgData{
            OldHeadRoot:   oldHeadRoot,
            OldHeadSlot:   oldBlock.Block().Slot(),
            NewHeadRoot:   newHeadRoot,
            NewHeadSlot:   newBlock.Block().Slot(),
            ReorgDistance: uint64(reorgDistance),
        },
    })

    // 2. 清理被reorg掉的分支上的数据
    return s.pruneReorgedBranch(ctx, oldHeadRoot, newHeadRoot)
}
```

### 24.4.3 Reorg 影响

```
Reorg的影响：

1. Attestation池
   - 需要重新验证attestations
   - 移除invalid的attestations

2. 区块池
   - 某些pending blocks可能需要重新评估

3. 验证者
   - 可能需要重新计算duties
   - 影响attestation和block提议

4. API用户
   - Head变化，查询结果可能改变
   - 需要通知订阅者
```

---

## 24.5 性能优化

### 24.5.1 延迟 Head 更新

```go
// 避免频繁更新head
func (s *Service) maybeUpdateHead(ctx context.Context) error {
    // 只在必要时更新
    newHead, err := s.cfg.ForkChoiceStore.Head(ctx)
    if err != nil {
        return err
    }

    // 如果head没变化，跳过
    if newHead == s.headRoot() {
        return nil
    }

    // 如果新head的权重优势不明显，等待
    currentWeight := s.cfg.ForkChoiceStore.Weight(s.headRoot())
    newWeight := s.cfg.ForkChoiceStore.Weight(newHead)

    if newWeight-currentWeight < minWeightDifference {
        return nil
    }

    return s.updateHead(ctx, newHead)
}
```

### 24.5.2 批量处理 Attestations

```go
func (s *Service) batchProcessAttestations(
    atts []ethpb.Attestation,
) error {
    // 按target epoch分组
    groups := make(map[primitives.Epoch][]*ethpb.Attestation)
    for _, att := range atts {
        epoch := att.Data.Target.Epoch
        groups[epoch] = append(groups[epoch], att)
    }

    // 批量更新fork choice
    for epoch, group := range groups {
        if err := s.updateForkChoiceWithAttestations(epoch, group); err != nil {
            return err
        }
    }

    // 只在最后重新计算head
    return s.recomputeHead()
}
```

---

## 24.6 小结

本章介绍了 Fork 选择如何与同步协同工作：

- **LMD-GHOST**: 选择最重分支作为 canonical chain
- **更新触发**: 区块、attestation、时间 tick 都会触发
- **Head 管理**: 动态跟踪和更新 chain head
- **Reorg 处理**: 检测和处理链重组
- **性能优化**: 批量处理、延迟更新

Fork 选择是共识的核心，确保网络中所有节点最终收敛到同一条链上。

---

## 阶段小结：Initial Sync 与 Regular Sync（第 17-24 章）

至此，我们完成了：

- **第五部分**: Initial Sync (第 17-20 章)
- **第六部分**: Regular Sync (第 21-24 章)

这两部分深入讲解了 Beacon 节点同步的核心机制，从初始同步的不同策略到常规同步的实时处理，构建了完整的同步知识体系。

**已完成章节总览**:

- 第 1-2 章: 基础概念与架构
- 第 17-20 章: 初始同步
- 第 21-24 章: Regular Sync

后续章节建议继续补齐其他同步机制与辅助模块，以便形成更完整的 Beacon 同步知识体系。
