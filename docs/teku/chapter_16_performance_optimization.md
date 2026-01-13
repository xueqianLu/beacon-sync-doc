# 第 16 章: Gossipsub 性能优化

## 16.1 优化策略

### 16.1.1 消息去重
```java
Cache<Bytes32, Boolean> seenMessages = Caffeine.newBuilder()
  .maximumSize(10000)
  .expireAfterWrite(Duration.ofMinutes(5))
  .build();
```

### 16.1.2 批量验证
- BLS 签名批量验证（32 个/批）
- 减少计算开销 80%

### 16.1.3 优先级队列
- HIGH: Block
- MEDIUM: Aggregate
- LOW: Individual attestation

## 16.2 监控指标

```java
// Prometheus 指标
Counter messagesReceived = Counter.builder("gossip_messages_received_total")
  .tag("topic", "")
  .register(registry);

Timer validationTime = Timer.builder("gossip_validation_duration_seconds")
  .register(registry);
```

## 16.3 性能对比

| 指标 | Prysm | Teku |
|------|-------|------|
| 消息吞吐 | ~500/s | ~600/s |
| 验证延迟 | ~50ms | ~45ms |
| 内存占用 | 中等 | 稍高（JVM） |

---

**最后更新**: 2026-01-13
