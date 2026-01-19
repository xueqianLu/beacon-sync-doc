# 第 16 章: Lighthouse Gossipsub 性能优化 v8.0.1

本章聚焦 gossipsub 侧的性能/稳定性优化点：去重、缓存窗口、消息压缩与大小限制、以及“订阅尚未建立时的发布兜底”。

---

## 16.1 MessageId：将 topic 纳入哈希（Altair+）

Lighthouse 的 `message_id_fn` 使用 `Sha256`，并在 Altair+ 把 topic 字符串（长度+内容）拼入 prefix：

- `gossipsub_config` 内部的 `prefix(...)` 与 `message_id_fn`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/config.rs

这样做的价值：

- 降低跨 topic 的误判重复（尤其是不同 topic 可能承载结构相似/长度相近的 SSZ 数据时）。

---

## 16.2 duplicate_cache_time：扩大到 2 epochs

同一文件中明确提到 Deneb/EIP-7045 的影响（attestation 可传播到 2 epochs 旧），因此 duplicate cache window 设置为 2 epochs：

- `duplicate_cache_time = 2 * slots_per_epoch * seconds_per_slot`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/config.rs

---

## 16.3 SnappyTransform：限制压缩/解压后的最大长度

`SnappyTransform` 在入站时先检查：

- 压缩后大小 `max_compressed_len`
- 解压后的预估长度 `max_uncompressed_len`

从而降低解压炸弹风险，同时给系统内存提供硬上限。

定位：

- `SnappyTransform::inbound_transform` / `outbound_transform`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

---

## 16.4 gossip_cache：无订阅 peer 时缓存并延迟发布

当 publish 遇到 `NoPeersSubscribedToTopic`，Lighthouse 会把消息缓存起来：

- `Service::publish`（遇到 NoPeersSubscribedToTopic → `gossip_cache.insert(...)`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

当后续发生 `gossipsub::Event::Subscribed`，会尝试把缓存消息重发，并记录对应 metrics：

- `inject_gs_event` 的 `Subscribed` 分支
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

---

## 16.5 动态更新 TopicScoreParams

Lighthouse 基于 active validators 与 slot 动态更新 topic params，避免在不同网络规模下出现“评分尺度不匹配”：

- `Service::update_gossipsub_parameters`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs
- `PeerScoreSettings::get_dynamic_topic_params`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/gossipsub_scoring_parameters.rs

---

## 16.6 与 Prysm/Teku 的对比

- 三者都依赖：去重缓存 + 评分 + 限流。
- Lighthouse 的“publish 时无 peer 订阅则缓存，订阅后重试”是一个偏工程化的可靠性增强点，在节点刚启动、mesh 尚未稳定时很有用。
