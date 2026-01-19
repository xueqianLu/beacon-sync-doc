# 第 1 章: Lighthouse PoS 共识机制概述

本章复用“PoS/Beacon Chain 基础概念”的通用知识框架，但会标注 Lighthouse（`v8.0.1`）在代码与数据结构层面常见的对应点，方便后续章节引用。

---

## 1.1 从 PoW 到 PoS：共识层要解决的问题

在以太坊合并后（The Merge），共识层（Consensus Layer, CL）负责：

- **出块与最终性**：基于 Slot/Epoch 的提议与证明（attestation）
- **fork choice**：用 LMD-GHOST + FFG（Casper）规则选择 head
- **网络传播与同步**：通过 libp2p/gossipsub 与 req/resp 协议传播区块与证明，并通过同步模块追赶链头

> Lighthouse 文档重点：同步模块如何与网络层交互（后续第 3-10 章）。

---

## 1.2 时间与单位：Slot / Epoch

- **Slot**：一个出块时隙（主网通常 12s）
- **Epoch**：若干 slot 的集合（主网通常 32 slots/epoch）

同步与网络协议中大量字段直接使用 `slot` / `epoch`：

- Status 握手里会携带 `head_slot`、`finalized_epoch`
- BlocksByRange/ByRoot 请求以 `slot` 或 `block_root` 作为查询维度

---

## 1.3 核心对象：Block、State、Checkpoint

### 1.3.1 BeaconBlock / SignedBeaconBlock

- 网络上传播的常见对象是“带签名”的区块（Signed Beacon Block）
- 请求响应（req/resp）里 `BlocksByRange` 与 `BlocksByRoot` 的响应通常是“区块流”（按块分片返回）

### 1.3.2 BeaconState

- 负责记录验证者集、最终性信息、委员会分配、历史根等状态
- 同步通常要保证“区块可导入 + 状态可推进”

### 1.3.3 Checkpoint / Finalized Checkpoint

- 最终性（finality）对同步策略很关键：
  - 同步落后时，常以 finalized checkpoint 为锚点追赶
  - Status 握手里 exchange finalized root/epoch 用于判断“对方链是否可信/是否更先进”

---

## 1.4 Lighthouse v8.0.1 里你会频繁看到的概念映射

这一章不做源码深挖，只给出“后续章节会引用到”的高频映射点：

- **ChainSpec / ForkContext**：协议常量与分叉上下文（请求上限、fork digest 等）
- **StatusMessage**：Status 握手消息类型（第 8 章）
- **BlocksByRangeRequest / BlocksByRootRequest**：请求结构（第 9-10 章）
- **Router / NetworkBeaconProcessor**：Beacon Node 网络侧事件路由与 RPC 处理（第 7-10 章）

可从这里开始跳转：

- Lighthouse RPC 方法与消息结构（固定到 v8.0.1）：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs

---

## 1.5 与 Prysm / Teku 的写作对齐点

为了便于横向对比，本仓库对三个客户端都遵循同一视角：

- **协议字段含义**：一致（来自共识规范）
- **工程拆分**：不同（Go/Java/Rust 的模块边界与并发模型不同）
- **同步策略细节**：不同（缓存、限流、请求调度、错误处理各有风格）

本章之后将开始从“Lighthouse 的工程结构与网络协议实现”切入。
