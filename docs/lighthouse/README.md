# Lighthouse Beacon 节点同步模块详解

[![Progress](https://img.shields.io/badge/Progress-62.2%25-yellowgreen)](../../LATEST_PROGRESS.md)

> 基于 Lighthouse（Rust）实现的以太坊 Beacon 节点同步机制深度解析（对齐本仓库既有章节架构，便于与 Prysm/Teku 横向对比）。

---

## 关于 Lighthouse

**Lighthouse** 是由 Sigma Prime 开发的以太坊共识层客户端，使用 **Rust** 语言实现。

- **官方仓库**: https://github.com/sigp/lighthouse
- **文档基线版本**: `v8.0.1`
- **语言**: Rust

---

## 文档目录

查看 [outline.md](./outline.md) 获取完整章节列表（当前已完成第 1-28 章）。

### 已完成章节（28/45 - 62.2%）

#### 第一部分：基础概念与架构（3/3）

- [第 1 章: PoS 共识机制概述](./chapter_01_pos_overview.md)
- [第 2 章: Beacon 节点架构概览](./chapter_02_beacon_architecture.md)
- [第 3 章: 同步模块与 P2P 的协同设计](./chapter_03_sync_module_design.md)

#### 第二部分：P2P 网络层基础（3/3）

- [第 4 章: libp2p 网络栈](./chapter_04_libp2p_stack.md)
- [第 5 章: 协议协商](./chapter_05_protocol_negotiation.md)
- [第 6 章: 节点发现机制](./chapter_06_node_discovery.md)

#### 第三部分：Req/Resp 协议域（4/4）

- [第 7 章: Req/Resp 协议基础](./chapter_07_reqresp_basics.md)
- [第 8 章: Status 协议](./chapter_08_status_protocol.md)
- [第 9 章: BeaconBlocksByRange](./chapter_09_blocks_by_range.md)
- [第 10 章: BeaconBlocksByRoot](./chapter_10_blocks_by_root.md)

#### 第四部分：Gossipsub 协议域（6/6）

- [第 11 章: Gossipsub 概述](./chapter_11_gossipsub_overview.md)
- [第 12 章: 区块广播](./chapter_12_block_broadcast.md)
- [第 13 章: Gossip Topics](./chapter_13_gossip_topics.md)
- [第 14 章: Gossip Validation](./chapter_14_gossip_validation.md)
- [第 15 章: Peer Scoring](./chapter_15_peer_scoring.md)
- [第 16 章: 性能优化（Gossipsub）](./chapter_16_performance_optimization.md)

#### 第五部分：初始同步（4/4）

- [第 17 章: Initial Sync 概述](./chapter_17_initial_sync_overview.md)
- [第 18 章: Full Sync](./chapter_18_full_sync.md)
- [第 19 章: Checkpoint Sync](./chapter_19_checkpoint_sync.md)
- [第 20 章: Optimistic Sync](./chapter_20_optimistic_sync.md)

#### 第六部分：Regular Sync（4/4）

- [第 21 章: Regular Sync 概述](./chapter_21_regular_sync.md)
- [第 22 章: Block Pipeline](./chapter_22_block_pipeline.md)
- [第 23 章: Missing Parent](./chapter_23_missing_parent.md)
- [第 24 章: Forkchoice Sync](./chapter_24_forkchoice_sync.md)

#### 第七部分：辅助机制（4/4）

- [第 25 章: Error Handling](./chapter_25_error_handling.md)
- [第 26 章: Performance Optimization](./chapter_26_performance_optimization.md)
- [第 27 章: Metrics Monitoring](./chapter_27_metrics_monitoring.md)
- [第 28 章: Testing](./chapter_28_testing.md)

---

## 代码参考

- [code_references.md](./code_references.md) 汇总了 Lighthouse v8.0.1 中与网络与同步相关的关键路径、核心类型和常用入口。

---

## 附录：同步流程图

- [同步流程图索引（business1-7）](./chapter_sync_flow_diagrams.md)

---

## 快速导航

- **返回首页**: [../../index.md](../../index.md)
- **与 Prysm/Teku 对比**: [../../comparison/](../../comparison/)

---

**最后更新**: 2026-01-19  
**当前进度**: 28/45 章 (62.2%)
