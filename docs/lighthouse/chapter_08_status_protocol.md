# 第 8 章: Lighthouse Status 协议（v8.0.1）

Status 是 Eth2 节点建立会话时最关键的握手协议：

- 校验对方是否处于同一网络/分叉（fork digest）
- 交换 head 与 finality，用于判断是否需要同步
- 在 Lighthouse 中，Status 的结果会直接影响 peer 是否被 sync 层接纳

---

## 8.1 协议标识与消息类型

协议 ID（共识规范）：

- `/eth2/beacon_chain/req/status/1/ssz_snappy`

Lighthouse 的消息类型：

- `StatusMessage`（存在版本变体，V1/V2）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs

在 v8.0.1 中你会看到：

- 基础字段：`fork_digest`、`finalized_root`、`finalized_epoch`、`head_root`、`head_slot`
- V2 扩展：`earliest_available_slot`（用于描述节点“可提供数据的最早 slot”）

> 文档写作时建议把 V2 的字段解释清楚：它影响对方是否会向你请求历史数据。

---

## 8.2 Lighthouse 如何生成本地 Status

Beacon Node 侧提供 `ToStatusMessage` trait：

- `beacon_node/network/src/status.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/status.rs

它把 `BeaconChain` 的当前状态转换成一个 `StatusMessage`，供 router/sync 发给 peer。

---

## 8.3 收到 Status 后的处理：相关性判断（relevance）

Lighthouse 的处理主线在 `NetworkBeaconProcessor::process_status`：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/rpc_methods.rs

其中的关键逻辑是：

1. `check_peer_relevance(remote_status)`：判断 peer 是否“值得连接/值得同步”
2. 不相关则发送 Goodbye（例如不同 fork/network）
3. 相关则构造 `SyncInfo`，通过 `SyncMessage::AddPeer` 交给 sync 层

从源码可见的典型拒绝理由包括：

- `fork_digest` 不一致（不同网络/分叉）
- 对方 head_slot 明显超前本地当前 slot（疑似系统时钟/创世时间不一致）
- 对方 finality 太旧且无法在本地数据库范围内验证

> 这个“relevance gate”是 Lighthouse 的一个显著风格：把 peer 过滤前置，减少无意义的同步尝试。

---

## 8.4 router 侧的发送与响应路径（定位）

router 负责把网络事件分发，同时也会主动触发对某些 peer 发送 Status：

- `beacon_node/network/src/router.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

你可以从 router 里找到：

- 发送 Status（例如 `send_status(...)`）
- 收到 Status request/response 的分支处理（把消息交给 processor 进一步处理）

---

## 8.5 与 Prysm / Teku 的对比

- 三者都用 Status 进行握手与状态交换（协议一致）。
- Lighthouse 的差异点主要在“握手结果如何影响同步”：
  - 通过 `check_peer_relevance` 进行更强的早期过滤
  - 将状态转换为统一的 `SyncInfo`，交给 sync 管理器进行后续策略选择

下一章进入 BlocksByRange：这是同步阶段最常用的批量拉取协议。
