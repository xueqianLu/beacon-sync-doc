# 第 15 章: Peer 评分系统

本章详细介绍 Teku 中基于 Gossipsub 的 Peer 评分机制，包括评分配置、计算算法、惩罚策略和连接管理。

---

## 15.1 评分系统概述

### Gossipsub Peer Scoring

Teku 使用 libp2p Gossipsub 的内置评分系统来管理 peer 质量：

```java
package tech.pegasys.teku.networking.eth2.peers.scoring;

public class PeerScoringService {
  private final GossipScoring gossipScoring;
  private final PeerManager peerManager;
  private final Map<PeerId, PeerScore> peerScores = 
    new ConcurrentHashMap<>();
  
  public void initialize() {
    // 配置 GossipSub 评分参数
    GossipScoringParams params = createScoringParams();
    gossipScoring.updateParams(params);
    
    // 启动定期评分更新
    startPeriodicScoring();
  }
  
  public double getPeerScore(PeerId peerId) {
    return peerScores.getOrDefault(
      peerId, PeerScore.NEUTRAL
    ).getValue();
  }
  
  public void updatePeerScore(
      PeerId peerId,
      ScoreUpdate update) {
    
    PeerScore current = peerScores.computeIfAbsent(
      peerId, id -> new PeerScore()
    );
    
    current.apply(update);
    
    // 检查是否需要断连
    if (current.isBelowDisconnectThreshold()) {
      disconnectPeer(peerId, "Low peer score");
    }
  }
}
```

---

## 15.2 GossipScoringConfig 配置

### 主题级别评分参数

```java
public class GossipScoringConfig {
  // 全局参数
  public static final double GRAYLIST_THRESHOLD = -4000;
  public static final double PUBLISH_THRESHOLD = -8000;
  public static final double GOSSIP_THRESHOLD = -16000;
  
  // 主题权重
  private static final double BEACON_BLOCK_WEIGHT = 0.5;
  private static final double BEACON_AGGREGATE_WEIGHT = 0.5;
  private static final double BEACON_ATTESTATION_WEIGHT = 1.0;
  
  public GossipScoringParams createParams(Spec spec) {
    GossipScoringParams params = new GossipScoringParams();
    
    // 全局阈值
    params.setGraylistThreshold(GRAYLIST_THRESHOLD);
    params.setPublishThreshold(PUBLISH_THRESHOLD);
    params.setGossipThreshold(GOSSIP_THRESHOLD);
    
    // IP 协同评分
    params.setIPColocationFactorWeight(-35.11);
    params.setIPColocationFactorThreshold(10);
    
    // Behaviour penalties
    params.setBehaviourPenaltyWeight(-15.92);
    params.setBehaviourPenaltyDecay(0.986);
    
    // 主题参数
    params.setTopicParams(createTopicParams(spec));
    
    return params;
  }
  
  private Map<String, TopicScoreParams> createTopicParams(Spec spec) {
    Map<String, TopicScoreParams> topicParams = new HashMap<>();
    
    // Beacon block 主题
    topicParams.put(
      "/eth2/{fork_digest}/beacon_block/{encoding}",
      createBeaconBlockParams(spec)
    );
    
    // Beacon attestation 主题（64 个 subnet）
    for (int subnet = 0; subnet < 64; subnet++) {
      topicParams.put(
        String.format("/eth2/{fork_digest}/beacon_attestation_%d/{encoding}", subnet),
        createAttestationParams(spec)
      );
    }
    
    // Beacon aggregate 主题
    topicParams.put(
      "/eth2/{fork_digest}/beacon_aggregate_and_proof/{encoding}",
      createAggregateParams(spec)
    );
    
    return topicParams;
  }
}
```

### BeaconBlock 主题参数

```java
private TopicScoreParams createBeaconBlockParams(Spec spec) {
  TopicScoreParams params = new TopicScoreParams();
  
  // 时间参数
  Duration slotDuration = Duration.ofSeconds(
    spec.getGenesisSpecConfig().getSecondsPerSlot()
  );
  Duration epochDuration = slotDuration.multipliedBy(
    spec.getGenesisSpecConfig().getSlotsPerEpoch()
  );
  
  // 时间窗口
  params.setTimeInMeshQuantum(slotDuration);
  params.setTimeInMeshCap(3600.0 / slotDuration.getSeconds());
  params.setTimeInMeshWeight(0.03333);
  
  // 首次消息传递
  params.setFirstMessageDeliveriesWeight(1.1471);
  params.setFirstMessageDeliveriesDecay(0.9928);
  params.setFirstMessageDeliveriesCap(179.0754);
  
  // Mesh 消息传递
  params.setMeshMessageDeliveriesWeight(-458.31);
  params.setMeshMessageDeliveriesDecay(0.9716);
  params.setMeshMessageDeliveriesCap(2.0817);
  params.setMeshMessageDeliveriesThreshold(0.6944);
  params.setMeshMessageDeliveriesActivation(epochDuration);
  params.setMeshMessageDeliveriesWindow(Duration.ofSeconds(2));
  
  // Mesh 失败惩罚
  params.setMeshFailurePenaltyWeight(-458.31);
  params.setMeshFailurePenaltyDecay(0.9716);
  
  // 无效消息惩罚
  params.setInvalidMessageDeliveriesWeight(-214.99);
  params.setInvalidMessageDeliveriesDecay(0.9971);
  
  // 主题权重
  params.setTopicWeight(BEACON_BLOCK_WEIGHT);
  
  return params;
}
```

---

## 15.3 PeerScore 计算算法

### 评分组成部分

Peer 总分由以下部分组成：

```java
public class PeerScore {
  private double topicScore = 0.0;
  private double ipColocationScore = 0.0;
  private double behaviourPenalty = 0.0;
  private double applicationScore = 0.0;
  
  public double getTotalScore() {
    return topicScore + 
           ipColocationScore + 
           behaviourPenalty + 
           applicationScore;
  }
  
  // 1. Topic Score: 基于消息传递质量
  public void updateTopicScore(String topic, TopicScore score) {
    topicScore += score.calculate();
  }
  
  // 2. IP Colocation: 同一 IP 地址的 peer 数量惩罚
  public void updateIPColocationScore(int peersFromSameIP) {
    if (peersFromSameIP > IP_COLOCATION_THRESHOLD) {
      ipColocationScore = 
        (peersFromSameIP - IP_COLOCATION_THRESHOLD) * 
        IP_COLOCATION_FACTOR_WEIGHT;
    }
  }
  
  // 3. Behaviour Penalty: 行为惩罚（如断连、超时）
  public void applyBehaviourPenalty(double penalty) {
    behaviourPenalty += penalty;
  }
  
  // 4. Application Score: 应用层评分（Teku 自定义）
  public void updateApplicationScore(double score) {
    applicationScore = score;
  }
}
```

### Topic Score 详细计算

```java
public class TopicScore {
  private double timeInMeshScore = 0.0;
  private double firstMessageDeliveriesScore = 0.0;
  private double meshMessageDeliveriesScore = 0.0;
  private double invalidMessagePenalty = 0.0;
  
  public double calculate() {
    return (timeInMeshScore + 
            firstMessageDeliveriesScore + 
            meshMessageDeliveriesScore + 
            invalidMessagePenalty) * topicWeight;
  }
  
  // P1: Time in Mesh
  // 奖励在 mesh 中停留时间长的 peer
  public void updateTimeInMesh(Duration time) {
    double t = Math.min(
      time.getSeconds() / timeInMeshQuantum.getSeconds(),
      timeInMeshCap
    );
    timeInMeshScore = t * timeInMeshWeight;
  }
  
  // P2: First Message Deliveries
  // 奖励首次传递有效消息的 peer
  public void recordFirstDelivery() {
    firstMessageDeliveries = Math.min(
      firstMessageDeliveries + 1,
      firstMessageDeliveriesCap
    );
    firstMessageDeliveriesScore = 
      firstMessageDeliveries * firstMessageDeliveriesWeight;
  }
  
  // P3: Mesh Message Deliveries
  // 惩罚在 mesh 中但不传递消息的 peer
  public void updateMeshDeliveries(int delivered, int expected) {
    double deficit = Math.max(
      meshMessageDeliveriesThreshold - delivered,
      0
    );
    meshMessageDeliveriesScore = 
      -deficit * meshMessageDeliveriesWeight;
  }
  
  // P4: Invalid Message Penalty
  // 惩罚传递无效消息的 peer
  public void recordInvalidMessage() {
    invalidMessageDeliveries++;
    invalidMessagePenalty = 
      -invalidMessageDeliveries * invalidMessageDeliveriesWeight;
  }
  
  // 定期衰减
  public void decay() {
    firstMessageDeliveries *= firstMessageDeliveriesDecay;
    invalidMessageDeliveries *= invalidMessageDeliveriesDecay;
  }
}
```

---

## 15.4 IP Colocation 评分

### IP 地址管理

```java
public class IPColocationScorer {
  private final Map<InetAddress, Set<PeerId>> ipToPeers = 
    new ConcurrentHashMap<>();
  
  public void registerPeer(PeerId peerId, InetAddress ip) {
    ipToPeers.computeIfAbsent(ip, k -> ConcurrentHashMap.newKeySet())
      .add(peerId);
    
    // 更新该 IP 下所有 peer 的评分
    updateScoresForIP(ip);
  }
  
  public void unregisterPeer(PeerId peerId, InetAddress ip) {
    Set<PeerId> peers = ipToPeers.get(ip);
    if (peers != null) {
      peers.remove(peerId);
      if (peers.isEmpty()) {
        ipToPeers.remove(ip);
      } else {
        updateScoresForIP(ip);
      }
    }
  }
  
  private void updateScoresForIP(InetAddress ip) {
    Set<PeerId> peers = ipToPeers.get(ip);
    if (peers == null) return;
    
    int count = peers.size();
    
    if (count > IP_COLOCATION_THRESHOLD) {
      double penalty = (count - IP_COLOCATION_THRESHOLD) * 
                       IP_COLOCATION_FACTOR_WEIGHT;
      
      for (PeerId peer : peers) {
        peerScoringService.applyIPColocationPenalty(peer, penalty);
      }
    }
  }
}
```

---

## 15.5 Behaviour Penalties

### 行为惩罚场景

```java
public class BehaviourPenaltyApplier {
  // 惩罚值
  private static final double DISCONNECT_PENALTY = -100.0;
  private static final double TIMEOUT_PENALTY = -10.0;
  private static final double INVALID_MESSAGE_PENALTY = -50.0;
  private static final double RATE_LIMIT_PENALTY = -20.0;
  
  public void onPeerDisconnected(
      PeerId peerId,
      DisconnectReason reason) {
    
    double penalty = switch (reason) {
      case REMOTE_FAULT -> DISCONNECT_PENALTY;
      case PROTOCOL_ERROR -> DISCONNECT_PENALTY * 2;
      case RATE_LIMITING -> RATE_LIMIT_PENALTY;
      default -> 0.0;
    };
    
    if (penalty != 0.0) {
      peerScoringService.applyBehaviourPenalty(peerId, penalty);
    }
  }
  
  public void onRequestTimeout(PeerId peerId) {
    peerScoringService.applyBehaviourPenalty(
      peerId, TIMEOUT_PENALTY
    );
  }
  
  public void onInvalidMessage(
      PeerId peerId,
      ValidationResult result) {
    
    if (result == ValidationResult.REJECT) {
      peerScoringService.applyBehaviourPenalty(
        peerId, INVALID_MESSAGE_PENALTY
      );
    }
  }
}
```

---

## 15.6 评分衰减机制

### 定期衰减

```java
public class ScoreDecayScheduler {
  private static final Duration DECAY_INTERVAL = Duration.ofSeconds(1);
  
  private final AsyncRunner asyncRunner;
  private final PeerScoringService scoringService;
  
  public void start() {
    asyncRunner.runWithFixedDelay(
      this::applyDecay,
      DECAY_INTERVAL,
      this::handleDecayError
    );
  }
  
  private void applyDecay() {
    for (PeerId peerId : scoringService.getAllPeers()) {
      PeerScore score = scoringService.getScore(peerId);
      
      // 衰减各个分数组件
      score.decayFirstMessageDeliveries();
      score.decayInvalidMessageDeliveries();
      score.decayBehaviourPenalty();
      
      // 更新总分
      scoringService.updateScore(peerId, score);
    }
  }
  
  private void handleDecayError(Throwable error) {
    LOG.error("Score decay failed", error);
  }
}
```

### 衰减参数

```java
// 首次消息传递衰减（每秒）
firstMessageDeliveries *= 0.9928;  // ~12 小时衰减到 0

// 无效消息衰减（每秒）
invalidMessageDeliveries *= 0.9971;  // ~6 小时衰减到 0

// 行为惩罚衰减（每秒）
behaviourPenalty *= 0.986;  // ~1 小时衰减到 0
```

---

## 15.7 断连策略

### 基于评分的断连

```java
public class ScoreBasedDisconnectionManager {
  // 阈值
  private static final double GRAYLIST_THRESHOLD = -4000;
  private static final double DISCONNECT_THRESHOLD = -8000;
  
  public void checkAndDisconnect(PeerId peerId, double score) {
    if (score < DISCONNECT_THRESHOLD) {
      // 立即断连并加入黑名单
      disconnect(peerId, "Score below disconnect threshold");
      blacklist(peerId, Duration.ofHours(24));
      
    } else if (score < GRAYLIST_THRESHOLD) {
      // 加入灰名单，限制交互
      graylist(peerId);
      
      // 如果持续低分，最终断连
      scheduleConditionalDisconnect(peerId);
    }
  }
  
  private void disconnect(PeerId peerId, String reason) {
    LOG.warn("Disconnecting peer",
      kv("peer", peerId),
      kv("reason", reason)
    );
    
    peerManager.disconnectPeer(peerId);
    
    // 记录断连事件
    metricsSystem.recordDisconnection(peerId, reason);
  }
  
  private void blacklist(PeerId peerId, Duration duration) {
    reputationManager.blacklist(peerId, duration);
  }
  
  private void graylist(PeerId peerId) {
    // 灰名单：不主动断连，但不转发其消息
    reputationManager.graylist(peerId);
  }
}
```

---

## 15.8 应用层评分（Teku 自定义）

### 自定义评分逻辑

```java
public class ApplicationScorer {
  public double calculateApplicationScore(PeerId peerId) {
    double score = 0.0;
    
    // 1. 响应时间评分
    score += scoreResponseTime(peerId);
    
    // 2. 数据质量评分
    score += scoreDataQuality(peerId);
    
    // 3. 协议遵守评分
    score += scoreProtocolCompliance(peerId);
    
    return score;
  }
  
  private double scoreResponseTime(PeerId peerId) {
    Duration avgResponseTime = metricsManager
      .getAverageResponseTime(peerId);
    
    if (avgResponseTime.compareTo(Duration.ofSeconds(5)) < 0) {
      return 10.0;  // 快速响应
    } else if (avgResponseTime.compareTo(Duration.ofSeconds(30)) < 0) {
      return 0.0;   // 正常响应
    } else {
      return -10.0; // 慢速响应
    }
  }
  
  private double scoreDataQuality(PeerId peerId) {
    PeerStats stats = peerManager.getPeerStats(peerId);
    
    double validRatio = (double) stats.getValidMessages() / 
                        Math.max(stats.getTotalMessages(), 1);
    
    return (validRatio - 0.95) * 100;  // 期望 95% 以上有效
  }
  
  private double scoreProtocolCompliance(PeerId peerId) {
    int violations = protocolMonitor.getViolations(peerId);
    return -violations * 5.0;
  }
}
```

---

## 15.9 与 Prysm 对比

### 架构对比

| 维度 | Prysm | Teku |
|------|-------|------|
| **评分系统** | 自定义实现 | Gossipsub 内置 |
| **主题评分** | 简化版本 | 完整 libp2p 规范 |
| **IP 惩罚** | 手动检查 | 自动 IP colocation |
| **衰减机制** | 定时任务 | Gossipsub 自动 |
| **应用评分** | Peer 状态评分 | 自定义应用层评分 |

### Prysm 评分代码

```go
type peerScorer struct {
  store *peerDataStore
  config *ScorerConfig
}

func (s *peerScorer) Score(pid peer.ID) float64 {
  data, exists := s.store.PeerData(pid)
  if !exists {
    return 0
  }
  
  score := 0.0
  
  // 区块评分
  score += s.scoreBlocks(data)
  
  // 响应时间评分
  score += s.scoreResponseTime(data)
  
  // 错误惩罚
  score -= float64(data.BadResponses) * BadResponsePenalty
  
  return score
}

func (s *peerScorer) scoreBlocks(data *peerData) float64 {
  if data.ProcessedBlocks == 0 {
    return 0
  }
  
  ratio := float64(data.ValidBlocks) / float64(data.ProcessedBlocks)
  return ratio * BlockScore
}
```

### Teku 评分代码

```java
public double calculateScore(PeerId peerId) {
  // 1. Gossipsub 内置评分
  double gossipScore = gossipScoring.score(peerId);
  
  // 2. 应用层评分
  double appScore = applicationScorer.calculateScore(peerId);
  
  // 3. 合并评分
  return gossipScore + appScore;
}

// Gossipsub 自动计算：
// - Topic scores (P1-P4)
// - IP colocation penalty
// - Behaviour penalty
```

**Teku 优势**:
- ✅ 符合 libp2p 标准规范
- ✅ 自动处理复杂评分逻辑
- ✅ 主题级别细粒度控制
- ✅ 社区验证的参数

**Prysm 优势**:
- ✅ 实现简单直观
- ✅ 易于调试和定制
- ✅ 资源占用更少

---

## 15.10 监控与调试

### 评分监控指标

```java
// Peer 评分分布
Histogram peerScoreDistribution = Histogram.build()
  .name("teku_peer_score_distribution")
  .help("Distribution of peer scores")
  .buckets(-10000, -1000, -100, 0, 100, 1000, 10000)
  .register();

// 断连原因统计
Counter disconnectionsByReason = Counter.build()
  .name("teku_peer_disconnections_total")
  .help("Peer disconnections by reason")
  .labelNames("reason")
  .register();

// 评分组件贡献
Gauge scoreComponents = Gauge.build()
  .name("teku_peer_score_components")
  .help("Score components for peers")
  .labelNames("peer_id", "component")
  .register();
```

### 调试日志

```java
public void logPeerScore(PeerId peerId) {
  PeerScore score = getScore(peerId);
  
  LOG.debug("Peer score details",
    kv("peer", peerId),
    kv("total", score.getTotalScore()),
    kv("topic", score.getTopicScore()),
    kv("ipColocation", score.getIPColocationScore()),
    kv("behaviour", score.getBehaviourPenalty()),
    kv("application", score.getApplicationScore())
  );
}
```

---

## 15.11 最佳实践

### 1. 渐进式惩罚

```java
// 不要一次性施加大惩罚，而是逐步增加
public void applyGradualPenalty(PeerId peerId, PenaltyType type) {
  int violations = violationCounter.get(peerId, type);
  double penalty = BASE_PENALTY * Math.pow(1.5, violations);
  
  applyBehaviourPenalty(peerId, penalty);
  violationCounter.increment(peerId, type);
}
```

### 2. 宽容期

```java
// 给新 peer 一个宽容期
public boolean isInGracePeriod(PeerId peerId) {
  Duration connected = Duration.between(
    connectionTime.get(peerId),
    Instant.now()
  );
  return connected.compareTo(GRACE_PERIOD) < 0;
}

public void checkAndDisconnectWithGrace(PeerId peerId, double score) {
  if (!isInGracePeriod(peerId)) {
    checkAndDisconnect(peerId, score);
  }
}
```

### 3. 评分上限

```java
// 防止评分无限增长
public double capScore(double score) {
  return Math.max(
    Math.min(score, MAX_SCORE),
    MIN_SCORE
  );
}
```

---

## 15.12 总结

**Peer 评分核心要点**:
1. ✅ 多维度评分：主题、IP、行为、应用
2. ✅ 自动衰减：防止旧惩罚永久影响
3. ✅ 渐进惩罚：从警告到断连
4. ✅ 标准化：遵循 libp2p Gossipsub 规范
5. ✅ 可调节：参数可根据网络状况调整

**Teku 设计特点**:
- 🎯 **标准化**: 完整实现 Gossipsub 评分规范
- 🎯 **细粒度**: 主题级别独立评分
- 🎯 **自动化**: 无需手动管理衰减和阈值
- 🎯 **可扩展**: 支持自定义应用层评分

**下一章预告**: 第 16 章将探讨 Gossipsub 性能优化实践。

---

**最后更新**: 2026-01-13  
**参考代码**: 
- `tech.pegasys.teku.networking.p2p.gossip.scoring`
- `tech.pegasys.teku.networking.eth2.peers.PeerScorer`
- libp2p Gossipsub Spec
