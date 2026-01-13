# Teku Beacon 节点同步模块详解

[![Progress](https://img.shields.io/badge/Progress-0%25-red)](../../PROGRESS.md)

> 基于 Teku 实现的以太坊 Beacon 节点同步机制深度解析

---

## 📖 关于 Teku

**Teku** 是由 Consensys 开发的以太坊共识层客户端，使用 **Java 语言**实现。

- 🔗 **官方仓库**: [github.com/Consensys/teku](https://github.com/Consensys/teku)
- 📚 **官方文档**: [docs.teku.consensys.io](https://docs.teku.consensys.io/)
- 🏷️ **版本**: v24.0+
- 💻 **语言**: Java

---

## 📚 文档目录

### 🚧 进行中章节

本文档将按照与 Prysm 相同的章节结构编写，预计包含：

- **基础概念**: 第 1-3 章（通用内容）
- **P2P 网络**: 第 4-6 章（libp2p 通用）
- **Req/Resp 协议**: 第 7-10 章（Teku 实现）
- **Gossipsub**: 第 11-16 章（Teku 实现）
- **初始同步**: 第 17-20 章（Teku 实现）
- **Regular Sync**: 第 21-24 章（Teku 实现）
- **辅助机制**: 第 25-28 章（Teku 实现）

---

## 🔍 代码参考

Teku 同步模块关键路径：

```
teku/
├── networking/eth2/src/main/java/tech/pegasys/teku/networking/eth2/
│   ├── rpc/                           # Req/Resp 协议实现
│   │   ├── core/
│   │   └── beaconchain/
│   └── gossip/                        # Gossipsub 实现
├── beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/
│   ├── forward/                       # Forward Sync (类似 Regular Sync)
│   ├── gossip/                        # Gossip 处理
│   └── historical/                    # 历史同步
└── infrastructure/
```

---

## 🚀 快速导航

- **返回总览**: [../../README.md](../../README.md)
- **与 Prysm 对比**: [../../comparison/](../../comparison/)

---

## 📊 Teku 特点（预览）

| 特性 | 说明 |
|------|------|
| **编程语言** | Java |
| **架构风格** | 事件驱动、异步处理 |
| **Checkpoint Sync** | ✅ 支持 |
| **Optimistic Sync** | ✅ 支持 |
| **代码风格** | 企业级、类型安全 |

---

**最后更新**: 2026-01-13
