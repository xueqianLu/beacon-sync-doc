# 第 22 章: Lighthouse Block Pipeline v8.0.1

本章把“区块从网络进入本地链”的 pipeline 串起来（同时涵盖 gossip 与 rpc 两条路径）。

---

## 22.0 流程图

下面这张图把 gossip 路径与“验证回传传播决策”放在一个视角里，便于对照 22.1 的步骤列表：

![Lighthouse Regular Sync Flow](../../img/lighthouse/business7_regular_sync_flow.png)

源文件：

- ../../img/lighthouse/business7_regular_sync_flow.puml

配套的分页图集（区块主线的生成/广播/接收/处理拆图，以及 regular sync 的子流程拆图）见：

- [附录：业务 1（Block）流程图](./chapter_sync_flow_business1_block.md)
- [附录：业务 7（Regular Sync）流程图](./chapter_sync_flow_business7_regular.md)

---

## 22.1 Gossip 路径：PubsubMessage::BeaconBlock

1. libp2p service 收到 gossipsub message，decode 成 `PubsubMessage`
   - `inject_gs_event`
   - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs
2. network/router 分发到 processor
   - `Router::handle_gossip` / `PubsubMessage::BeaconBlock`
   - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs
3. `NetworkBeaconProcessor` 投递异步工作并处理
   - `send_gossip_beacon_block` / `process_gossip_block`
   - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs
4. processor 上报验证结果，决定是否传播
   - `propagate_validation_result`
   - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/gossip_methods.rs
5. network/service 转发到 libp2p，最终调用 gossipsub 的 `report_message_validation_result`
   - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs
   - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

---

## 22.2 RPC 路径：BlocksByRange / BlocksByRoot

1. libp2p service 收到 RPC response
2. router 根据 request 类型调用回调
   - `on_blocks_by_range_response` / `on_blocks_by_root_response`
   - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs
3. router 将响应片段包装为 `SyncMessage::{RpcBlock,...}` 发送给 sync manager
4. sync manager（range sync / lookup）决定是否请求更多、如何组 batch、以及何时提交给 processor

sync manager 入口：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/manager.rs

请求生命周期与请求表：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/network_context.rs

---

## 22.3 统一的“处理器”抽象：NetworkBeaconProcessor

无论是 gossip 还是 rpc，最终都倾向进入 `NetworkBeaconProcessor`，再投递到 `beacon_processor` 线程池。

入口：

- `beacon_node/network/src/network_beacon_processor/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs

它携带：

- `duplicate_cache`（去重）
- `invalid_block_storage`（可选落盘无效块 SSZ）
- metrics / peer action 上报通道

---

## 22.4 与 Prysm/Teku 的对比

- pipeline 的总体结构相似：decode → validate → import → report。
- Lighthouse 把“传播验证回传”做成 `NetworkMessage::ValidationResult`，并与 processor 的工作队列强绑定，结构上更模块化。
