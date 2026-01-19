# 第 20 章: Optimistic Sync 实现

本章介绍 Teku 中 Optimistic Sync（乐观同步）的实现，允许在 EL 验证完成前乐观地处理区块。

---

## 20.1 Optimistic Sync 概念

### 核心思想

Optimistic Sync 允许节点在执行层（EL）验证完成前，乐观地导入和传播区块：

```java
public class OptimisticSyncService {
  private final ExecutionEngineClient executionEngine;
  private final ForkChoice forkChoice;
  private final RecentChainData chainData;

  public SafeFuture<BlockImportResult> importOptimistically(
      SignedBeaconBlock block) {

    LOG.debug("Optimistic block import",
      kv("slot", block.getSlot()),
      kv("root", block.getRoot())
    );

    // 1. 验证共识层
    return validateConsensusLayer(block)
      .thenCompose(valid -> {
        if (!valid) {
          return SafeFuture.completedFuture(
            BlockImportResult.failed("Consensus validation failed")
          );
        }

        // 2. 乐观导入
        return importOptimisticallyInternal(block);
      })
      .thenCompose(result -> {
        // 3. 异步触发 EL 验证
        scheduleExecutionValidation(block);
        return SafeFuture.completedFuture(result);
      });
  }

  private SafeFuture<BlockImportResult> importOptimisticallyInternal(
      SignedBeaconBlock block) {

    // 标记为 optimistic
    chainData.markBlockOptimistic(block.getRoot(), true);

    // 导入区块
    return blockImporter.importBlock(block)
      .thenApply(result -> {
        if (result.isSuccessful()) {
          LOG.debug("Block imported optimistically",
            kv("root", block.getRoot())
          );
        }
        return result;
      });
  }
}
```

---

## 20.2 ExecutionEngineClient 集成

### EL 通信

```java
public class ExecutionEngineClient {
  private final HttpClient httpClient;
  private final String engineApiUrl;

  public SafeFuture<ExecutionPayloadStatus> validatePayload(
      ExecutionPayload payload) {

    // Engine API: engine_newPayloadV2
    JsonRpcRequest request = new JsonRpcRequest(
      "engine_newPayloadV2",
      List.of(payload.toJson())
    );

    return httpClient.sendAsync(request)
      .thenApply(response -> parsePayloadStatus(response))
      .exceptionally(error -> {
        LOG.error("EL validation failed", error);
        return ExecutionPayloadStatus.SYNCING;
      });
  }

  public SafeFuture<ForkchoiceUpdatedResult> updateForkchoice(
      ForkchoiceState forkchoiceState) {

    // Engine API: engine_forkchoiceUpdatedV2
    JsonRpcRequest request = new JsonRpcRequest(
      "engine_forkchoiceUpdatedV2",
      List.of(forkchoiceState.toJson())
    );

    return httpClient.sendAsync(request)
      .thenApply(response -> parseForkchoiceResult(response));
  }
}
```

---

## 20.3 Optimistic Block 处理

### 状态管理

```java
public class OptimisticBlockTracker {
  private final Map<Bytes32, OptimisticBlockInfo> optimisticBlocks =
    new ConcurrentHashMap<>();

  public void markOptimistic(Bytes32 blockRoot) {
    optimisticBlocks.put(
      blockRoot,
      new OptimisticBlockInfo(
        blockRoot,
        Instant.now(),
        OptimisticStatus.PENDING
      )
    );
  }

  public void markValidated(Bytes32 blockRoot, boolean valid) {
    OptimisticBlockInfo info = optimisticBlocks.get(blockRoot);
    if (info != null) {
      info.setStatus(valid
        ? OptimisticStatus.VALID
        : OptimisticStatus.INVALID
      );
      info.setValidationTime(Instant.now());

      if (!valid) {
        // 无效块，触发重组
        handleInvalidBlock(blockRoot);
      }
    }
  }

  public boolean isOptimistic(Bytes32 blockRoot) {
    OptimisticBlockInfo info = optimisticBlocks.get(blockRoot);
    return info != null &&
           info.getStatus() == OptimisticStatus.PENDING;
  }

  private void handleInvalidBlock(Bytes32 blockRoot) {
    LOG.warn("Invalid optimistic block detected",
      kv("root", blockRoot)
    );

    // 1. 标记该块及其后代为无效
    markDescendantsInvalid(blockRoot);

    // 2. 触发 fork choice 重新计算
    forkChoice.onBlockInvalidated(blockRoot);

    // 3. 断连提供该块的 peer
    Optional<PeerId> source = getBlockSource(blockRoot);
    source.ifPresent(peer ->
      peerManager.disconnectPeer(peer, "Invalid optimistic block")
    );
  }
}
```

---

## 20.4 Fork Choice 更新

### Optimistic Fork Choice

```java
public class OptimisticForkChoice {
  public void processHead() {
    Bytes32 headRoot = computeHead();

    // 检查 head 是否为 optimistic
    boolean isOptimistic = optimisticTracker.isOptimistic(headRoot);

    if (isOptimistic) {
      LOG.debug("Head is optimistic", kv("root", headRoot));

      // 使用 safe head 作为 justified
      Bytes32 safeHead = getSafeHead();
      updateForkchoice(headRoot, safeHead);
    } else {
      // 正常 fork choice 更新
      Bytes32 justified = getJustifiedRoot();
      updateForkchoice(headRoot, justified);
    }
  }

  private Bytes32 getSafeHead() {
    // Safe head: 最新的已验证（非 optimistic）块
    return chainData.getBlocks()
      .stream()
      .filter(block -> !optimisticTracker.isOptimistic(block.getRoot()))
      .max(Comparator.comparing(SignedBeaconBlock::getSlot))
      .map(SignedBeaconBlock::getRoot)
      .orElse(chainData.getGenesisBlockRoot());
  }
}
```

---

## 20.5 Safe/Finalized Head 管理

### 三层 Head 管理

```java
public class MultiHeadManager {
  // 1. Optimistic Head: 最新的可能未验证的块
  private volatile Bytes32 optimisticHead;

  // 2. Safe Head: 最新的已验证块
  private volatile Bytes32 safeHead;

  // 3. Finalized Head: 已 finalized 的块
  private volatile Bytes32 finalizedHead;

  public void updateHeads(Bytes32 newBlock) {
    // 更新 optimistic head
    optimisticHead = newBlock;

    // 检查是否可以更新 safe head
    if (!optimisticTracker.isOptimistic(newBlock)) {
      safeHead = newBlock;
    }

    // Finalized head 由 consensus 决定
    Checkpoint finalized = chainData.getFinalizedCheckpoint();
    finalizedHead = finalized.getRoot();

    // 通知 EL
    notifyExecutionEngine();
  }

  private void notifyExecutionEngine() {
    ForkchoiceState state = new ForkchoiceState(
      optimisticHead,
      safeHead,
      finalizedHead
    );

    executionEngine.updateForkchoice(state)
      .thenAccept(result -> {
        if (result.getStatus() != ForkchoiceStatus.VALID) {
          LOG.warn("Forkchoice update failed",
            kv("status", result.getStatus())
          );
        }
      });
  }
}
```

---

## 20.6 降级到 Full Sync

### 同步降级

```java
public class SyncFallbackManager {
  public void checkAndFallback() {
    // 检查是否有太多 optimistic 块
    int optimisticCount = optimisticTracker.getOptimisticCount();

    if (optimisticCount > MAX_OPTIMISTIC_BLOCKS) {
      LOG.warn("Too many optimistic blocks, falling back to full sync",
        kv("count", optimisticCount)
      );

      fallbackToFullSync();
    }

    // 检查 optimistic 块是否超时
    List<OptimisticBlockInfo> timedOut =
      optimisticTracker.getTimedOutBlocks(Duration.ofMinutes(5));

    if (!timedOut.isEmpty()) {
      LOG.warn("Optimistic blocks timed out",
        kv("count", timedOut.size())
      );

      handleTimedOutBlocks(timedOut);
    }
  }

  private void fallbackToFullSync() {
    // 1. 停止 optimistic 导入
    optimisticSyncService.disable();

    // 2. 回滚到 safe head
    Bytes32 safeHead = multiHeadManager.getSafeHead();
    chainData.reorgToBlock(safeHead);

    // 3. 启动 full sync
    Bytes32 targetHead = selectSyncTarget();
    forwardSyncService.sync(
      chainData.getHeadSlot(),
      getSlotForBlock(targetHead)
    );

    // 4. 同步完成后重新启用 optimistic
    forwardSyncService.whenComplete(() -> {
      optimisticSyncService.enable();
    });
  }
}
```

---

## 20.7 完整流程图

```
New Block Arrives
       ↓
Consensus Validation
       ↓
   ┌───┴───┐
   │ Valid?│ → No → Reject
   └───┬───┘
       ↓ Yes
Mark as Optimistic
       ↓
Import to Chain
       ↓
Update Fork Choice
       ↓
Trigger EL Validation (async)
       ↓
   ┌──────────┐
   │ EL Check │
   └────┬─────┘
        ├─→ VALID → Mark Validated
        ├─→ INVALID → Reorg + Disconnect Peer
        └─→ SYNCING → Keep Optimistic

Safe Head = Latest Validated
Finalized Head = From Consensus
Optimistic Head = Latest Block
```

---

## 20.8 与 Prysm 对比

| 维度            | Prysm      | Teku       |
| --------------- | ---------- | ---------- |
| Optimistic 支持 | 是         | 是         |
| EL 通信         | Engine API | Engine API |
| Head 管理       | 三层       | 三层       |
| 无效块处理      | Reorg      | Reorg      |
| 降级策略        | 自动       | 自动       |
| 超时处理        | 固定时间   | 可配置     |

**Prysm 代码**:

```go
func (s *Service) ImportOptimistically(block *eth.SignedBeaconBlock) error {
  // Mark as optimistic
  s.cfg.ForkChoiceStore.SetOptimistic(block.Block.Root())

  // Import block
  if err := s.cfg.Chain.ReceiveBlock(ctx, block); err != nil {
    return err
  }

  // Async EL validation
  go s.validateExecutionPayload(block.Block.Body.ExecutionPayload)

  return nil
}
```

---

## 20.9 安全性分析

### 攻击向量

1. **无效 Payload 攻击**

   - 防御：EL 最终会验证，无效块被拒绝
   - 影响：临时分叉，自动恢复

2. **DoS 攻击**

   - 防御：限制 optimistic 块数量
   - 影响：降级到 full sync

3. **长链攻击**
   - 防御：基于 safe head 的 fork choice
   - 影响：受 weak subjectivity 保护

### 安全保证

```java
// 1. Optimistic 块不影响 finalization
public boolean canFinalize(Bytes32 blockRoot) {
  // 只有非 optimistic 块可以被 finalized
  return !optimisticTracker.isOptimistic(blockRoot);
}

// 2. Attestation 基于 safe head
public Bytes32 getAttestationHead() {
  // 验证者始终基于 safe head 进行 attestation
  return multiHeadManager.getSafeHead();
}

// 3. Fork choice 优先 validated 分支
public Bytes32 computeHead() {
  // 在相同权重下，优先选择 validated 分支
  return forkChoice.getHead(
    ForkChoiceStrategy.PREFER_VALIDATED
  );
}
```

---

## 20.10 总结

**Optimistic Sync 核心要点**:

1. 快速同步：无需等待 EL 验证
2. 安全性：基于 safe head 保证
3. 自动恢复：无效块自动回滚
4. 性能优化：并行处理 CL 和 EL

**Teku 设计特点**:

- **三层 Head 管理**: Optimistic/Safe/Finalized
- **异步验证**: EL 验证不阻塞导入
- **自动降级**: 超时或异常时回退
- **Peer 惩罚**: 无效块提供者被断连

**适用场景**:

- 节点快速追赶网络
- EL 同步滞后于 CL
- 网络短暂分区恢复

---

**最后更新**: 2026-01-13  
**参考**:

- `tech.pegasys.teku.beacon.sync.optimistic`
- Engine API Specification
- Optimistic Sync Spec (EIP-3675)
