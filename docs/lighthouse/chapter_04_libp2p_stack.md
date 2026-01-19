# 第 4 章: Lighthouse libp2p 网络栈（v8.0.1）

本章聚焦 Lighthouse 的网络栈“怎么拼起来”：transport、安全、多路复用、Swarm/Behaviour 组合，以及它如何把 eth2 的核心协议（discv5、req/resp、gossipsub）纳入同一套事件循环。

---

## 4.1 network crate 入口

Lighthouse 在 `beacon_node/lighthouse_network/` crate 中封装了 rust-libp2p：

- `beacon_node/lighthouse_network/src/lib.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/lib.rs

它对外 re-export 了大量 libp2p 类型，同时暴露：

- `service`：Swarm/Behaviour 的组装与驱动
- `rpc`：Req/Resp 实现（wire protocol）
- `discovery`：discv5/ENR
- `peer_manager`：PeerDB、评分、连接管理

---

## 4.2 Behaviour 组合：把核心协议拼到同一个 Swarm

核心组装位置：

- `beacon_node/lighthouse_network/src/service/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

在这里，Lighthouse 用一个派生的 `Behaviour` 把多个子行为组合起来（顺序很关键）：

- `connection_limits`：连接硬限制（先执行，避免无意义地初始化其他行为）
- `peer_manager`：连接/评分/状态
- `eth2_rpc`：Req/Resp
- `discovery`：discv5
- `identify`：libp2p identify
- `upnp`：端口映射（可选）
- `gossipsub`：pubsub

这和多数客户端“把所有协议都塞进一个网络服务”一致，但 Lighthouse 强调“组合顺序可控”，把可能 reject 连接的行为放前面。

---

## 4.3 NetworkEvent：对上层暴露的稳定接口

同样在 `service/mod.rs`，Lighthouse 定义了 `NetworkEvent`（上层 router/sync 消费它）：

- 连接事件：PeerConnected/Disconnected
- RPC 事件：RequestReceived/ResponseReceived/RPCFailed
- Pubsub 事件：PubsubMessage
- Status 触发：StatusPeer

这使得 Beacon Node 侧（`beacon_node/network/`）无需关心 libp2p 细节，只需处理“对同步/链有意义”的事件。

---

## 4.4 Transport 与安全/多路复用（定位为主）

具体 transport 细节通常封装在 service utils 中（例如构建 TCP/QUIC、Noise、yamux 等）。

建议阅读：

- `beacon_node/lighthouse_network/src/service/utils.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/utils.rs

> 本仓库后续章节更关注“同步协议行为”，所以这里以定位为主，不展开到每一种 transport 参数。

---

## 4.5 与 Prysm / Teku 的对比提示

- 三者都基于 libp2p（或等价网络栈）完成：discovery + gossipsub + req/resp
- Lighthouse 的特点是：
  - 通过 Rust 类型系统把行为边界做得更清晰
  - 通过 `NetworkEvent` 稳定上层接口，使同步策略演进更容易

下一章会进入“协议协商”：如何在 Lighthouse 的 Req/Resp 中管理协议版本与编码。
