# Lighthouse 文档大纲（对齐 45 章架构）

**客户端**: Lighthouse (Rust)  
**源码基线**: `sigp/lighthouse` `v8.0.1`

> 本大纲对齐本仓库既有 45 章结构，保证可以和 Prysm/Teku 在同一章节编号下直接横向对比。

---

## ✅ 已完成（第 1-28 章）

1. [第 1 章: PoS 共识机制概述](./chapter_01_pos_overview.md)
2. [第 2 章: Beacon 节点架构概览](./chapter_02_beacon_architecture.md)
3. [第 3 章: 同步模块与 P2P 的协同设计](./chapter_03_sync_module_design.md)
4. [第 4 章: libp2p 网络栈](./chapter_04_libp2p_stack.md)
5. [第 5 章: 协议协商](./chapter_05_protocol_negotiation.md)
6. [第 6 章: 节点发现机制](./chapter_06_node_discovery.md)
7. [第 7 章: Req/Resp 协议基础](./chapter_07_reqresp_basics.md)
8. [第 8 章: Status 协议](./chapter_08_status_protocol.md)
9. [第 9 章: BeaconBlocksByRange](./chapter_09_blocks_by_range.md)
10. [第 10 章: BeaconBlocksByRoot](./chapter_10_blocks_by_root.md)

11. [第 11 章: Gossipsub 概述](./chapter_11_gossipsub_overview.md)
12. [第 12 章: 区块广播](./chapter_12_block_broadcast.md)
13. [第 13 章: Gossip Topics](./chapter_13_gossip_topics.md)
14. [第 14 章: Gossip Validation](./chapter_14_gossip_validation.md)
15. [第 15 章: Peer Scoring](./chapter_15_peer_scoring.md)
16. [第 16 章: 性能优化（Gossipsub）](./chapter_16_performance_optimization.md)

17. [第 17 章: Initial Sync 概述](./chapter_17_initial_sync_overview.md)
18. [第 18 章: Full Sync](./chapter_18_full_sync.md)
19. [第 19 章: Checkpoint Sync](./chapter_19_checkpoint_sync.md)
20. [第 20 章: Optimistic Sync](./chapter_20_optimistic_sync.md)

21. [第 21 章: Regular Sync 概述](./chapter_21_regular_sync.md)
22. [第 22 章: Block Pipeline](./chapter_22_block_pipeline.md)
23. [第 23 章: Missing Parent](./chapter_23_missing_parent.md)
24. [第 24 章: Forkchoice Sync](./chapter_24_forkchoice_sync.md)

25. [第 25 章: Error Handling](./chapter_25_error_handling.md)
26. [第 26 章: Performance Optimization](./chapter_26_performance_optimization.md)
27. [第 27 章: Metrics Monitoring](./chapter_27_metrics_monitoring.md)
28. [第 28 章: Testing](./chapter_28_testing.md)

---

## 🚧 待编写（第 29-45 章）

### 第八-十二部分：高级主题与实践

29-45.（按本仓库既有章节标题对齐，后续逐步补齐）

---

## 📎 附录：同步流程图（business1-7）

- [同步流程图索引](./chapter_sync_flow_diagrams.md)
- [业务 1：区块（Block）](./chapter_sync_flow_business1_block.md)
- [业务 2：证明（Attestation）](./chapter_sync_flow_business2_attestation.md)
- [业务 3：执行层（Execution）](./chapter_sync_flow_business3_execution.md)
- [业务 4：Checkpoint/Backfill](./chapter_sync_flow_business4_checkpoint.md)
- [业务 5：聚合（Aggregate）](./chapter_sync_flow_business5_aggregate.md)
- [业务 6：初始同步（Initial Sync）](./chapter_sync_flow_business6_initial.md)
- [业务 7：常态同步（Regular Sync）](./chapter_sync_flow_business7_regular.md)

**说明**

- 后续章节的写作将继续遵循同一模板：协议/机制 → Lighthouse 代码入口（v8.0.1）→ 行为边界/限流/错误处理 → 与 Prysm/Teku 对比。
