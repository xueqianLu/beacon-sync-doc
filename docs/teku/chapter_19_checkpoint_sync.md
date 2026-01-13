# 第 19 章: Teku Checkpoint Sync

## 19.1 Checkpoint Sync 优势

- ⚡ 快速启动（分钟级 vs 小时级）
- 💾 减少磁盘空间
- 🔒 弱主观性安全

## 19.2 使用方法

```bash
teku --initial-state=https://checkpoint.example.com/eth/v2/debug/beacon/states/finalized
```

## 19.3 实现流程

```java
public class CheckpointSyncService {
  public SafeFuture<Void> sync(URI checkpointUrl) {
    return downloadState(checkpointUrl)
      .thenCompose(this::validateWeakSubjectivity)
      .thenCompose(this::importState)
      .thenCompose(this::syncFromCheckpoint);
  }
}
```

## 19.4 Backfill 同步

```java
// 后台异步回填历史区块
public class BackfillService {
  public void startBackfill(UInt64 checkpointSlot) {
    asyncRunner.runAsync(() -> {
      fetchHistoricalBlocks(UInt64.ZERO, checkpointSlot);
    });
  }
}
```

---

**最后更新**: 2026-01-13
