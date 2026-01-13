# 第 15 章: Peer 评分系统

## 15.1 评分机制

```java
public class PeerScorer {
  private final Map<Peer, PeerScore> scores = new ConcurrentHashMap<>();
  
  public void recordValidMessage(Peer peer) {
    PeerScore score = scores.computeIfAbsent(peer, PeerScore::new);
    score.incrementValid();
  }
  
  public void recordInvalidMessage(Peer peer) {
    PeerScore score = scores.computeIfAbsent(peer, PeerScore::new);
    score.incrementInvalid();
    
    if (score.shouldDisconnect()) {
      disconnectPeer(peer);
    }
  }
  
  public double getScore(Peer peer) {
    return scores.getOrDefault(peer, PeerScore.DEFAULT).getScore();
  }
}
```

## 15.2 评分参数

| 行为 | 分数变化 |
|------|----------|
| 有效消息 | +1 |
| 无效消息 | -10 |
| 重复消息 | -1 |
| 超时 | -5 |
| 断开阈值 | -100 |

---

**最后更新**: 2026-01-13
