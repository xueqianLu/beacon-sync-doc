# 第 15 章: Lighthouse Peer Scoring v8.0.1

Peer Scoring 的目标：在不可靠的网络里，给每个 peer 一个可量化的信誉值，用于：

- 控制 gossip 的 mesh graft/prune
- 决定是否 graylist / disconnect / ban
- 将“协议错误/无效数据/慢响应”折算成可执行的惩罚

Lighthouse 的评分体系包含两层：

1. **Gossipsub Peer Score**（libp2p gossipsub 内建）
2. **PeerDB / Lighthouse Score**（peer_manager 自己维护的 [-100, 100] 信誉分）

---

## 15.1 Gossipsub 评分参数与阈值

评分阈值（gossip/publish/graylist 等）定义在：

- `lighthouse_gossip_thresholds()` / `GREYLIST_THRESHOLD`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/gossipsub_scoring_parameters.rs

动态评分参数生成逻辑：

- `PeerScoreSettings::get_peer_score_params(...)`
- `PeerScoreSettings::get_dynamic_topic_params(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/gossipsub_scoring_parameters.rs

Lighthouse 会基于 active validators 与当前 slot 进行动态更新：

- `Service::update_gossipsub_parameters(...)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

> 从代码可见：当前显式纳入 topic score map 的主要是 BeaconBlock、AggregateAndProof、Attestation 子网，以及 exit/slashings 等“经典 topic”。

---

## 15.2 PeerDB：将 gossipsub 分数映射到断连/封禁策略

PeerDB 的评分实现：

- `peer_manager/peerdb/score.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/peer_manager/peerdb/score.rs

其中一个关键点：

- Lighthouse 会把 **负向 gossipsub 分数**做权重缩放，避免“仅凭 gossipsub 分数”就把 peer 断开（注释中明确提到解决 disconnected peer 的 non-decaying gossipsub score 问题）。

---

## 15.3 统一的惩罚入口：ReportPeer / PeerAction

Beacon processor 与 sync 等模块对 peer 的惩罚会以 `PeerAction` 的形式上报：

- `NetworkMessage::ReportPeer { peer_id, action, source, msg }`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/service.rs

processor 侧的一个典型入口：

- `gossip_penalize_peer`（source=Gossipsub）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/gossip_methods.rs

---

## 15.4 与 Prysm/Teku 的对比

- 三者都有“gossipsub 分数 + 自定义 peer 信誉/惩罚”的组合。
- Lighthouse 在 peerdb 里明确做了 **gossipsub negative score 权重缩放**，这是一个易被忽略但很实用的工程化细节。
