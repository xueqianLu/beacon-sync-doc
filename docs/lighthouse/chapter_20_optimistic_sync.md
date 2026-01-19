# 第 20 章: Lighthouse Optimistic Sync v8.0.1

本仓库的章节编号将“Optimistic Sync”单独展开。对 Lighthouse 而言，最贴近该主题的实现点在 **Range Sync 的 optimistic start**：

- 在长距离同步时，允许优先处理一个“更靠近 head”的 batch，使节点更快获得可用 head（同时继续在后台补齐更早的 batches）。

> 说明：这里的 “optimistic” 指 **range sync 的批次处理顺序优化**（`optimistic_start`），不是“execution payload 的乐观验证/乐观头（optimistic head）”那类语义。后者通常出现在执行层可用性/验证链路中，本仓库在流程图附录里另行单独展示。

---

## 20.0 附录导航（流程图）

- 初始同步（含 range sync 主线）：[chapter_sync_flow_business6_initial.md](chapter_sync_flow_business6_initial.md)
- 常态同步（含 catch-up 与 missing parent 兜底）：[chapter_sync_flow_business7_regular.md](chapter_sync_flow_business7_regular.md)

---

## 20.1 optimistic_start：SyncingChain 内的可选目标

`SyncingChain` 包含：

- `optimistic_start: Option<BatchId>`
- `attempted_optimistic_starts: HashSet<BatchId>`（避免反复尝试相同 optimistic 点）

定位：

- `beacon_node/network/src/sync/range_sync/chain.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/range_sync/chain.rs

---

## 20.2 状态机视角：optimistic_start 如何“推进/失败/退避”

把 `SyncingChain` 当作一个小状态机来读，会更容易理解 optimistic start 的行为边界：

1. **候选选择**：从当前 batches 中选出一个候选 `BatchId` 作为 `optimistic_start`（更靠近 head、更可能快速产出“可用 head”）。
2. **优先处理**：当 `optimistic_start` 存在时，处理逻辑会倾向先处理这个 batch，而不是严格按“从旧到新”的 processing target。
3. **失败退避**：一旦候选失败，会走“drop”路径并把该 `BatchId` 记录到 `attempted_optimistic_starts`，避免重复尝试。
4. **回到主线**：如果没有合适候选或候选失败，继续按原有 processing target 推进。

这种设计的核心点不是“放弃正确性”，而是把“更快产出可服务 head”的目标显式纳入同步调度策略，并且为失败提供可控的退避机制。

---

## 20.3 与 batch 重试/惩罚的关系

在 range sync 里，“下载失败”与“处理失败”往往对应不同的处置：

- **下载失败**：更像网络问题（peer 不稳定、超时、断连、限流），通常走请求重试/换 peer。
- **处理失败**：更像数据问题（无效链段、错误响应、父子不连续等），通常更倾向触发 peer 归因与惩罚。

optimistic start 会让某些 batch 被更早处理，因此也会让“处理失败”更早暴露，这对缩短故障定位时间是正收益。

---

## 20.4 观测与定位建议

读日志时，可以从 `chain.rs` 中提到的典型分支/日志字符串入手，例如：

- `Processing optimistic start`
- `Dropping optimistic candidate`
- `request_batches_optimistic`

如果观察到某个 optimistic candidate 反复被丢弃（但又不断出现新的候选），通常意味着：

- peers 对 head/链段的一致性不足（peer pool 质量问题）
- 或者本地对 chain segment 的预期与网络响应不匹配（请求生命周期/响应路由问题）

## 20.2 优先处理 optimistic batch

RangeSync 的处理逻辑里有明确注释：

- “优先处理 optimistic batches，再处理 processing target”

可通过以下关键日志/分支定位该行为：

- `Processing optimistic start`
- `Dropping optimistic candidate`
- `request_batches_optimistic`

定位（同一文件内多处出现 `optimistic_start` 相关逻辑）：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/range_sync/chain.rs

---

## 20.3 价值与风险边界（写作建议）

建议在文档中解释：

- 价值：更快接近 head，缩短“不能服务/不能参与完整 gossip”的窗口。
- 风险：如果 optimistic batch 失败，需要回退候选点（代码里通过 `attempted_optimistic_starts` 与 reject 路径控制）。

---

## 20.4 与 Prysm/Teku 的对比

- 三者都会在初始同步阶段引入“尽快接近 head”的优化策略。
- Lighthouse 把它做成 `SyncingChain` 的显式字段，读代码时更容易定位其状态机与失败兜底。
