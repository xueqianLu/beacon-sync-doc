# 同步策略对比

## 初始同步 (Initial Sync)

### Prysm

- **策略**: Round-Robin
- **批量大小**: 64 blocks
- **并发度**: 多 peer 并行拉取
- **实现文件**: `beacon-chain/sync/initial-sync/round_robin.go`

### Teku

- **策略**: Parallel Batching
- **批量大小**: 50 blocks (可配置)
- **并发度**: 基于事件的异步处理
- **实现文件**: `beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/forward/`

---

## Regular Sync

### Prysm

- **触发机制**: Gossipsub 接收新区块
- **缺失父块**: 主动回溯请求
- **队列管理**: Pending blocks queue
- **实现文件**: `beacon-chain/sync/pending_blocks_queue.go`

### Teku

- **触发机制**: 事件驱动
- **缺失父块**: 异步请求链
- **队列管理**: 基于 CompletableFuture
- **实现文件**: `beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/gossip/`

---

## Checkpoint Sync

| 特性 | Prysm | Teku |
|------|-------|------|
| 支持 | ✅ | ✅ |
| 启动参数 | `--checkpoint-sync-url` | `--initial-state` |
| Backfill | 后台异步 | 可配置优先级 |

---

**对比结论**:
- Prysm 更注重批量处理效率
- Teku 更注重异步事件驱动
- 两者都支持现代同步特性（Checkpoint、Optimistic）

---

**最后更新**: 2026-01-13
