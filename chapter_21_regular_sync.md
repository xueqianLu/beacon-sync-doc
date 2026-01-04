# 第21章 Regular Sync概述

## 21.1 与Initial Sync的区别

### 21.1.1 同步模式对比

```
┌─────────────────┬────────────────┬─────────────────┐
│   特性          │ Initial Sync   │ Regular Sync    │
├─────────────────┼────────────────┼─────────────────┤
│ 触发时机        │ 节点启动       │ 持续运行        │
│ 数据来源        │ Req/Resp主导   │ Gossipsub主导   │
│ 同步范围        │ 大量历史区块   │ 最新几个区块    │
│ Peer策略        │ 批量轮询       │ 被动接收        │
│ 验证强度        │ 可降低         │ 完全验证        │
│ 状态            │ Syncing        │ Synced          │
└─────────────────┴────────────────┴─────────────────┘
```

### 21.1.2 Regular Sync特点

```go
// Regular sync主要职责
type RegularSync struct {
    // 1. 监听Gossipsub消息
    subscribeToTopics()
    
    // 2. 实时验证新区块
    validateIncomingBlocks()
    
    // 3. 处理缺失父块
    handleMissingParents()
    
    // 4. 管理pending队列
    managePendingQueue()
    
    // 5. 更新fork choice
    updateForkChoice()
}
```

---

## 21.2 实时跟踪网络头部

### 21.2.1 Gossipsub监听

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
    
    // 快速路径：直接处理
    if s.hasParent(signed) {
        return s.chain.ReceiveBlock(ctx, signed, blockRoot)
    }
    
    // 慢速路径：父块缺失，加入pending队列
    return s.addToPendingQueue(signed)
}
```

### 21.2.2 实时性保证

```go
// Regular sync的时间约束
const (
    // 区块必须在SECONDS_PER_SLOT内传播
    SECONDS_PER_SLOT = 12
    
    // 允许的时钟偏差
    MAXIMUM_GOSSIP_CLOCK_DISPARITY = 500 * time.Millisecond
    
    // Attestation传播时间窗口  
    ATTESTATION_PROPAGATION_SLOT_RANGE = 32 // 1 epoch
)

func (s *Service) validateBlockTime(block interfaces.SignedBeaconBlock) error {
    blockSlot := block.Block().Slot()
    currentSlot := s.chain.CurrentSlot()
    
    // 不能太早
    if blockSlot > currentSlot+1 {
        return errors.New("block is too far in the future")
    }
    
    // 不能太晚
    if blockSlot+ATTESTATION_PROPAGATION_SLOT_RANGE < currentSlot {
        return errors.New("block is too old")
    }
    
    return nil
}
```

---

## 21.3 触发条件

### 21.3.1 从Initial切换到Regular

```go
func (s *Service) checkTransitionToRegularSync() {
    currentSlot := s.chain.CurrentSlot()
    headSlot := s.chain.HeadSlot()
    
    // 只落后不到1个epoch，切换到regular sync
    if currentSlot-headSlot < params.BeaconConfig().SlotsPerEpoch {
        s.setInitialSyncComplete()
        log.Info("Transitioned to regular sync")
    }
}
```

### 21.3.2 Regular Sync工作流

```
           Gossipsub消息到达
                  ↓
            验证消息有效性
                  ↓
              有父块？
            ╱          ╲
          Yes           No
           ↓             ↓
      直接处理      加入Pending队列
           ↓             ↓
      更新Head     请求缺失父块
           ↓             ↓
      转发消息      父块到达后处理
```

### 21.3.3 保持同步状态

```go
func (s *Service) maintainSync() {
    ticker := time.NewTicker(12 * time.Second) // 每个slot检查
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            // 检查是否落后
            if s.isFallingBehind() {
                log.Warn("Falling behind, may need to resync")
                s.requestMissingBlocks()
            }
            
        case <-s.ctx.Done():
            return
        }
    }
}

func (s *Service) isFallingBehind() bool {
    currentSlot := s.chain.CurrentSlot()
    headSlot := s.chain.HeadSlot()
    
    // 落后超过2个epoch认为是falling behind
    return currentSlot-headSlot > 2*params.BeaconConfig().SlotsPerEpoch
}
```

---

## 21.4 性能优化

### 21.4.1 早期拒绝（Early Rejection）

```go
func (s *Service) validateBeaconBlockPubSub(
    ctx context.Context,
    msg *pubsub.Message,
) pubsub.ValidationResult {
    // 1. 快速检查：是否已seen
    if s.hasSeenBlock(msg.ID) {
        return pubsub.ValidationIgnore
    }
    
    // 2. 快速检查：slot是否合理
    if err := s.quickValidateSlot(msg.Data); err != nil {
        return pubsub.ValidationReject
    }
    
    // 3. 完整验证
    return s.fullValidateBlock(ctx, msg)
}
```

### 21.4.2 批量处理

```go
// 累积一小批blocks后批量处理
func (s *Service) batchProcessor() {
    batch := make([]interfaces.SignedBeaconBlock, 0, 32)
    timer := time.NewTimer(100 * time.Millisecond)
    
    for {
        select {
        case block := <-s.blockChan:
            batch = append(batch, block)
            if len(batch) >= 32 {
                s.processBatch(batch)
                batch = batch[:0]
            }
            
        case <-timer.C:
            if len(batch) > 0 {
                s.processBatch(batch)
                batch = batch[:0]
            }
            timer.Reset(100 * time.Millisecond)
        }
    }
}
```

---

**下一章**: 第22章 Block Processing Pipeline详解
