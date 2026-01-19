# 第 2 章: Lighthouse Beacon 节点架构概览（v8.0.1）

本章目标：从“仓库结构 + 关键 crate 职责 + 数据/事件流”建立 Lighthouse 的整体心智模型，为后续同步与网络章节（第 3-10 章）提供定位入口。

---

## 2.1 仓库结构：从可执行程序到核心 crate

Lighthouse 仓库是 workspace 形态，常见的顶层目录包括：

- `lighthouse/`：主二进制入口与 CLI 组装
- `beacon_node/`：Beacon Node 相关 crate
- `validator_client/`：验证者客户端
- `common/`、`consensus/`、`crypto/`：共识、密码学与通用组件

### 2.1.1 主入口

- `lighthouse/src/main.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/lighthouse/src/main.rs

它负责：

- CLI 参数解析与 subcommand 分发
- 启动 Beacon Node / Validator Client 等组件
- 初始化日志、metrics、运行时等

---

## 2.2 Beacon Node 内部：网络与链的协作

在 Beacon Node 侧，我们关心两块：

1. **链服务（beacon_chain）**：负责区块验证/导入、fork choice、状态推进
2. **网络服务（lighthouse_network + network）**：负责 peer、gossipsub、req/resp、discv5 以及同步调度

### 2.2.1 网络栈的两层

Lighthouse 在工程上把网络分为两层（这对写文档很友好）：

- `beacon_node/lighthouse_network/`
  - 直接对接 rust-libp2p：Swarm/Behaviour、RPC、discovery、peer manager
- `beacon_node/network/`
  - Beacon Node 侧“编排层”：router、network_beacon_processor、sync manager

这一层负责把 libp2p 的事件翻译成“对同步/链有意义的事件”，并调度请求。

---

## 2.3 关键模块速览（第 3-10 章会反复引用）

### 2.3.1 libp2p Service 与 Behaviour

- `beacon_node/lighthouse_network/src/service/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

这里定义了核心 `NetworkEvent`（例如 `RequestReceived`/`ResponseReceived`/`StatusPeer`）以及组合 Behaviour（peer manager + rpc + discovery + gossipsub）。

### 2.3.2 Beacon Node 网络路由

- `beacon_node/network/src/router.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

router 的职责是：

- 将 `NetworkEvent` 分流到 “RPC handler / sync handler / gossip handler”
- 负责主动发送部分请求（例如 Status）或触发 processor 执行

### 2.3.3 NetworkBeaconProcessor：RPC 服务端处理

- `beacon_node/network/src/network_beacon_processor/rpc_methods.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/rpc_methods.rs

它包含了对 Status/BlocksByRange/BlocksByRoot 等方法的处理函数（本仓库第 8-10 章会以这些入口为主线）。

---

## 2.4 数据流（高层）：消息 → 验证 → 导入 → 状态更新

一个典型路径（以“通过 req/resp 拉取区块”为例）：

1. 同步模块决定要向某个 peer 请求区块（例如 `BlocksByRange`）
2. network 编排层发起请求（通过 processor/rpc 行为）
3. 收到响应后，router 将响应回调交给 sync 侧处理
4. sync 将区块送入链导入管线（beacon_chain），更新 head/finalized

> 这套路径的“工程分层”是 Lighthouse 的特色之一：libp2p 细节留在 lighthouse_network，Beacon Node 逻辑留在 network。

---

## 2.5 与 Prysm / Teku 的对比视角

- Prysm（Go）常把 sync 和 p2p 紧密耦合在同一服务里，通过接口抽象做隔离。
- Teku（Java）更偏向“服务 + handler”的异步组合（SafeFuture + 事件总线式调用）。
- Lighthouse（Rust）倾向于“libp2p 网络 crate + beacon_node 编排层”两段式：
  - 让底层网络行为更可复用、可测试
  - 让同步/链逻辑更专注在状态机与导入策略

下一章会落到“同步模块与 P2P 的协同设计”，把这两层如何配合讲清楚。
