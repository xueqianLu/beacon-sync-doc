# 第 10 章: Lighthouse BlocksByRoot（BeaconBlocksByRoot）v8.0.1

BlocksByRoot 用于“按区块根精确拉取区块”，常见场景：

- 处理缺失父块（missing parent）
- backfill / 修复链数据缺口
- 某些同步阶段需要精确补齐特定 root 的区块

---

## 10.1 协议标识

来自共识规范的常见协议 ID：

- `/eth2/beacon_chain/req/beacon_blocks_by_root/1/ssz_snappy`

（注意：不同客户端实现可能支持多个版本号/分叉适配，具体以各自 RPC protocol 枚举为准。）

---

## 10.2 请求结构：Roots 列表 + 上限来自 ChainSpec

在 Lighthouse 中：

- `BlocksByRootRequest` 内部携带 `block_roots` 列表
- 构造函数会读取 `ForkContext.spec.max_request_blocks(...)` 来限制 roots 数量

定位：

- `BlocksByRootRequest::new(..., fork_context)`：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/rpc/methods.rs

这意味着：

- 文档里不建议写死 `MAX_REQUEST_BLOCKS=1024` 之类的固定值
- 更准确的说法是：上限由 `ChainSpec` 决定，并随 fork/网络配置而变化

---

## 10.3 服务端处理：handle_blocks_by_root_request

服务端入口同样在 `NetworkBeaconProcessor`：

- `handle_blocks_by_root_request`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/rpc_methods.rs

从源码可以看到典型处理模式：

1. 统计请求的 roots 数
2. 从 chain 侧获取 block stream（可能需要异步访问执行层以补 payload）
3. 对 stream 中的每个结果（root → block/err）发送响应分片
4. 结束响应流

这类实现强调两点：

- **按 root 精确命中**：不存在的 root 通常不会返回 block
- **流式返回**：避免一次性把大量区块加载到内存

---

## 10.4 客户端发起：send_blocks_by_roots_request

请求发起侧位于：

- `beacon_node/network/src/network_beacon_processor/mod.rs` 的 `send_blocks_by_roots_request`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/mod.rs

路由层会处理响应分片：

- `on_blocks_by_root_response`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/router.rs

此外，sync 侧会用“活跃请求集合”跟踪 blocks_by_root：

- `beacon_node/network/src/sync/network_context.rs`（`blocks_by_root_requests`）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/network_context.rs

这个模块通常负责：

- 超时/完成
- peer 归因（坏数据/无响应是谁的问题）
- “一个 root 一个请求”或“多 roots 批量”的策略边界

---

## 10.5 与 Prysm / Teku 的对比

- 三者都用 blocks_by_root 解决“精确补块”的问题。
- Lighthouse 的特点在于：
  - 将请求上限与 fork context/spec 绑定（构造阶段即校验）
  - 在 sync/network_context 中对请求做集中化管理，便于追踪与归因

第 1-10 章到这里为止，后续章节将进入 gossip（11-16）与同步阶段细节（17+）。
