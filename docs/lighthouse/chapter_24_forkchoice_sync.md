# 第 24 章: Lighthouse Forkchoice Sync v8.0.1

Forkchoice Sync（本仓库语境）关注点是：网络同步与 fork choice 的交互边界。

- 新块导入如何影响 fork choice
- attestation/aggregate 如何推动 fork choice
- checkpoint/anchor 如何初始化 fork choice

换句话说：fork choice 并不“拉数据”，它消费来自网络/导入管线的输入（block 与投票），并产出 head 以及 justified/finalized 等状态。

---

## 24.0 附录导航（流程图）

- 区块输入与处理： [chapter_sync_flow_business1_block.md](chapter_sync_flow_business1_block.md)
- 证明输入（attestation）：[chapter_sync_flow_business2_attestation.md](chapter_sync_flow_business2_attestation.md)
- 聚合证明（aggregate）：[chapter_sync_flow_business5_aggregate.md](chapter_sync_flow_business5_aggregate.md)
- 状态机更新（head 变更、reorg 等）：[chapter_sync_flow_business7_regular.md](chapter_sync_flow_business7_regular.md)

---

## 24.1 Fork choice crate 入口

Lighthouse 的 fork choice 实现在 workspace 的 `consensus/fork_choice` crate：

- `consensus/fork_choice/src/lib.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/consensus/fork_choice/src/lib.rs

核心类型：

- `ForkChoice` / `ForkChoiceStore` / `ProtoArray` 相关类型

---

## 24.2 Checkpoint / Anchor：如何初始化 forkchoice

从 checkpoint state 启动时，builder 会以 anchor 构建 fork choice：

- `ForkChoice::from_anchor(...)`

定位（可看到 forkchoice 初始化与 anchor/state/block/root 的绑定）：

- `beacon_node/beacon_chain/src/builder.rs`

  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/beacon_chain/src/builder.rs

  写作建议：把 checkpoint sync（第 19 章）的“weak subjectivity state 构建”与这里的 forkchoice anchor 结合起来看，能更清晰理解：

  - 为什么 checkpoint state/block 的一致性校验很关键
  - fork choice 的起点如何影响后续 head 选择（尤其是刚启动阶段）

---

## 24.3 Gossip 证明与 forkchoice

`NetworkBeaconProcessor` 在处理 gossip attestation/aggregate 时，会尝试：

- 满足 gossip propagation criteria 时上报 `Accept`
- 并尝试 apply 到 fork choice / aggregation pool

入口：

- `process_gossip_attestation` / `process_gossip_aggregate`

  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/gossip_methods.rs

  ### 24.3.1 “验证通过”与“影响 forkchoice”不是同一件事

  从工程上看，`Accept/Ignore/Reject` 的主要作用是控制传播与归因惩罚；而 fork choice 需要的是“可被应用的投票/区块输入”。因此在阅读代码/日志时，建议区分两类问题：

  - gossip 层是否接受（传播层）
  - fork choice 是否真正消费并改变 head（状态机层）

  这也是为什么把处理逻辑集中在 `NetworkBeaconProcessor` 会更容易：同一处既能做传播回传，也能做导入与 fork choice 更新的触发。

  ***

  ## 24.4 常见问题与定位路径

  ### 24.4.1 “我收到很多 attestation，但 head 不动”

  优先分两步排查：

  1. attestation 是否被接受（看 validation/未接受占比）
  2. fork choice 是否获得可应用输入（需要结合 fork_choice crate 的日志/metrics）

  ### 24.4.2 “发生 reorg 时，网络层要注意什么？”

  reorg 本质上是 fork choice 的结果变化，但网络层往往会观察到：

  - 新 head 区块 gossip 增多
  - 旧 head 分支上的块可能被标记为无效或不再被选择

  因此在排查时，建议把“网络输入（block/attestation）是否稳定”与“fork choice 选择是否稳定”分开观察。

---

## 24.5 与 Prysm/Teku 的对比

- 三者在 fork choice 层都遵循 ProtoArray 思路（实现细节各异）。
- Lighthouse 的 fork choice 被拆成独立 crate，使其与 networking/sync 的边界更清晰：
  - networking 负责收集与验证输入
  - fork choice 负责状态机/权重/头部选择
