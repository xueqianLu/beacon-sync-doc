# 附录：同步流程图（Lighthouse）

本附录参考 Teku 的 `chapter_sync_flow_*` 组织方式，将 Lighthouse 的“同步/网络核心路径”按业务拆分为 7 组，避免单页图片过多。

> 约定：每张 PNG 的文件名来自对应 `.puml` 的 `@startuml <name>`，因此本仓库保持 `puml 文件名 == @startuml 名称 == png 文件名`。

## 目录

- [业务 1：区块（Block）](chapter_sync_flow_business1_block.md)
- [业务 2：证明（Attestation）](chapter_sync_flow_business2_attestation.md)
- [业务 3：执行层（Execution）](chapter_sync_flow_business3_execution.md)
- [业务 4：Checkpoint/Backfill](chapter_sync_flow_business4_checkpoint.md)
- [业务 5：聚合（Aggregate）](chapter_sync_flow_business5_aggregate.md)
- [业务 6：初始同步（Initial Sync）](chapter_sync_flow_business6_initial.md)
- [业务 7：常态同步（Regular Sync）](chapter_sync_flow_business7_regular.md)
