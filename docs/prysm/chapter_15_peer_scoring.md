# 第15章 Peer评分与管理

## 15.1 Peer评分系统

### 15.1.1 评分机制概述

Prysm使用libp2p的peer scoring机制来管理对等节点的质量。评分系统基于多个因素：

```go
// beacon-chain/p2p/peers/scorers/scorer.go

// PeerScorer manages peer scores.
type PeerScorer struct {
    store         *peerstore.PeerStore
    badPeers      map[peer.ID]time.Time
    badPeersLock  sync.RWMutex
    bannedPeers   map[peer.ID]time.Time
    bannedLock    sync.RWMutex
}

// Score components
const (
    // 行为评分
    ScoreBlockRequest      = 1    // 成功响应区块请求
    ScoreBlockProvide      = 2    // 主动提供有效区块
    ScoreInvalidBlock      = -100 // 发送无效区块
    ScoreInvalidAttestation = -50  // 发送无效attestation
    
    // 性能评分
    ScoreFastResponse  = 1   // 快速响应
    ScoreSlowResponse  = -1  // 慢速响应
    ScoreTimeout       = -10 // 请求超时
    
    // 连接评分
    ScoreSuccessfulDial = 1  // 成功连接
    ScoreFailedDial     = -5 // 连接失败
)
```

### 15.1.2 评分更新

```go
// UpdateScore updates peer score based on behavior.
func (ps *PeerScorer) UpdateScore(
    pid peer.ID,
    delta int,
    reason string,
) {
    currentScore := ps.store.PeerScore(pid)
    newScore := currentScore + delta
    
    // 更新评分
    ps.store.SetPeerScore(pid, newScore)
    
    log.WithFields(logrus.Fields{
        "peer":     pid.String(),
        "delta":    delta,
        "newScore": newScore,
        "reason":   reason,
    }).Debug("Updated peer score")
    
    // 检查是否需要惩罚
    if newScore < params.BeaconNetworkConfig().BadPeerThreshold {
        ps.markBadPeer(pid)
    }
    
    // 检查是否需要封禁
    if newScore < params.BeaconNetworkConfig().BanPeerThreshold {
        ps.banPeer(pid, params.BeaconNetworkConfig().BanDuration)
    }
}

// markBadPeer marks a peer as bad.
func (ps *PeerScorer) markBadPeer(pid peer.ID) {
    ps.badPeersLock.Lock()
    defer ps.badPeersLock.Unlock()
    
    ps.badPeers[pid] = time.Now()
    
    log.WithField("peer", pid.String()).Warn("Peer marked as bad")
}

// banPeer bans a peer for specified duration.
func (ps *PeerScorer) banPeer(pid peer.ID, duration time.Duration) {
    ps.bannedLock.Lock()
    defer ps.bannedLock.Unlock()
    
    banUntil := time.Now().Add(duration)
    ps.bannedPeers[pid] = banUntil
    
    log.WithFields(logrus.Fields{
        "peer":     pid.String(),
        "duration": duration,
        "until":    banUntil,
    }).Warn("Peer banned")
    
    // 断开连接
    if err := ps.host.Network().ClosePeer(pid); err != nil {
        log.WithError(err).Error("Failed to disconnect banned peer")
    }
}
```

## 15.2 Gossipsub评分

### 15.2.1 Topic评分参数

```go
// beacon-chain/p2p/gossip_scoring_params.go

// BeaconBlockTopicParams returns scoring params for block topic.
func BeaconBlockTopicParams() *pubsub.TopicScoreParams {
    return &pubsub.TopicScoreParams{
        // Topic weight
        TopicWeight: 0.5,
        
        // Time in mesh
        TimeInMeshWeight:  0.03333,
        TimeInMeshQuantum: time.Second,
        TimeInMeshCap:     300, // 300 seconds max
        
        // First message deliveries
        FirstMessageDeliveriesWeight: 1,
        FirstMessageDeliveriesDecay:  0.99,
        FirstMessageDeliveriesCap:    100,
        
        // Mesh message deliveries
        MeshMessageDeliveriesWeight:     -1,
        MeshMessageDeliveriesDecay:      0.97,
        MeshMessageDeliveriesCap:        100,
        MeshMessageDeliveriesThreshold:  5,
        MeshMessageDeliveriesWindow:     2 * time.Second,
        MeshMessageDeliveriesActivation: 4 * time.Second,
        
        // Invalid messages
        InvalidMessageDeliveriesWeight: -1000,
        InvalidMessageDeliveriesDecay:  0.99,
    }
}

// AttestationSubnetTopicParams returns params for attestation subnet.
func AttestationSubnetTopicParams() *pubsub.TopicScoreParams {
    return &pubsub.TopicScoreParams{
        TopicWeight: 0.5,
        
        TimeInMeshWeight:  0.03333,
        TimeInMeshQuantum: time.Second,
        TimeInMeshCap:     300,
        
        FirstMessageDeliveriesWeight: 0.2,
        FirstMessageDeliveriesDecay:  0.99,
        FirstMessageDeliveriesCap:    50,
        
        MeshMessageDeliveriesWeight:     -0.2,
        MeshMessageDeliveriesDecay:      0.97,
        MeshMessageDeliveriesCap:        50,
        MeshMessageDeliveriesThreshold:  5,
        MeshMessageDeliveriesWindow:     2 * time.Second,
        MeshMessageDeliveriesActivation: 4 * time.Second,
        
        InvalidMessageDeliveriesWeight: -1000,
        InvalidMessageDeliveriesDecay:  0.99,
    }
}
```

### 15.2.2 应用评分参数

```go
// beacon-chain/p2p/gossip_scoring.go

// applyGossipScoring applies scoring parameters to pubsub.
func (s *Service) applyGossipScoring() error {
    // 创建peer score thresholds
    thresholds := &pubsub.PeerScoreThresholds{
        GossipThreshold:             -4000,
        PublishThreshold:            -8000,
        GraylistThreshold:           -16000,
        AcceptPXThreshold:           100,
        OpportunisticGraftThreshold: 5,
    }
    
    // 创建score params
    params := &pubsub.PeerScoreParams{
        AppSpecificScore: func(pid peer.ID) float64 {
            return s.scorer.Score(pid)
        },
        AppSpecificWeight: 1.0,
        
        // IP colocation
        IPColocationFactorWeight:    -50,
        IPColocationFactorThreshold: 10,
        IPColocationFactorWhitelist: nil,
        
        // Behavior penalties
        BehaviourPenaltyWeight: -10,
        BehaviourPenaltyDecay:  0.99,
        BehaviourPenaltyThreshold: 6,
        
        // Decay interval
        DecayInterval: time.Minute,
        DecayToZero:   0.01,
        
        // Retention
        RetainScore: 100 * time.Hour,
        
        // Topic score params
        Topics: make(map[string]*pubsub.TopicScoreParams),
    }
    
    // 添加区块主题评分
    blockTopic := s.BlockTopic()
    params.Topics[blockTopic] = BeaconBlockTopicParams()
    
    // 添加attestation子网评分
    for i := uint64(0); i < params.AttestationSubnetCount; i++ {
        topic := s.AttestationTopic(i)
        params.Topics[topic] = AttestationSubnetTopicParams()
    }
    
    // 应用评分参数
    if err := s.pubsub.SetPeerScoreParams(params); err != nil {
        return errors.Wrap(err, "failed to set peer score params")
    }
    
    // 设置thresholds
    s.pubsub.SetPeerScoreThresholds(thresholds)
    
    log.Info("Gossipsub scoring parameters applied")
    return nil
}
```

## 15.3 Peer状态管理

### 15.3.1 Peer状态枚举

```go
// beacon-chain/p2p/peers/status.go

// PeerConnectionState represents peer connection state.
type PeerConnectionState int

const (
    // PeerDisconnected means no connection to peer.
    PeerDisconnected PeerConnectionState = iota
    // PeerConnecting means connection is being established.
    PeerConnecting
    // PeerConnected means connection is active.
    PeerConnected
    // PeerDisconnecting means connection is being closed.
    PeerDisconnecting
)

// PeerStatus tracks the status of a peer.
type PeerStatus struct {
    pid               peer.ID
    connectionState   PeerConnectionState
    chainState        *pb.Status  // Status from /eth2/beacon_chain/req/status/1
    score             int
    latency           time.Duration
    direction         network.Direction
    validatedBlocks   uint64  // 成功验证的区块数
    invalidMessages   uint64  // 发送的无效消息数
    lastSeen          time.Time
    enr               *enr.Record
}

// Status returns the current peer status.
func (ps *PeerStore) Status(pid peer.ID) *PeerStatus {
    ps.lock.RLock()
    defer ps.lock.RUnlock()
    
    status, exists := ps.peers[pid]
    if !exists {
        return nil
    }
    
    return status
}

// SetChainState updates peer's chain state.
func (ps *PeerStore) SetChainState(pid peer.ID, state *pb.Status) {
    ps.lock.Lock()
    defer ps.lock.Unlock()
    
    if status, exists := ps.peers[pid]; exists {
        status.chainState = state
        status.lastSeen = time.Now()
    }
}
```

### 15.3.2 Peer筛选

```go
// beacon-chain/p2p/peers/scorer.go

// BestPeers returns the best peers for syncing.
func (ps *PeerStore) BestPeers(
    count int,
    finalizedEpoch primitives.Epoch,
) []peer.ID {
    ps.lock.RLock()
    defer ps.lock.RUnlock()
    
    type peerScore struct {
        pid   peer.ID
        score float64
    }
    
    scored := make([]peerScore, 0, len(ps.peers))
    
    for pid, status := range ps.peers {
        // 只考虑已连接的peer
        if status.connectionState != PeerConnected {
            continue
        }
        
        // 检查chain state
        if status.chainState == nil {
            continue
        }
        
        // 过滤掉落后的peer
        if status.chainState.FinalizedEpoch < finalizedEpoch {
            continue
        }
        
        // 计算综合评分
        score := ps.calculatePeerScore(status)
        scored = append(scored, peerScore{pid, score})
    }
    
    // 按评分排序
    sort.Slice(scored, func(i, j int) bool {
        return scored[i].score > scored[j].score
    })
    
    // 返回top N
    result := make([]peer.ID, 0, count)
    for i := 0; i < min(count, len(scored)); i++ {
        result = append(result, scored[i].pid)
    }
    
    return result
}

// calculatePeerScore calculates综合评分.
func (ps *PeerStore) calculatePeerScore(status *PeerStatus) float64 {
    score := float64(status.score)
    
    // 考虑延迟
    if status.latency > 0 {
        latencyPenalty := float64(status.latency.Milliseconds()) / 1000.0
        score -= latencyPenalty
    }
    
    // 考虑有效消息比例
    if status.validatedBlocks > 0 {
        validRatio := float64(status.validatedBlocks) / 
            float64(status.validatedBlocks + status.invalidMessages)
        score *= validRatio
    }
    
    // 考虑最后活跃时间
    timeSinceLastSeen := time.Since(status.lastSeen)
    if timeSinceLastSeen > time.Minute {
        stalePenalty := float64(timeSinceLastSeen.Minutes())
        score -= stalePenalty
    }
    
    return score
}
```

## 15.4 Peer连接管理

### 15.4.1 连接限制

```go
// beacon-chain/p2p/connection_gater.go

// ConnectionGater controls peer connections.
type ConnectionGater struct {
    host           host.Host
    bannedPeers    map[peer.ID]time.Time
    maxPeers       int
    maxInbound     int
    maxOutbound    int
    lock           sync.RWMutex
}

// InterceptPeerDial is called on outbound dials.
func (cg *ConnectionGater) InterceptPeerDial(pid peer.ID) bool {
    cg.lock.RLock()
    defer cg.lock.RUnlock()
    
    // 检查是否被ban
    if banUntil, banned := cg.bannedPeers[pid]; banned {
        if time.Now().Before(banUntil) {
            log.WithField("peer", pid.String()).Debug("Blocked dial to banned peer")
            return false
        }
        // Ban已过期，移除
        delete(cg.bannedPeers, pid)
    }
    
    // 检查outbound连接数
    outboundCount := cg.countOutboundConnections()
    if outboundCount >= cg.maxOutbound {
        log.Debug("Max outbound connections reached")
        return false
    }
    
    return true
}

// InterceptAccept is called on inbound connections.
func (cg *ConnectionGater) InterceptAccept(conn network.ConnMultiaddrs) bool {
    cg.lock.RLock()
    defer cg.lock.RUnlock()
    
    // 检查inbound连接数
    inboundCount := cg.countInboundConnections()
    if inboundCount >= cg.maxInbound {
        log.Debug("Max inbound connections reached")
        return false
    }
    
    // 检查总连接数
    totalCount := len(cg.host.Network().Conns())
    if totalCount >= cg.maxPeers {
        log.Debug("Max total connections reached")
        return false
    }
    
    return true
}

// countOutboundConnections counts outbound connections.
func (cg *ConnectionGater) countOutboundConnections() int {
    count := 0
    for _, conn := range cg.host.Network().Conns() {
        if conn.Stat().Direction == network.DirOutbound {
            count++
        }
    }
    return count
}

// countInboundConnections counts inbound connections.
func (cg *ConnectionGater) countInboundConnections() int {
    count := 0
    for _, conn := range cg.host.Network().Conns() {
        if conn.Stat().Direction == network.DirInbound {
            count++
        }
    }
    return count
}
```

### 15.4.2 Peer修剪

```go
// beacon-chain/p2p/peer_pruning.go

// prunePeers periodically prunes low-quality peers.
func (s *Service) prunePeers() {
    ticker := time.NewTicker(time.Minute * 5)
    defer ticker.Stop()
    
    for {
        select {
        case <-s.ctx.Done():
            return
        case <-ticker.C:
            s.performPruning()
        }
    }
}

// performPruning performs peer pruning.
func (s *Service) performPruning() {
    peers := s.host.Network().Peers()
    
    // 如果未达到最大连接数，不需要修剪
    if len(peers) < s.cfg.MaxPeers {
        return
    }
    
    log.WithField("count", len(peers)).Debug("Checking peers for pruning")
    
    // 按评分排序
    type scoredPeer struct {
        pid   peer.ID
        score float64
    }
    
    scored := make([]scoredPeer, 0, len(peers))
    for _, pid := range peers {
        status := s.peers.Status(pid)
        if status == nil {
            continue
        }
        
        score := s.peers.calculatePeerScore(status)
        scored = append(scored, scoredPeer{pid, score})
    }
    
    sort.Slice(scored, func(i, j int) bool {
        return scored[i].score < scored[j].score  // 从低到高
    })
    
    // 移除最差的10%
    pruneCount := len(scored) / 10
    if pruneCount == 0 {
        return
    }
    
    for i := 0; i < pruneCount; i++ {
        pid := scored[i].pid
        
        log.WithFields(logrus.Fields{
            "peer":  pid.String(),
            "score": scored[i].score,
        }).Debug("Pruning low-score peer")
        
        if err := s.host.Network().ClosePeer(pid); err != nil {
            log.WithError(err).Warn("Failed to disconnect peer")
        }
    }
    
    log.WithField("pruned", pruneCount).Info("Peer pruning completed")
}
```

## 15.5 Peer查询与选择

### 15.5.1 按Head选择Peer

```go
// beacon-chain/sync/peer_selection.go

// SelectPeerForRequest selects best peer for a request.
func (s *Service) SelectPeerForRequest(
    targetSlot primitives.Slot,
) (peer.ID, error) {
    // 获取所有已连接的peer
    peers := s.cfg.P2P.Peers().Connected()
    if len(peers) == 0 {
        return "", errors.New("no connected peers")
    }
    
    // 筛选合适的peer
    candidates := make([]peer.ID, 0)
    
    for _, pid := range peers {
        status := s.cfg.P2P.Peers().ChainState(pid)
        if status == nil {
            continue
        }
        
        // Peer的head必须 >= 目标slot
        if status.HeadSlot < targetSlot {
            continue
        }
        
        // 检查peer评分
        score := s.cfg.P2P.Peers().Score(pid)
        if score < 0 {
            continue
        }
        
        candidates = append(candidates, pid)
    }
    
    if len(candidates) == 0 {
        return "", errors.New("no suitable peers found")
    }
    
    // 随机选择一个候选peer
    selected := candidates[rand.Intn(len(candidates))]
    
    return selected, nil
}

// SelectPeersForBatch selects multiple peers for batch requests.
func (s *Service) SelectPeersForBatch(
    count int,
    targetSlot primitives.Slot,
) []peer.ID {
    peers := s.cfg.P2P.Peers().Connected()
    if len(peers) == 0 {
        return nil
    }
    
    // 获取最佳peer
    bestPeers := s.cfg.P2P.Peers().BestPeers(
        count,
        s.cfg.Chain.FinalizedCheckpoint().Epoch,
    )
    
    // 过滤符合slot要求的peer
    result := make([]peer.ID, 0, count)
    for _, pid := range bestPeers {
        status := s.cfg.P2P.Peers().ChainState(pid)
        if status != nil && status.HeadSlot >= targetSlot {
            result = append(result, pid)
            if len(result) >= count {
                break
            }
        }
    }
    
    return result
}
```

### 15.5.2 Peer多样性

```go
// beacon-chain/p2p/peer_diversity.go

// ensurePeerDiversity ensures peer diversity across different attributes.
func (s *Service) ensurePeerDiversity() {
    peers := s.host.Network().Peers()
    
    // 统计IP分布
    ipCount := make(map[string]int)
    for _, pid := range peers {
        addrs := s.host.Peerstore().Addrs(pid)
        for _, addr := range addrs {
            if ip, err := manet.ToIP(addr); err == nil {
                ipCount[ip.String()]++
            }
        }
    }
    
    // 检查IP聚集
    for ip, count := range ipCount {
        if count > params.BeaconNetworkConfig().MaxPeersPerIP {
            log.WithFields(logrus.Fields{
                "ip":    ip,
                "count": count,
            }).Warn("Too many peers from same IP")
            
            // 断开多余连接
            s.pruneIPExcess(ip, count - params.BeaconNetworkConfig().MaxPeersPerIP)
        }
    }
}
```

## 15.6 本章小结

本章详细介绍了Peer评分与管理机制：

1. **评分系统**：基于行为、性能、连接质量的综合评分
2. **Gossipsub评分**：针对gossip行为的专门评分参数
3. **状态管理**：跟踪peer的连接状态和链状态
4. **连接控制**：限制连接数、过滤恶意peer
5. **Peer修剪**：定期移除低质量peer
6. **Peer选择**：为同步请求选择最佳peer

这些机制确保了节点与高质量peer保持连接，提高同步效率和网络安全性。
