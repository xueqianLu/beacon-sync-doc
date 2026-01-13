# 第 14 章: 消息验证流程

## 14.1 验证流水线

```java
public class MessageValidationPipeline {
  public SafeFuture<ValidationResult> validate(GossipMessage message) {
    return preValidate(message)
      .thenCompose(this::signatureValidate)
      .thenCompose(this::contentValidate);
  }
  
  private SafeFuture<ValidationResult> preValidate(GossipMessage message) {
    // 快速检查：格式、大小、基础字段
    if (!isValidFormat(message)) {
      return SafeFuture.completedFuture(ValidationResult.REJECT);
    }
    return SafeFuture.completedFuture(ValidationResult.ACCEPT);
  }
  
  private SafeFuture<ValidationResult> signatureValidate(ValidationResult prev) {
    if (prev != ValidationResult.ACCEPT) return SafeFuture.completedFuture(prev);
    // BLS 签名验证
    return blsVerifier.verify(message.getSignature());
  }
  
  private SafeFuture<ValidationResult> contentValidate(ValidationResult prev) {
    if (prev != ValidationResult.ACCEPT) return SafeFuture.completedFuture(prev);
    // 完整内容验证
    return fullValidator.validate(message.getContent());
  }
}
```

## 14.2 批量 BLS 验证

```java
public class BatchBlsVerifier {
  private final List<PendingVerification> batch = new ArrayList<>();
  
  public SafeFuture<Boolean> addToBatch(BLSSignature signature) {
    SafeFuture<Boolean> result = new SafeFuture<>();
    batch.add(new PendingVerification(signature, result));
    
    if (batch.size() >= BATCH_SIZE) {
      processBatch();
    }
    
    return result;
  }
  
  private void processBatch() {
    // 批量验证签名
    boolean allValid = BLS.verifyBatch(
      batch.stream().map(p -> p.signature).collect(toList())
    );
    batch.forEach(p -> p.result.complete(allValid));
    batch.clear();
  }
}
```

---

**最后更新**: 2026-01-13
