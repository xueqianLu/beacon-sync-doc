# Nimbus (v25.12.0) 代码参考索引

> 目标：为本仓库 Nimbus 文档提供“可点击、可复用、可核对”的源码入口清单。所有链接固定到 `v25.12.0` tag，避免上游变更导致引用漂移。

---

## 1. 仓库结构（高层）

- `beacon_chain/`：Beacon Node 及其网络、同步、gossip、forkchoice 等核心实现
- `tests/`：网络/同步/gossip 等相关测试

---

## 2. Beacon Node 启动与组装

- Beacon Node 入口与组件组装：`beacon_chain/beacon_node.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/beacon_node.nim

---

## 3. P2P / libp2p 网络层（含 pubsub / req-resp）

### 3.1 网络主封装（Eth2Node / Peer / quota / 编解码）

- `beacon_chain/networking/eth2_network.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim

### 3.2 协议 DSL（Req/Resp 声明与代码生成宏）

- `beacon_chain/networking/eth2_protocol_dsl.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_protocol_dsl.nim

### 3.3 PeerPool / PeerScore

- `beacon_chain/networking/peer_pool.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_pool.nim
- `beacon_chain/networking/peer_scores.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_scores.nim

---

## 4. Req/Resp：Status / BlocksByRange / BlocksByRoot

### 4.1 Status（握手与对等节点一致性检查）

- `beacon_chain/networking/peer_protocol.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_protocol.nim

### 4.2 BeaconBlocksByRange / BeaconBlocksByRoot（服务端处理）

- `beacon_chain/sync/sync_protocol.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_protocol.nim

### 4.3 同步编排（Range / Queue / Worker）

- `beacon_chain/sync/sync_manager.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_manager.nim
- `beacon_chain/sync/sync_queue.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_queue.nim

### 4.4 缺块补齐 / ByRoot 请求聚合（更偏“常态补齐”）

- `beacon_chain/sync/request_manager.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/request_manager.nim

---

## 5. Gossip：订阅、Topic、验证与处理

### 5.1 GossipSub / Gossipsub 配置与消息编解码

- `beacon_chain/networking/eth2_network.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim

### 5.2 Gossip Validation（入站消息校验）

- `beacon_chain/gossip_processing/gossip_validation.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/gossip_validation.nim

### 5.3 Block Processor / Eth2 Processor（从网络到链服务的处理器）

- `beacon_chain/gossip_processing/block_processor.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/block_processor.nim
- `beacon_chain/gossip_processing/eth2_processor.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/eth2_processor.nim

---

## 6. 协议常量与限流（文档引用优先）

- 协议常量（含 `MAX_REQUEST_BLOCKS = 1024`、`RESP_TIMEOUT = 10`、`MAX_PAYLOAD_SIZE = 10485760`）：

  - `beacon_chain/spec/datatypes/constants.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/spec/datatypes/constants.nim

- `RESP_TIMEOUT` 的 Duration 包装：
  - `beacon_chain/spec/network.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/spec/network.nim

---

## 7. 测试（推荐阅读入口）

- Sync Manager：`tests/test_sync_manager.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/test_sync_manager.nim
- Gossip Validation：`tests/test_gossip_validation.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/test_gossip_validation.nim
- Networking fixtures：`tests/consensus_spec/test_fixture_networking.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/consensus_spec/test_fixture_networking.nim
- Metadata：`tests/test_network_metadata.nim`
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/test_network_metadata.nim
