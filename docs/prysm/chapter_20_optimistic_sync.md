# 第20章 Optimistic Sync详解

## 20.1 Optimistic Sync原理

### 20.1.1 为什么需要Optimistic Sync

合并后，CL需要EL验证执行payload，但EL同步慢：

```
问题：
CL同步快 ──> 等待EL验证 ──> 延迟增加
                ↑
          EL同步慢（可能数小时）

解决：
CL先乐观接受 ──> 异步等待EL ──> 降低延迟
             ↓
          后台验证
```

### 20.1.2 三种Head状态

```go
type HeadStatus int

const (
    // Optimistic: CL接受但EL未验证
    Optimistic HeadStatus = iota
    
    // Validated: EL已验证通过  
    Validated
    
    // Invalid: EL验证失败
    Invalid
)
```

### 20.1.3 状态转换

```
接收新区块
    ↓
CL验证通过？ ──No──> 拒绝
    ↓ Yes
父块已验证？
    ↓ Yes              ↓ No
提交EL验证         标记Optimistic
    ↓                   ↓
验证通过？ ──No─> 回滚   等待父块验证
    ↓ Yes              ↓
标记Validated      继续等待
```

### 20.1.4 实现代码

```go
// 来自prysm/beacon-chain/blockchain/optimistic_sync.go
func (s *Service) onBlockOptimistic(
    ctx context.Context,
    signed interfaces.SignedBeaconBlock,
) error {
    blockRoot, err := signed.Block().HashTreeRoot()
    if err != nil {
        return err
    }
    
    // 1. CL验证
    if err := s.validateBlock(ctx, signed); err != nil {
        return err
    }
    
    // 2. 检查父块状态
    parentOptimistic, err := s.IsOptimistic(ctx)
    if err != nil {
        return err
    }
    
    // 3. 如果父块是optimistic，这个块也标记为optimistic
    if parentOptimistic {
        s.markOptimistic(blockRoot)
    }
    
    // 4. 提交给EL异步验证
    go s.validateWithEL(ctx, signed, blockRoot)
    
    return s.saveBlock(ctx, signed)
}

func (s *Service) validateWithEL(
    ctx context.Context,
    signed interfaces.SignedBeaconBlock,
    blockRoot [32]byte,
) {
    // 调用Engine API验证
    valid, err := s.cfg.ExecutionEngineCaller.ValidatePayload(
        ctx,
        signed.Block().Body().ExecutionPayload(),
    )
    
    if err != nil || !valid {
        // 验证失败，标记为invalid
        s.markInvalid(blockRoot)
        // 需要回滚到上一个valid head
        s.rollbackToValidHead(ctx)
        return
    }
    
    // 验证成功，标记为validated
    s.markValidated(blockRoot)
}
```

---

## 20.2 安全保证

### 20.2.1 限制条件

```python
# 只能在justified之后optimistic
def can_optimistic_sync(block, store):
    justified_checkpoint = store.justified_checkpoint
    
    # Block必须是justified checkpoint的后代
    return is_descendant(
        store,
        justified_checkpoint.root,
        block.parent_root
    )
```

### 20.2.2 回滚机制

```go
func (s *Service) rollbackToValidHead(ctx context.Context) error {
    // 1. 找到最近的validated block
    validRoot := s.findLastValidatedRoot()
    
    // 2. 回滚head
    if err := s.updateHead(ctx, validRoot); err != nil {
        return err
    }
    
    // 3. 清理invalid blocks
    return s.pruneInvalidBranch(validRoot)
}
```

---

## 20.3 性能影响

**同步时间对比**:
```
无Optimistic: CL等待EL ──> 可能数小时延迟
有Optimistic: CL继续前进 ──> 数分钟内跟上head
```

**权衡**:
- ✅ 更快跟上网络
- ⚠️ 临时接受未完全验证的blocks
- ✅ 最终都会被EL验证

---

**下一章**: 第21章 Regular Sync概述
