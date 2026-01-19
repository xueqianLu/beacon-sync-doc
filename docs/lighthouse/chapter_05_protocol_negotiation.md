# 第 5 章: Lighthouse 协议协商（v8.0.1）

本章讨论 Lighthouse 如何在 libp2p 之上进行 Eth2 协议协商：

- Req/Resp（RPC）的协议 ID 与版本
- 编码方式（SSZ + Snappy）
- 方法枚举与路由

---

## 5.1 Req/Resp 协议在 Lighthouse 的位置

Lighthouse 将 Eth2 wire 协议的 Req/Resp 部分封装在：

- `beacon_node/lighthouse_network/src/rpc/`
  - https://github.com/sigp/lighthouse/tree/v8.0.1/beacon_node/lighthouse_network/src/rpc

入口文件：

- `rpc/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/mod.rs

这里直接说明了其角色：基于 libp2p 的“purpose built Ethereum 2.0 wire protocol”，用于点对点请求链信息（主要用于同步）。

---

## 5.2 RequestType：把方法变成枚举

在 Lighthouse 的 RPC 层，核心思路是：

- 将每一种协议方法抽象成 `RequestType<E>` 的一个变体
- 统一通过 `RPCSend` / `RPCReceived` 进行发送与接收

参考：

- `rpc/mod.rs` 导出的 `RequestType`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/mod.rs
- `rpc/protocol.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/protocol.rs

这种设计的好处：

- 让“方法集合”在类型层面可枚举
- 让“不同方法的编码/限流/响应终止”可以按 protocol 维度配置

---

## 5.3 协议版本与分叉上下文（ForkContext）

以 BlocksByRoot 为例：

- 请求构造会读取 `ForkContext` / `ChainSpec` 中的上限（例如 `max_request_blocks`）
- 这意味着“同一方法的限制参数”会随 fork/网络而变

定位：

- `rpc/methods.rs`：`BlocksByRootRequest::new(..., fork_context)`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs

> 这个点在写文档时很重要：不要把某个常量写死为一个值，而应说明它来自 `ChainSpec`，并可能随 fork 改变。

---

## 5.4 编码：SSZ + Snappy（定位）

Lighthouse 的 RPC 编码实现位于 `rpc/codec`：

- `beacon_node/lighthouse_network/src/rpc/codec/`
  - https://github.com/sigp/lighthouse/tree/v8.0.1/beacon_node/lighthouse_network/src/rpc/codec

在本仓库第 7-10 章里，我们会按“消息结构/字段含义/边界条件”展开，而编码层面以引用为主：

- SSZ：用于结构化数据编码
- Snappy：用于压缩
- 流式响应：BlocksByRange/ByRoot 等方法的响应通常按 chunk 逐块发送

---

## 5.5 与 Prysm / Teku 的对比

- 三者的协议 ID 都来自共识规范，整体一致。
- Lighthouse 更偏向“强类型 + enum 驱动的协议路由”，而 Prysm/Teku 会在各自语言生态中用接口/handler 来实现类似效果。

下一章进入节点发现（discv5/ENR），这也是建立健康 peer 池的基础。
