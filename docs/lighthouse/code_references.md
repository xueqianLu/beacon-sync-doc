# Lighthouse (v8.0.1) 代码参考索引

> 目标：为本仓库 Lighthouse 文档提供“可点击、可复用、可核对”的源码入口清单。所有链接都固定到 `v8.0.1` tag，避免上游代码变更导致引用漂移。

---

## 1. 仓库结构（高层）

- `lighthouse/`：主二进制入口与 CLI 组装
- `beacon_node/`：Beacon Node 相关 crate
  - `beacon_node/network/`：Beacon Node 侧网络与同步编排（路由、sync manager、处理器）
  - `beacon_node/lighthouse_network/`：libp2p 网络栈实现（Swarm/Behaviour、discovery、rpc、peer manager）
  - `beacon_node/beacon_chain/`：链数据结构与链逻辑（本仓库第 1-10 章仅引用其“状态生成/依赖点”）

---

## 2. 关键入口（第 1-10 章用）

### 2.1 主程序入口

- `lighthouse/src/main.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/lighthouse/src/main.rs

### 2.2 libp2p 网络 Service

- `beacon_node/lighthouse_network/src/lib.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/lib.rs
- `beacon_node/lighthouse_network/src/service/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

### 2.3 节点发现（discv5/ENR）

- `beacon_node/lighthouse_network/src/discovery/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/discovery/mod.rs
- `beacon_node/lighthouse_network/src/discovery/enr.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/discovery/enr.rs

### 2.4 Req/Resp（RPC）协议框架与消息类型

- RPC 行为入口：`beacon_node/lighthouse_network/src/rpc/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/mod.rs
- RPC 方法与消息结构：`beacon_node/lighthouse_network/src/rpc/methods.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs
- RPC 协议枚举：`beacon_node/lighthouse_network/src/rpc/protocol.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/protocol.rs

### 2.5 Beacon Node 网络侧路由与处理

- RPC/同步事件路由：`beacon_node/network/src/router.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs
- RPC 处理方法：`beacon_node/network/src/network_beacon_processor/rpc_methods.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/rpc_methods.rs

---

## 3. 第 8-10 章常用定位点

### 3.1 Status

- StatusMessage 生成：`beacon_node/network/src/status.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/status.rs
- 路由侧发送/接收 Status：`beacon_node/network/src/router.rs`（`send_status` / `on_status_request` 等）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

### 3.2 BlocksByRange（服务端处理 & 客户端发起）

- 服务端处理：`beacon_node/network/src/network_beacon_processor/rpc_methods.rs`（`handle_blocks_by_range_request`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/rpc_methods.rs
- 发送请求：`beacon_node/network/src/network_beacon_processor/mod.rs`（`send_blocks_by_range_request`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs
- 路由层响应回调：`beacon_node/network/src/router.rs`（`on_blocks_by_range_response`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

### 3.3 BlocksByRoot（服务端处理 & 请求跟踪）

- 服务端处理：`beacon_node/network/src/network_beacon_processor/rpc_methods.rs`（`handle_blocks_by_root_request`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/rpc_methods.rs
- 发送请求：`beacon_node/network/src/network_beacon_processor/mod.rs`（`send_blocks_by_roots_request`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs
- 请求管理：`beacon_node/network/src/sync/network_context.rs`（`blocks_by_root_requests`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/network_context.rs

---

## 4. 协议与编码约定（用于第 7-10 章）

- Lighthouse 的 Req/Resp 实现遵循以太坊共识层规范的 wire 协议：
  - **SSZ 编码** + **Snappy 压缩**（体现在 rpc codec / gossipsub 编码封装）
- 请求上限通常由 `ChainSpec` / `ForkContext` 提供（例如 `max_request_blocks`）。

---

## 5. 使用建议

- 文档写作时，优先引用：
  - “入口文件 + 关键函数/类型名 + 固定 tag 链接”
- 避免大段复制源码；更推荐用“结构化描述 + 小段伪代码”说明行为边界。

---

## 6. Gossipsub（第 11-16 章）

### 6.1 Topic / Pubsub 类型体系

- Topics 与订阅集合：`types/topics.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/topics.rs
- Pubsub 消息编解码（SSZ + Snappy）：`types/pubsub.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/types/pubsub.rs

### 6.2 Gossipsub 配置

- `gossipsub_config(...)`（message_id_fn、duplicate_cache_time、validate_messages 等）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/config.rs

### 6.3 Gossip 事件入口与回传验证结果

- 事件入口：`Service::inject_gs_event`
- 回传验证结果：`Service::report_message_validation_result`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/mod.rs

### 6.4 Peer scoring（gossipsub 侧）

- `gossipsub_scoring_parameters.rs`（阈值、PeerScoreParams、TopicScoreParams 生成）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/service/gossipsub_scoring_parameters.rs

### 6.5 PeerDB 评分与断连阈值

- `peer_manager/peerdb/score.rs`（将 gossipsub 分数映射到 lighthouse score，disconnect/ban 等）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/peer_manager/peerdb/score.rs

---

## 7. Sync（第 17-24 章）

### 7.1 SyncManager 主入口

- `sync/manager.rs`（Range/Batch Sync + Parent Lookup + SyncMessage 定义）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/manager.rs

### 7.2 Range Sync（Full Sync）

- `sync/range_sync/chain.rs`（`SyncingChain`、batch 常量、peer pool、optimistic_start）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/range_sync/chain.rs

### 7.3 Backfill Sync（Checkpoint 后回填）

- `sync/backfill_sync/mod.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/backfill_sync/mod.rs

### 7.4 Missing Parent / Block Lookup

- `sync/block_lookups/mod.rs`（事件驱动状态机、PARENT_DEPTH_TOLERANCE、MAX_LOOKUPS 等）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/block_lookups/mod.rs

### 7.5 请求生命周期管理

- `sync/network_context.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/network_context.rs

---

## 8. Checkpoint Sync / Weak Subjectivity（第 19 章）

- 启动侧（checkpoint 下载与解析）：`client/src/builder.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/client/src/builder.rs
- 构建侧（写 DB、校验 state/block、构造 forkchoice anchor）：`beacon_chain/src/builder.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/beacon_chain/src/builder.rs

---

## 9. Forkchoice（第 24 章）

- `consensus/fork_choice` crate（ForkChoice、ForkChoiceStore、metrics）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/consensus/fork_choice/src/lib.rs

---

## 10. Metrics & Testing（第 27-28 章）

- 网络栈 metrics：`lighthouse_network/src/metrics.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/metrics.rs
- beacon node network metrics：`network/src/metrics.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/metrics.rs
- sync tests：`network/src/sync/tests/`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/tests
- processor tests：`network/src/network_beacon_processor/tests.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/tests.rs
- fork choice tests：`consensus/fork_choice/tests/tests.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/consensus/fork_choice/tests/tests.rs
