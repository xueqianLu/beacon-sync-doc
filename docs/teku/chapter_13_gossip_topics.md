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
