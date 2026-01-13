# 附录：同步相关流程图索引

本附录作为流程图导航页，按业务主线列出所有同步相关的流程图页面，避免在单个页面中一次性加载过多图片。

> 说明：
>
> - 所有 `.puml` 文件位于 `img/` 目录，由 GitHub Actions 自动渲染为 `.png` 后在 Pages 中展示。
> - 各业务的主流程图也会嵌入到对应章节中，便于在阅读正文时对照理解。

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
