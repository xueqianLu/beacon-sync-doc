# 第 18 章: Full Sync 实现

本章详细介绍 Teku 中 Full Sync（完全同步）的实现，从创世块同步到当前链头。

---

## 18.1 ForwardSyncService 核心

### 服务架构

```java
package tech.pegasys.teku.beacon.sync.forward;

public class ForwardSyncService {
  private final RecentChainData chainData;
  private final P2PNetwork p2pNetwork;
  private final BlockImporter blockImporter;
  private final SyncConfig syncConfig;

  private final AtomicReference<SyncState> syncState =
    new AtomicReference<>(SyncState.IDLE);

  public SafeFuture<SyncResult> sync(
      UInt64 startSlot,
      UInt64 targetSlot) {

    if (!syncState.compareAndSet(SyncState.IDLE, SyncState.SYNCING)) {
      return SafeFuture.failedFuture(
        new IllegalStateException("Sync already in progress")
      );
    }

    LOG.info("Starting forward sync",
      kv("start", startSlot),
      kv("target", targetSlot)
    );

    return performSync(startSlot, targetSlot)
      .whenComplete((result, error) -> {
        syncState.set(SyncState.IDLE);
        if (error != null) {
          LOG.error("Forward sync failed", error);
        } else {
          LOG.info("Forward sync completed");
        }
      });
  }

  private SafeFuture<SyncResult> performSync(
      UInt64 startSlot,
      UInt64 targetSlot) {

    return selectSyncPeers()
      .thenCompose(peers ->
        new SinglePeerSyncService(
          chainData,
          blockImporter,
          syncConfig
        ).sync(peers.get(0), startSlot, targetSlot)
      );
  }
}
```

---

## 18.2 批量同步策略

### BatchSync 实现

```java
public class BatchSync {
  private static final int DEFAULT_BATCH_SIZE = 50;
  private static final int MAX_CONCURRENT_BATCHES = 5;

  private final Semaphore batchSemaphore =
    new Semaphore(MAX_CONCURRENT_BATCHES);

  public SafeFuture<List<SignedBeaconBlock>> syncBatch(
      Peer peer,
      UInt64 startSlot,
      UInt64 count) {

    return SafeFuture.of(() -> {
      batchSemaphore.acquire();
      return fetchBatch(peer, startSlot, count);
    })
    .thenCompose(blocks -> validateBatch(blocks))
    .whenComplete((result, error) -> {
      batchSemaphore.release();
    });
  }

  private SafeFuture<List<SignedBeaconBlock>> fetchBatch(
      Peer peer,
      UInt64 startSlot,
      UInt64 count) {

    return peer.requestBlocksByRange(
      startSlot,
      count,
      UInt64.ONE
    ).thenApply(blocks -> {
      LOG.debug("Fetched batch",
        kv("peer", peer.getId()),
        kv("start", startSlot),
        kv("count", blocks.size())
      );
      return blocks;
    });
  }

  private SafeFuture<List<SignedBeaconBlock>> validateBatch(
      List<SignedBeaconBlock> blocks) {

    // 验证批次连续性
    for (int i = 1; i < blocks.size(); i++) {
      SignedBeaconBlock prev = blocks.get(i - 1);
      SignedBeaconBlock curr = blocks.get(i);

      if (!curr.getParentRoot().equals(prev.getRoot())) {
        return SafeFuture.failedFuture(
          new InvalidBlockException("Batch not continuous")
        );
      }
    }

    return SafeFuture.completedFuture(blocks);
  }
}
```

---

## 18.3 Peer 选择策略

### 最佳 Peer 选择

```java
public class SyncPeerSelector {
  public SafeFuture<List<Peer>> selectSyncPeers(
      int count,
      UInt64 targetSlot) {

    return SafeFuture.of(() -> {
      List<Peer> candidates = p2pNetwork.getPeers().stream()
        .filter(peer -> isEligibleForSync(peer, targetSlot))
        .sorted(Comparator.comparingDouble(this::scorePeer).reversed())
        .limit(count)
        .collect(Collectors.toList());

      if (candidates.isEmpty()) {
        throw new NoSyncPeersException(
          "No eligible peers for sync"
        );
      }

      return candidates;
    });
  }

  private boolean isEligibleForSync(Peer peer, UInt64 targetSlot) {
    PeerStatus status = peer.getStatus();

    // Peer 必须领先我们
    if (status.getHeadSlot().isLessThan(targetSlot)) {
      return false;
    }

    // Peer 必须已完成 finalization
    if (status.getFinalizedEpoch().isLessThan(
        chainData.getFinalizedEpoch())) {
      return false;
    }

    // Peer 评分必须合格
    double score = peerScorer.getScore(peer.getId());
    if (score < MINIMUM_SYNC_PEER_SCORE) {
      return false;
    }

    return true;
  }

  private double scorePeer(Peer peer) {
    double score = 0.0;

    // 1. 链高度评分
    score += peer.getStatus().getHeadSlot().longValue() * 0.1;

    // 2. Peer 评分
    score += peerScorer.getScore(peer.getId());

    // 3. 响应时间评分
    Duration avgResponse = peer.getAverageResponseTime();
    score -= avgResponse.toMillis() * 0.01;

    return score;
  }
}
```

---

## 18.4 并发控制

### 信号量控制

```java
public class ConcurrentSyncController {
  private final Semaphore blockImportSemaphore;
  private final Semaphore networkRequestSemaphore;

  public ConcurrentSyncController(SyncConfig config) {
    this.blockImportSemaphore = new Semaphore(
      config.getMaxConcurrentBlockImports()
    );
    this.networkRequestSemaphore = new Semaphore(
      config.getMaxConcurrentNetworkRequests()
    );
  }

  public SafeFuture<Void> importWithControl(
      SignedBeaconBlock block) {

    return SafeFuture.of(() -> {
      blockImportSemaphore.acquire();
      return blockImporter.importBlock(block);
    })
    .whenComplete((result, error) -> {
      blockImportSemaphore.release();
    });
  }

  public SafeFuture<List<SignedBeaconBlock>> fetchWithControl(
      Supplier<SafeFuture<List<SignedBeaconBlock>>> fetcher) {

    return SafeFuture.of(() -> {
      networkRequestSemaphore.acquire();
      return fetcher.get();
    })
    .thenCompose(future -> future)
    .whenComplete((result, error) -> {
      networkRequestSemaphore.release();
    });
  }
}
```

---

## 18.5 验证管道

### Pipeline 设计

```java
public class BlockValidationPipeline {
  public SafeFuture<Void> processBatch(
      List<SignedBeaconBlock> blocks) {

    return SafeFuture.of(() -> {
      // Stage 1: 预验证（快速检查）
      preValidateAll(blocks);
    })
    .thenCompose(__ -> {
      // Stage 2: 并行签名验证
      return parallelSignatureValidation(blocks);
    })
    .thenCompose(__ -> {
      // Stage 3: 顺序状态转换
      return sequentialStateTransition(blocks);
    });
  }

  private void preValidateAll(List<SignedBeaconBlock> blocks) {
    for (SignedBeaconBlock block : blocks) {
      // 检查基本字段
      if (block.getSlot().isZero()) {
        throw new ValidationException("Invalid slot");
      }

      // 检查 proposer index
      validateProposerIndex(block);
    }
  }

  private SafeFuture<Void> parallelSignatureValidation(
      List<SignedBeaconBlock> blocks) {

    List<SafeFuture<Boolean>> futures = blocks.stream()
      .map(this::validateSignature)
      .collect(Collectors.toList());

    return SafeFuture.allOf(futures.toArray(new SafeFuture[0]))
      .thenAccept(__ -> {
        boolean allValid = futures.stream()
          .allMatch(SafeFuture::join);

        if (!allValid) {
          throw new ValidationException(
            "Batch contains invalid signatures"
          );
        }
      });
  }

  private SafeFuture<Void> sequentialStateTransition(
      List<SignedBeaconBlock> blocks) {

    SafeFuture<Void> chain = SafeFuture.COMPLETE;

    for (SignedBeaconBlock block : blocks) {
      chain = chain.thenCompose(__ ->
        blockImporter.importBlock(block)
      );
    }

    return chain;
  }
}
```

---

## 18.6 状态转换处理

### 状态管理

```java
public class SyncStateManager {
  private final Map<Bytes32, BeaconState> stateCache =
    new ConcurrentHashMap<>();

  public SafeFuture<BeaconState> getOrComputeState(
      SignedBeaconBlock block) {

    Bytes32 stateRoot = block.getStateRoot();

    // 检查缓存
    BeaconState cached = stateCache.get(stateRoot);
    if (cached != null) {
      return SafeFuture.completedFuture(cached);
    }

    // 从父状态计算
    return getParentState(block)
      .thenCompose(parentState ->
        spec.processBlock(parentState, block)
      )
      .thenApply(newState -> {
        stateCache.put(stateRoot, newState);
        return newState;
      });
  }

  private SafeFuture<BeaconState> getParentState(
      SignedBeaconBlock block) {

    Bytes32 parentRoot = block.getParentRoot();

    return chainData.getBlockByRoot(parentRoot)
      .map(parentBlock -> getOrComputeState(parentBlock))
      .orElseThrow(() ->
        new StateNotFoundException("Parent state not found")
      );
  }
}
```

---

## 18.7 完整流程图

```
Start Sync
    ↓
Select Best Peers
    ↓
┌─────────────────────────┐
│ Batch Loop              │
│                         │
│  1. Calculate range     │
│  2. Request blocks      │
│  3. Validate batch      │
│  4. Import blocks       │
│  5. Update progress     │
│                         │
│  Continue until target  │
└────────┬────────────────┘
         ↓
    All batches done?
         ↓ Yes
┌─────────────────────────┐
│ Finalization            │
│  - Update chain head    │
│  - Emit sync complete   │
│  - Release resources    │
└─────────────────────────┘
```

---

## 18.8 性能指标

### 同步速度

```java
public class SyncMetrics {
  private final Counter blocksProcessed = Counter.build()
    .name("teku_sync_blocks_processed_total")
    .help("Total blocks processed during sync")
    .register();

  private final Histogram batchProcessingTime = Histogram.build()
    .name("teku_sync_batch_duration_seconds")
    .help("Batch processing duration")
    .buckets(0.1, 0.5, 1, 5, 10, 30)
    .register();

  private final Gauge syncProgress = Gauge.build()
    .name("teku_sync_progress_ratio")
    .help("Sync progress (0-1)")
    .register();

  public void recordBatchProcessed(
      int blockCount,
      Duration duration) {

    blocksProcessed.inc(blockCount);
    batchProcessingTime.observe(duration.toMillis() / 1000.0);

    double progress = calculateProgress();
    syncProgress.set(progress);
  }
}
```

### 典型性能数据

```
同步速度:        ~80-120 blocks/s
批量大小:        50 blocks
并发批次:        5
内存占用:        ~2-3GB (稳定)
CPU 使用:        30-50%
网络带宽:        ~10-20 Mbps
```

---

## 18.9 与 Prysm 对比

| 维度      | Prysm       | Teku              |
| --------- | ----------- | ----------------- |
| 批量大小  | 64 (可调)   | 50 (可调)         |
| 并发模型  | Goroutines  | Semaphore         |
| Peer 选择 | Round-robin | Score-based       |
| 状态管理  | 缓存 + DB   | ConcurrentHashMap |
| 验证策略  | 批量 BLS    | 并行 Future       |
| 重试机制  | 固定 3 次   | 指数退避          |

**Prysm 代码**:

```go
func (s *Service) syncToGenesis() error {
  startSlot := primitives.Slot(0)
  targetSlot := s.chain.HeadSlot()

  for currentSlot := startSlot; currentSlot < targetSlot; {
    blocks, err := s.requestBlocksByRange(currentSlot, 64)
    if err != nil {
      return err
    }

    for _, block := range blocks {
      if err := s.chain.ReceiveBlock(ctx, block); err != nil {
        return err
      }
    }

    currentSlot += 64
  }

  return nil
}
```

**Teku 优势**:

- 基于评分的智能 Peer 选择
- 细粒度并发控制
- 异步非阻塞管道

**Prysm 优势**:

- 代码简洁
- Goroutine 轻量高效

---

## 18.10 错误处理

### 重试策略

```java
public class SyncRetryHandler {
  private static final int MAX_RETRIES = 5;
  private static final Duration INITIAL_BACKOFF =
    Duration.ofSeconds(1);

  public <T> SafeFuture<T> withRetry(
      Supplier<SafeFuture<T>> operation,
      int retriesLeft) {

    return operation.get()
      .exceptionallyCompose(error -> {
        if (retriesLeft <= 0) {
          return SafeFuture.failedFuture(error);
        }

        if (!isRetriable(error)) {
          return SafeFuture.failedFuture(error);
        }

        Duration backoff = calculateBackoff(
          MAX_RETRIES - retriesLeft
        );

        LOG.warn("Sync operation failed, retrying",
          kv("retriesLeft", retriesLeft),
          kv("backoff", backoff)
        );

        return asyncRunner.runAfterDelay(
          () -> withRetry(operation, retriesLeft - 1),
          backoff
        );
      });
  }

  private Duration calculateBackoff(int attempt) {
    long millis = INITIAL_BACKOFF.toMillis() *
                  (long) Math.pow(2, attempt);
    return Duration.ofMillis(Math.min(millis, 60000));
  }
}
```

---

## 18.11 总结

**Full Sync 核心要点**:

1. 批量处理：提高网络效率
2. 并发控制：平衡速度和资源
3. 智能 Peer 选择：提高成功率
4. 验证管道：确保数据正确性
5. 错误恢复：自动重试机制

**Teku 设计特点**:

- **异步流水线**: SafeFuture 链式处理
- **资源控制**: Semaphore 限制并发
- **可观测性**: 完善的监控指标
- **可配置**: 灵活的同步参数

---

**最后更新**: 2026-01-13  
**参考代码**: `tech.pegasys.teku.beacon.sync.forward`
