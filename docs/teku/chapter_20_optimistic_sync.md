# 第 20 章: Teku Optimistic Sync

## 20.1 Optimistic Sync 原理

允许 CL 在 EL 同步完成前接受区块，提升用户体验。

```
CL Sync ━━━━━━━━━━━━━→ Current Head (Optimistic)
          ↓
EL Sync ━━━━━━━━━━━━━━━→ Validated
```

## 20.2 实现

```java
public class OptimisticSyncService {
  public SafeFuture<BlockImportResult> importOptimistically(
      SignedBeaconBlock block) {
    
    return validateConsensus(block)
      .thenCompose(result -> {
        if (result.isValid()) {
          // 标记为 optimistic
          return importAsOptimistic(block);
        }
        return SafeFuture.completedFuture(
          BlockImportResult.failed(result.getFailureReason())
        );
      });
  }
  
  private SafeFuture<BlockImportResult> importAsOptimistic(
      SignedBeaconBlock block) {
    
    block.markAsOptimistic();
    
    return blockImporter.importBlock(block)
      .thenCompose(result -> {
        // 等待 EL 验证
        return waitForExecutionValidation(block)
          .thenApply(elValid -> {
            if (elValid) {
              block.markAsValidated();
            } else {
              revertOptimisticBlock(block);
            }
            return result;
          });
      });
  }
}
```

## 20.3 安全保证

- ✅ Fork choice 正确性
- ✅ 不参与证明
- ✅ EL 验证失败回滚

---

**最后更新**: 2026-01-13
