# 第 12 章: BeaconBlockTopicHandler 实现

本章详细分析 Teku 中 Gossipsub 区块主题处理器的完整实现。

---

## 12.1 核心类设计

### BeaconBlockTopicHandler

```java
package tech.pegasys.teku.networking.eth2.gossip.topics;

public class BeaconBlockTopicHandler
    implements Eth2TopicHandler<SignedBeaconBlock> {

  private final RecentChainData recentChainData;
  private final BlockValidator blockValidator;
  private final GossipedBlockProcessor processor;

  @Override
  public SafeFuture<ValidationResult> handleMessage(
      Eth2PreparedGossipMessage message) {

    SignedBeaconBlock block = message.getMessage();

    // 1. 预验证
    return SafeFuture.of(() -> preValidate(block))
      .thenCompose(result -> {
        if (result != ValidationResult.ACCEPT) {
          return SafeFuture.completedFuture(result);
        }
        // 2. 完整验证
        return blockValidator.validate(block);
      })
      .thenCompose(result -> {
        if (result == ValidationResult.ACCEPT) {
          // 3. 导入区块
          return processor.process(block)
            .thenApply(__ -> ValidationResult.ACCEPT);
        }
        return SafeFuture.completedFuture(result);
      });
  }

  private ValidationResult preValidate(SignedBeaconBlock block) {
    // Slot 检查
    if (!isValidSlot(block)) {
      return ValidationResult.IGNORE;
    }
    // 重复检查
    if (recentChainData.containsBlock(block.getRoot())) {
      return ValidationResult.IGNORE;
    }
    return ValidationResult.ACCEPT;
  }

  private boolean isValidSlot(SignedBeaconBlock block) {
    UInt64 currentSlot = recentChainData.getCurrentSlot();
    UInt64 blockSlot = block.getSlot();

    // 不在未来
    UInt64 maxSlot = currentSlot.plus(CLOCK_DISPARITY_SLOTS);
    if (blockSlot.isGreaterThan(maxSlot)) {
      return false;
    }

    // 不太旧 (1 epoch)
    UInt64 minSlot = currentSlot.minusMinZero(SLOTS_PER_EPOCH);
    return blockSlot.isGreaterThanOrEqualTo(minSlot);
  }
}
```

---

## 12.2 区块验证器

### BlockValidator

```java
public class BlockValidator {
  private final Spec spec;
  private final RecentChainData chainData;

  public SafeFuture<ValidationResult> validate(
      SignedBeaconBlock block) {

    return validateStructure(block)
      .thenCompose(r -> r == ValidationResult.ACCEPT
        ? validateSignature(block) : SafeFuture.completedFuture(r))
      .thenCompose(r -> r == ValidationResult.ACCEPT
        ? validateParent(block) : SafeFuture.completedFuture(r))
      .thenCompose(r -> r == ValidationResult.ACCEPT
        ? validateContent(block) : SafeFuture.completedFuture(r));
  }

  private SafeFuture<ValidationResult> validateSignature(
      SignedBeaconBlock block) {

    BeaconState state = chainData.getHeadState();
    Validator proposer = state.getValidators()
      .get(block.getMessage().getProposerIndex().intValue());

    BLSPublicKey pubkey = proposer.getPubkey();
    Bytes32 domain = spec.getDomain(state, Domain.BEACON_PROPOSER,
      spec.computeEpochAtSlot(block.getSlot()));

    Bytes signingRoot = spec.computeSigningRoot(
      block.getMessage(), domain);

    boolean valid = BLS.verify(pubkey, signingRoot,
      block.getSignature());

    return SafeFuture.completedFuture(
      valid ? ValidationResult.ACCEPT : ValidationResult.REJECT);
  }

  private SafeFuture<ValidationResult> validateParent(
      SignedBeaconBlock block) {

    if (!chainData.containsBlock(block.getParentRoot())) {
      return SafeFuture.completedFuture(
        ValidationResult.SAVE_FOR_FUTURE);
    }
    return SafeFuture.completedFuture(ValidationResult.ACCEPT);
  }
}
```

---

## 12.3 验证结果

```java
public enum ValidationResult {
  ACCEPT,           // 接受并传播
  IGNORE,           // 忽略
  REJECT,           // 拒绝并惩罚
  SAVE_FOR_FUTURE   // 保存待处理
}
```

| 结果            | 操作 | Peer 评分 | 传播 |
| --------------- | ---- | --------- | ---- |
| ACCEPT          | 导入 | +1        | 是   |
| IGNORE          | 丢弃 | 0         | 否   |
| REJECT          | 拒绝 | -10       | 否   |
| SAVE_FOR_FUTURE | 队列 | 0         | 否   |

---

## 12.4 完整流程

```
Gossip Message
     ↓
Pre-Validation → IGNORE (slot无效/已知)
     ↓ ACCEPT
Signature Check → REJECT (签名无效)
     ↓ ACCEPT
Parent Check → SAVE_FOR_FUTURE (父块缺失)
     ↓ ACCEPT
Content Check → REJECT (内容无效)
     ↓ ACCEPT
Import Block → SUCCESS
```

---

## 12.5 性能优化

### 批量签名验证

```java
public class BatchBlockValidator {
  private static final int BATCH_SIZE = 64;
  private final Queue<SignedBeaconBlock> pending =
    new ConcurrentLinkedQueue<>();

  public void processBatch() {
    List<SignedBeaconBlock> batch = new ArrayList<>();
    pending.drainTo(batch, BATCH_SIZE);

    if (!batch.isEmpty()) {
      batchVerifySignatures(batch);
    }
  }

  private void batchVerifySignatures(
      List<SignedBeaconBlock> blocks) {

    List<BLSPublicKey> pubkeys = blocks.stream()
      .map(this::getProposerPubkey)
      .collect(Collectors.toList());

    List<Bytes> messages = blocks.stream()
      .map(this::computeSigningRoot)
      .collect(Collectors.toList());

    List<BLSSignature> sigs = blocks.stream()
      .map(SignedBeaconBlock::getSignature)
      .collect(Collectors.toList());

    boolean allValid = BLS.batchVerify(pubkeys, messages, sigs);

    if (allValid) {
      blocks.forEach(this::acceptBlock);
    } else {
      blocks.forEach(this::verifyIndividually);
    }
  }
}
```

---

## 12.6 与 Prysm 对比

| 维度    | Prysm                     | Teku                    |
| ------- | ------------------------- | ----------------------- |
| Handler | beaconBlockSubscriber     | BeaconBlockTopicHandler |
| 验证器  | validateBeaconBlockPubSub | BlockValidator          |
| 异步    | Goroutines                | SafeFuture              |
| 事件    | Channel                   | EventBus                |

**Prysm 代码**:

```go
func (s *Service) validateBeaconBlockPubSub(
    msg *pubsub.Message) pubsub.ValidationResult {

  block := decode(msg.Data)

  if !isValidSlot(block) {
    return pubsub.ValidationIgnore
  }

  if !verifySignature(block) {
    return pubsub.ValidationReject
  }

  if err := s.chain.ReceiveBlock(block); err != nil {
    return pubsub.ValidationIgnore
  }

  return pubsub.ValidationAccept
}
```

**Teku 优势**:

- 类型安全 Future 链
- 细粒度验证步骤
- EventBus 解耦

**Prysm 优势**:

- 代码简洁
- 同步易调试

---

## 12.7 监控指标

```java
Counter gossipBlocksReceived = Counter.build()
  .name("teku_gossip_blocks_received_total")
  .help("Total blocks received")
  .register();

Histogram validationDuration = Histogram.build()
  .name("teku_block_validation_seconds")
  .help("Validation duration")
  .buckets(0.01, 0.05, 0.1, 0.5, 1.0)
  .register();
```

---

## 12.8 错误处理

### 常见场景

1. **区块在未来**: 返回 IGNORE
2. **父块缺失**: 返回 SAVE_FOR_FUTURE
3. **签名无效**: 返回 REJECT
4. **已知区块**: 返回 IGNORE

### 降级策略

```java
public SafeFuture<ValidationResult> validateWithFallback(
    SignedBeaconBlock block) {

  return validator.validate(block)
    .exceptionallyCompose(error -> {
      if (error instanceof TimeoutException) {
        return validator.validate(block); // 重试
      } else if (error instanceof StateNotFoundException) {
        return SafeFuture.completedFuture(
          ValidationResult.SAVE_FOR_FUTURE);
      } else {
        return SafeFuture.completedFuture(
          ValidationResult.REJECT);
      }
    });
}
```

---

## 12.9 总结

**核心职责**:

1. 预验证（快速过滤）
2. 签名验证（安全性）
3. 内容验证（完整性）
4. 区块导入（持久化）
5. 结果传播（网络）

**Teku 特点**:

- 类型安全
- 异步流水线
- 清晰分层
- 事件驱动

---

**最后更新**: 2026-01-13  
**参考**: `tech.pegasys.teku.networking.eth2.gossip.topics.BeaconBlockTopicHandler`
