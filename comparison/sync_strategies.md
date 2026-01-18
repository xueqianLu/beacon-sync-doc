# 同步策略对比（Prysm vs Teku）

本节尽量从“代码入口/关键类/关键配置”的角度对齐两端实现，避免只停留在概念层。

## 总览

| 维度         | Prysm                                                                                                     | Teku                                                                                             |
| ------------ | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| 核心同步拆分 | Initial Sync / Checkpoint Sync / Optimistic Sync / Regular Sync（模块化在 `prysm/beacon-chain/sync/` 下） | Forward Sync（头部前进）+ Historical/Backfill（历史回填）+ 状态引导/弱主观性（拆分在多个模块包） |
| 并发模型     | Goroutine + channel（偏 CSP）                                                                             | `SafeFuture`/`CompletableFuture` + `AsyncRunner`（事件驱动）                                     |
| 主动拉取     | Req/Resp：BlocksByRange/BlocksByRoot                                                                      | Req/Resp：BlocksByRange/BlocksByRoot（Forward/Historical 都会用）                                |
| 被动接收     | Gossip：订阅新区块与验证                                                                                  | Gossip：订阅新区块并异步导入                                                                     |
| 关键目标     | 快速追头 + 稳定验证/提交 + 缺失父块修复 + 限流/度量                                                       | 异步流水线化导入 + 多 peer 批量拉取 + 在安全约束下快速建立锚点                                   |

Prysm 的代码入口/路径摘要可参考：[docs/prysm/code_references.md](../docs/prysm/code_references.md)。

## 初始同步（Initial Sync / Forward Sync）

### Prysm

- **策略形态**：轮询（Round-robin）从多个 peer 批量拉取区块，循环“拉取 → 验证 → 处理 → 推进 slot”。
- **关键实现入口**：
  - `prysm/beacon-chain/sync/initial-sync/service.go`
  - `prysm/beacon-chain/sync/initial-sync/round_robin.go`
  - `prysm/beacon-chain/sync/initial-sync/blocks_fetcher.go`
- **批量与上限**：请求级别会受协议/常量约束（如 `MAX_REQUEST_BLOCKS = 1024`、`MAX_PAYLOAD_SIZE = 10MiB`），不要假定固定“64 blocks”。常量汇总见 [docs/prysm/code_references.md](../docs/prysm/code_references.md)。
- **并发点**：典型是“多 peer 并行拉取 + 统一处理/提交”的结构（由 goroutine 调度完成）。

### Teku

- **策略形态**：Forward Sync 以事件驱动方式推进头部同步，常见实现是把“获取/验证/导入”拆为异步链路，并支持多 peer 批次拉取。
- **关键实现入口（Forward + 多 peer 批导入）**：
  - Forward Sync 包：`beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/forward/`
  - 多 peer 批导入：
    - `BatchImporter`（保证脱离 event thread，在 worker 线程导入）
      - https://github.com/consensys/teku/blob/main/beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/forward/multipeer/BatchImporter.java
- **批量与并发**：批次的数据会被复制后在 worker 线程导入（避免跨线程访问 batch 数据），并且支持 blob sidecars 与 blocks 的顺序导入（见同文件注释与实现）。

## Regular Sync（Gossip 驱动的头部跟随）

### Prysm

- **触发机制**：通过 gossipsub 订阅块主题，收到新区块后进行解码与校验。
- **缺失父块**：缺失父块时不会直接丢弃，倾向进入 pending/缺失父块修复路径，再通过 Req/Resp 回补。
- **关键实现入口**：
  - `prysm/beacon-chain/sync/subscriber_beacon_blocks.go`
  - `prysm/beacon-chain/sync/validate_beacon_blocks.go`
  - `prysm/beacon-chain/sync/pending_blocks_queue.go`

### Teku

- **触发机制**：同样以 gossip 到达作为事件源，但导入通常是异步执行，并把“接收/验证/导入/记录性能”拆成链路。
- **队列/缓冲**：BlockManager 在导入流程中对 UNKNOWN_PARENT 等失败原因会进入 pending pool，并在父块导入后触发重试。
- **关键实现入口（Block 导入与 UNKNOWN_PARENT 分支）**：
  - `BlockManager`：https://github.com/consensys/teku/blob/main/ethereum/statetransition/src/main/java/tech/pegasys/teku/statetransition/block/BlockManager.java

## Historical / Backfill（历史回填）

### Prysm

- **定位**：初始/检查点后对历史区块的补全，独立为 backfill 子模块。
- **关键实现入口**：`prysm/beacon-chain/sync/backfill/`（见 [docs/prysm/code_references.md](../docs/prysm/code_references.md)）。

### Teku

- **定位**：Historical 同步负责拉取并持久化已最终确定（finalized）的历史数据，可与头部 forward 同时/交错进行。
- **关键实现入口（批量校验与写入 finalized blocks）**：
  - `HistoricalBatchFetcher`：https://github.com/consensys/teku/blob/main/beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/historical/HistoricalBatchFetcher.java
  - 其中 `importBatch()` 会先做批量签名校验与 sidecar 校验，再调用 `storageUpdateChannel.onFinalizedBlocks(...)` 一次性写入。

## Checkpoint Sync / 弱主观性（Weak Subjectivity）

### Prysm

- **启动与锚点**：支持从 checkpoint 引导启动，并在后台进行回填。
- **关键实现入口**：`prysm/beacon-chain/sync/checkpoint/`（路径见 [docs/prysm/code_references.md](../docs/prysm/code_references.md)）。
- **协议/安全约束**：弱主观性周期、请求范围等常量在 [docs/prysm/code_references.md](../docs/prysm/code_references.md) 有汇总（例如 `MIN_EPOCHS_FOR_BLOCK_REQUESTS`）。

### Teku

- **锚点加载与校验**：通过 “initial-state / checkpoint-sync-url / ws-checkpoint” 等配置建立启动锚点，并在初始化阶段校验 fork 与弱主观性周期。
- **关键实现入口（弱主观性）**：
  - `WeakSubjectivityInitializer`：https://github.com/consensys/teku/blob/main/services/beaconchain/src/main/java/tech/pegasys/teku/services/beaconchain/WeakSubjectivityInitializer.java
  - `WeakSubjectivityValidator`：https://github.com/consensys/teku/blob/main/ethereum/weaksubjectivity/src/main/java/tech/pegasys/teku/weaksubjectivity/WeakSubjectivityValidator.java
  - CLI 选项 `--ws-checkpoint`：https://github.com/consensys/teku/blob/main/teku/src/main/java/tech/pegasys/teku/cli/options/WeakSubjectivityOptions.java
- **存储落地**：弱主观性 checkpoint 会持久化到数据库并在启动时与 CLI 参数合并/仲裁（见 `WeakSubjectivityInitializer.finalizeAndStoreConfig(...)` 相关逻辑）。

## Optimistic Sync / 执行层（Execution Layer）交互

### Prysm

- **定位**：在执行层验证未完成时允许 optimistic 的头部推进，同时对“payload 验证/回退/缺失父块修复”等路径做一致性处理。
- **文档入口**：可以对照本仓库 Prysm 章节的 optimistic/regular/block pipeline（如 [docs/prysm/chapter_20_optimistic_sync.md](../docs/prysm/chapter_20_optimistic_sync.md)、[docs/prysm/chapter_22_block_pipeline.md](../docs/prysm/chapter_22_block_pipeline.md)）。

### Teku

- **定位**：通过 `engine_newPayload*`、`engine_forkchoiceUpdated*`、`engine_getPayload*` 等接口与执行层交互；同步/导入过程会在需要时触发 payload 验证。
- **关键实现入口（Engine API 调度与版本分派）**：
  - `ExecutionClientHandlerImpl.engineNewPayload(...)`：https://github.com/consensys/teku/blob/main/ethereum/executionlayer/src/main/java/tech/pegasys/teku/ethereum/executionlayer/ExecutionClientHandlerImpl.java
  - `MilestoneBasedEngineJsonRpcMethodsResolver`：https://github.com/consensys/teku/blob/main/ethereum/executionlayer/src/main/java/tech/pegasys/teku/ethereum/executionlayer/MilestoneBasedEngineJsonRpcMethodsResolver.java
  - Forkchoice payload 执行器：
    - https://github.com/consensys/teku/blob/main/ethereum/statetransition/src/main/java/tech/pegasys/teku/statetransition/forkchoice/ForkChoicePayloadExecutor.java

## 可操作的结论（面向实现/调参）

- Prysm 更偏“同步模块集中在 `sync/` 内统一编排”，从入口（`service.go` / `initial-sync/service.go`）往下看即可还原完整链路。
- Teku 更偏“职责分散但异步链路清晰”：Forward/Historical/WS/EL 分别在各自模块中实现，串联点通常在 Controller/Service 层。
- 两者都把性能关键点放在“批量验证/批量写入/并行拉取”，差异主要是并发模型与模块边界，而非协议本身。

---

**最后更新**: 2026-01-18
