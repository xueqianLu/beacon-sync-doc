# 第 13 章: Gossip 主题管理

## 13.1 核心 Topic

```java
public class GossipTopics {
  // 区块 topic
  public static String getBlockTopic(Bytes4 forkDigest) {
    return String.format("/eth2/%s/beacon_block/ssz_snappy", forkDigest);
  }
  
  // 聚合证明 topic
  public static String getAggregateAndProofTopic(Bytes4 forkDigest) {
    return String.format("/eth2/%s/beacon_aggregate_and_proof/ssz_snappy", forkDigest);
  }
  
  // Attestation 子网 topic
  public static String getAttestationSubnetTopic(Bytes4 forkDigest, int subnetId) {
    return String.format("/eth2/%s/beacon_attestation_%d/ssz_snappy", forkDigest, subnetId);
  }
}
```

## 13.2 动态订阅

```java
public class DynamicSubscriptionManager {
  public void subscribeToRequiredTopics() {
    // 始终订阅区块 topic
    subscribeToBlockTopic();
    
    // 订阅聚合证明 topic
    subscribeToAggregateAndProofTopic();
    
    // 动态订阅 attestation 子网
    subscribeToAttestationSubnets();
  }
  
  public void updateSubscriptions(Epoch currentEpoch) {
    // 根据验证者职责更新订阅
    Set<Integer> requiredSubnets = calculateRequiredSubnets(currentEpoch);
    updateAttestationSubnetSubscriptions(requiredSubnets);
  }
}
```

## 13.3 订阅策略

- **区块**: 始终订阅
- **聚合证明**: 始终订阅
- **Attestation**: 动态订阅（基于验证者职责）
- **Sync Committee**: 条件订阅

---

**最后更新**: 2026-01-13

---

## 13.2 主题管理器

### TopicSubscriptionManager

```java
public class TopicSubscriptionManager {
  private final GossipNetwork gossipNetwork;
  private final Set<Bytes4> subscribedForkDigests = new ConcurrentHashSet<>();
  
  public void subscribeToBlocks(Bytes4 forkDigest) {
    String topic = GossipTopics.getBeaconBlockTopic(forkDigest);
    gossipNetwork.subscribe(topic, blockHandler);
    subscribedForkDigests.add(forkDigest);
  }
  
  public void subscribeToAttestationSubnets(
      Bytes4 forkDigest, Set<Integer> subnets) {
    
    for (Integer subnet : subnets) {
      String topic = GossipTopics.getAttestationSubnetTopic(
        forkDigest, subnet);
      gossipNetwork.subscribe(topic, attestationHandler);
    }
  }
}
```

### 主题命名规范

```
/eth2/{fork_digest}/{name}/{encoding}

示例:
/eth2/4a26c58b/beacon_block/ssz_snappy
/eth2/4a26c58b/beacon_aggregate_and_proof/ssz_snappy
/eth2/4a26c58b/beacon_attestation_{subnet_id}/ssz_snappy
```

---

## 13.3 动态订阅

```java
public class DynamicSubnetSubscriber {
  private static final int SUBNETS_PER_NODE = 2;
  private static final Duration SUBSCRIPTION_DURATION = 
    Duration.ofHours(256);
  
  public void updateSubscriptions() {
    Set<Integer> requiredSubnets = calculateRequiredSubnets();
    Set<Integer> currentSubnets = getC\urrentSubscriptions();
    
    // 订阅新 subnet
    Sets.difference(requiredSubnets, currentSubnets)
      .forEach(this::subscribeToSubnet);
    
    // 取消旧 subnet
    Sets.difference(currentSubnets, requiredSubnets)
      .forEach(this::unsubscribeFromSubnet);
  }
  
  private Set<Integer> calculateRequiredSubnets() {
    // 基于本地验证者计算需要的 subnet
    return validators.stream()
      .map(this::getValidatorSubnet)
      .collect(Collectors.toSet());
  }
}
```

---

## 13.4 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| 主题管理 | pubsubTopicMappings | TopicSubscriptionManager |
| 动态订阅 | updateSubnetSubscriptions | DynamicSubnetSubscriber |
| Fork管理 | digest.New() | ForkDigestCalculator |

**Prysm 代码**:
```go
func (s *Service) subscribeDynamicWithSubnets(
    epoch primitives.Epoch, subnets []uint64) {
  
  for _, subnet := range subnets {
    topic := p2p.GossipTypeMapping[p2p.GossipAttestationMessage]
    fullTopic := fmt.Sprintf(topic, s.cfg.p2p.Encoding().ProtocolSuffix(), subnet)
    s.cfg.p2p.PubSub().Subscribe(fullTopic, ...)
  }
}
```

---

**最后更新**: 2026-01-13
