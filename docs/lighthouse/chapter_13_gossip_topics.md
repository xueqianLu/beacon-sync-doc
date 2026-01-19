# 第 13 章: Lighthouse Gossip Topics v8.0.1

Gossip topic 是“消息类型 + fork digest + 编码方式”的组合。它决定了：节点订阅什么、消息如何路由、以及同一条消息的去重/评分如何计算。

---

## 13.1 Topic 的字符串格式

Lighthouse 的 topic 相关常量与编码后缀在：

- `TOPIC_PREFIX = "eth2"`
- `SSZ_SNAPPY_ENCODING_POSTFIX = "ssz_snappy"`

定位：

- `beacon_node/lighthouse_network/src/types/topics.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/topics.rs

典型 topic（示意）：

- `eth2/<fork_digest>/beacon_block/ssz_snappy`
- `eth2/<fork_digest>/beacon_aggregate_and_proof/ssz_snappy`
- `eth2/<fork_digest>/beacon_attestation_<subnet>/ssz_snappy`

---

## 13.2 GossipKind：消息“种类”枚举

`GossipKind` 是 Lighthouse 内部的“topic kind”抽象，覆盖（随分叉演进）多种消息：

- BeaconBlock
- Attestation(subnet)
- BeaconAggregateAndProof
- VoluntaryExit / Slashings
- SyncCommitteeMessage / SignedContributionAndProof
- Deneb 相关：BlobSidecar
- Fulu/PeerDAS 相关：DataColumnSidecar
- Light client updates

定位：

- `GossipKind` enum
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/topics.rs

---

## 13.3 core_topics_to_subscribe：按 fork 选择订阅集合

Lighthouse 会根据当前 fork（以及配置）选择“核心订阅 topic 集合”。

定位：

- `core_topics_to_subscribe(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/topics.rs

此外，Beacon Node 网络线程在“认为自己已 sync 或接近 head”时才触发订阅核心 topics：

- `NetworkMessage::SubscribeCoreTopics`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs

这与 `SLOT_IMPORT_TOLERANCE`（见同步章节）共同形成“同步完成/接近完成才参与完整 gossip”的策略。

---

## 13.4 PubsubMessage 与 Topic 的对应关系

`PubsubMessage` 会通过 `kind()` 与 `topics()` 映射到 `GossipKind` / `GossipTopic`：

- `PubsubMessage::kind`
- `PubsubMessage::topics`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

> 这层抽象的好处：上层只处理“业务消息类型”，底层统一决定 topic 的 fork digest 与编码。

---

## 13.5 与 Prysm/Teku 的对比

- topic 维度三者一致：fork digest + topic name + ssz_snappy。
- Lighthouse 的实现更强调“同一套类型系统（GossipKind/PubsubMessage）贯穿 publish/subscribe/decode/route”。
