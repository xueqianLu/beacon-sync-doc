# 第27章：监控指标与日志

## 27.1 Prometheus指标

### 27.1.1 同步进度指标

```go
// beacon-chain/sync/metrics.go
package sync

import (
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    // 同步状态指标
    syncStatus = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "beacon_sync_status",
        Help: "Sync status: 0=synced, 1=syncing, 2=not synced",
    })
    
    // 当前slot
    headSlot = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "beacon_head_slot",
        Help: "Current head slot",
    })
    
    // 目标slot
    targetSlot = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "beacon_sync_target_slot",
        Help: "Target slot for sync",
    })
    
    // 同步进度百分比
    syncProgress = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "beacon_sync_progress_percent",
        Help: "Sync progress percentage",
    })
    
    // 同步速率 (slots/sec)
    syncRate = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "beacon_sync_rate_slots_per_second",
        Help: "Sync rate in slots per second",
    })
    
    // 剩余同步时间估计
    syncETA = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "beacon_sync_eta_seconds",
        Help: "Estimated time to complete sync in seconds",
    })
)

// 更新同步指标
func (s *Service) updateSyncMetrics() {
    currentSlot := s.chain.HeadSlot()
    clockSlot := slots.Since(s.chain.GenesisTime())
    
    headSlot.Set(float64(currentSlot))
    targetSlot.Set(float64(clockSlot))
    
    // 计算进度
    if clockSlot > 0 {
        progress := float64(currentSlot) / float64(clockSlot) * 100
        syncProgress.Set(progress)
    }
    
    // 更新同步状态
    if s.chainStarted && !s.initialSync.Syncing() {
        syncStatus.Set(0) // synced
    } else if s.initialSync.Syncing() {
        syncStatus.Set(1) // syncing
    } else {
        syncStatus.Set(2) // not synced
    }
    
    // 计算同步速率和ETA
    s.calculateSyncRate()
}

func (s *Service) calculateSyncRate() {
    const measureWindow = 60 // 60秒窗口
    
    currentSlot := s.chain.HeadSlot()
    currentTime := time.Now()
    
    if s.lastMeasureTime.IsZero() {
        s.lastMeasureSlot = currentSlot
        s.lastMeasureTime = currentTime
        return
    }
    
    elapsedTime := currentTime.Sub(s.lastMeasureTime).Seconds()
    if elapsedTime < measureWindow {
        return
    }
    
    slotsDelta := float64(currentSlot - s.lastMeasureSlot)
    rate := slotsDelta / elapsedTime
    syncRate.Set(rate)
    
    // 计算ETA
    clockSlot := slots.Since(s.chain.GenesisTime())
    remainingSlots := float64(clockSlot - currentSlot)
    if rate > 0 {
        eta := remainingSlots / rate
        syncETA.Set(eta)
    }
    
    // 更新测量点
    s.lastMeasureSlot = currentSlot
    s.lastMeasureTime = currentTime
}
```

### 27.1.2 P2P网络指标

```go
// beacon-chain/p2p/metrics.go
var (
    // Peer数量
    peerCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
        Name: "p2p_peer_count",
        Help: "Number of peers by state",
    }, []string{"state"})
    
    // 入站/出站连接数
    connectionCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
        Name: "p2p_connection_count",
        Help: "Number of connections by direction",
    }, []string{"direction"})
    
    // 消息计数
    messageCount = promauto.NewCounterVec(prometheus.CounterOpts{
        Name: "p2p_message_total",
        Help: "Total number of p2p messages by type and direction",
    }, []string{"type", "direction"})
    
    // 消息大小
    messageSize = promauto.NewHistogramVec(prometheus.HistogramOpts{
        Name:    "p2p_message_size_bytes",
        Help:    "Size of p2p messages in bytes",
        Buckets: prometheus.ExponentialBuckets(100, 10, 6),
    }, []string{"type"})
    
    // 消息延迟
    messageLatency = promauto.NewHistogramVec(prometheus.HistogramOpts{
        Name:    "p2p_message_latency_seconds",
        Help:    "Latency of p2p message processing",
        Buckets: prometheus.ExponentialBuckets(0.001, 2, 10),
    }, []string{"type"})
    
    // 带宽使用
    bandwidthUsage = promauto.NewCounterVec(prometheus.CounterOpts{
        Name: "p2p_bandwidth_bytes_total",
        Help: "Total bandwidth usage",
    }, []string{"direction"})
)

// 更新peer指标
func (s *Service) updatePeerMetrics() {
    peers := s.peers.All()
    
    // 统计不同状态的peer
    connected := 0
    connecting := 0
    disconnecting := 0
    disconnected := 0
    
    for _, pid := range peers {
        state := s.peers.ConnectionState(pid)
        switch state {
        case peers.PeerConnected:
            connected++
        case peers.PeerConnecting:
            connecting++
        case peers.PeerDisconnecting:
            disconnecting++
        case peers.PeerDisconnected:
            disconnected++
        }
    }
    
    peerCount.WithLabelValues("connected").Set(float64(connected))
    peerCount.WithLabelValues("connecting").Set(float64(connecting))
    peerCount.WithLabelValues("disconnecting").Set(float64(disconnecting))
    peerCount.WithLabelValues("disconnected").Set(float64(disconnected))
    
    // 统计入站/出站连接
    inbound := 0
    outbound := 0
    for _, pid := range peers {
        if s.peers.Direction(pid) == network.DirInbound {
            inbound++
        } else {
            outbound++
        }
    }
    
    connectionCount.WithLabelValues("inbound").Set(float64(inbound))
    connectionCount.WithLabelValues("outbound").Set(float64(outbound))
}

// 记录消息指标
func recordMessage(msgType string, direction string, size int, startTime time.Time) {
    messageCount.WithLabelValues(msgType, direction).Inc()
    messageSize.WithLabelValues(msgType).Observe(float64(size))
    
    latency := time.Since(startTime).Seconds()
    messageLatency.WithLabelValues(msgType).Observe(latency)
    
    bandwidthUsage.WithLabelValues(direction).Add(float64(size))
}
```

### 27.1.3 区块处理指标

```go
// beacon-chain/blockchain/metrics.go
var (
    // 区块处理时间
    blockProcessingTime = promauto.NewHistogram(prometheus.HistogramOpts{
        Name:    "beacon_block_processing_seconds",
        Help:    "Time to process a beacon block",
        Buckets: prometheus.ExponentialBuckets(0.01, 2, 10),
    })
    
    // 状态转换时间
    stateTransitionTime = promauto.NewHistogram(prometheus.HistogramOpts{
        Name:    "beacon_state_transition_seconds",
        Help:    "Time to execute state transition",
        Buckets: prometheus.ExponentialBuckets(0.01, 2, 10),
    })
    
    // Fork choice更新时间
    forkChoiceTime = promauto.NewHistogram(prometheus.HistogramOpts{
        Name:    "beacon_fork_choice_seconds",
        Help:    "Time to update fork choice",
        Buckets: prometheus.ExponentialBuckets(0.001, 2, 10),
    })
    
    // 区块到达时间
    blockArrivalTime = promauto.NewHistogram(prometheus.HistogramOpts{
        Name:    "beacon_block_arrival_seconds",
        Help:    "Time from slot start to block arrival",
        Buckets: []float64{1, 2, 3, 4, 5, 6, 8, 10, 12},
    })
    
    // 处理的区块总数
    processedBlocks = promauto.NewCounter(prometheus.CounterOpts{
        Name: "beacon_blocks_processed_total",
        Help: "Total number of processed blocks",
    })
    
    // 处理失败的区块
    failedBlocks = promauto.NewCounterVec(prometheus.CounterOpts{
        Name: "beacon_blocks_failed_total",
        Help: "Total number of failed blocks by reason",
    }, []string{"reason"})
    
    // 队列中的区块数
    queuedBlocks = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "beacon_blocks_queued",
        Help: "Number of blocks in processing queue",
    })
)

// 在区块处理中记录指标
func (s *Service) onBlock(ctx context.Context, signed interfaces.ReadOnlySignedBeaconBlock, blockRoot [32]byte) error {
    startTime := time.Now()
    defer func() {
        blockProcessingTime.Observe(time.Since(startTime).Seconds())
    }()
    
    // 记录区块到达时间
    slotStartTime := slots.StartTime(s.genesisTime, signed.Block().Slot())
    arrivalTime := time.Now().Sub(slotStartTime).Seconds()
    blockArrivalTime.Observe(arrivalTime)
    
    // 状态转换
    stateStart := time.Now()
    postState, err := s.executeStateTransition(ctx, signed)
    if err != nil {
        failedBlocks.WithLabelValues("state_transition").Inc()
        return err
    }
    stateTransitionTime.Observe(time.Since(stateStart).Seconds())
    
    // Fork choice更新
    fcStart := time.Now()
    if err := s.updateForkChoice(ctx, blockRoot, postState); err != nil {
        failedBlocks.WithLabelValues("fork_choice").Inc()
        return err
    }
    forkChoiceTime.Observe(time.Since(fcStart).Seconds())
    
    processedBlocks.Inc()
    return nil
}
```

## 27.2 结构化日志

### 27.2.1 日志级别和字段

```go
// beacon-chain/sync/log.go
package sync

import (
    "github.com/sirupsen/logrus"
)

var log = logrus.WithField("prefix", "sync")

// 记录同步开始
func (s *Service) logSyncStart(startSlot, targetSlot types.Slot) {
    log.WithFields(logrus.Fields{
        "startSlot":  startSlot,
        "targetSlot": targetSlot,
        "slots":      targetSlot - startSlot,
    }).Info("Starting initial sync")
}

// 记录同步进度
func (s *Service) logSyncProgress(currentSlot, targetSlot types.Slot, rate float64) {
    progress := float64(currentSlot) / float64(targetSlot) * 100
    remainingSlots := targetSlot - currentSlot
    eta := time.Duration(float64(remainingSlots)/rate) * time.Second
    
    log.WithFields(logrus.Fields{
        "currentSlot":     currentSlot,
        "targetSlot":      targetSlot,
        "progress":        fmt.Sprintf("%.2f%%", progress),
        "rate":            fmt.Sprintf("%.2f slots/s", rate),
        "remainingSlots":  remainingSlots,
        "eta":             eta.Round(time.Second),
    }).Info("Sync progress")
}

// 记录区块处理
func (s *Service) logBlockProcessed(block interfaces.ReadOnlySignedBeaconBlock, processingTime time.Duration) {
    log.WithFields(logrus.Fields{
        "slot":           block.Block().Slot(),
        "root":           fmt.Sprintf("%#x", bytesutil.Trunc(block.Block().HashTreeRoot())),
        "proposer":       block.Block().ProposerIndex(),
        "attestations":   len(block.Block().Body().Attestations()),
        "processingTime": processingTime,
    }).Debug("Block processed")
}

// 记录peer连接
func (s *Service) logPeerConnected(pid peer.ID, status *p2ppb.Status) {
    log.WithFields(logrus.Fields{
        "peer":           pid.Pretty(),
        "headSlot":       status.HeadSlot,
        "headRoot":       fmt.Sprintf("%#x", bytesutil.Trunc(status.HeadRoot)),
        "finalizedEpoch": status.FinalizedEpoch,
    }).Debug("Peer connected")
}

// 记录错误
func (s *Service) logError(err error, context string, fields logrus.Fields) {
    if fields == nil {
        fields = logrus.Fields{}
    }
    fields["context"] = context
    
    log.WithFields(fields).WithError(err).Error("Sync error")
}
```

### 27.2.2 性能日志

```go
// beacon-chain/blockchain/log.go
type performanceLogger struct {
    chain *Service
    lastLogTime time.Time
    lastSlot types.Slot
}

func (p *performanceLogger) logPerformance() {
    currentSlot := p.chain.HeadSlot()
    currentTime := time.Now()
    
    if p.lastLogTime.IsZero() {
        p.lastLogTime = currentTime
        p.lastSlot = currentSlot
        return
    }
    
    // 计算性能指标
    elapsed := currentTime.Sub(p.lastLogTime)
    slotsDelta := currentSlot - p.lastSlot
    rate := float64(slotsDelta) / elapsed.Seconds()
    
    // 获取内存统计
    var m runtime.MemStats
    runtime.ReadMemStats(&m)
    
    // 获取goroutine数量
    numGoroutines := runtime.NumGoroutine()
    
    log.WithFields(logrus.Fields{
        "slot":           currentSlot,
        "rate":           fmt.Sprintf("%.2f slots/s", rate),
        "memAlloc":       fmt.Sprintf("%d MB", m.Alloc/1024/1024),
        "memSys":         fmt.Sprintf("%d MB", m.Sys/1024/1024),
        "numGC":          m.NumGC,
        "numGoroutines":  numGoroutines,
        "peers":          p.chain.peers.Connected().Len(),
    }).Info("Performance metrics")
    
    p.lastLogTime = currentTime
    p.lastSlot = currentSlot
}
```

## 27.3 追踪与调试

### 27.3.1 分布式追踪

```go
// beacon-chain/sync/trace.go
import (
    "go.opencensus.io/trace"
)

func (s *Service) processBlockWithTrace(ctx context.Context, signed interfaces.ReadOnlySignedBeaconBlock) error {
    ctx, span := trace.StartSpan(ctx, "sync.processBlock")
    defer span.End()
    
    blockRoot, err := signed.Block().HashTreeRoot()
    if err != nil {
        span.SetStatus(trace.Status{Code: trace.StatusCodeInternal, Message: err.Error()})
        return err
    }
    
    span.AddAttributes(
        trace.Int64Attribute("slot", int64(signed.Block().Slot())),
        trace.StringAttribute("root", fmt.Sprintf("%#x", blockRoot)),
    )
    
    // 验证区块
    ctx, validateSpan := trace.StartSpan(ctx, "sync.validateBlock")
    if err := s.validateBlock(ctx, signed); err != nil {
        validateSpan.SetStatus(trace.Status{Code: trace.StatusCodeInvalidArgument, Message: err.Error()})
        validateSpan.End()
        return err
    }
    validateSpan.End()
    
    // 执行状态转换
    ctx, stateSpan := trace.StartSpan(ctx, "sync.stateTransition")
    postState, err := s.executeStateTransition(ctx, signed)
    if err != nil {
        stateSpan.SetStatus(trace.Status{Code: trace.StatusCodeInternal, Message: err.Error()})
        stateSpan.End()
        return err
    }
    stateSpan.End()
    
    // 保存到数据库
    ctx, dbSpan := trace.StartSpan(ctx, "sync.saveBlock")
    if err := s.saveBlock(ctx, signed, blockRoot, postState); err != nil {
        dbSpan.SetStatus(trace.Status{Code: trace.StatusCodeInternal, Message: err.Error()})
        dbSpan.End()
        return err
    }
    dbSpan.End()
    
    span.SetStatus(trace.Status{Code: trace.StatusCodeOK})
    return nil
}
```

### 27.3.2 调试端点

```go
// beacon-chain/rpc/prysm/v1alpha1/debug/debug.go
type Server struct {
    BeaconDB           db.ReadOnlyDatabase
    HeadFetcher        blockchain.HeadFetcher
    PeersFetcher       p2p.PeersProvider
    SyncChecker        sync.Checker
}

// GetBeaconState 返回指定slot的beacon state
func (s *Server) GetBeaconState(ctx context.Context, req *ethpb.StateRequest) (*ethpb.BeaconState, error) {
    var st state.BeaconState
    var err error
    
    switch q := req.QueryFilter.(type) {
    case *ethpb.StateRequest_Slot:
        st, err = s.BeaconDB.State(ctx, bytesutil.ToBytes32([]byte{byte(q.Slot)}))
    case *ethpb.StateRequest_BlockRoot:
        st, err = s.BeaconDB.State(ctx, bytesutil.ToBytes32(q.BlockRoot))
    default:
        st = s.HeadFetcher.HeadState(ctx)
    }
    
    if err != nil {
        return nil, err
    }
    
    return st.ToProto(), nil
}

// GetPeer 返回peer信息
func (s *Server) GetPeer(ctx context.Context, req *ethpb.PeerRequest) (*ethpb.Peer, error) {
    pid, err := peer.Decode(req.PeerId)
    if err != nil {
        return nil, err
    }
    
    peerInfo := s.PeersFetcher.Peers().Peer(pid)
    if peerInfo == nil {
        return nil, errors.New("peer not found")
    }
    
    return &ethpb.Peer{
        PeerId:          pid.Pretty(),
        Enr:             peerInfo.Enr.String(),
        Address:         peerInfo.Address,
        Direction:       int32(peerInfo.Direction),
        ConnectionState: int32(peerInfo.ConnectionState),
        ChainState:      peerInfo.ChainState,
    }, nil
}

// ListPeers 返回所有peer列表
func (s *Server) ListPeers(ctx context.Context, req *ethpb.ListPeersRequest) (*ethpb.ListPeersResponse, error) {
    peers := s.PeersFetcher.Peers().All()
    
    resp := &ethpb.ListPeersResponse{
        Peers: make([]*ethpb.Peer, 0, len(peers)),
    }
    
    for _, pid := range peers {
        peerInfo := s.PeersFetcher.Peers().Peer(pid)
        if peerInfo == nil {
            continue
        }
        
        resp.Peers = append(resp.Peers, &ethpb.Peer{
            PeerId:          pid.Pretty(),
            Address:         peerInfo.Address,
            Direction:       int32(peerInfo.Direction),
            ConnectionState: int32(peerInfo.ConnectionState),
            ChainState:      peerInfo.ChainState,
        })
    }
    
    return resp, nil
}

// GetSyncStatus 返回同步状态
func (s *Server) GetSyncStatus(ctx context.Context, _ *emptypb.Empty) (*ethpb.SyncStatus, error) {
    headSlot := s.HeadFetcher.HeadSlot()
    targetSlot := slots.Since(s.HeadFetcher.GenesisTime())
    
    return &ethpb.SyncStatus{
        Syncing:    s.SyncChecker.Syncing(),
        HeadSlot:   uint64(headSlot),
        TargetSlot: uint64(targetSlot),
    }, nil
}
```

## 27.4 告警系统

### 27.4.1 告警规则定义

```go
// beacon-chain/monitoring/alerts.go
type AlertRule struct {
    Name        string
    Description string
    Condition   func() bool
    Severity    string
    Action      func()
}

type AlertManager struct {
    rules       []*AlertRule
    activeAlerts map[string]time.Time
    mu          sync.RWMutex
}

func NewAlertManager() *AlertManager {
    return &AlertManager{
        rules:        make([]*AlertRule, 0),
        activeAlerts: make(map[string]time.Time),
    }
}

func (am *AlertManager) RegisterRule(rule *AlertRule) {
    am.mu.Lock()
    defer am.mu.Unlock()
    am.rules = append(am.rules, rule)
}

func (am *AlertManager) Start(ctx context.Context) {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            am.checkRules()
        }
    }
}

func (am *AlertManager) checkRules() {
    am.mu.Lock()
    defer am.mu.Unlock()
    
    now := time.Now()
    
    for _, rule := range am.rules {
        if rule.Condition() {
            // 检查是否已经触发
            if lastAlert, exists := am.activeAlerts[rule.Name]; exists {
                // 避免频繁告警（至少间隔5分钟）
                if now.Sub(lastAlert) < 5*time.Minute {
                    continue
                }
            }
            
            // 触发告警
            log.WithFields(logrus.Fields{
                "alert":       rule.Name,
                "description": rule.Description,
                "severity":    rule.Severity,
            }).Warn("Alert triggered")
            
            // 执行告警动作
            if rule.Action != nil {
                rule.Action()
            }
            
            am.activeAlerts[rule.Name] = now
        } else {
            // 清除已解决的告警
            delete(am.activeAlerts, rule.Name)
        }
    }
}
```

### 27.4.2 预定义告警

```go
// beacon-chain/monitoring/sync_alerts.go
func RegisterSyncAlerts(am *AlertManager, syncService *sync.Service, chain blockchain.HeadFetcher) {
    // 告警：同步卡死
    am.RegisterRule(&AlertRule{
        Name:        "SyncStuck",
        Description: "Sync appears to be stuck",
        Severity:    "critical",
        Condition: func() bool {
            if !syncService.Syncing() {
                return false
            }
            
            // 检查最近5分钟是否有进度
            elapsed := time.Since(syncService.LastProgressTime())
            return elapsed > 5*time.Minute
        },
        Action: func() {
            // 尝试重启同步
            syncService.Restart()
        },
    })
    
    // 告警：Peer数量过低
    am.RegisterRule(&AlertRule{
        Name:        "LowPeerCount",
        Description: "Connected peer count is too low",
        Severity:    "warning",
        Condition: func() bool {
            return syncService.P2P().Peers().Connected().Len() < 5
        },
    })
    
    // 告警：链不同步
    am.RegisterRule(&AlertRule{
        Name:        "ChainNotSynced",
        Description: "Chain is not synced with network",
        Severity:    "warning",
        Condition: func() bool {
            headSlot := chain.HeadSlot()
            clockSlot := slots.Since(chain.GenesisTime())
            
            // 落后超过32个slot（~6.4分钟）
            return clockSlot > headSlot+32
        },
    })
    
    // 告警：内存使用过高
    am.RegisterRule(&AlertRule{
        Name:        "HighMemoryUsage",
        Description: "Memory usage is too high",
        Severity:    "warning",
        Condition: func() bool {
            var m runtime.MemStats
            runtime.ReadMemStats(&m)
            
            // 超过4GB内存使用
            return m.Alloc > 4*1024*1024*1024
        },
        Action: func() {
            // 强制GC
            runtime.GC()
        },
    })
}
```

这一章详细介绍了Prysm中的监控指标、日志系统、追踪和告警机制。这些工具对于运维和调试beacon节点非常重要。
