# 第 21 章: Regular Sync 概述

本章介绍 Teku 中 Regular Sync（常规同步）的实现，用于节点完成 Initial Sync 后的实时跟踪。

---

## 21.1 Regular Sync 概念

### 与 Initial Sync 的区别

```java
public class SyncMode {
  public enum Mode {
    INITIAL_SYNC,    // 大量历史区块同步
    REGULAR_SYNC,    // 实时跟踪最新区块
    CHECKPOINT_SYNC  // 从检查点启动
  }

  private volatile Mode currentMode = Mode.INITIAL_SYNC;

  public void transitionToRegularSync() {
    if (isInitialSyncComplete()) {
      currentMode = Mode.REGULAR_SYNC;
      LOG.info("Transitioned to regular sync");

      // 停止批量同步
      initialSyncService.stop();

      // 启动实时同步
      regularSyncService.start();
    }
  }

  private boolean isInitialSyncComplete() {
    UInt64 headSlot = chainData.getHeadSlot();
    UInt64 currentSlot = chainData.getCurrentSlot();

    // Head 在当前 slot 的 1 个 epoch 内
    return currentSlot.minus(headSlot)
      .isLessThan(UInt64.valueOf(SLOTS_PER_EPOCH));
  }
}
```

---

## 21.2 RegularSyncService 架构

### 核心服务

```java
package tech.pegasys.teku.beacon.sync.gossip;

public class RegularSyncService {
  private final GossipNetwork gossipNetwork;
  private final BlockImporter blockImporter;
  private final FetchRecentBlocksService recentBlocksFetcher;
  private final RecentChainData chainData;

  private final AtomicBoolean isRunning = new AtomicBoolean(false);

  public void start() {
    if (!isRunning.compareAndSet(false, true)) {
      LOG.warn("Regular sync already running");
      return;
    }

    LOG.info("Starting regular sync");

    // 1. 订阅 Gossipsub 主题
    subscribeToGossipTopics();

    // 2. 启动定期检查
    startPeriodicHeadCheck();

    // 3. 处理积压的区块
    processBacklog();
  }

  public void stop() {
    if (isRunning.compareAndSet(true, false)) {
      LOG.info("Stopping regular sync");
      unsubscribeFromGossipTopics();
    }
  }

  private void subscribeToGossipTopics() {
    // 订阅区块主题
    gossipNetwork.subscribe(
      GossipTopics.BEACON_BLOCK,
      this::onBeaconBlock
    );

    // 订阅 attestation 主题
    gossipNetwork.subscribe(
      GossipTopics.BEACON_AGGREGATE_AND_PROOF,
      this::onAggregateAttestation
    );
  }

  private SafeFuture<Void> onBeaconBlock(
      SignedBeaconBlock block) {

    LOG.debug("Received gossip block",
      kv("slot", block.getSlot()),
      kv("root", block.getRoot())
    );

    return blockImporter.importBlock(block)
      .thenAccept(result -> {
        if (result.isSuccessful()) {
          LOG.debug("Block imported",
            kv("slot", block.getSlot())
          );
        } else {
          handleImportFailure(block, result);
        }
      });
  }
}
```

---

## 21.3 实时跟踪机制

### Head 追踪

```java
public class HeadTracker {
  private static final Duration HEAD_CHECK_INTERVAL =
    Duration.ofSeconds(12);

  private final ScheduledExecutorService scheduler;

  public void startTracking() {
    scheduler.scheduleAtFixedRate(
      this::checkHead,
      0,
      HEAD_CHECK_INTERVAL.getSeconds(),
      TimeUnit.SECONDS
    );
  }

  private void checkHead() {
    UInt64 localHead = chainData.getHeadSlot();
    UInt64 currentSlot = chainData.getCurrentSlot();

    // 检查是否落后
    if (isFallingBehind(localHead, currentSlot)) {
      LOG.warn("Node falling behind",
        kv("localHead", localHead),
        kv("currentSlot", currentSlot)
      );

      triggerCatchUp(localHead, currentSlot);
    }

    // 检查是否需要请求父块
    if (hasMissingParents()) {
      fetchMissingParents();
    }
  }

  private boolean isFallingBehind(UInt64 localHead, UInt64 currentSlot) {
    return currentSlot.minus(localHead)
      .isGreaterThan(UInt64.valueOf(SLOTS_PER_EPOCH));
  }

  private void triggerCatchUp(UInt64 from, UInt64 to) {
    // 触发批量同步来追赶
    forwardSyncService.syncRange(from, to);
  }
}
```

---

## 21.4 状态管理

### Sync State Machine

```java
public class SyncStateMachine {
  public enum State {
    SYNCING,      // 正在同步
    IN_SYNC,      // 已同步
    OPTIMISTIC,   // 乐观同步
    BEHIND        // 落后
  }

  private volatile State currentState = State.SYNCING;

  public void updateState() {
    State newState = calculateState();

    if (newState != currentState) {
      LOG.info("Sync state transition",
        kv("from", currentState),
        kv("to", newState)
      );

      currentState = newState;
      notifyListeners(newState);
    }
  }

  private State calculateState() {
    UInt64 headSlot = chainData.getHeadSlot();
    UInt64 currentSlot = chainData.getCurrentSlot();
    UInt64 lag = currentSlot.minus(headSlot);

    if (lag.isZero()) {
      return State.IN_SYNC;
    } else if (lag.isLessThan(SYNC_THRESHOLD)) {
      return optimisticTracker.isOptimistic(chainData.getHeadRoot())
        ? State.OPTIMISTIC
        : State.IN_SYNC;
    } else if (lag.isLessThan(BEHIND_THRESHOLD)) {
      return State.BEHIND;
    } else {
      return State.SYNCING;
    }
  }

  private void notifyListeners(State newState) {
    eventBus.post(new SyncStateChangedEvent(newState));
  }
}
```

---

## 21.5 区块接收流程

```
Gossip Block Received
        ↓
┌───────────────┐
│  Validation   │ → Invalid → Reject
└───────┬───────┘
        ↓ Valid
┌───────────────┐
│ Parent Check  │ → Missing → Request Parent
└───────┬───────┘
        ↓ Parent Present
┌───────────────┐
│ Import Block  │
└───────┬───────┘
        ↓
┌───────────────┐
│ Update Head   │
└───────┬───────┘
        ↓
┌───────────────┐
│ Propagate     │
└───────────────┘
```

---

## 21.6 与 Prysm 对比

| 维度        | Prysm                     | Teku                     |
| ----------- | ------------------------- | ------------------------ |
| 同步判断    | Head slot vs Current slot | 同样                     |
| Gossip 订阅 | BeaconBlockSubscriber     | GossipNetwork.subscribe  |
| Head 检查   | 定时任务                  | ScheduledExecutorService |
| 状态机      | 4 状态                    | 4 状态                   |
| 落后处理    | 自动切换                  | triggerCatchUp           |
| 事件通知    | Channel                   | EventBus                 |

**Prysm 代码**:

```go
func (s *Service) regularSync() {
  ticker := time.NewTicker(12 * time.Second)
  defer ticker.Stop()

  for {
    select {
    case <-ticker.C:
      if s.isBehind() {
        s.requestMissingBlocks()
      }
    case block := <-s.blockChan:
      s.processBlock(block)
    }
  }
}
```

---

## 21.7 性能指标

```java
// Regular Sync 指标
Gauge syncStatus = Gauge.build()
  .name("teku_sync_status")
  .help("Sync status (0=syncing, 1=in_sync, 2=optimistic, 3=behind)")
  .register();

Gauge headLag = Gauge.build()
  .name("teku_head_lag_slots")
  .help("Head lag in slots")
  .register();

Counter blocksReceived = Counter.build()
  .name("teku_regular_sync_blocks_received_total")
  .help("Total blocks received via gossip")
  .register();

Histogram blockImportTime = Histogram.build()
  .name("teku_block_import_duration_seconds")
  .help("Block import duration")
  .buckets(0.01, 0.05, 0.1, 0.5, 1.0)
  .register();
```

---

## 21.8 最佳实践

### 1. 及时切换同步模式

```java
public void checkAndTransition() {
  if (currentMode == Mode.INITIAL_SYNC &&
      isReadyForRegularSync()) {
    transitionToRegularSync();
  } else if (currentMode == Mode.REGULAR_SYNC &&
             isFallingBehind()) {
    transitionToInitialSync();
  }
}
```

### 2. 优雅处理切换

```java
private void transitionToRegularSync() {
  // 1. 等待当前批次完成
  initialSyncService.waitForCompletion();

  // 2. 切换模式
  currentMode = Mode.REGULAR_SYNC;

  // 3. 启动 Regular Sync
  regularSyncService.start();

  // 4. 通知监听器
  eventBus.post(new SyncModeChangedEvent(Mode.REGULAR_SYNC));
}
```

### 3. 监控同步状态

```java
scheduler.scheduleAtFixedRate(() -> {
  State state = syncStateMachine.getState();
  UInt64 lag = calculateHeadLag();

  syncStatus.set(state.ordinal());
  headLag.set(lag.longValue());

  if (state == State.BEHIND) {
    LOG.warn("Node is behind", kv("lag", lag));
  }
}, 12, 12, TimeUnit.SECONDS);
```

---

## 21.9 总结

**Regular Sync 核心要点**:

1. 实时跟踪：通过 Gossipsub 接收最新区块
2. 状态管理：4 种同步状态（SYNCING/IN_SYNC/OPTIMISTIC/BEHIND）
3. 自动切换：根据 head lag 自动调整同步模式
4. 父块请求：检测并填补缺失的父块
5. 性能监控：完善的指标和告警

**Teku 设计特点**:

- **EventBus 解耦**: 状态变化事件驱动
- **异步处理**: SafeFuture 链式调用
- **资源优化**: 切换模式时释放资源
- **可观测性**: 详细的监控指标

**下一章预告**: 第 22 章将详细介绍区块处理管道的实现。

---

**最后更新**: 2026-01-13  
**参考**: `tech.pegasys.teku.beacon.sync.gossip.RegularSyncService`
