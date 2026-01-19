# Phase 5 执行计划 - Teku Regular Sync & 辅助机制

**启动日期**: 2026-01-13  
**目标**: 完成 Regular Sync (第 21-24 章) 和辅助机制 (第 25-28 章)  
**预计耗时**: 4-5 小时

---

## 当前状态

```
Teku 进度:      ████████████░░░░░░░░░░░░░ 42.2% (19/45)
目标进度:       ██████████████████░░░░░░░ 62.2% (28/45)
增长目标:       +9 章 (+20%)
```

---

## Phase 5 目标

完成 Teku 的 Regular Sync 部分和辅助机制，使其与 Prysm 进度对齐（28/45 章）。

---

## 执行清单

### Phase 5.1 - Regular Sync (第 21-24 章)

#### 1. 第 21 章: Regular Sync 概述 (目标 200+ 行)

**核心内容**:

- [ ] Regular Sync 服务架构
- [ ] 与 Initial Sync 的区别
- [ ] 实时跟踪机制
- [ ] 状态管理
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_21_regular_sync.md` (221 行)
- Teku 代码: `tech.pegasys.teku.beacon.sync.forward`

#### 2. 第 22 章: Block Processing Pipeline (目标 300+ 行)

**核心内容**:

- [ ] 区块接收流程
- [ ] 验证管道设计
- [ ] 状态转换处理
- [ ] Fork choice 集成
- [ ] 批量处理优化
- [ ] 完整流程图
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_22_block_pipeline.md` (395 行)
- Teku 代码: `tech.pegasys.teku.beacon.sync.gossip`

#### 3. 第 23 章: 缺失父块处理 (目标 250+ 行)

**核心内容**:

- [ ] 父块缺失检测
- [ ] 请求策略（BlocksByRoot）
- [ ] 重试机制
- [ ] 缓存管理
- [ ] 超时处理
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_23_missing_parent.md` (252 行)
- Teku 代码: `tech.pegasys.teku.beacon.sync.fetch`

#### 4. 第 24 章: Fork 选择与同步 (目标 300+ 行)

**核心内容**:

- [ ] Fork choice 算法（LMD-GHOST）
- [ ] 与同步集成
- [ ] Attestation 处理
- [ ] Head 更新流程
- [ ] Reorg 处理
- [ ] 完整流程图
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_24_forkchoice_sync.md` (382 行)
- Teku 代码: `tech.pegasys.teku.spec.logic.common.forkchoice`

---

### Phase 5.2 - 辅助机制 (第 25-28 章)

#### 5. 第 25 章: 错误处理机制 (目标 300+ 行)

**核心内容**:

- [ ] 错误分类
- [ ] 异常处理策略
- [ ] 重试逻辑
- [ ] 降级策略
- [ ] 错误恢复
- [ ] 日志记录
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_25_error_handling.md` (592 行)

#### 6. 第 26 章: 性能优化实践 (目标 300+ 行)

**核心内容**:

- [ ] 同步性能优化
- [ ] 资源管理
- [ ] 缓存策略
- [ ] 并发控制
- [ ] JVM 调优
- [ ] 性能测试数据
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_26_performance_optimization.md` (664 行)

#### 7. 第 27 章: 监控与指标 (目标 350+ 行)

**核心内容**:

- [ ] Prometheus 指标
- [ ] Grafana 仪表盘
- [ ] 关键指标定义
- [ ] 告警规则
- [ ] 日志分析
- [ ] 故障排查
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_27_metrics_monitoring.md` (779 行)

#### 8. 第 28 章: 测试与调试 (目标 300+ 行)

**核心内容**:

- [ ] 单元测试
- [ ] 集成测试
- [ ] 性能测试
- [ ] 调试技巧
- [ ] 故障模拟
- [ ] 测试工具
- [ ] 与 Prysm 对比

**参考**:

- Prysm: `chapter_28_testing.md` (643 行)

---

## 预期成果

```
Phase 5 完成后:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
新增/扩充:       8 章 (第 21-28 章)
新增行数:        ~2,300+ lines
新增大小:        ~70KB
总进度:          19/45 → 28/45 (42.2% → 62.2%)
整体进度:        47/90 → 56/90 (52.2% → 62.2%)
```

---

## 执行策略

### 分批执行

**批次 1** (2 小时): 第 21-22 章 (Regular Sync 核心)
**批次 2** (1.5 小时): 第 23-24 章 (缺失块和 Fork choice)
**批次 3** (1.5 小时): 第 25-26 章 (错误处理和性能)
**批次 4** (1 小时): 第 27-28 章 (监控和测试)

### 质量标准

每章应包含：

- 完整的关键类/接口与方法签名（与源码路径对应）
- 关键流程图或时序描述（gossip/rpc/链服务交互）
- 与 Prysm 的差异点说明（设计取舍、边界条件、性能影响）
- 指标/日志口径（用于定位同步状态与性能瓶颈）
- 错误处理与降级路径（重试、超时、限流、断连）

---

## 参考资源

### Teku 核心代码路径

```
teku/beacon/sync/
├── forward/                    # Regular Sync
│   ├── ForwardSyncService.java
│   └── singlepeer/
├── gossip/                     # Block Pipeline
│   └── GossipedBlockProcessor.java
├── fetch/                      # 缺失块
│   ├── FetchRecentBlocksService.java
│   └── FetchTaskFactory.java
└── events/

teku/spec/logic/common/forkchoice/  # Fork Choice
└── ForkChoice.java

teku/infrastructure/
├── metrics/                    # 监控指标
└── logging/                    # 日志
```

### Prysm 参考章节

- `docs/prysm/chapter_21_regular_sync.md`
- `docs/prysm/chapter_22_block_pipeline.md`
- `docs/prysm/chapter_23_missing_parent.md`
- `docs/prysm/chapter_24_forkchoice_sync.md`
- `docs/prysm/chapter_25_error_handling.md`
- `docs/prysm/chapter_26_performance_optimization.md`
- `docs/prysm/chapter_27_metrics_monitoring.md`
- `docs/prysm/chapter_28_testing.md`

---

## 成功要素

1. **参考 Prysm 结构**: 保持章节一致性
2. **复用 Phase 4 经验**: 使用已建立的模板
3. **增量提交**: 每完成 2 章提交一次
4. **质量优先**: 确保代码和对比的准确性

---

## 成功标准

- 所有 8 章内容完整（平均 250+ 行）
- 每章包含 Prysm 深度对比
- 流程图清晰易懂
- 代码示例完整可运行
- Teku 进度达到 62.2%（与 Prysm 对齐）

---

执行入口：优先完成第 21-24 章（Regular Sync 主链路），再补齐第 25-28 章（辅助机制）。
