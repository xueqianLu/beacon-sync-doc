# 第 3 章: 同步模块与 P2P 的协同设计

> Nimbus 将“网络 + req/resp + pubsub + 限流/配额”集中在 `Eth2Node` 这一层封装，同步模块通过 PeerPool 获取 peer 并发起请求。

## 关键代码定位

- 网络封装（Eth2Node / Peer / quota / wire 编解码）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim
- 同步编排（worker + queue）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_manager.nim
- 缺块补齐与 ByRoot 请求聚合：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/request_manager.nim
