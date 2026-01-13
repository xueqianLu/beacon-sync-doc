# Teku Beacon 节点同步模块详解

[![Progress](https://img.shields.io/badge/Progress-22.2%25-orange)](../../PROGRESS.md)

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

### ✅ 已完成章节 (10/45 - 22.2%)

#### 第一部分：基础概念与架构 (3/3) ✅
- [第 1 章: PoS 共识机制概述](./chapter_01_pos_overview.md)
- [第 2 章: Beacon 节点架构](./chapter_02_beacon_architecture.md)
- [第 3 章: Teku 同步模块设计](./chapter_03_sync_module_design.md) ⭐

#### 第二部分：P2P 网络层 (3/3) ✅
- [第 4 章: libp2p 网络栈](./chapter_04_libp2p_stack.md)
- [第 5 章: 协议协商](./chapter_05_protocol_negotiation.md)
- [第 6 章: 节点发现](./chapter_06_node_discovery.md)

#### 第三部分：Req/Resp 协议 (4/6) 🚧
- [第 7 章: Req/Resp 协议基础](./chapter_07_reqresp_basics.md) ⭐
- [第 8 章: Status 协议](./chapter_08_status_protocol.md) ⭐
- [第 9 章: BeaconBlocksByRange](./chapter_09_blocks_by_range.md) ⭐
- [第 10 章: BeaconBlocksByRoot](./chapter_10_blocks_by_root.md) ⭐
- 🚧 第 11 章: Blob Sidecars 协议
- 🚧 第 12 章: 其他 Req/Resp 协议

### 🚧 计划中章节 (0/35)

- **第四部分**: Gossipsub 协议域 (13-16 章)
- **第五部分**: 初始同步 (17-20 章)
- **第六部分**: Regular Sync (21-24 章)
- **第七部分**: 辅助机制 (25-28 章)
- 其他章节...

完整规划见 [outline.md](./outline.md)

---

## 🔍 代码参考

Teku 同步模块关键路径：
```
beacon/sync/                    # 同步核心
├── forward/                    # Forward Sync
├── gossip/                     # Gossip 处理
├── historical/                 # 历史同步
└── fetch/                      # 数据获取

networking/eth2/                # Eth2 网络层
├── rpc/beaconchain/methods/    # Req/Resp 实现
└── gossip/topics/              # Gossipsub 实现
```

详见 [code_references.md](./code_references.md)

---

## 🚀 快速导航

- **返回总览**: [../../README.md](../../README.md)
- **与 Prysm 对比**: [../../comparison/](../../comparison/)
- **完整大纲**: [outline.md](./outline.md)

---

## 📊 Teku 特点

| 特性 | 说明 |
|------|------|
| **编程语言** | Java 21+ |
| **架构风格** | 事件驱动、异步处理 |
| **并发模型** | CompletableFuture + AsyncRunner |
| **类型安全** | 泛型 + 接口 |
| **Checkpoint Sync** | ✅ 支持 |
| **Optimistic Sync** | ✅ 支持 |

---

**最后更新**: 2026-01-13  
**当前进度**: 10/45 章 (22.2%)
