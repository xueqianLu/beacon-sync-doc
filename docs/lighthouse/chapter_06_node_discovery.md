# 第 6 章: Lighthouse 节点发现机制（discv5/ENR）v8.0.1

本章聚焦 Lighthouse 的发现层：如何维护 ENR、如何运行 discv5、如何围绕“子网（subnet）发现”进行查询与 peer 扩容。

---

## 6.1 发现层在 Lighthouse 的位置

Lighthouse 的发现实现位于：

- `beacon_node/lighthouse_network/src/discovery/`
  - https://github.com/sigp/lighthouse/tree/v8.0.1/beacon_node/lighthouse_network/src/discovery

入口文件：

- `discovery/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/discovery/mod.rs

该模块的注释明确：这是一个围绕 discv5 的 libp2p dummy-behaviour，负责查询并管理对路由表的访问。

---

## 6.2 ENR：节点对外发布的信息

ENR（Ethereum Node Record）是节点发现的核心数据载体：

- IP/端口（TCP/UDP/QUIC 等）
- 公钥与 node id
- eth2 扩展字段（fork id、subnet bitfield 等）

Lighthouse 对 ENR 的构建与加载：

- `discovery/enr.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/discovery/enr.rs

在实现上会涉及：

- 启动时从磁盘加载 `enr.dat`（或生成新的）
- 将 fork digest、subnet bitfield 等写入 ENR

> ENR 的内容会影响：你会发现哪些 peer、以及你会被哪些 peer 发现。

---

## 6.3 Discovery Service：核心职责

`Discovery<E>`（见 `discovery/mod.rs`）通常承担：

- 维护本地 ENR
- 驱动 discv5 event stream
- 执行查询（FindNode / 查找子网 peer 等）
- 缓存已见 ENR（提升解析与映射效率）

注意点：

- 模块里有针对并发/重试/缓存容量的常量（例如 `MAX_CONCURRENT_SUBNET_QUERIES`、`ENR_CACHE_CAPACITY` 等）。这些体现了“发现层也需要限流/资源管理”。

---

## 6.4 Subnet Discovery：围绕 gossip 子网扩容

共识层存在多类子网（例如 attestation 子网、sync committee 子网等）。为了让 gossip 更有效，节点需要“针对性发现某些子网的 peer”。

Lighthouse 的做法是把“subnet predicate / grouped query”等策略写进 discovery：

- `discovery/subnet_predicate.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/discovery/subnet_predicate.rs

写文档时建议强调两点：

1. 子网发现不是“找更多 peer”，而是“找对的 peer”
2. 子网发现的目标数量与重试次数需要与连接管理/评分系统配合，否则容易造成无效连接风暴

---

## 6.5 与 Prysm / Teku 的对比

- 三者都基于 discv5/ENR，协议层一致。
- Lighthouse 在代码层更显式地把“发现策略参数”（并发、重试、缓存）写成常量/结构体，便于审计与调参。

下一章进入 Req/Resp 基础：发现拿到 peer 之后，如何用 RPC 协议获取链数据。
