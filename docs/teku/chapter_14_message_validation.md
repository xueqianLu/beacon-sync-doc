# 第 14 章: Gossipsub 消息验证流程

本章详细介绍 Teku 中 Gossipsub 消息的完整验证流程，包括预验证、签名验证、内容验证和批量优化。

---

## 14.1 消息验证架构

### Eth2PreparedGossipMessage

```java
package tech.pegasys.teku.networking.eth2.gossip;

public class Eth2PreparedGossipMessage {
  private final GossipTopic topic;
  private final Bytes originalMessage;
  private final Object decodedMessage;
  private final Optional<UInt64> arrivalTimestamp;
  
  public Eth2PreparedGossipMessage(
      GossipTopic topic,
      Bytes originalMessage,
      Object decodedMessage) {
    this.topic = topic;
    this.originalMessage = originalMessage;
    this.decodedMessage = decodedMessage;
    this.arrivalTimestamp = Optional.of(
      UInt64.valueOf(System.currentTimeMillis())
    );
  }
  
  @SuppressWarnings("unchecked")
  public <T> T getMessage() {
    return (T) decodedMessage;
  }
  
  public GossipTopic getTopic() {
    return topic;
  }
  
  public boolean isWithinValidTimeWindow(UInt64 currentTime) {
    if (arrivalTimestamp.isEmpty()) {
      return true;
    }
    
    UInt64 age = currentTime.minus(arrivalTimestamp.get());
    return age.isLessThanOrEqualTo(
      UInt64.valueOf(MAXIMUM_GOSSIP_CLOCK_DISPARITY_MS)
    );
  }
}
```

---

## 14.2 验证管道设计

### MessageValidator 接口

```java
public interface MessageValidator<T> {
  SafeFuture<InternalValidationResult> validate(
    Eth2PreparedGossipMessage message
  );
  
  default SafeFuture<InternalValidationResult> validateQuick(
    Eth2PreparedGossipMessage message) {
    return validate(message);
  }
}
```

### 三阶段验证流程

```java
public class GossipMessageValidator<T> implements MessageValidator<T> {
  private final RecentChainData chainData;
  private final SignatureVerificationService sigVerifier;
  private final ContentValidator<T> contentValidator;
  
  @Override
  public SafeFuture<InternalValidationResult> validate(
      Eth2PreparedGossipMessage message) {
    
    T msg = message.getMessage();
    
    // Phase 1: 预验证（快速检查）
    return SafeFuture.of(() -> preValidate(msg))
      .thenCompose(result -> {
        if (!result.isAccept()) {
          return SafeFuture.completedFuture(result);
        }
        
        // Phase 2: 签名验证（可批量）
        return validateSignature(msg);
      })
      .thenCompose(result -> {
        if (!result.isAccept()) {
          return SafeFuture.completedFuture(result);
        }
        
        // Phase 3: 内容验证（深度检查）
        return validateContent(msg);
      });
  }
  
  private InternalValidationResult preValidate(T message) {
    // 1. 时间窗口检查
    if (!isWithinTimeWindow(message)) {
      return InternalValidationResult.reject(
        "Message outside time window"
      );
    }
    
    // 2. 基本字段检查
    if (!hasValidFields(message)) {
      return InternalValidationResult.reject(
        "Invalid message fields"
      );
    }
    
    // 3. 重复消息检查
    if (isDuplicate(message)) {
      return InternalValidationResult.ignore(
        "Duplicate message"
      );
    }
    
    return InternalValidationResult.ACCEPT;
  }
  
  private SafeFuture<InternalValidationResult> validateSignature(T message) {
    return sigVerifier.verify(
      message.getPublicKey(),
      message.getSigningRoot(),
      message.getSignature()
    ).thenApply(valid -> {
      if (valid) {
        return InternalValidationResult.ACCEPT;
      } else {
        return InternalValidationResult.reject(
          "Invalid signature"
        );
      }
    });
  }
  
  private SafeFuture<InternalValidationResult> validateContent(T message) {
    return contentValidator.validate(message);
  }
}
```

---

## 14.3 时间窗口验证

### 时间检查逻辑

```java
public class TimeWindowValidator {
  private static final Duration MAXIMUM_GOSSIP_CLOCK_DISPARITY = 
    Duration.ofMillis(500);
  
  public boolean isWithinTimeWindow(
      SignedBeaconBlock block,
      UInt64 currentSlot) {
    
    UInt64 blockSlot = block.getSlot();
    
    // 检查区块不在未来（允许时钟偏差）
    UInt64 maxAllowedSlot = currentSlot.plus(
      MAXIMUM_GOSSIP_CLOCK_DISPARITY.dividedBy(
        SECONDS_PER_SLOT * 1000
      )
    );
    
    if (blockSlot.isGreaterThan(maxAllowedSlot)) {
      LOG.debug("Block in future",
        kv("blockSlot", blockSlot),
        kv("currentSlot", currentSlot)
      );
      return false;
    }
    
    // 检查区块不太旧（SLOTS_PER_EPOCH = 32）
    UInt64 minValidSlot = currentSlot.minusMinZero(
      UInt64.valueOf(SLOTS_PER_EPOCH)
    );
    
    if (blockSlot.isLessThan(minValidSlot)) {
      LOG.debug("Block too old", kv("blockSlot", blockSlot));
      return false;
    }
    
    return true;
  }
  
  public boolean isAttestationTimely(
      Attestation attestation,
      UInt64 currentSlot) {
    
    UInt64 attSlot = attestation.getData().getSlot();
    
    // Attestation 必须在 32 个 slot 内
    return currentSlot.isLessThanOrEqualTo(
      attSlot.plus(SLOTS_PER_EPOCH)
    );
  }
}
```

---

## 14.4 签名批量验证

### BatchSignatureVerifier

```java
public class BatchSignatureVerifier {
  private static final int BATCH_SIZE = 64;
  private static final Duration BATCH_TIMEOUT = Duration.ofMillis(100);
  
  private final Queue<PendingVerification> pendingQueue = 
    new ConcurrentLinkedQueue<>();
  private final AsyncRunner asyncRunner;
  private final AtomicBoolean batchScheduled = new AtomicBoolean(false);
  
  public SafeFuture<Boolean> verify(
      BLSPublicKey publicKey,
      Bytes signingRoot,
      BLSSignature signature) {
    
    SafeFuture<Boolean> result = new SafeFuture<>();
    PendingVerification pending = new PendingVerification(
      publicKey, signingRoot, signature, result
    );
    
    pendingQueue.add(pending);
    
    // 达到批量大小或超时时触发验证
    if (pendingQueue.size() >= BATCH_SIZE) {
      processBatchNow();
    } else {
      scheduleBatchProcessing();
    }
    
    return result;
  }
  
  private void scheduleBatchProcessing() {
    if (batchScheduled.compareAndSet(false, true)) {
      asyncRunner.runAfterDelay(
        this::processBatchNow,
        BATCH_TIMEOUT
      );
    }
  }
  
  private void processBatchNow() {
    batchScheduled.set(false);
    
    List<PendingVerification> batch = new ArrayList<>();
    PendingVerification pending;
    while ((pending = pendingQueue.poll()) != null && batch.size() < BATCH_SIZE) {
      batch.add(pending);
    }
    
    if (batch.isEmpty()) {
      return;
    }
    
    asyncRunner.runAsync(() -> processBatch(batch));
  }
  
  private void processBatch(List<PendingVerification> batch) {
    try {
      // 提取批量验证所需数据
      List<BLSPublicKey> publicKeys = batch.stream()
        .map(p -> p.publicKey)
        .collect(Collectors.toList());
      
      List<Bytes> messages = batch.stream()
        .map(p -> p.signingRoot)
        .collect(Collectors.toList());
      
      List<BLSSignature> signatures = batch.stream()
        .map(p -> p.signature)
        .collect(Collectors.toList());
      
      // BLS 批量验证
      boolean allValid = BLS.batchVerify(
        publicKeys, messages, signatures
      );
      
      if (allValid) {
        // 所有签名有效
        batch.forEach(p -> p.result.complete(true));
      } else {
        // 存在无效签名，降级为单个验证
        batch.forEach(this::verifyIndividually);
      }
      
    } catch (Exception e) {
      LOG.error("Batch verification failed", e);
      batch.forEach(p -> p.result.completeExceptionally(e));
    }
  }
  
  private void verifyIndividually(PendingVerification pending) {
    boolean valid = BLS.verify(
      pending.publicKey,
      pending.signingRoot,
      pending.signature
    );
    pending.result.complete(valid);
  }
  
  private static class PendingVerification {
    final BLSPublicKey publicKey;
    final Bytes signingRoot;
    final BLSSignature signature;
    final SafeFuture<Boolean> result;
    
    PendingVerification(
        BLSPublicKey publicKey,
        Bytes signingRoot,
        BLSSignature signature,
        SafeFuture<Boolean> result) {
      this.publicKey = publicKey;
      this.signingRoot = signingRoot;
      this.signature = signature;
      this.result = result;
    }
  }
}
```

---

## 14.5 Merkle Proof 验证

### Deposit Proof 验证

```java
public class DepositValidator {
  private final Spec spec;
  
  public boolean verifyDepositProof(Deposit deposit) {
    DepositData data = deposit.getData();
    
    // 验证 Merkle proof
    return spec.predicates().isValidMerkleBranch(
      data.hashTreeRoot(),
      deposit.getProof(),
      DEPOSIT_CONTRACT_TREE_DEPTH + 1,
      deposit.getIndex().intValue(),
      chainData.getDepositTreeRoot()
    );
  }
}
```

---

## 14.6 验证结果缓存

### ValidationResultCache

```java
public class ValidationResultCache {
  private final Cache<Bytes32, InternalValidationResult> cache;
  
  public ValidationResultCache(int maxSize, Duration expiry) {
    this.cache = Caffeine.newBuilder()
      .maximumSize(maxSize)
      .expireAfterWrite(expiry)
      .recordStats()
      .build();
  }
  
  public Optional<InternalValidationResult> get(Bytes32 messageRoot) {
    return Optional.ofNullable(cache.getIfPresent(messageRoot));
  }
  
  public void put(
      Bytes32 messageRoot,
      InternalValidationResult result) {
    
    // 只缓存最终结果（ACCEPT 或 REJECT）
    if (result.isAccept() || result.isReject()) {
      cache.put(messageRoot, result);
    }
  }
  
  public CacheStats getStats() {
    return cache.stats();
  }
}
```

---

## 14.7 完整验证流程图

```
Gossip Message
      ↓
┌─────────────────┐
│  Decode Message │
└────────┬────────┘
         ↓
┌─────────────────┐
│  Cache Check    │ → Cache Hit → Return Cached Result
└────────┬────────┘
         ↓ Cache Miss
┌─────────────────┐
│  Pre-Validation │
│  - Time window  │
│  - Duplicate    │
│  - Format       │
└────────┬────────┘
         ↓
    ┌────┴────┐
    │ IGNORE? │ → Yes → Return IGNORE
    └────┬────┘
         ↓ No
┌─────────────────┐
│ Signature Check │
│  (Batch/Single) │
└────────┬────────┘
         ↓
    ┌────┴────┐
    │ REJECT? │ → Yes → Return REJECT
    └────┬────┘
         ↓ No
┌─────────────────┐
│ Content Check   │
│  - Merkle proof │
│  - State trans  │
│  - Constraints  │
└────────┬────────┘
         ↓
    ┌────┴────┐
    │ ACCEPT? │ → Yes → Cache + Return ACCEPT
    └────┬────┘
         ↓ No
    Return REJECT/IGNORE
```

---

## 14.8 与 Prysm 对比

### 架构对比

| 维度 | Prysm | Teku |
|------|-------|------|
| **验证管道** | 单个函数 | 三阶段 Future 链 |
| **批量验证** | 手动批量 | 自动批量队列 |
| **结果缓存** | LRU Cache | Caffeine Cache |
| **时间检查** | 简单比较 | 带时钟偏差 |
| **错误处理** | 返回 error | Future 异常 |

### Prysm 验证代码

```go
func (s *Service) validateBeaconBlockPubSub(
    ctx context.Context,
    msg *pubsub.Message) pubsub.ValidationResult {
  
  // 1. 解码
  block := new(eth.SignedBeaconBlock)
  if err := decode(msg.Data, block); err != nil {
    return pubsub.ValidationReject
  }
  
  // 2. 时间检查
  if !isValidSlot(block.Block.Slot) {
    return pubsub.ValidationIgnore
  }
  
  // 3. 签名验证
  if err := verifyBlockSignature(block); err != nil {
    return pubsub.ValidationReject
  }
  
  // 4. 处理区块
  if err := s.chain.ReceiveBlock(ctx, block); err != nil {
    return pubsub.ValidationIgnore
  }
  
  return pubsub.ValidationAccept
}
```

### Teku 验证代码

```java
@Override
public SafeFuture<InternalValidationResult> validate(
    Eth2PreparedGossipMessage message) {
  
  SignedBeaconBlock block = message.getMessage();
  
  // 1. 预验证
  return SafeFuture.of(() -> preValidate(block))
    .thenCompose(result -> {
      if (!result.isAccept()) {
        return SafeFuture.completedFuture(result);
      }
      // 2. 批量签名验证
      return batchVerifier.verify(
        block.getMessage().getProposerIndex(),
        block.getMessage().hashTreeRoot(),
        block.getSignature()
      ).thenApply(valid -> valid 
        ? InternalValidationResult.ACCEPT 
        : InternalValidationResult.REJECT);
    })
    .thenCompose(result -> {
      if (!result.isAccept()) {
        return SafeFuture.completedFuture(result);
      }
      // 3. 内容验证
      return processor.process(block)
        .thenApply(__ -> InternalValidationResult.ACCEPT);
    });
}
```

**Teku 优势**:
- ✅ 异步非阻塞流水线
- ✅ 自动批量签名优化
- ✅ 细粒度错误处理
- ✅ 结果缓存机制

**Prysm 优势**:
- ✅ 代码简洁直观
- ✅ 同步流程易调试
- ✅ 错误上下文清晰

---

## 14.9 性能优化技巧

### 1. 早期退出

```java
// 在昂贵操作前尽早检查
if (isDuplicate(messageRoot)) {
  return InternalValidationResult.IGNORE;
}

if (!isValidTimeWindow(slot)) {
  return InternalValidationResult.IGNORE;
}

// 只有通过快速检查才进行签名验证
```

### 2. 并行验证

```java
public SafeFuture<List<InternalValidationResult>> validateParallel(
    List<Eth2PreparedGossipMessage> messages) {
  
  List<SafeFuture<InternalValidationResult>> futures = 
    messages.stream()
      .map(this::validate)
      .collect(Collectors.toList());
  
  return SafeFuture.allOf(futures.toArray(new SafeFuture[0]))
    .thenApply(__ -> futures.stream()
      .map(SafeFuture::join)
      .collect(Collectors.toList())
    );
}
```

### 3. 预计算缓存

```java
// 缓存常用的 domain 计算
private final Cache<DomainCacheKey, Bytes32> domainCache = 
  Caffeine.newBuilder()
    .maximumSize(100)
    .build();

public Bytes32 getDomain(DomainType type, UInt64 epoch) {
  return domainCache.get(
    new DomainCacheKey(type, epoch),
    key -> spec.getDomain(chainData.getHeadState(), type, epoch)
  );
}
```

---

## 14.10 监控指标

```java
// Prometheus 指标
Counter messagesValidated = Counter.build()
  .name("teku_gossip_validation_total")
  .help("Total messages validated")
  .labelNames("topic", "result")
  .register();

Histogram validationDuration = Histogram.build()
  .name("teku_gossip_validation_duration_seconds")
  .help("Validation duration")
  .labelNames("topic", "phase")
  .buckets(0.001, 0.005, 0.01, 0.05, 0.1, 0.5)
  .register();

Gauge batchSize = Gauge.build()
  .name("teku_signature_batch_size")
  .help("Current signature batch size")
  .register();
```

---

## 14.11 错误处理

### 常见错误场景

1. **时间窗口外**: 返回 `IGNORE`
2. **签名无效**: 返回 `REJECT` + 惩罚 peer
3. **内容不一致**: 返回 `REJECT`
4. **重复消息**: 返回 `IGNORE`
5. **状态缺失**: 返回 `IGNORE` + 触发同步

### 错误恢复策略

```java
public SafeFuture<InternalValidationResult> validateWithRetry(
    Eth2PreparedGossipMessage message) {
  
  return validate(message)
    .exceptionallyCompose(error -> {
      if (error instanceof TimeoutException) {
        LOG.warn("Validation timeout, retrying");
        return validate(message);
      } else if (error instanceof StateNotFoundException) {
        LOG.debug("State not found, saving for later");
        return SafeFuture.completedFuture(
          InternalValidationResult.SAVE_FOR_FUTURE
        );
      } else {
        LOG.error("Validation failed", error);
        return SafeFuture.completedFuture(
          InternalValidationResult.REJECT
        );
      }
    });
}
```

---

## 14.12 总结

**消息验证核心要点**:
1. ✅ 三阶段验证：预验证 → 签名 → 内容
2. ✅ 批量优化：自动批量签名验证
3. ✅ 早期退出：快速过滤无效消息
4. ✅ 结果缓存：避免重复验证
5. ✅ 异步流水线：非阻塞处理

**Teku 设计特点**:
- 🎯 **类型安全**: Future 链确保流程正确
- 🎯 **自动优化**: 批量验证无需手动管理
- 🎯 **细粒度**: 每个阶段可独立监控
- 🎯 **可扩展**: 易于添加新的验证规则

**下一章预告**: 第 15 章将探讨 Peer 评分系统的实现。

---

**最后更新**: 2026-01-13  
**参考代码**: 
- `tech.pegasys.teku.networking.eth2.gossip.GossipMessageValidator`
- `tech.pegasys.teku.infrastructure.async.SafeFuture`
- `tech.pegasys.teku.spec.logic.common.block.BlockValidator`
