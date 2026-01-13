# 第 17 章: Teku Initial Sync 概述

## 17.1 Initial Sync 简介

Initial Sync（初始同步）是节点首次启动时快速同步到最新状态的过程。

### 17.1.1 同步模式

Teku 支持三种初始同步模式：

```
1. Forward Sync（标准同步）
   Genesis → Current Head
   
2. Checkpoint Sync（检查点同步）
   Checkpoint → Current Head (快速)
   
3. Optimistic Sync（乐观同步）
   CL Head → EL Sync (并行)
```

---

## 17.2 Teku 同步架构

### 17.2.1 核心组件

```java
public class DefaultSyncService implements SyncService {
  private final ForwardSyncService forwardSyncService;
  private final HistoricalBatchFetcher historicalBatchFetcher;
  private final FetchRecentBlocksService recentBlockFetcher;
  private final SyncStateTracker syncStateTracker;
  
  @Override
  public SafeFuture<Void> start() {
    return SafeFuture.allOf(
      forwardSyncService.start(),
      historicalBatchFetcher.start(),
      recentBlockFetcher.start()
    ).thenAccept(__ -> {
      LOG.info("Sync service started");
    });
  }
  
  @Override
  public boolean isSyncActive() {
    return syncStateTracker.isSyncing();
  }
}
```

### 17.2.2 同步状态机

```
┌─────────────┐
│   IDLE      │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  SYNCING    │◄──┐
└──────┬──────┘   │
       │          │
       ▼          │
┌─────────────┐   │
│ IN_SYNC     │   │
└──────┬──────┘   │
       │          │
       └──────────┘
```

---

## 17.3 Forward Sync 服务

### 17.3.1 ForwardSyncService

```java
public class ForwardSyncService {
  private final BlockManager blockManager;
  private final SyncTargetSelector targetSelector;
  private final AsyncRunner asyncRunner;
  
  public SafeFuture<Void> sync(UInt64 startSlot, UInt64 targetSlot) {
    return SafeFuture.of(() -> {
      SyncTarget target = targetSelector.selectBestTarget();
      
      return syncToTarget(startSlot, targetSlot, target);
    }).thenCompose(result -> {
      if (!isComplete(result)) {
        // 继续同步
        return sync(result.getEndSlot(), targetSlot);
      }
      return SafeFuture.COMPLETE;
    });
  }
  
  private SafeFuture<SyncResult> syncToTarget(
      UInt64 startSlot,
      UInt64 targetSlot,
      SyncTarget target) {
    
    UInt64 batchSize = UInt64.valueOf(50);
    List<SafeFuture<Void>> batchFutures = new ArrayList<>();
    
    UInt64 currentSlot = startSlot;
    while (currentSlot.isLessThan(targetSlot)) {
      UInt64 endSlot = currentSlot.plus(batchSize).min(targetSlot);
      
      SafeFuture<Void> batchFuture = fetchAndImportBatch(
        target.getPeer(),
        currentSlot,
        endSlot
      );
      
      batchFutures.add(batchFuture);
      currentSlot = endSlot;
    }
    
    return SafeFuture.allOf(batchFutures.toArray(new SafeFuture[0]))
      .thenApply(__ -> new SyncResult(targetSlot, true));
  }
}
```

### 17.3.2 并行批次处理

```java
public class ParallelBatchProcessor {
  private static final int MAX_PARALLEL_BATCHES = 5;
  
  public SafeFuture<Void> processBatches(List<BatchRequest> batches) {
    Semaphore semaphore = new Semaphore(MAX_PARALLEL_BATCHES);
    
    List<SafeFuture<Void>> futures = batches.stream()
      .map(batch -> {
        return SafeFuture.of(() -> {
          semaphore.acquire();
          return processBatch(batch);
        }).thenAccept(__ -> {
          semaphore.release();
        });
      })
      .collect(Collectors.toList());
    
    return SafeFuture.allOf(futures.toArray(new SafeFuture[0]));
  }
}
```

---

## 17.4 Checkpoint Sync

### 17.4.1 配置

```bash
# 命令行参数
--initial-state=https://checkpoint-sync.example.com/eth/v2/debug/beacon/states/finalized

# 配置文件
initial-state: "https://checkpoint-sync.example.com/eth/v2/debug/beacon/states/finalized"
```

### 17.4.2 实现

```java
public class CheckpointSyncService {
  private final StateDownloader stateDownloader;
  
  public SafeFuture<BeaconState> syncFromCheckpoint(URI checkpointUrl) {
    return stateDownloader.downloadState(checkpointUrl)
      .thenCompose(this::validateState)
      .thenCompose(state -> {
        LOG.info("Checkpoint sync successful",
          kv("slot", state.getSlot())
        );
        return SafeFuture.completedFuture(state);
      });
  }
  
  private SafeFuture<BeaconState> validateState(BeaconState state) {
    // 验证状态
    if (!isValidCheckpoint(state)) {
      return SafeFuture.failedFuture(
        new InvalidCheckpointException("State validation failed")
      );
    }
    return SafeFuture.completedFuture(state);
  }
}
```

---

## 17.5 同步目标选择

### 17.5.1 Peer 选择策略

```java
public class SyncTargetSelector {
  private final PeerPool peerPool;
  
  public SyncTarget selectBestTarget() {
    return peerPool.streamPeers()
      .filter(this::isValidSyncPeer)
      .max(Comparator.comparing(Peer::getHeadSlot))
      .map(peer -> new SyncTarget(peer, peer.getHeadSlot()))
      .orElseThrow(() -> new NoValidPeerException());
  }
  
  private boolean isValidSyncPeer(Peer peer) {
    return peer.isConnected()
        && peer.getStatus().isPresent()
        && peer.getHeadSlot().isGreaterThan(currentSlot())
        && peer.getScore() > MINIMUM_PEER_SCORE;
  }
}
```

---

## 17.6 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| **同步策略** | Round-Robin | 并行批次 |
| **批量大小** | 64 blocks | 50 blocks |
| **并发度** | 多 peer 轮询 | 信号量控制 |
| **Checkpoint** | ✅ 支持 | ✅ 支持 |
| **状态追踪** | 状态机 | SyncStateTracker |

---

## 17.7 性能优化

### 17.7.1 批次优化

```java
public class BatchOptimizer {
  public int calculateOptimalBatchSize(
      NetworkConditions conditions) {
    
    int baseBatchSize = 50;
    
    // 根据网络条件调整
    if (conditions.getLatency().toMillis() < 50) {
      return baseBatchSize * 2; // 低延迟，增大批次
    } else if (conditions.getLatency().toMillis() > 200) {
      return baseBatchSize / 2; // 高延迟，减小批次
    }
    
    return baseBatchSize;
  }
}
```

### 17.7.2 监控指标

```java
public class SyncMetrics {
  private final Gauge syncProgress;
  private final Counter blocksImported;
  private final Timer syncDuration;
  
  public void recordSyncProgress(UInt64 currentSlot, UInt64 targetSlot) {
    double progress = currentSlot.doubleValue() / targetSlot.doubleValue();
    syncProgress.set(progress);
  }
}
```

---

## 17.8 本章总结

✅ Teku 支持三种初始同步模式  
✅ Forward Sync 采用并行批次处理  
✅ Checkpoint Sync 快速启动  
✅ 完善的 peer 选择与状态追踪  
✅ 性能优化与监控指标

**下一章**: Full Sync 详细实现

---

**最后更新**: 2026-01-13
