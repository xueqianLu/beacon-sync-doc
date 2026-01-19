---
layout: default
title: 首页
---

# Ethereum Beacon 同步模块详解 - 多客户端实现

> 深入对比主流以太坊客户端的 Beacon 节点同步机制

[![GitHub](https://img.shields.io/badge/GitHub-beacon-sync-doc-blue?logo=github)](https://github.com/xueqianLu/beacon-sync-doc)
[![License](https://img.shields.io/badge/License-MIT-yellow)](./LICENSE)

---

## 项目简介

本项目提供详尽的技术文档，深入讲解以太坊 PoS Beacon 节点的同步模块设计与实现，**覆盖多个主流客户端的对比分析**。

### 支持的客户端

<table>
<tr>
<td width="50%">

#### [Prysm (Go)](./docs/prysm/)

- 28/45 章 (62.2%)
- 基础概念、P2P 网络
- Req/Resp、Gossipsub
- Initial & Regular Sync
- 错误处理、性能优化

[开始阅读](./docs/prysm/README.md)

</td>
<td width="50%">

#### [Teku (Java)](./docs/teku/)

- 28/45 章 (62.2%)
- 基础概念、P2P 网络
- Req/Resp、Gossipsub
- Initial & Regular Sync
- 错误处理、性能优化

[查看文档](./docs/teku/README.md)

</td>
</tr>
</table>

---

#### [Lighthouse (Rust)](./docs/lighthouse/)

- 28/45 章 (62.2%)
- 基础概念、P2P 网络
- Req/Resp（Status / BlocksByRange / BlocksByRoot）
- 基于源码版本：`v8.0.1`

[开始阅读](./docs/lighthouse/README.md)

---

## 快速导航

### 按客户端浏览

- **[Prysm 文档](./docs/prysm/README.md)** - Go 实现，28 章完成
- **[Teku 文档](./docs/teku/README.md)** - Java 实现，28 章完成
- **[Lighthouse 文档](./docs/lighthouse/README.md)** - Rust 实现，28 章完成
- **Nimbus** - Nim 实现（计划中）

### 同步流程图章节索引

#### Prysm

- [流程图总览](./docs/prysm/chapter_sync_flow_diagrams.md)
- [业务 1：区块处理](./docs/prysm/chapter_sync_flow_business1_block.md)
- [业务 2：Attestation](./docs/prysm/chapter_sync_flow_business2_attestation.md)
- [业务 3：执行层](./docs/prysm/chapter_sync_flow_business3_execution.md)
- [业务 4：Checkpoint Sync](./docs/prysm/chapter_sync_flow_business4_checkpoint.md)
- [业务 5：Aggregate](./docs/prysm/chapter_sync_flow_business5_aggregate.md)
- [业务 6：Initial Sync](./docs/prysm/chapter_sync_flow_business6_initial.md)
- [业务 7：Regular Sync](./docs/prysm/chapter_sync_flow_business7_regular.md)

#### Teku

- [流程图总览](./docs/teku/chapter_sync_flow_diagrams.md)
- [业务 1：区块处理](./docs/teku/chapter_sync_flow_business1_block.md)
- [业务 2：Attestation](./docs/teku/chapter_sync_flow_business2_attestation.md)
- [业务 3：执行层](./docs/teku/chapter_sync_flow_business3_execution.md)
- [业务 4：Checkpoint Sync](./docs/teku/chapter_sync_flow_business4_checkpoint.md)
- [业务 5：Aggregate](./docs/teku/chapter_sync_flow_business5_aggregate.md)
- [业务 6：Initial Sync](./docs/teku/chapter_sync_flow_business6_initial.md)
- [业务 7：Regular Sync](./docs/teku/chapter_sync_flow_business7_regular.md)

#### Lighthouse

- [流程图总览](./docs/lighthouse/chapter_sync_flow_diagrams.md)
- [业务 1：区块处理](./docs/lighthouse/chapter_sync_flow_business1_block.md)
- [业务 2：Attestation](./docs/lighthouse/chapter_sync_flow_business2_attestation.md)
- [业务 3：执行层](./docs/lighthouse/chapter_sync_flow_business3_execution.md)
- [业务 4：Checkpoint Sync](./docs/lighthouse/chapter_sync_flow_business4_checkpoint.md)
- [业务 5：Aggregate](./docs/lighthouse/chapter_sync_flow_business5_aggregate.md)
- [业务 6：Initial Sync](./docs/lighthouse/chapter_sync_flow_business6_initial.md)
- [业务 7：Regular Sync](./docs/lighthouse/chapter_sync_flow_business7_regular.md)

### 对比分析

- [同步策略对比](./comparison/sync_strategies.md) - Initial Sync、Regular Sync 差异
- [实现差异分析](./comparison/implementation_diff.md) - 架构、设计模式对比
- [更多对比](./comparison/README.md)

### 共享资源

- [术语表](./shared/glossary.md) - 统一术语定义
- [PoS 基础](./shared/README.md) - 通用基础知识

---

## 阅读建议

### 初学者路径

1. 从 [Prysm 第 1 章](./docs/prysm/chapter_01_pos_overview.md) 开始了解 PoS 基础
2. 阅读 [第 2 章](./docs/prysm/chapter_02_beacon_architecture.md) 理解节点架构
3. 学习 [第 17 章](./docs/prysm/chapter_17_initial_sync_overview.md) 了解同步流程

### 开发者路径

1. 查看 [第 3 章](./docs/prysm/chapter_03_sync_module_design.md) 理解模块设计
2. 深入 [第 4-6 章](./docs/prysm/chapter_04_libp2p_stack.md) 掌握 P2P 网络
3. 研究 [第 18 章](./docs/prysm/chapter_18_full_sync.md) 学习实现细节

### 客户端对比

1. 阅读 [Prysm 文档](./docs/prysm/)
2. 对比 [Teku 实现](./docs/teku/)（即将完成）
3. 查看 [对比分析](./comparison/sync_strategies.md)

---

## 项目统计

```
客户端覆盖:   3/5 (Prysm, Teku, Lighthouse)
Prysm 进度:   28/45 章 (62.2%)
Teku 进度:    28/45 章 (62.2%)
Lighthouse:   28/45 章 (62.2%)
总行数:       25,000+ 行
代码示例:     350+ 段
流程图:       80+ 个
对比分析:     持续增加中
```

---

## 技术栈

- **Prysm**: [github.com/prysmaticlabs/prysm](https://github.com/prysmaticlabs/prysm) (Go)
- **Teku**: [github.com/Consensys/teku](https://github.com/Consensys/teku) (Java)
- **协议规范**: [Ethereum Consensus Specs](https://github.com/ethereum/consensus-specs)
- **P2P**: [libp2p](https://libp2p.io/)

---

## 最近更新

### 2026-01-13

- **结构调整**：仓库定位为多客户端文档中心
- Prysm 文档迁移至 `docs/prysm/`
- 创建 Teku 文档框架
- 新增客户端对比分析
- 新增共享通用内容

---

## 参与贡献

欢迎通过 PR 方式补充与勘误：

- 改进文档内容
- 修正错误
- 补充数据

请参考 [CONTRIBUTING.md](./CONTRIBUTING.md)。

---

## 相关链接

- [Prysm 官方文档](https://docs.prylabs.network/)
- [Teku 官方文档](https://docs.teku.consensys.io/)
- [以太坊官网](https://ethereum.org/)
- [共识规范](https://github.com/ethereum/consensus-specs)

---

---

**最后更新**: 2026-01-19 | **版本**: v2.0 | **维护状态**: active
