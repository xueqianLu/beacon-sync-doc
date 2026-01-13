# 附录：同步相关流程图索引

本附录作为 Teku 流程图导航页，按业务主线列出所有同步相关的流程图页面，避免在单个页面中一次性加载过多图片。

> 说明：
>
> - 所有 `.puml` 文件位于 `img/teku/` 目录，由 GitHub Actions 自动渲染为 `.png` 后在 Pages 中展示。
> - 各业务的主流程图也会嵌入到对应章节中，便于在阅读正文时对照理解。
> - Teku 采用 Java/SafeFuture 异步模型，与 Prysm 的 Go/Channel 模型有所不同。

---

## 业务主线索引

- 业务 1：区块生成 → 广播 → 接收 → 验证与处理  
  👉 [附录：业务 1 – 区块生成与处理（Block Pipeline）](./chapter_sync_flow_business1_block.md)

- 业务 2：Attestation 生成 → 广播 → 接收 → 处理  
  👉 [附录：业务 2 – Attestation 生成与处理](./chapter_sync_flow_business2_attestation.md)

- 业务 3：执行层交易提交 → 打包（含 MEV / PBS）→ 执行  
  👉 [附录：业务 3 – 执行层交易 → 打包 → 执行](./chapter_sync_flow_business3_execution.md)

- 业务 4：Checkpoint Sync + Backfill  
  👉 [附录：业务 4 – Checkpoint Sync 与 Backfill](./chapter_sync_flow_business4_checkpoint.md)

- 业务 5：Aggregate & Proof 聚合流程  
  👉 [附录：业务 5 – Aggregate & Proof 聚合投票](./chapter_sync_flow_business5_aggregate.md)

- 业务 6：Initial Sync 启动与模式选择  
  👉 [附录：业务 6 – Initial Sync 启动与模式选择](./chapter_sync_flow_business6_initial.md)

- 业务 7：Regular Sync 日常同步  
  👉 [附录：业务 7 – Regular Sync 日常同步](./chapter_sync_flow_business7_regular.md)

---

## Teku 特有架构说明

### 异步模型差异

| 维度 | Prysm (Go) | Teku (Java) |
|------|------------|-------------|
| 异步原语 | Goroutines + Channels | SafeFuture + CompletableFuture |
| 并发控制 | WaitGroup + Context | Semaphore + ExecutorService |
| 事件传播 | Channel | EventBus |
| 错误处理 | error 返回值 | exceptionally / exceptionallyCompose |

### 流程图约定

- 🔷 **蓝色框**：Teku 核心服务组件
- 🟢 **绿色框**：异步操作（SafeFuture）
- 🟡 **黄色框**：外部依赖（P2P/EL/DB）
- 🔴 **红色框**：错误处理分支

---

## 相关章节

- [第 3 章：Teku 同步模块设计](./chapter_03_sync_module_design.md)
- [第 12 章：BeaconBlockTopicHandler](./chapter_12_block_topic_handler.md)
- [第 18 章：Full Sync 实现](./chapter_18_full_sync.md)
- [第 21 章：Regular Sync 概述](./chapter_21_regular_sync.md)
- [第 22 章：Block Processing Pipeline](./chapter_22_block_pipeline.md)

---

**最后更新**: 2026-01-13  
**参考**: Prysm 流程图保持一致的业务逻辑，但体现 Teku 实现特点
