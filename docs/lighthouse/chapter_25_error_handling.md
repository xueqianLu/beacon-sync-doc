# 第 25 章: Lighthouse Error Handling v8.0.1

同步与网络的错误处理主要体现在三条链路：

1. **gossip decode/validation 错误**（Reject/Ignore + metrics）
2. **RPC 请求错误**（超时、断连、错误码、限流）
3. **sync/processor 导入错误**（PeerAction 惩罚、回退/重试）

从工程结构上看，Lighthouse 把“错误的产生点”与“最终可执行动作（惩罚/断连/Goodbye）”尽量解耦：

- 产生点可能在 `lighthouse_network`（decode）、`network`（router/sync）、`NetworkBeaconProcessor`（验证/导入）。
- 最终动作通常汇聚到网络线程的 `NetworkMessage` 分支（便于统一执行与统计 metrics）。

---

## 25.0 附录导航（流程图）

- Regular Sync（gossip 验证闭环）：[chapter_sync_flow_business7_regular.md](chapter_sync_flow_business7_regular.md)
- Missing Parent（Block Lookup 兜底）：[chapter_sync_flow_business7_regular.md](chapter_sync_flow_business7_regular.md)

---

## 25.1 Gossip decode 失败：立即 Reject

`inject_gs_event` decode 失败会立刻 `Reject`：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

同时未接受消息会按 client 统计：

- `GOSSIP_UNACCEPTED_MESSAGES_PER_CLIENT`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/metrics.rs

### 25.1.1 为什么 decode 失败要“立刻 Reject”？

decode 失败意味着消息甚至无法被解析为 `PubsubMessage`：

- 继续传播没有意义（其他节点也无法可靠解析）
- 反而会放大资源消耗（带宽/CPU）

因此 Lighthouse 的策略是：**在网络栈层尽早拦截**，把成本压到最低。

---

## 25.2 RPC 错误：router → sync manager

router 把 RPC 错误发送到 sync manager：

- `Router::on_rpc_error` → `SyncMessage::RpcError`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

SyncMessage 定义：

- `SyncMessage::RpcError { peer_id, sync_request_id, error }`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/manager.rs

### 25.2.1 错误“可归因”的关键：request id + peer id

对同步而言，很多问题只看 “error string” 不够：

- 同一个 peer 可能同时承载多个 range/root 请求
- 同一个请求会分片返回多个 blocks（流式响应）

因此把 `peer_id` 和 `sync_request_id` 贯穿到错误链路中，是 Lighthouse 后续做“限流/退避/惩罚/重试”的基础。

---

## 25.3 惩罚与断连：PeerAction / Goodbye

统一惩罚入口：

- `NetworkMessage::ReportPeer` / `PeerAction`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs

peerdb 侧会把累计错误折算成 disconnect/ban：

- `peer_manager/peerdb/score.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/peer_manager/peerdb/score.rs

### 25.3.1 常见惩罚来源（读代码时的检索建议）

建议用“从动作反推原因”的方式检索代码：

- 看到 `ReportPeer`/`PeerAction`：向上追溯是谁在什么条件下上报（processor/sync/router）。
- 看到 `Goodbye`：通常意味着“协议不兼容/远端行为异常/不再信任”的强动作。

---

## 25.4 实战定位：从 metrics 反推错误类型

当你怀疑出现了“系统性错误”（不是单个 peer 问题），可以用一组指标做快速分层：

1. **decode/validation 层**：`gossipsub_unaccepted_messages_per_client`
2. **RPC 层**：`libp2p_rpc_errors_per_client`（按 client 维度观察是否集中在少数客户端/版本）
3. **导入层**：`beacon_processor_*` 相关导入成功/失败计数

指标入口见：

- network 栈 metrics：[beacon_node/lighthouse_network/src/metrics.rs](https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/metrics.rs)
- beacon node network metrics：[beacon_node/network/src/metrics.rs](https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/metrics.rs)

## 25.4 与 Prysm/Teku 的对比

- 三者都强调“错误要可观测（metrics/log）+ 可归因（peer id/request id）+ 可执行（惩罚/重试）”。
- Lighthouse 的 `NetworkMessage` 设计让“错误/惩罚”从 processor 与 sync 模块汇聚到网络线程，路径较统一。
