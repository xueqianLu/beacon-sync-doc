# Teku Beacon 节点同步模块详解

[![Progress](https://img.shields.io/badge/Progress-62.2%25-green)](../../LATEST_PROGRESS.md)

> 基于 Teku 实现的以太坊 Beacon 节点同步机制深度解析

---

## 📖 关于 Teku

**Teku** 是由 Consensys 开发的以太坊共识层客户端，使用 **Java 语言**实现。

- 🔗 **官方仓库**: [github.com/Consensys/teku](https://github.com/Consensys/teku)
- 📚 **官方文档**: [docs.teku.consensys.io](https://docs.teku.consensys.io/)
- 🏷️ **版本**: v24.12.0+
- 💻 **语言**: Java 21+

---

## 📚 文档目录

查看 [outline.md](./outline.md) 获取完整章节列表（28/45 章已完成）

### 核心章节

- **基础概念**: 第 1-3 章
- **P2P 网络**: 第 4-6 章
- **Req/Resp 协议**: 第 7-10 章
- **Gossipsub**: 第 11-16 章
- **初始同步**: 第 17-20 章
- **Regular Sync**: 第 21-24 章
- **辅助机制**: 第 25-28 章

### 同步流程图章节（业务拆分）

- [流程图总览](./chapter_sync_flow_diagrams.md)
- [业务 1：区块处理](./chapter_sync_flow_business1_block.md)
- [业务 2：Attestation](./chapter_sync_flow_business2_attestation.md)
- [业务 3：执行层](./chapter_sync_flow_business3_execution.md)
- [业务 4：Checkpoint Sync](./chapter_sync_flow_business4_checkpoint.md)
- [业务 5：Aggregate](./chapter_sync_flow_business5_aggregate.md)
- [业务 6：Initial Sync](./chapter_sync_flow_business6_initial.md)
- [业务 7：Regular Sync](./chapter_sync_flow_business7_regular.md)

---

## 🔍 代码参考

查看对应章节内的“代码参考/关键类”段落，以及对比分析目录 [../../comparison/](../../comparison/)。

---

## 🚀 快速导航

- **返回总览**: [../../README.md](../../README.md)
- **与 Prysm 对比**: [../../comparison/](../../comparison/)

---

**最后更新**: 2026-01-18  
**当前进度**: 28/45 章 (62.2%)
