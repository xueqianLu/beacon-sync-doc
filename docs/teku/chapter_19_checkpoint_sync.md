# 第 19 章: Checkpoint Sync 实现

本章介绍 Teku 中 Checkpoint Sync（检查点同步）的实现，允许从信任的检查点快速启动。

---

## 19.1 Checkpoint Sync 概述

### 核心概念

Checkpoint Sync 允许节点从一个已知的、信任的状态开始同步，而不是从创世块：

```java
public class CheckpointSyncService {
  private final Spec spec;
  private final RecentChainData chainData;
  private final P2PNetwork p2pNetwork;

  public SafeFuture<Void> syncFromCheckpoint(
      Checkpoint checkpoint) {

    LOG.info("Starting checkpoint sync",
      kv("checkpointRoot", checkpoint.getRoot()),
      kv("checkpointEpoch", checkpoint.getEpoch())
    );

    // 1. 下载检查点状态
    return downloadCheckpointState(checkpoint)
      .thenCompose(state -> {
        // 2. 初始化链数据
        return initializeFromState(state, checkpoint);
      })
      .thenCompose(__ -> {
        // 3. 同步后续区块
        return syncForwardFromCheckpoint(checkpoint);
      });
  }
}
```

---

## 19.2 Weak Subjectivity Checkpoint

### WSP 验证

```java
public class WeakSubjectivityValidator {
  public boolean isValidCheckpoint(
      Checkpoint checkpoint,
      BeaconState state) {

    // 1. 验证检查点在弱主观性周期内
    UInt64 wsPeriod = spec.getWeakSubjectivityPeriod(state);
    UInt64 currentEpoch = spec.getCurrentEpoch(state);

    if (checkpoint.getEpoch().plus(wsPeriod)
        .isLessThan(currentEpoch)) {
      LOG.warn("Checkpoint outside WSP");
      return false;
    }

    // 2. 验证状态根匹配
    Bytes32 computedRoot = state.hashTreeRoot();
    if (!computedRoot.equals(checkpoint.getRoot())) {
      LOG.warn("State root mismatch");
      return false;
    }

    return true;
  }
}
```

---

## 19.3 State 下载流程

### 状态获取

```java
public class CheckpointStateDownloader {
  public SafeFuture<BeaconState> downloadState(
      Checkpoint checkpoint) {

    return selectStatePeers(checkpoint)
      .thenCompose(peers ->
        downloadWithRetry(peers, checkpoint)
      )
      .thenCompose(state ->
        validateState(state, checkpoint)
      );
  }

  private SafeFuture<List<Peer>> selectStatePeers(
      Checkpoint checkpoint) {

    return SafeFuture.of(() -> {
      return p2pNetwork.getPeers().stream()
        .filter(peer -> canProvideState(peer, checkpoint))
        .limit(5)
        .collect(Collectors.toList());
    });
  }

  private SafeFuture<BeaconState> downloadWithRetry(
      List<Peer> peers,
      Checkpoint checkpoint) {

    SafeFuture<BeaconState> result = SafeFuture.failedFuture(
      new NoSuchElementException("No peers available")
    );

    for (Peer peer : peers) {
      result = result.exceptionallyCompose(__ ->
        peer.requestBeaconState(checkpoint.getRoot())
      );
    }

    return result;
  }
}
```

---

## 19.4 Block Backfill 机制

### 回填历史区块

```java
public class BackfillService {
  public SafeFuture<Void> backfillBlocks(
      UInt64 fromSlot,
      UInt64 toSlot) {

    LOG.info("Starting backfill",
      kv("from", fromSlot),
      kv("to", toSlot)
    );

    return backfillBatches(fromSlot, toSlot)
      .thenAccept(__ -> {
        LOG.info("Backfill completed");
      });
  }

  private SafeFuture<Void> backfillBatches(
      UInt64 fromSlot,
      UInt64 toSlot) {

    SafeFuture<Void> chain = SafeFuture.COMPLETE;

    UInt64 currentSlot = toSlot;
    while (currentSlot.isGreaterThan(fromSlot)) {
      UInt64 batchStart = currentSlot.minusMinZero(BATCH_SIZE);
      UInt64 batchSize = currentSlot.minus(batchStart);

      final UInt64 start = batchStart;
      chain = chain.thenCompose(__ ->
        fetchAndProcessBatch(start, batchSize)
      );

      currentSlot = batchStart;
    }

    return chain;
  }
}
```

---

## 19.5 配置选项

### Checkpoint 配置

```yaml
# Teku configuration
beacon-chain:
  # Checkpoint sync URL
  initial-state: https://checkpoint.ethereum.org/eth/v2/debug/beacon/states/finalized

  # Or from file
  initial-state: /path/to/state.ssz

  # Weak subjectivity
  ws-checkpoint: 0x1234...5678:12345
```

```java
public class CheckpointSyncConfig {
  private Optional<String> initialStateUrl;
  private Optional<String> initialStatePath;
  private Optional<Checkpoint> wsCheckpoint;

  public boolean isCheckpointSyncEnabled() {
    return initialStateUrl.isPresent() ||
           initialStatePath.isPresent();
  }

  public SafeFuture<BeaconState> loadInitialState() {
    if (initialStatePath.isPresent()) {
      return loadStateFromFile(initialStatePath.get());
    } else if (initialStateUrl.isPresent()) {
      return downloadStateFromUrl(initialStateUrl.get());
    } else {
      return SafeFuture.failedFuture(
        new IllegalStateException("No initial state configured")
      );
    }
  }
}
```

---

## 19.6 安全考虑

### 信任模型

```java
public class CheckpointTrustValidator {
  public void validateTrust(
      Checkpoint checkpoint,
      BeaconState state) {

    // 1. 验证来源可信
    if (!isTrustedSource(checkpoint.getSource())) {
      throw new UntrustedCheckpointException(
        "Checkpoint from untrusted source"
      );
    }

    // 2. 验证足够的 finalization
    if (!isSufficientlyFinalized(state)) {
      throw new UnfinalizedCheckpointException(
        "Checkpoint not finalized"
      );
    }

    // 3. 验证验证者集合
    if (!hasValidValidatorSet(state)) {
      throw new InvalidValidatorSetException(
        "Invalid validator set"
      );
    }
  }

  private boolean isSufficientlyFinalized(BeaconState state) {
    UInt64 currentEpoch = spec.getCurrentEpoch(state);
    UInt64 finalizedEpoch = state.getFinalizedCheckpoint().getEpoch();

    // 要求 finalized epoch 接近当前 epoch
    return currentEpoch.minus(finalizedEpoch)
      .isLessThan(UInt64.valueOf(2));
  }
}
```

---

## 19.7 与 Prysm 对比

| 维度            | Prysm    | Teku     |
| --------------- | -------- | -------- |
| Checkpoint 来源 | URL/File | URL/File |
| State 格式      | SSZ      | SSZ      |
| Backfill        | 可选     | 可选     |
| WSP 验证        | 支持     | 支持     |
| 信任检查        | 基础     | 增强     |

**Prysm 代码**:

```go
func (s *Service) LoadCheckpoint(ctx context.Context) error {
  state, err := downloadState(s.config.CheckpointURL)
  if err != nil {
    return err
  }

  return s.chain.InitializeFromState(ctx, state)
}
```

---

## 19.8 总结

**Checkpoint Sync 优势**:

1. 快速启动：秒级而非小时级
2. 降低资源：无需下载完整历史
3. 安全性：基于弱主观性
4. 灵活性：支持多种检查点来源

**关键要点**:

- 验证检查点在 WSP 内
- 从可信来源获取
- 可选回填历史区块
- 定期更新检查点

---

**最后更新**: 2026-01-13  
**参考**: `tech.pegasys.teku.beacon.sync.checkpoint`
