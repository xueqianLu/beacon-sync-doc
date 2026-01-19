# 第 3 章: Lighthouse 同步模块与 P2P 的协同设计（v8.0.1）

本章目标：明确 Lighthouse 的“同步编排”如何穿过网络栈（libp2p）与链服务（beacon_chain），以及它把哪些职责放在网络层、哪些放在同步层。

---

## 3.1 设计切面：三条主线

在 Lighthouse 的实现里，同步模块通常围绕三条主线组织：

1. **Peer 状态与选择**：谁更先进、谁更可靠、对谁发请求
2. **请求生命周期**：发请求、收响应、超时/失败、重试与降级
3. **链导入与反馈**：区块/数据导入成功与否，如何反向影响 peer 评分/同步策略

这些主线分别落在：

- `beacon_node/lighthouse_network/`：PeerManager、RPC、Discovery
- `beacon_node/network/`：Router、NetworkBeaconProcessor、Sync 管理
- `beacon_node/beacon_chain/`：区块验证与导入、fork choice

---

## 3.2 分层接口：NetworkEvent 与 Router

Lighthouse 的关键抽象是：

- 网络层对外输出 **NetworkEvent**（统一事件流）
- Beacon Node 侧由 **router** 消费这些事件，并分流给 sync/rpc/gossip 等处理器

参考：

- `NetworkEvent` 定义：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs
- router 入口：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

你可以把它理解为：

> libp2p 的 SwarmEvent →（lighthouse_network 归一化）→ NetworkEvent →（router 分发）→ 同步/链逻辑

---

## 3.3 Sync 的“网络上下文”：请求跟踪与并发边界

在同步相关代码里，一个非常核心的概念是“网络上下文/请求集合（ActiveRequests）”：

- 同一个 Req/Resp 方法会有一个活跃请求集合
- 每个集合负责：
  - 并发上限
  - 超时
  - peer 归因（把错误/坏数据归因到具体 peer）
  - 响应收集/终止（流式响应）

示例（BlocksByRoot 请求集合）：

- `beacon_node/network/src/sync/network_context.rs` 中的 `blocks_by_root_requests`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/network_context.rs

> 这类“按方法分桶的请求管理”使得同步逻辑可以明确地对不同方法设置不同的策略（例如 blocks_by_root 与 blocks_by_range 的重试逻辑不同）。

---

## 3.4 Status 在同步中的作用（只给定位，细节在第 8 章）

在 Lighthouse 中，Status 不仅用于初次握手，也用于：

- 周期性更新 peer 的链状态
- 触发“是否需要对某些 peer 重新评估”的逻辑
- 为 range sync / backfill 等选择目标 peer 提供依据

定位：

- StatusMessage 生成：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/status.rs
- router 触发发送 Status：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

---

## 3.5 与 Prysm / Teku 的对比要点

- **并发/异步模型**

  - Prysm：goroutine + channel/ctx
  - Teku：SafeFuture/AsyncRunner
  - Lighthouse：Rust async + 明确的请求集合与事件路由

- **抽象边界**
  - Lighthouse 的“network crate vs beacon_node/network”二层分离，使得：
    - libp2p 细节更集中
    - 同步策略更容易在编排层演进

下一章会具体拆开 Lighthouse 的 libp2p 网络栈（Swarm/Behaviour 组合）与关键组件。
