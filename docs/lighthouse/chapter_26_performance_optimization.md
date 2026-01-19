# 第 26 章: Lighthouse 同步性能优化 v8.0.1

本章从 sync/lookup/backfill 的角度，列出 Lighthouse v8.0.1 中可直接看到的性能优化手段与关键常量。

---

## 26.1 通过“容忍区间”避免频繁切换同步模式

- `SLOT_IMPORT_TOLERANCE = 32`

它既用于决定是否 range sync，也用于 block lookup 的最大深度（`PARENT_DEPTH_TOLERANCE`）：

- `SyncManager`：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/manager.rs
- `block_lookups`：
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/block_lookups/mod.rs

---

## 26.2 RangeSync：batch buffer + 分离“下载失败/处理失败”

RangeSync 的常量：

- `EPOCHS_PER_BATCH = 1`
- `BATCH_BUFFER_SIZE = 5`
- `MAX_BATCH_DOWNLOAD_ATTEMPTS = 5`
- `MAX_BATCH_PROCESSING_ATTEMPTS = 3`

定位：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/range_sync/chain.rs

---

## 26.3 BackfillSync：更高的重试上限

Backfill 对历史数据更“宽容”，默认下载/处理重试更高：

- `MAX_BATCH_DOWNLOAD_ATTEMPTS = 10`
- `MAX_BATCH_PROCESSING_ATTEMPTS = 10`

定位：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/backfill_sync/mod.rs

---

## 26.4 BlockLookups：LRU 缓存与最大并发 lookup 数量

lookup 侧通过多个边界控制内存/活性：

- `LOOKUP_MAX_DURATION_*`（stuck/no peers 超时）
- `MAX_LOOKUPS = 200`（限制并发 lookup 数量，避免内存爆炸）
- `ignored_chains: LRUTimeCache`（对失败链短期忽略，减少无效重试）

定位：

- https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/block_lookups/mod.rs

---

## 26.5 与 Prysm/Teku 的对比

- 三者都有“批量拉取 + 重试 + 缓存 + 超时”的组合。
- Lighthouse 的 block lookup 对“stuck”情况做了显式定义与超时兜底（并在注释里指导维护者），对线上可维护性非常关键。
