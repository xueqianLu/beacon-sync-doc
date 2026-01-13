# 第 12 章: BeaconBlockTopicHandler 实现

## 12.1 BeaconBlockTopicHandler

```java
public class BeaconBlockTopicHandler implements Eth2TopicHandler<SignedBeaconBlock> {
  private final BlockValidator blockValidator;
  private final ForwardSync forwardSync;
  private final RecentChainData recentChainData;
  
  @Override
  public SafeFuture<ValidationResult> handleMessage(
      Eth2PreparedGossipMessage message) {
    
    SignedBeaconBlock block = message.getMessage();
    
    return SafeFuture.of(() -> {
      // 1. 基础验证
      if (!isValidSlot(block)) {
        return ValidationResult.IGNORE;
      }
      
      // 2. 验证签名
      return blockValidator.validateSignature(block);
    })
    .thenCompose(sigResult -> {
      if (sigResult != ValidationResult.ACCEPT) {
        return SafeFuture.completedFuture(sigResult);
      }
      
      // 3. 验证区块内容
      return blockValidator.validateBlock(block);
    })
    .thenCompose(validationResult -> {
      if (validationResult == ValidationResult.ACCEPT) {
        // 4. 导入区块
        return forwardSync.onGossipBlock(block)
          .thenApply(__ -> ValidationResult.ACCEPT);
      }
      return SafeFuture.completedFuture(validationResult);
    });
  }
  
  private boolean isValidSlot(SignedBeaconBlock block) {
    UInt64 currentSlot = recentChainData.getCurrentSlot();
    UInt64 blockSlot = block.getSlot();
    
    // 检查区块不在未来
    if (blockSlot.isGreaterThan(currentSlot)) {
      return false;
    }
    
    // 检查区块不太旧
    UInt64 minValidSlot = currentSlot.minusMinZero(
      UInt64.valueOf(SLOTS_PER_EPOCH)
    );
    return blockSlot.isGreaterThanOrEqualTo(minValidSlot);
  }
}
```

## 12.2 区块验证流程

```
接收区块
  ↓
Slot 验证 → 太旧/未来 → IGNORE
  ↓
签名验证 → 无效 → REJECT
  ↓
内容验证 → 无效 → REJECT
  ↓
导入区块 → 成功 → ACCEPT
```

## 12.3 与 Prysm 对比

| 验证步骤 | Prysm | Teku |
|----------|-------|------|
| Slot 检查 | ✅ | ✅ |
| 签名验证 | 批量 | 批量 |
| 父块检查 | ✅ | ✅ |
| 状态转换 | 同步 | 异步 |

---

**最后更新**: 2026-01-13
