# Copilot 使用说明（面向 AI 编码代理）

目标：帮助 AI 代理在此仓库中快速定位背景知识、发现关键约定并生成高质量变更。

- **项目类型**: 文档仓库 + 同步模块设计参考（基于 Prysm 实现与 Ethereum Consensus Specs）。主要为技术文档，不包含可运行的服务代码。
- **快速上下文**: 阅读 [README.md](README.md#L1) 与 [beacon_sync_outline.md](beacon_sync_outline.md#L1) 可快速把握章节结构与范围。

要点（可直接使用）

- **大局架构**: 同步模块分为 Initial Sync / Checkpoint Sync / Optimistic Sync / Regular Sync；P2P 层基于 libp2p（见 `chapter_04_libp2p_stack.md`）以及 Req/Resp（BeaconBlocksByRange/ByRoot 等，见 `chapter_09_blocks_by_range.md` 与 `chapter_10_blocks_by_root.md`）。建议将改动限制在单一同步阶段（例如仅修改 initial-sync），并在提交说明中指明影响的章节文件。

- **关键参考文件**: 优先读取 `code_references.md`（代码路径、接口与常量总结），`chapter_03_sync_module_design.md`（设计目标与组件边界），以及 `chapter_18_full_sync.md`（Full Sync 流程实现细节）。在提交 PR 时引用这些文件的具体段落以便审阅者快速定位。

- **编码与协议约定**: 使用 SSZ + Snappy 编码；网络消息受限于常量（示例：`MAX_REQUEST_BLOCKS = 1024`, `MAX_PAYLOAD_SIZE = 10485760`），见 `code_references.md` 的“重要常量”部分。任何修改消息格式或默认常量必须在文档中明确说明兼容性影响。

- **开发/预览工作流**:

  - 本地阅读/预览：`bundle install` 然后 `bundle exec jekyll serve`（见 `README.md` 的“本地预览（Jekyll）”）。
  - 文档/章节更新：修改相应 `.md` 文件（例如 `chapter_XX_*.md`），本地预览后提交 PR，描述中请列出受影响章节。

- **测试与示例代码位置**: 本仓库为文档仓库，但 `code_references.md` 列出 Prysm 中的测试文件路径（如 `sync/rpc_status_test.go`、`sync/validate_beacon_blocks_test.go`）——当生成代码补丁或示例时，参考这些路径与接口签名以保证与真实实现一致。

- **常见模式与约定**:

  - 同步循环与策略：Round-Robin 批量拉取 → 验证 → 提交到链服务（参见 `code_references.md` 中的 `round_robin.go` 与 `initial-sync/service.go` 摘要）。
  - P2P 接口抽象：`P2P` 接口负责 `Send`/`Peers`/`Encoding`（见 `code_references.md`）。修改网络相关逻辑时，请同时更新 Req/Resp 与 Gossipsub 对应章节。
  - 日志与度量：使用项目中约定的日志字段（peer、slot、blockRoot）与 metrics 名称（如 `syncBlocksPerSecond`），以便文档示例与监控定义一致。

- **PR 编写建议（对 AI 代理）**:

  - PR 标题与描述应包含：受影响章节（例如“Chapter 18: Full Sync”）、所做变更摘要、兼容性或行为差异说明、如何在本地验证（Jekyll 预览或引用 Prysm 测试）。
  - 在文档中插入代码示例时，优先使用仓库中 `code_references.md` 的类型签名与常量值作为示例基线。

- **不要做的事（保守策略）**:
  - 不要假定运行时实现细节：该仓库并不包含完整 Prysm 源码，推理改动时请引用 `code_references.md` 或外部 Prysm 链接。
  - 不要直接更改协议常量或消息格式，除非能提供兼容性说明与参考实现链接。

联系与反馈

- 如果不确定某段实现细节，请在 PR 描述中引用 `code_references.md` 的相关片段并提问。
- 完成草稿后请询问仓库维护者是否需要把更改同时反映到 GitHub Pages（见 `DEPLOY.md`）。

——
请审阅此指令草稿并指出想要补充的细节（例如需要把更多函数签名或常量值列入可参考表）。
