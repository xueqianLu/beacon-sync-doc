# Teku Beacon 节点同步模块完整大纲

## 文档版本信息

- **版本**: 1.0.0
- **创建日期**: 2026-01-13
- **基于规范**: Ethereum Consensus Specs (Deneb+)
- **参考实现**: Teku by Consensys
- **编程语言**: Java

---

## 完整目录结构

本文档按照 Prysm 相同的 45 章结构编写，便于横向对比。

### 已完成章节 (7/45)

#### 第一部分：基础概念与架构 (Chapters 1-3) - 100%

- [第 1 章: 以太坊 PoS 共识机制概述](./chapter_01_pos_overview.md)
- [第 2 章: Beacon 节点架构概览](./chapter_02_beacon_architecture.md)
- [第 3 章: Teku 同步模块设计](./chapter_03_sync_module_design.md)

#### 第二部分：P2P 网络层基础 (Chapters 4-6) - 100%

- [第 4 章: libp2p 网络栈](./chapter_04_libp2p_stack.md)
- [第 5 章: 协议协商](./chapter_05_protocol_negotiation.md)
- [第 6 章: 节点发现机制](./chapter_06_node_discovery.md)

#### 第三部分：Req/Resp 协议域 (Chapters 7-12) - 0%

- 第 7 章: Req/Resp 协议基础（计划中）
- 第 8 章: Status 协议（计划中）
- 第 9 章: BeaconBlocksByRange（计划中）
- 第 10 章: BeaconBlocksByRoot（计划中）
- 第 11 章: Blob Sidecars 协议（计划中）
- 第 12 章: 其他 Req/Resp 协议（计划中）

### 计划中章节 (0/38)

详细章节规划参考 [Prysm outline.md](../prysm/outline.md)，Teku 版本将包含：

- 第四部分：Gossipsub 协议域 (13-16 章)
- 第五部分：初始同步 (17-20 章)
- 第六部分：Regular Sync (21-24 章)
- 第七部分：辅助机制 (25-28 章)
- 第八部分：高级主题 (29-32 章)
- 第九部分：错误处理 (33-36 章)
- 第十部分：测试 (37-39 章)
- 第十一部分：实践指南 (40-43 章)
- 第十二部分：未来发展 (44-45 章)

---

## Teku 特色章节（计划扩展）

除了标准 45 章，Teku 版本将增加以下特色章节：

### Teku 专属特性

- **Appendix A**: Java 异步编程模型（SafeFuture vs CompletableFuture）
- **Appendix B**: EventBus 事件驱动架构详解
- **Appendix C**: Teku 配置最佳实践
- **Appendix D**: Java 虚拟线程（Project Loom）在同步中的应用
- **Appendix E**: Teku 与 Besu (Execution Client) 集成

---

## 阅读指南

### 对比阅读路径

如果你已经熟悉 Prysm：

1. 重点阅读 [第 3 章](./chapter_03_sync_module_design.md) - 了解 Teku 架构差异
2. 查看 [code_references.md](./code_references.md) - 代码结构对比
3. 直接跳至具体实现章节（7-28 章）
4. 参考 [对比分析](../../comparison/implementation_diff.md)

### 新手路径

按顺序阅读 1-28 章，理解完整同步流程。

---

## Teku 代码参考

**核心路径**:

```
teku/
├── beacon/sync/                    # 同步核心
├── networking/eth2/                # Eth2 网络层
└── infrastructure/async/           # 异步基础设施
```

详见 [code_references.md](./code_references.md)

---

## 进度追踪

| 部分         | 章节数 | 已完成 | 进度      |
| ------------ | ------ | ------ | --------- |
| 基础概念     | 3      | 3      | 100%      |
| P2P 网络     | 3      | 3      | 100%      |
| Req/Resp     | 6      | 0      | 0%        |
| Gossipsub    | 4      | 0      | 0%        |
| 初始同步     | 4      | 0      | 0%        |
| Regular Sync | 4      | 0      | 0%        |
| 辅助机制     | 4      | 0      | 0%        |
| 高级主题     | 4      | 0      | 0%        |
| 错误处理     | 4      | 0      | 0%        |
| 测试         | 3      | 0      | 0%        |
| 实践指南     | 4      | 0      | 0%        |
| 未来发展     | 2      | 0      | 0%        |
| **总计**     | **45** | **7**  | **15.6%** |

---

## 下一步计划

### Phase 2 (当前)

- 完成第 1-6 章基础内容
- 创建 code_references.md
- 创建 Teku 特定第 3 章

### Phase 3 (即将开始)

- 编写第 7-12 章：Req/Resp 协议（Teku 实现）
- 编写第 13-16 章：Gossipsub 实现
- 编写第 17-20 章：初始同步

### Phase 4 (长期)

- 编写第 21-28 章：Regular Sync 与辅助机制
- 完善对比分析文档
- 添加性能测试数据

---

**最后更新**: 2026-01-13  
**当前进度**: 7/45 章 (15.6%)  
**预计完成**: 2026-02-15
