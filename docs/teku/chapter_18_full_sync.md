# 第 18 章: Teku Full Sync 实现

## 18.1 Full Sync 流程

```java
public class FullSyncManager {
  public SafeFuture<Void> performFullSync() {
    UInt64 startSlot = getGenesisSlot();
    UInt64 targetSlot = getCurrentHeadSlot();
    
    return syncBlocks(startSlot, targetSlot)
      .thenCompose(this::validateChain)
      .thenAccept(__ -> {
        LOG.info("Full sync completed",
          kv("slots", targetSlot.minus(startSlot))
        );
      });
  }
  
  private SafeFuture<Void> syncBlocks(UInt64 start, UInt64 end) {
    return forwardSyncService.sync(start, end);
  }
}
```

## 18.2 批量处理策略

| 策略 | Prysm | Teku |
|------|-------|------|
| 批量大小 | 64 | 50（可调） |
| 并发批次 | 多 peer | 信号量控制 |
| 失败重试 | 3 次 | 指数退避 |

## 18.3 性能指标

- 同步速度: ~100 blocks/s
- 内存占用: ~2GB（稳定）
- CPU 使用: 中等

---

**最后更新**: 2026-01-13
