# Ethereum Beacon 同步模块详解 - 多客户端实现

[![GitHub Pages](https://img.shields.io/badge/docs-GitHub%20Pages-blue)](https://xueqianLu.github.io/beacon-sync-doc/)
[![License](https://img.shields.io/badge/License-MIT-yellow)](./LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./CONTRIBUTING.md)

> 深入对比主流以太坊客户端的 Beacon 节点同步机制

---

## 📚 在线阅读

**GitHub Pages**: [https://xueqianLu.github.io/beacon-sync-doc/](https://xueqianLu.github.io/beacon-sync-doc/)

---

## 🎯 项目简介

本项目提供详尽的技术文档，深入讲解以太坊 PoS Beacon 节点的同步模块设计与实现，**覆盖多个主流客户端的对比分析**。

### 支持的客户端

| 客户端                               | 语言       | 进度                | 文档入口                                |
| ------------------------------------ | ---------- | ------------------- | --------------------------------------- |
| **[Prysm](./docs/prysm/)**           | Go         | ✅ 28/45 章 (62.2%) | [查看文档](./docs/prysm/README.md)      |
| **[Teku](./docs/teku/)**             | Java       | ✅ 28/45 章 (62.2%) | [查看文档](./docs/teku/README.md)       |
| **[Lighthouse](./docs/lighthouse/)** | Rust       | ✅ 28/45 章 (62.2%) | [查看文档](./docs/lighthouse/README.md) |
| **Nimbus**                           | Nim        | 🔜 计划中           | -                                       |
| **Lodestar**                         | TypeScript | 🔜 计划中           | -                                       |

### 📊 客户端对比分析

- [同步策略对比](./comparison/sync_strategies.md) - Initial Sync、Regular Sync 实现差异
- [实现差异分析](./comparison/implementation_diff.md) - 代码架构、设计模式对比
- [协议实现对比](./comparison/) - Req/Resp、Gossipsub 细节对比

### 特色

- ✅ **多客户端覆盖**: Prysm、Teku 及更多（持续增加）
- ✅ **理论与实践结合**: 完整理论体系 + 真实代码实现
- ✅ **横向对比分析**: 设计思路、性能差异一目了然
- ✅ **深度与广度兼备**: 从基础到高级，覆盖全栈

### 适合人群

- 🎓 区块链开发者
- 🏗️ 系统架构师
- 🔧 节点运维人员
- 📖 技术研究者
- 🔍 客户端选型决策者

---

## 📖 快速导航

### 按客户端浏览

<table>
<tr>
<td width="50%">

#### 🟦 [Prysm (Go)](./docs/prysm/)

- ✅ **28/45 章完成** (62.2%)
- 基础概念 (1-6 章)
- Req/Resp 协议 (7-10 章)
- Gossipsub (11-16 章)
- Initial Sync (17-20 章)
- Regular Sync (21-24 章)
- 辅助机制 (25-28 章)

[📖 开始阅读](./docs/prysm/README.md) | [📋 完整大纲](./docs/prysm/outline.md)

</td>
<td width="50%">

#### 🟧 [Teku (Java)](./docs/teku/)

- ✅ **28/45 章完成** (62.2%)
- 基础概念、P2P 网络
- Req/Resp、Gossipsub
- Initial & Regular Sync
- 错误处理、性能优化

[📖 开始阅读](./docs/teku/README.md)

</td>
</tr>
</table>

#### 🟩 [Lighthouse (Rust)](./docs/lighthouse/)

- ✅ **28/45 章完成** (62.2%)
- 基础概念、P2P 网络
- Req/Resp（Status / BlocksByRange / BlocksByRoot）
- 基于源码版本：`v8.0.1`

[📖 开始阅读](./docs/lighthouse/README.md)

### 📊 对比分析

- [同步策略对比](./comparison/sync_strategies.md)
- [实现差异分析](./comparison/implementation_diff.md)
- [更多对比内容](./comparison/README.md)

### 📚 共享资源

- [PoS 基础知识](./shared/pos_fundamentals.md)
- [术语表](./shared/glossary.md)
- [更多通用内容](./shared/README.md)

---

## 🚀 快速开始

### 在线阅读（推荐）

访问 [GitHub Pages](https://xueqianLu.github.io/beacon-sync-doc/) 在线阅读。

### 本地阅读

```bash
# 克隆仓库
git clone https://github.com/xueqianLu/beacon-sync-doc.git
cd beacon-sync-doc

# 使用Markdown阅读器打开任意章节
# 或者在GitHub/IDE中直接阅读
```

### 本地预览（Jekyll）

```bash
# 安装依赖
bundle install

# 启动本地服务器
bundle exec jekyll serve

# 访问 http://localhost:4000/beacon-sync-doc/
```

详见 [DEPLOY.md](./DEPLOY.md) 了解部署详情。

---

## 📊 项目统计

```
客户端覆盖:   3/5 (Prysm ✅, Teku ✅, Lighthouse ✅)
Prysm 进度:   28/45 章 (62.2%)
Teku 进度:    28/45 章 (62.2%)
Lighthouse:   28/45 章 (62.2%)
总行数:       25,000+ 行
代码示例:     350+ 段
流程图:       80+ 个
对比分析:     持续增加中
```

---

## 🛠️ 技术栈

### 参考实现

- **Prysm**: [github.com/prysmaticlabs/prysm](https://github.com/prysmaticlabs/prysm) (Go)
- **Teku**: [github.com/Consensys/teku](https://github.com/Consensys/teku) (Java)
- **Lighthouse**: [github.com/sigp/lighthouse](https://github.com/sigp/lighthouse) (Rust)

### 协议规范

- **Consensus Specs**: [github.com/ethereum/consensus-specs](https://github.com/ethereum/consensus-specs)
- **P2P 网络**: [libp2p](https://libp2p.io/)
- **编码**: SSZ + Snappy

### 文档工具

- **Jekyll** + **GitHub Pages**

---

## 📝 最近更新

### 2026-01-13

- 🔄 **重大重构**: 转型为多客户端文档中心
- ✅ Prysm 文档迁移至 `docs/prysm/`
- ✅ 创建 Teku 文档框架 `docs/teku/`
- ✅ 新增客户端对比分析 `comparison/`
- ✅ 新增共享通用内容 `shared/`

### 2026-01-04

- ✅ 新增第 3 章：同步模块与 P2P 的协同设计
- ✅ 增强第 4 章：添加与同步集成章节
- ✅ Prysm 第一部分现已 100% 完成

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

### 客户端官方资源

- **Prysm**: [docs.prylabs.network](https://docs.prylabs.network/)
- **Teku**: [docs.teku.consensys.io](https://docs.teku.consensys.io/)
- **Lighthouse**: [lighthouse-book.sigmaprime.io](https://lighthouse-book.sigmaprime.io/)

### 协议与规范

- **Consensus Specs**: [github.com/ethereum/consensus-specs](https://github.com/ethereum/consensus-specs)
- **libp2p**: [docs.libp2p.io](https://docs.libp2p.io/)

### 本项目

- **在线文档**: [https://xueqianLu.github.io/beacon-sync-doc/](https://xueqianLu.github.io/beacon-sync-doc/)
- **GitHub 仓库**: [github.com/xueqianLu/beacon-sync-doc](https://github.com/xueqianLu/beacon-sync-doc)

---

## ⭐ 支持项目

如果这个项目对你有帮助，请给个 ⭐️！

---

## 📧 联系方式

- **Issues**: [GitHub Issues](https://github.com/xueqianLu/beacon-sync-doc/issues)
- **Email**: xueqian1991@gmail.com

---

**最后更新**: 2026-01-18 | **版本**: v2.0 | **状态**: 🟢 持续更新中
