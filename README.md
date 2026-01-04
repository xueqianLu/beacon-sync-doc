# Beacon Node 同步模块详解

[![GitHub Pages](https://img.shields.io/badge/docs-GitHub%20Pages-blue)](https://luxq.github.io/beaconsync/)
[![Progress](https://img.shields.io/badge/Progress-28.9%25-green)](./PROGRESS.md)
[![License](https://img.shields.io/badge/License-MIT-yellow)](./LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./CONTRIBUTING.md)

> 深入解析以太坊Beacon节点同步机制 - 基于Prysm实现

---

## 📚 在线阅读

**GitHub Pages**: [https://xueqianLu.github.io/beacon-sync-doc/](https://xueqianLu.github.io/beacon-sync-doc/)

---

## 🎯 项目简介

本项目是一份详尽的技术文档，深入讲解以太坊2.0（PoS）Beacon节点的同步模块设计与实现。

### 特色

- ✅ **理论与实践结合**: 完整的理论体系 + Prysm真实代码
- ✅ **深度与广度兼备**: 从基础到高级，覆盖全栈
- ✅ **实用性强**: 配置示例、问题解答、性能优化

### 适合人群

- 🎓 区块链开发者
- 🏗️ 系统架构师
- 🔧 节点运维人员
- 📖 技术研究者

---

## 📖 目录

### ✅ 已完成章节 (13/45)

#### [第一部分：基础概念与架构](./beacon_sync_outline.md) (100%)
- [第1章: PoS共识机制概述](./chapter_01_pos_overview.md)
- [第2章: Beacon节点架构](./chapter_02_beacon_architecture.md)
- [第3章: 同步模块与P2P协同](./chapter_03_sync_module_design.md)

#### [第二部分：P2P网络层基础](./beacon_sync_outline.md) (100%)
- [第4章: libp2p网络栈](./chapter_04_libp2p_stack.md)
- [第5章: 协议协商](./chapter_05_protocol_negotiation.md)
- [第6章: 节点发现(discv5)](./chapter_06_node_discovery.md)

#### [第五部分：初始同步](./beacon_sync_outline.md) (100%)
- [第17章: Initial Sync概述](./chapter_17_initial_sync_overview.md)
- [第18章: Full Sync实现](./chapter_18_full_sync.md)
- [第19章: Checkpoint Sync](./chapter_19_checkpoint_sync.md)
- [第20章: Optimistic Sync](./chapter_20_optimistic_sync.md)

#### [第六部分：Regular Sync](./beacon_sync_outline.md) (100%)
- [第21章: Regular Sync概述](./chapter_21_regular_sync.md)
- [第22章: Block Pipeline](./chapter_22_block_pipeline.md)
- [第23章: 缺失父块处理](./chapter_23_missing_parent.md)
- [第24章: Fork Choice同步](./chapter_24_forkchoice_sync.md)

### 📋 计划中章节

- 第三部分: Req/Resp协议域 (0/6章)
- 第四部分: Gossipsub协议域 (0/4章)
- 第七~十二部分: 辅助机制、高级主题 (0/21章)

查看完整大纲: [beacon_sync_outline.md](./beacon_sync_outline.md)

---

## 🚀 快速开始

### 在线阅读（推荐）

访问 [GitHub Pages](https://luxq.github.io/beaconsync/) 在线阅读。

### 本地阅读

```bash
# 克隆仓库
git clone https://github.com/luxq/beaconsync.git
cd beaconsync

# 使用Markdown阅读器打开任意章节
# 或者在GitHub/IDE中直接阅读
```

### 本地预览（Jekyll）

```bash
# 安装依赖
bundle install

# 启动本地服务器
bundle exec jekyll serve

# 访问 http://localhost:4000/beaconsync/
```

详见 [DEPLOY.md](./DEPLOY.md) 了解部署详情。

---

## 📊 文档统计

```
总章节数:    45章 (计划)
已完成:      13章 (28.9%)
总行数:      7,905行
文件大小:    ~196KB
代码示例:    70+段
流程图:      30+个
```

---

## 🛠️ 技术栈

- **参考实现**: [Prysm](https://github.com/OffchainLabs/prysm) v7
- **协议规范**: [Ethereum Consensus Specs](https://github.com/ethereum/consensus-specs)
- **P2P网络**: [libp2p](https://libp2p.io/)
- **编码**: SSZ + Snappy
- **文档工具**: Jekyll + GitHub Pages

---

## 📝 最近更新

### 2026-01-04
- ✅ 新增第3章：同步模块与P2P的协同设计
- ✅ 增强第4章：添加与同步集成章节
- ✅ 准备GitHub Pages部署文件
- ✅ 第一部分现已100%完成！

查看详细更新: [PROGRESS.md](./PROGRESS.md)

---

## 🤝 参与贡献

我们欢迎任何形式的贡献！

- 📖 改进文档内容
- 🐛 修正错误
- 💡 提出建议
- 🌐 翻译
- 📊 补充数据

详见 [CONTRIBUTING.md](./CONTRIBUTING.md)

---

## 📄 许可证

本项目采用 [MIT License](./LICENSE)。

---

## 🔗 相关链接

- **在线文档**: [https://luxq.github.io/beaconsync/](https://luxq.github.io/beaconsync/)
- **Prysm**: [https://docs.prylabs.network/](https://docs.prylabs.network/)
- **共识规范**: [https://github.com/ethereum/consensus-specs](https://github.com/ethereum/consensus-specs)
- **libp2p**: [https://docs.libp2p.io/](https://docs.libp2p.io/)

---

## ⭐ 支持项目

如果这个项目对你有帮助，请给个 ⭐️！

---

## 📧 联系方式

- **Issues**: [GitHub Issues](https://github.com/luxq/beaconsync/issues)
- **Email**: your-email@example.com

---

**最后更新**: 2026-01-04 | **版本**: v1.1 | **状态**: 🟢 持续更新中
