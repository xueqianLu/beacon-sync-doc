# 第 12 章: Lighthouse 区块广播（BeaconBlock Gossip）v8.0.1

本章聚焦 gossip 中最关键的 topic：`BeaconBlock`。它支撑“近实时跟头”与“快速传播新 head”。

---

## 12.1 消息类型与编码

BeaconBlock gossip 消息在 Lighthouse 被抽象为：

- `PubsubMessage::BeaconBlock(Arc<SignedBeaconBlock<E>>)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

编码/压缩约定：

- SSZ：`as_ssz_bytes()`
- Snappy：由 `SnappyTransform` 统一处理入站解压/出站压缩
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

---

## 12.2 接收链路：从 gossipsub 到 beacon processor

### 12.2.1 gossipsub 收到消息

`lighthouse_network` 在 `inject_gs_event` 解码成功后会抛出 `NetworkEvent::PubsubMessage`：

- `inject_gs_event` + `PubsubMessage::decode`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

### 12.2.2 router 分发 BeaconBlock

Beacon Node 网络路由在 `Router::handle_gossip` 按消息类型调用 processor：

- `PubsubMessage::BeaconBlock(block) => send_gossip_beacon_block(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

### 12.2.3 processor 异步处理

`NetworkBeaconProcessor::send_gossip_beacon_block` 会投递一个 `Work::GossipBlock` 给 `beacon_processor` 线程池：

- `send_gossip_beacon_block` / `process_gossip_block`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs

> Lighthouse 的“区块广播处理”本质上就是：**验证（gossip rule + 共识规则）→ 决定 Accept/Ignore/Reject → 可能导入 fork choice → metrics/惩罚/回传结果**。

---

## 12.3 验证结果如何影响传播

处理器侧通过 `propagate_validation_result` 回传：

- `NetworkBeaconProcessor::propagate_validation_result`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/gossip_methods.rs

网络线程收到 `NetworkMessage::ValidationResult` 后会调用：

- `self.libp2p.report_message_validation_result(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs

最终落到 libp2p service：

- `Service::report_message_validation_result`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

---

## 12.4 发送链路：publish BeaconBlock

Beacon Node 想要广播时，会向网络线程发送 `NetworkMessage::Publish { messages }`：

- `NetworkMessage::Publish`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs

网络线程会调用 libp2p service 的 `publish`，由 `PubsubMessage::topics(...)` 选择具体 topic（包含 fork digest）：

- `Service::publish` / `PubsubMessage::topics`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

---

## 12.5 与 Prysm/Teku 的对比

- 三者都会将 BeaconBlock gossip 视为“快速 head 跟踪路径”，但都会用 Req/Resp（BlocksByRange/Root）做兜底补齐。
- Lighthouse 的特点是把 gossip 验证与导入统一塞进 `NetworkBeaconProcessor`，使得：
  - gossip 与 rpc 的导入路径更容易共享 metrics/缓存/惩罚逻辑。

---

## 12.6 附录：流程图索引

- 区块主线（生成/广播/接收/处理）：[附录：业务 1（Block）流程图](./chapter_sync_flow_business1_block.md)
- 常态同步主线（含验证闭环）：[附录：业务 7（Regular Sync）流程图](./chapter_sync_flow_business7_regular.md)
