# 第 9 章: Lighthouse BlocksByRange（BeaconBlocksByRange）v8.0.1

BlocksByRange 是同步过程中最常用的“批量拉取区块”协议：给定起始 slot 与数量，返回该范围内存在的区块（通常为流式响应）。

---

## 9.1 协议标识

来自共识规范的常见协议 ID（不同版本号对应不同分叉/载荷变化）：

- `/eth2/beacon_chain/req/beacon_blocks_by_range/1/ssz_snappy`
- `/eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy`

Lighthouse 的请求类型在 `rpc/methods.rs`：

- `BlocksByRangeRequest`（V1/V2 变体）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs

---

## 9.2 请求结构与边界

在 Lighthouse 中，BlocksByRange 请求结构（概念上）就是：

- `start_slot: u64`
- `count: u64`

（注意：历史上 eth2 还存在带 `step` 的旧结构，Lighthouse 在 `methods.rs` 中保留了 `OldBlocksByRangeRequest` 用于兼容/转换。）

定位：

- `BlocksByRangeRequest` / `OldBlocksByRangeRequest`：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs

写文档时建议强调的边界：

- `count` 会受到规范上限约束（通常由 `ChainSpec` 派生）
- `start_slot` 不应超过当前 slot 太多（否则可能被视为无效/可疑）

---

## 9.3 服务端处理：handle_blocks_by_range_request

服务端入口在 `NetworkBeaconProcessor`：

- `handle_blocks_by_range_request`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/rpc_methods.rs

整体模式与 BlocksByRoot 类似：

1. 验证请求（边界、数据库能力等）
2. 从 chain 侧获取一个“区块流/迭代器”
3. 对每个区块分片发送响应
4. 终止响应流（EndOfStream/termination）

> Lighthouse 的 RPC 框架天然支持“流式响应结束事件”，这使得处理 blocks_by_range 这类方法更统一。

---

## 9.4 客户端发起：send_blocks_by_range_request

请求发起侧通常由 network beacon processor 编排：

- `send_blocks_by_range_request`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs

收到响应后，router 会把每个区块响应分片分发给相应的回调：

- `on_blocks_by_range_response`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

同步层会在这里“逐块接收 → 验证/入库 → 更新进度”。

---

## 9.5 与 Prysm / Teku 的对比

- 三者都会对 blocks_by_range 做：

  - 请求参数校验
  - 最大请求数量限制
  - 流式响应/分块处理

- Lighthouse 的差异点更多体现在“请求生命周期管理”：
  - RPC 层对 EndOfStream 有显式事件
  - sync/network_context 往往会对活跃请求做集中管理（超时、归因、重试）

下一章进入 BlocksByRoot：它常用于“补缺块/找父块/按 root 精确拉取”。
