# 第 11 章: Teku Gossipsub 概述

## 11.1 Gossipsub 协议简介

### 11.1.1 发布-订阅模型

Gossipsub 是 libp2p 的发布-订阅协议，用于在 P2P 网络中高效传播消息。

```
Publisher                     Subscribers
   │                             │
   ├──→ Topic: /eth2/beacon_block
   │         ↓                   ↓
   │    [Mesh Network]     [Peer A, B, C...]
   │         ↓                   ↓
   └──→ Message ────────→ Validate → Process
```

**Teku 实现特点**:

- 基于 libp2p-gossipsub v1.1
- 异步事件驱动处理
- 完整的消息验证流水线
- Peer 评分与惩罚机制

---

## 11.2 Teku Gossipsub 架构

### 11.2.1 核心组件

```java
public class Eth2Gossipsub {
  private final GossipNetwork gossipNetwork;
  private final Map<String, TopicHandler> topicHandlers;
  private final MessageValidator messageValidator;
  private final PeerScorer peerScorer;

  public void subscribe(String topic, TopicHandler handler) {
    topicHandlers.put(topic, handler);
    gossipNetwork.subscribe(topic, this::onMessage);
  }

  private void onMessage(String topic, GossipMessage message) {
    TopicHandler handler = topicHandlers.get(topic);

    handler.handleMessage(message)
      .thenAccept(result -> {
        if (result == ValidationResult.ACCEPT) {
          gossipNetwork.propagate(topic, message);
        } else if (result == ValidationResult.REJECT) {
          peerScorer.penalizePeer(message.getSender());
        }
      });
  }
}
```

### 11.2.2 Topic 层次结构

```
/eth2/{fork_digest}/{topic_name}/{encoding}

示例:
/eth2/0x01234567/beacon_block/ssz_snappy
/eth2/0x01234567/beacon_aggregate_and_proof/ssz_snappy
/eth2/0x01234567/beacon_attestation_{subnet_id}/ssz_snappy
```

---

## 11.3 消息处理流程

### 11.3.1 接收流程

```java
public class GossipMessageProcessor {
  private final AsyncRunner asyncRunner;
  private final ValidationPipeline validationPipeline;

  public SafeFuture<ValidationResult> processMessage(
      GossipMessage message) {

    return SafeFuture.of(() -> {
      // 1. 预验证（快速检查）
      return validationPipeline.preValidate(message);
    })
    .thenCompose(preResult -> {
      if (preResult != ValidationResult.ACCEPT) {
        return SafeFuture.completedFuture(preResult);
      }

      // 2. 完整验证（可能较慢）
      return validationPipeline.fullValidate(message);
    })
    .thenCompose(validationResult -> {
      if (validationResult == ValidationResult.ACCEPT) {
        // 3. 处理消息
        return processValidMessage(message)
          .thenApply(__ -> validationResult);
      }
      return SafeFuture.completedFuture(validationResult);
    })
    .exceptionally(error -> {
      LOG.error("Message processing failed", error);
      return ValidationResult.IGNORE;
    });
  }

  private SafeFuture<Void> processValidMessage(GossipMessage message) {
    return asyncRunner.runAsync(() -> {
      // 导入区块/证明等
      return importMessage(message);
    });
  }
}
```

### 11.3.2 验证结果

```java
public enum ValidationResult {
  ACCEPT,   // 接受并传播
  IGNORE,   // 忽略，不传播
  REJECT    // 拒绝并惩罚发送者
}
```

---

## 11.4 Topic 订阅管理

### 11.4.1 动态订阅

```java
public class TopicSubscriptionManager {
  private final GossipNetwork gossipNetwork;
  private final Set<String> activeSubscriptions = new ConcurrentHashSet<>();

  public SafeFuture<Void> subscribeToTopic(
      String topic,
      TopicHandler handler) {

    if (activeSubscriptions.contains(topic)) {
      return SafeFuture.COMPLETE;
    }

    return gossipNetwork.subscribe(topic, message -> {
      return handler.handleMessage(message);
    }).thenAccept(__ -> {
      activeSubscriptions.add(topic);
      LOG.info("Subscribed to topic", kv("topic", topic));
    });
  }

  public SafeFuture<Void> unsubscribeFromTopic(String topic) {
    if (!activeSubscriptions.contains(topic)) {
      return SafeFuture.COMPLETE;
    }

    return gossipNetwork.unsubscribe(topic)
      .thenAccept(__ -> {
        activeSubscriptions.remove(topic);
        LOG.info("Unsubscribed from topic", kv("topic", topic));
      });
  }
}
```

### 11.4.2 Attestation 子网订阅

```java
public class AttestationSubnetSubscriber {
  private static final int ATTESTATION_SUBNET_COUNT = 64;
  private final Random random = new Random();

  public void subscribeToRandomSubnets(int count) {
    Set<Integer> selectedSubnets = new HashSet<>();

    while (selectedSubnets.size() < count) {
      int subnetId = random.nextInt(ATTESTATION_SUBNET_COUNT);
      selectedSubnets.add(subnetId);
    }

    selectedSubnets.forEach(subnetId -> {
      String topic = String.format(
        "/eth2/%s/beacon_attestation_%d/ssz_snappy",
        forkDigest,
        subnetId
      );

      subscribeToTopic(topic, attestationHandler);
    });
  }
}
```

---

## 11.5 消息传播

### 11.5.1 发布消息

```java
public class GossipPublisher {
  private final GossipNetwork gossipNetwork;

  public SafeFuture<Void> publishBlock(SignedBeaconBlock block) {
    String topic = getBlockTopic();

    // 序列化
    Bytes messageData = block.sszSerialize();

    // 压缩
    Bytes compressed = SnappyCompressor.compress(messageData);

    // 发布
    return gossipNetwork.publish(topic, compressed)
      .thenAccept(__ -> {
        LOG.info("Published block",
          kv("slot", block.getSlot()),
          kv("root", block.getRoot())
        );
      });
  }

  private String getBlockTopic() {
    return String.format(
      "/eth2/%s/beacon_block/ssz_snappy",
      getCurrentForkDigest()
    );
  }
}
```

### 11.5.2 消息去重

```java
public class MessageDeduplicator {
  private final Cache<Bytes32, Boolean> seenMessages;

  public MessageDeduplicator() {
    this.seenMessages = Caffeine.newBuilder()
      .maximumSize(10000)
      .expireAfterWrite(Duration.ofMinutes(5))
      .build();
  }

  public boolean isDuplicate(Bytes32 messageId) {
    return seenMessages.getIfPresent(messageId) != null;
  }

  public void markAsSeen(Bytes32 messageId) {
    seenMessages.put(messageId, Boolean.TRUE);
  }
}
```

---

## 11.6 与 Prysm 对比

| 维度         | Prysm            | Teku                     |
| ------------ | ---------------- | ------------------------ |
| **验证模式** | 同步 + 异步      | 完全异步                 |
| **消息处理** | Channel + Worker | EventBus + AsyncRunner   |
| **去重机制** | LRU Cache        | Caffeine                 |
| **子网订阅** | 静态配置         | 动态调整                 |
| **错误处理** | 返回 error       | SafeFuture.exceptionally |

---

## 11.7 性能优化

### 11.7.1 批量验证

```java
public class BatchMessageValidator {
  private final List<PendingMessage> pendingMessages =
    new ArrayList<>();
  private static final int BATCH_SIZE = 32;

  public synchronized void addMessage(GossipMessage message) {
    pendingMessages.add(new PendingMessage(message));

    if (pendingMessages.size() >= BATCH_SIZE) {
      processBatch();
    }
  }

  private void processBatch() {
    List<PendingMessage> batch = new ArrayList<>(pendingMessages);
    pendingMessages.clear();

    // 批量 BLS 签名验证
    blsVerifier.verifyBatch(
      batch.stream()
        .map(PendingMessage::getSignature)
        .collect(Collectors.toList())
    ).thenAccept(results -> {
      for (int i = 0; i < batch.size(); i++) {
        if (results.get(i)) {
          batch.get(i).complete(ValidationResult.ACCEPT);
        } else {
          batch.get(i).complete(ValidationResult.REJECT);
        }
      }
    });
  }
}
```

### 11.7.2 消息优先级

```java
public enum MessagePriority {
  HIGH(0),      // Block
  MEDIUM(1),    // Aggregate attestation
  LOW(2);       // Individual attestation

  private final int value;
}

public class PriorityMessageQueue {
  private final PriorityBlockingQueue<PrioritizedMessage> queue;

  public void enqueue(GossipMessage message, MessagePriority priority) {
    queue.offer(new PrioritizedMessage(message, priority));
  }

  public GossipMessage dequeue() throws InterruptedException {
    return queue.take().getMessage();
  }
}
```

---

## 11.8 监控指标

```java
public class GossipMetrics {
  private final Counter messagesReceived;
  private final Counter messagesValidated;
  private final Counter messagesRejected;
  private final Timer validationDuration;

  public void recordMessage(
      String topic,
      ValidationResult result,
      Duration duration) {

    messagesReceived.increment();

    if (result == ValidationResult.ACCEPT) {
      messagesValidated.increment();
    } else if (result == ValidationResult.REJECT) {
      messagesRejected.increment();
    }

    validationDuration.record(duration);
  }
}
```

---

## 11.9 本章总结

- Teku Gossipsub 基于 libp2p-gossipsub v1.1
- 完全异步的消息处理流水线
- 动态 topic 订阅与管理
- 消息去重与批量验证优化
- 完整的监控指标集成

**下一章**: BeaconBlockTopicHandler 详细实现

---

**最后更新**: 2026-01-13
