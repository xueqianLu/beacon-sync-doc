# 第 7 章: Lighthouse Req/Resp（RPC）协议基础（v8.0.1）

本章介绍 Lighthouse 如何实现 Eth2 的 Req/Resp（wire）协议：

- 方法枚举与事件模型（RequestType / RPCSend / RPCReceived）
- 请求/响应的生命周期（含流式响应的终止）
- 编码与限流（SSZ+Snappy、并发与速率限制）

---

## 7.1 Lighthouse 的 RPC 模块位置

Lighthouse 将 Req/Resp 封装为一个 libp2p `NetworkBehaviour`：

- `beacon_node/lighthouse_network/src/rpc/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/mod.rs

该模块是 Eth2 wire protocol 的实现入口，围绕“点对点链数据交换（主要用于同步）”。

---

## 7.2 方法建模：RequestType

Lighthouse 用 `RequestType<E>`（与 `EthSpec` 绑定）表示“某一种 RPC 方法 + 该方法的请求体”。

从 `rpc/mod.rs` 可以看到它对外 re-export：

- `RequestType`
- 常见请求结构：`StatusMessage`、`BlocksByRangeRequest`、`BlocksByRootRequest` 等

方法与消息类型的集中定义在：

- `beacon_node/lighthouse_network/src/rpc/methods.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs

这种“枚举驱动”的方式让上层（router/sync）无需知道 substream 细节，只需要关心：

- 发送哪个 `RequestType`
- 收到哪个响应类型

---

## 7.3 事件模型：RPCSend / RPCReceived

在 Lighthouse 的 rpc 模块中，发送/接收分别以 enum 表达：

- `RPCSend`：

  - `Request(Id, RequestType)`：主动发起请求
  - `Response(SubstreamId, RpcResponse)`：对 inbound request 进行响应（注意：一个响应可能分多次发送）
  - `Shutdown(Id, GoodbyeReason)`：断连

- `RPCReceived`：
  - `Request(InboundRequestId, RequestType)`：收到对方请求
  - `Response(Id, RpcSuccessResponse)`：收到对方对“我们发起的请求”的响应分片
  - `EndOfStream(Id, ResponseTermination)`：流式响应结束

这些类型都在：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/mod.rs

关键点：

- Lighthouse 显式把“流式响应结束”做成了一个事件（EndOfStream），这对 BlocksByRange/ByRoot 这类方法非常重要。

---

## 7.4 InboundRequestId：对入站请求的定位

对方发来的请求，RPC 层会用 `InboundRequestId`（connection_id + substream_id）唯一标识。

- 上层在发送响应时必须带回这个 id
- RPC 层会在必要时把入站请求保留在 `active_inbound_requests` 中，直到需要终止 stream

定位：

- `InboundRequestId` 与 `active_inbound_requests`：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/mod.rs

---

## 7.5 编码：SSZ + Snappy（定位）

Lighthouse 的 RPC 编码实现位于：

- https://github.com/sigp/lighthouse/tree/v8.0.1/beacon_node/lighthouse_network/src/rpc/codec

文档写作建议：

- 协议字段含义来自共识规范（描述即可）
- 编码/压缩与“长度前缀/分片”等细节，以定位链接为主，避免在文档里重复实现细节

---

## 7.6 并发与限流：两个层次

### 7.6.1 并发限制（protocol 维度）

在 rpc/mod.rs 中可见一个并发常量：

- `MAX_CONCURRENT_REQUESTS`（每个 protocol id 的并发请求上限）

这类限制用于防止：

- 单个 peer 或单种方法压垮本地资源
- 并发过高导致响应乱序、缓存爆炸

### 7.6.2 速率限制（inbound/outbound）

RPC 层还存在：

- inbound response limiter（限制我们对外响应的速率/大小）
- outbound self limiter（限制我们对外发起请求的速率/并发）

定位：

- https://github.com/sigp/lighthouse/tree/v8.0.1/beacon_node/lighthouse_network/src/rpc

---

## 7.7 与 Prysm / Teku 的对比

- Prysm：对每个方法有独立 handler，并在 sync service 内编排重试/限流。
- Teku：以“方法 handler + rate limiter + chain data client”的组合实现。
- Lighthouse：
  - 在 RPC 层把“方法、编码、终止、限流、事件”集中管理
  - 在 beacon_node/network 层用 router + processor + sync context 管理策略

下一章进入 Status 协议：它是握手与同步策略选择的基础。
