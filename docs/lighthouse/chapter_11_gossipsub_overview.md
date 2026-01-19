# 第 11 章: Lighthouse Gossipsub 概述 v8.0.1

Gossipsub 是 Beacon 节点“实时消息传播”的核心：区块、证明、slashings、sync committee、light client updates 等都会通过 Gossip 广播到网络。Lighthouse 将它拆成两层：

- **libp2p 网络栈层**（`beacon_node/lighthouse_network`）：负责 Swarm/Behaviour、Gossipsub 参数、Topic 管理、编码/压缩。
- **Beacon Node 网络编排层**（`beacon_node/network`）：负责将 gossip 事件路由到 `NetworkBeaconProcessor` 做验证/导入，并把验证结果回传给 gossipsub。

---

## 11.1 关键入口（从“收到一条 gossip”开始）

Lighthouse 对 gossipsub 的事件入口在网络栈 Service：

- `inject_gs_event`：收到 `gossipsub::Event::Message` 后，先 **decode** 成 `PubsubMessage`，再向上抛出 `NetworkEvent::PubsubMessage`。
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

`PubsubMessage` 的编解码（SSZ + Snappy）定义在：

- `PubsubMessage<E>` / `SnappyTransform`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

> 重要：Lighthouse 在 `inject_gs_event` decode 失败时会立刻向 gossipsub 上报 `Reject`，避免传播无法解码的数据。

### 11.1.1 代码速览：从 libp2p event 到 NetworkEvent（简化伪代码）

> 提示：以下为“结构与调用关系”的**简化伪代码**（非逐行源码拷贝）。精确实现以链接中的 v8.0.1 源码为准。

```rust
// lighthouse_network/service/mod.rs（简化示意）
fn inject_gs_event(event: GossipsubEvent) {
  match event {
    GossipsubEvent::Message { id, source, data, topic } => {
      // 1) snappy 解压 + SSZ decode
      let decoded: Result<PubsubMessage, DecodeError> = PubsubMessage::decode(&data);

      // 2) decode 失败：立刻 Reject（不进入上层 router/processor）
      if decoded.is_err() {
        gossipsub.report_message_validation_result(&id, source, Reject);
        return;
      }

      // 3) decode 成功：上抛给 beacon_node/network
      emit(NetworkEvent::PubsubMessage {
        id,
        peer_id: source,
        topic,
        message: decoded.unwrap(),
      });
    }
    _ => { /* 其他事件 */ }
  }
}
```

---

## 11.2 GossipsubConfig：验证模式、MessageId、缓存窗口

Gossipsub 参数构建函数：

- `gossipsub_config(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/config.rs

文档里建议重点解释这些点：

1. **`validate_messages()` + `ValidationMode::Anonymous`**
   - 表示“必须先验证再传播”，且验证阶段不暴露发布者身份。
2. **`message_id_fn`**
   - Lighthouse 用 `Sha256(prefix(..))` 的前 20 字节作为 `MessageId`。
   - `prefix(..)` 在 Altair+ 会把 _topic 字符串_ 也纳入哈希，减少跨 topic 的碰撞与误判重复。
3. **`duplicate_cache_time`**
   - 代码注释明确提到 Deneb/EIP-7045（允许 2 epoch 的 attestations 传播），因此将 duplicate cache window 设为 2 epochs。

---

## 11.3 Topic 与消息类型

Topic 的字符串格式、fork digest、以及“哪些 topic 需要订阅”在：

- `GossipTopic` / `GossipKind` / `core_topics_to_subscribe`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/topics.rs

消息类型（与 topic kind 一一对应）在：

- `PubsubMessage<E>` enum
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

---

## 11.4 “验证 → 传播”的闭环（网络线程 ↔ 处理器）

Lighthouse 的关键设计：gossipsub 层只做 **decode**，真正的 **共识层验证** 由 `NetworkBeaconProcessor` 完成。

链路（高层）如下：

1. `lighthouse_network` 收到 gossipsub message，decode 为 `PubsubMessage`
2. `network/router.rs` 将其分发到 `NetworkBeaconProcessor`（按消息类型）
3. `NetworkBeaconProcessor` 验证后发送 `NetworkMessage::ValidationResult`
4. `network/service.rs` 收到 ValidationResult，调用 `libp2p.report_message_validation_result(...)`
5. `lighthouse_network/service` 最终调用 `gossipsub.report_message_validation_result(...)`，决定是否传播

### 11.4.1 代码速览：ValidationResult 的闭环消息（简化伪代码）

```rust
// beacon_node/network/service.rs（简化示意）
enum NetworkMessage {
  ValidationResult {
    msg_id: MessageId,
    peer_id: PeerId,
    acceptance: MessageAcceptance, // Accept | Ignore | Reject
  },
  // ...
}

// lighthouse_network/service/mod.rs（简化示意）
fn report_message_validation_result(msg_id: MessageId, peer: PeerId, a: MessageAcceptance) {
  gossipsub.report_message_validation_result(&msg_id, peer, a);
}
```

关键源码：

- 分发 gossip 到 processor：`Router::handle_gossip`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs
- 上报验证结果：`NetworkBeaconProcessor::propagate_validation_result`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/gossip_methods.rs
- 网络线程转发验证结果：`NetworkMessage::ValidationResult` 分支
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs
- 网络栈实际调用 gossipsub：`Service::report_message_validation_result`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

---

## 11.5 与 Prysm/Teku 的对比要点

- 三者都遵循共识规范：**SSZ + Snappy**、topic 含 fork digest、以及按消息类型的验证规则。
- Lighthouse 的一个鲜明点：
  - **验证不在 libp2p service 内完成**，而是交给 `NetworkBeaconProcessor`（能复用 RPC 导入/缓存/metrics 逻辑）。

---

## 11.6 流程图（同步模块视角）

下面这张图从“已接近 head 的常态运行（Regular Sync）”视角，展示 gossip 消息如何 decode、路由到处理器、并将 Accept/Ignore/Reject 回传给 gossipsub：

![Lighthouse Regular Sync Flow](../../img/lighthouse/business7_regular_sync_flow.png)

源文件：

- ../../img/lighthouse/business7_regular_sync_flow.puml

更多同主题的分页图集（含 catch-up、missing parent、订阅管理等子流程）见：

- [附录：业务 7（Regular Sync）流程图](./chapter_sync_flow_business7_regular.md)
