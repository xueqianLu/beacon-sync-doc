# 第 14 章: Lighthouse Gossip Validation v8.0.1

Gossip Validation 的目标：在不信任的 P2P 网络里，决定一条消息应当被 **Accept/Ignore/Reject**，并将结果回传给 gossipsub，以控制传播。

---

## 14.1 验证模式：validate_messages + Anonymous

Lighthouse 的 gossipsub config 启用了“先验证再传播”：

- `validate_messages()`
- `validation_mode(gossipsub::ValidationMode::Anonymous)`

定位：

- `gossipsub_config(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/config.rs

---

## 14.2 decode 失败：立即 Reject

在 `inject_gs_event` 中，Lighthouse 首先将消息 decode 为 `PubsubMessage`：

- 失败：调用 `gossipsub.report_message_validation_result(... Reject ...)`
- 成功：抛出 `NetworkEvent::PubsubMessage` 给上层

定位：

- `inject_gs_event`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs
- `PubsubMessage::decode`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

---

## 14.3 业务验证：交给 NetworkBeaconProcessor

上层（`beacon_node/network`）会把 `PubsubMessage` 分发到 `NetworkBeaconProcessor`：

- `Router::handle_gossip`（按消息类型调用不同 send\_\*）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

例如区块：

- `send_gossip_beacon_block` → `process_gossip_block`（异步）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs

验证完成后，processor 会调用：

- `NetworkBeaconProcessor::propagate_validation_result(message_id, peer_id, MessageAcceptance::{Accept|Ignore|Reject})`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/gossip_methods.rs

---

## 14.4 回传到 gossipsub：ValidationResult

processor 通过 `NetworkMessage::ValidationResult` 把验证结果送回网络线程：

- `NetworkMessage::ValidationResult`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs

网络线程再调用 libp2p service：

- `self.libp2p.report_message_validation_result(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs

最终落到 `lighthouse_network`：

- `Service::report_message_validation_result`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

并实际调用 gossipsub 的 `report_message_validation_result`。

---

## 14.5 Accept / Ignore / Reject 的语义建议

从“传播控制”的角度，三者一般可理解为：

- `Accept`：可以传播
- `Ignore`：不传播，但通常不强惩罚（用于软失败、时序未到、暂时无法验证等）
- `Reject`：拒绝且可能导致惩罚（用于明显无效/恶意数据）

Lighthouse 也会把“未接受消息”按 client 统计到 metrics：

- `GOSSIP_UNACCEPTED_MESSAGES_PER_CLIENT`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/metrics.rs

---

## 14.6 与 Prysm/Teku 的对比

- 共同点：gossipsub 层都需要一个“异步验证”闭环。
- Lighthouse 的实现更显式地把验证结果回传做成 `NetworkMessage::ValidationResult`，结构清晰，便于加 metrics 与 peer action。

---

## 14.7 流程图

验证闭环（decode → processor 验证 → ValidationResult 回传 → gossipsub 传播决策）在 Regular Sync 图中最直观：

![Lighthouse Regular Sync Flow](../../img/lighthouse/business7_regular_sync_flow.png)

源文件：

- ../../img/lighthouse/business7_regular_sync_flow.puml

更多分页图集（含订阅管理、周期性 head 检查、missing parent 兜底等）见：

- [附录：业务 7（Regular Sync）流程图](./chapter_sync_flow_business7_regular.md)
