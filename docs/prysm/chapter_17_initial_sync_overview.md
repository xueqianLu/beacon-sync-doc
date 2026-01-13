# 第 17 章 初始同步概述

## 17.1 同步模式分类

### 17.0 初始同步主流程图

下面的流程图概览展示了 Initial Sync 从启动、模式选择，到执行 Full / Checkpoint / Optimistic Sync 并最终切换到 Regular Sync 的整体路径，详细子流程可参考附录中的同步流程图章节：

- 附录：同步相关流程图总览（业务 6：Initial Sync 启动与模式选择）

![业务 6：Initial Sync 主线](img/business6_initial_sync_flow.png)

### 17.1.1 为什么需要不同的同步模式

当一个新的 Beacon 节点启动时，它需要获取整个 Beacon Chain 的状态。根据不同的需求和场景，以太坊提供了三种主要的同步模式：

```
同步需求对比
┌─────────────┬──────────────┬──────────────┬──────────────┐
│  同步模式    │  同步时间    │  安全性      │  存储需求    │
├─────────────┼──────────────┼──────────────┼──────────────┤
│ Full Sync   │  数天-数周   │  最高        │  最大        │
│ Checkpoint  │  数小时      │  需要信任    │  中等        │
│ Optimistic  │  数小时      │  高(EL验证)  │  中等        │
└─────────────┴──────────────┴──────────────┴──────────────┘
```

### 17.1.2 Full Sync（全同步）

**定义**: 从创世块开始，依次同步和验证每一个区块。

**特点**:

- ✅ 完全无需信任任何第三方
- ✅ 验证所有历史数据的正确性
- ✅ 可以提供完整的历史查询服务
- ❌ 同步时间非常长（数天到数周）
- ❌ 需要大量存储空间

**适用场景**:

- 归档节点
- 需要完整历史数据的服务
- 对安全性要求极高的场景

```python
# Full Sync流程伪代码
def full_sync():
    current_slot = GENESIS_SLOT
    head_slot = get_network_head_slot()

    while current_slot < head_slot:
        # 从创世块开始，逐个同步
        block = request_block_by_slot(current_slot)
        if block:
            validate_block(block)
            apply_state_transition(block)
            save_block(block)
        current_slot += 1
```

### 17.1.3 Checkpoint Sync（检查点同步）

**定义**: 从一个可信的近期检查点（finalized checkpoint）开始同步。

**特点**:

- ✅ 同步速度快（数小时）
- ✅ 存储需求相对较小
- ⚠️ 需要信任检查点来源
- ❌ 缺失历史数据（可通过 backfill 补充）

**弱主观性（Weak Subjectivity）**:

```python
# 弱主观性周期约为5个月
MIN_EPOCHS_FOR_BLOCK_REQUESTS = 33_024  # ~5 months

# 检查点必须在这个周期内
def is_valid_checkpoint(checkpoint_epoch, current_epoch):
    return current_epoch - checkpoint_epoch < MIN_EPOCHS_FOR_BLOCK_REQUESTS
```

**适用场景**:

- 快速启动节点
- 验证者节点
- 普通用户节点

**Checkpoint 获取来源**:

1. 官方检查点 API（如 Infura、Alchemy）
2. 信任的节点运营商
3. 社区提供的检查点服务
4. 自己运行的其他节点

```bash
# Prysm启动时指定checkpoint
./prysm.sh beacon-chain \
  --checkpoint-sync-url=https://beaconstate.ethstaker.cc \
  --genesis-beacon-api-url=https://beaconstate.ethstaker.cc
```

### 17.1.4 Optimistic Sync（乐观同步）

**定义**: CL 先同步区块，暂时不等待 EL 的完整验证，在后台异步验证执行层数据。

**合并后的挑战**:

```
合并前                        合并后
┌──────────┐                 ┌──────────┐
│  CL only │                 │    CL    │
└──────────┘                 └────┬─────┘
                                  │ 需要EL验证
                             ┌────┴─────┐
                             │    EL    │
                             └──────────┘
```

**工作原理**:

```
时间线: t0 ──> t1 ──> t2 ──> t3 ──> t4

CL同步: [Block N] → [Block N+1] → [Block N+2] → [Block N+3]
              ↓乐观接受   ↓乐观接受    ↓乐观接受

EL验证:      [验证N] ──────> [验证N+1] ──> [验证N+2]
             (异步)         (可能较慢)

状态:    Optimistic → Optimistic → Validated → Validated
```

**关键概念**:

- **Optimistic Head**: CL 认为的最新 head，可能未经 EL 验证
- **Safe Head**: 已被 EL 完全验证的 head
- **Finalized Head**: 已最终确认的 head

```go
// 来自prysm/beacon-chain/blockchain/service.go
type headInfo struct {
    slot         primitives.Slot
    root         [32]byte
    state        state.BeaconState
    isOptimistic bool  // 标记是否为乐观同步状态
}

func (s *Service) IsOptimistic(ctx context.Context) (bool, error) {
    // 检查当前head是否处于乐观状态
    headRoot := s.headRoot()
    return s.cfg.ForkChoiceStore.IsOptimistic(headRoot)
}
```

**安全保证**:

1. **只能在 justified/finalized 之后**: 不能在未 justified 的区块上乐观同步
2. **EL 最终必须验证**: 所有区块最终都需要 EL 确认
3. **可以回滚**: 如果 EL 验证失败，需要回滚到 safe head

**适用场景**:

- 快速跟上网络进度
- EL 同步较慢时
- 减少同步延迟

---

## 17.2 同步状态机

### 17.2.1 同步状态定义

```go
// 来自prysm/beacon-chain/sync/initial-sync/service.go
type syncStatus int

const (
    // 尚未开始同步
    syncing syncStatus = iota

    // 正在进行初始同步
    initialSync

    // 已完成初始同步，处于regular sync
    synced
)
```

### 17.2.2 状态转换图

```
                    启动节点
                       │
                       ↓
              ┌────────────────┐
              │  检查本地状态  │
              └────────┬───────┘
                       │
        ┌──────────────┴──────────────┐
        │                              │
    本地有数据                      全新节点
        │                              │
        ↓                              ↓
  ┌──────────┐                  ┌──────────┐
  │检查是否落后│                  │Initial Sync│
  └────┬─────┘                  └─────┬────┘
       │                               │
   是否落后?                           │
    │    │                             │
   No   Yes                            │
    │    └─────────────────────────────┘
    │                   │
    │                   ↓
    │          ┌──────────────────┐
    │          │  Full/Checkpoint │
    │          │     Sync Mode    │
    │          └────────┬─────────┘
    │                   │
    │            同步到接近head
    │                   │
    │                   ↓
    │          ┌──────────────────┐
    │          │  Regular Sync    │
    │          │  (跟踪最新区块)  │
    │          └────────┬─────────┘
    │                   │
    └───────────────────┘
                │
                ↓
         ┌──────────────┐
         │   Synced     │
         │  (正常运行)  │
         └──────────────┘
```

### 17.2.3 同步状态判断

```go
// 来自prysm/beacon-chain/sync/initial-sync/service.go
func (s *Service) Syncing() bool {
    // 检查是否落后超过阈值
    return s.chainService.HeadSlot() < s.highestFinalizedSlot()-params.BeaconConfig().SlotsPerEpoch
}

func (s *Service) Status() error {
    if !s.chainStarted {
        return errors.New("chain not started")
    }
    if s.Syncing() {
        return errors.New("syncing")
    }
    return nil
}

// 判断是否需要initial sync
func (s *Service) needsInitialSync() bool {
    currentSlot := s.chain.CurrentSlot()
    headSlot := s.chain.HeadSlot()

    // 如果落后超过1个epoch，需要initial sync
    return currentSlot > headSlot+params.BeaconConfig().SlotsPerEpoch
}
```

### 17.2.4 同步触发条件

**Initial Sync 触发**:

```go
func (s *Service) Start() {
    // 1. 等待足够的peers
    if !s.waitForMinimumPeers() {
        return
    }

    // 2. 检查是否需要同步
    if !s.needsInitialSync() {
        log.Info("Node is already synced")
        return
    }

    // 3. 开始初始同步
    go s.initialSync()
}
```

**切换到 Regular Sync**:

```go
func (s *Service) checkSyncStatus() {
    currentSlot := s.chain.CurrentSlot()
    headSlot := s.chain.HeadSlot()

    // 如果只落后几个slot，切换到regular sync
    if currentSlot-headSlot < params.BeaconConfig().SlotsPerEpoch {
        s.status = synced
        log.Info("Initial sync complete, switching to regular sync")
    }
}
```

---

## 17.3 策略选择

### 17.3.1 决策树

```
启动Beacon节点
      │
      ↓
有checkpoint配置？
   │     │
  Yes    No
   │     │
   │     ↓
   │  需要完整历史？
   │     │     │
   │    Yes    No
   │     │     │
   │     │     ↓
   │     │  Full Sync
   │     │  (默认)
   │     ↓
   │  Archive Sync
   │  (全历史+状态)
   │
   ↓
Checkpoint Sync
   │
   ↓
backfill历史？
   │     │
  Yes    No
   │     │
   ↓     ↓
Backfill  完成
Sync
```

### 17.3.2 配置选项

```go
// Prysm配置示例
type SyncConfig struct {
    // 是否使用checkpoint sync
    CheckpointSyncURL string

    // 是否启用backfill
    EnableBackfillSync bool

    // 是否允许optimistic sync
    EnableOptimisticSync bool

    // Initial sync批量大小
    InitialSyncBatchSize uint64

    // 最小peer数量
    MinPeersToSync uint64
}
```

### 17.3.3 性能对比

**同步时间对比**（基于 2024 年主网数据）:

```
同步模式          时间        带宽消耗    CPU使用    存储需求
================================================================
Full Sync        7-10天      >1TB        高         ~800GB
Checkpoint       4-6小时     ~50GB       中         ~400GB
Checkpoint+      1-2天       ~600GB      高         ~800GB
  Backfill
Optimistic       3-5小时     ~50GB       中-高      ~400GB
```

### 17.3.4 选择建议

**验证者节点推荐**:

```yaml
模式: Checkpoint Sync
原因:
  - 快速启动，减少停机时间
  - 不需要完整历史数据
  - 可以快速开始验证
配置:
  checkpoint-sync-url: https://trusted-source.com
  enable-backfill: false
```

**归档节点推荐**:

```yaml
模式: Full Sync
原因:
  - 需要完整历史数据
  - 提供历史查询服务
  - 不依赖第三方
配置:
  archive-mode: true
  db-prune: false
```

**API 服务节点推荐**:

```yaml
模式: Checkpoint Sync + Backfill
原因:
  - 快速启动服务
  - 逐步补充历史数据
  - 平衡速度和完整性
配置:
  checkpoint-sync-url: https://trusted-source.com
  enable-backfill: true
  backfill-batch-size: 64
```

---

## 17.4 同步监控指标

### 17.4.1 关键 Metrics

```go
// 来自prysm/beacon-chain/sync/metrics.go
var (
    // 同步进度
    syncEth2FallBehind = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "sync_eth2_fallbehind",
        Help: "How far behind the chain head the node is",
    })

    // 同步速度
    syncBlocksPerSecond = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "sync_blocks_per_second",
        Help: "Number of blocks synced per second",
    })

    // Peer数量
    syncPeersCount = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "sync_peers_count",
        Help: "Number of peers used for syncing",
    })

    // 队列大小
    syncPendingBlocks = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "sync_pending_blocks",
        Help: "Number of blocks pending processing",
    })
)
```

### 17.4.2 监控示例

```go
func (s *Service) reportSyncMetrics() {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            headSlot := s.chain.HeadSlot()
            currentSlot := s.chain.CurrentSlot()

            // 报告落后程度
            fallBehind := uint64(currentSlot) - uint64(headSlot)
            syncEth2FallBehind.Set(float64(fallBehind))

            // 报告同步速度
            blocksProcessed := s.getBlocksProcessedLastInterval()
            syncBlocksPerSecond.Set(float64(blocksProcessed) / 10.0)

            // 报告peer数量
            peers := s.p2p.Peers().Connected()
            syncPeersCount.Set(float64(len(peers)))

        case <-s.ctx.Done():
            return
        }
    }
}
```

---

## 17.5 常见问题与解决

### 17.5.1 同步卡住

**症状**: 同步进度长时间不变

**可能原因**:

1. Peer 质量差
2. 网络带宽不足
3. 数据库性能问题
4. 验证逻辑卡死

**诊断方法**:

```bash
# 检查peer连接
curl http://localhost:3500/eth/v1/node/peers | jq '.data | length'

# 检查同步状态
curl http://localhost:3500/eth/v1/node/syncing

# 查看日志
tail -f /var/log/beacon.log | grep -i "sync"

# 检查metrics
curl http://localhost:8080/metrics | grep sync_
```

**解决方案**:

```bash
# 1. 增加peer连接
--p2p-max-peers=100

# 2. 切换checkpoint源
--checkpoint-sync-url=https://alternative-source.com

# 3. 调整批量大小
--initial-sync-batch-size=32

# 4. 重启节点（最后手段）
```

### 17.5.2 Checkpoint 验证失败

**症状**: "invalid checkpoint" 错误

**原因**:

- Checkpoint 来源不可信
- Checkpoint 已过期
- 网络分叉

**解决方案**:

```bash
# 使用可信的checkpoint源
--checkpoint-sync-url=https://beaconstate.ethstaker.cc

# 或使用官方API
--checkpoint-sync-url=https://mainnet.infura.io/v3/YOUR_KEY
```

### 17.5.3 同步速度慢

**优化策略**:

```go
// 1. 增加批量大小
InitialSyncBatchSize: 128,  // 默认64

// 2. 增加并发peer数
MaxConcurrentPeers: 10,     // 默认5

// 3. 调整验证策略
SkipBLSVerify: false,       // 生产环境不建议

// 4. 优化数据库
DBCache: 8192,              // 增加缓存(MB)
```

---

## 17.6 小结

本章介绍了初始同步的三种模式及其选择策略：

✅ **Full Sync**: 最安全但最慢，适合归档节点
✅ **Checkpoint Sync**: 快速启动，适合大多数场景
✅ **Optimistic Sync**: 异步验证，减少延迟
✅ **同步状态机**: 清晰的状态转换逻辑
✅ **监控指标**: 实时跟踪同步进度
✅ **故障排查**: 常见问题的解决方案

理解这些同步模式是运行可靠 Beacon 节点的关键。下一章将深入探讨 Full Sync 的实现细节。

---

**下一章预告**: 第 18 章将详细分析 Full Sync 的实现，包括 Round-Robin 策略和性能优化技巧。
