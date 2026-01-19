# 第 3 章: Teku 同步模块设计

## 3.1 Teku 架构概览

### 3.1.1 事件驱动架构

Teku 采用完全异步、事件驱动的架构：

```
┌─────────────────────────────────────────────┐
│         Teku Beacon Node                    │
├─────────────────────────────────────────────┤
│  EventBus (事件总线)                        │
│    ↓          ↓           ↓                 │
│  Sync      Network    Validator             │
│  Module    Module     Module                │
│    ↓                                        │
│  ┌──────────────────────────────┐          │
│  │  SyncService                 │          │
│  │  ├── ForwardSync (Forward)   │←─ Gossip│
│  │  ├── Historical (Backfill)   │          │
│  │  └── FetchRecent (Catch-up)  │          │
│  └──────────────────────────────┘          │
└─────────────────────────────────────────────┘
```

**核心特点**:

- 异步非阻塞：基于 `CompletableFuture`/`SafeFuture`
- 事件驱动：EventBus 解耦模块
- 高并发：利用 Java NIO + 虚拟线程（Project Loom）
- 类型安全：强类型检查

---

## 3.2 同步模块组件

### 3.2.1 核心服务

#### SyncService 接口

```java
public interface SyncService extends Service {
  // 获取同步状态（异步）
  SafeFuture<SyncStatus> getSyncStatus();

  // 是否正在同步
  boolean isSyncActive();

  // 订阅同步状态变更
  long subscribeToSyncChanges(SyncStatusListener listener);

  // 取消订阅
  void unsubscribe(long subscriberId);
}
```

**与 Prysm 对比**:
| 特性 | Prysm | Teku |
|------|-------|------|
| 同步状态 | 返回值 | SafeFuture（异步） |
| 状态变更 | Channel | 订阅-监听 |
| 服务生命周期 | Start/Stop | Service 接口 |

---

### 3.2.2 ForwardSync 服务（Regular Sync）

```java
public class ForwardSyncService {
  private final AsyncRunner asyncRunner;
  private final Eth2P2PNetwork network;
  private final BlockManager blockManager;

  public SafeFuture<Void> start() {
    // 订阅 Gossip 区块
    network.subscribeToBlocksGossip(this::onGossipBlock);

    // 启动区块管理器
    return blockManager.start();
  }

  private void onGossipBlock(SignedBeaconBlock block) {
    asyncRunner.runAsync(() ->
      blockManager.importBlock(block)
        .thenAccept(result -> handleImportResult(result))
    );
  }
}
```

**流程**:

1. **订阅 Gossip** → 2. **接收区块** → 3. **异步导入** → 4. **处理结果**

**关键类**:

- `BlockManager` - 区块管理与验证
- `BlockImporter` - 区块导入逻辑
- `FutureBlockProcessor` - 处理未来区块（parent 未知）

---

### 3.2.3 HistoricalSync 服务（Backfill）

```java
public class HistoricalBatchFetcher {
  private final CombinedChainDataClient chainDataClient;
  private final Eth2P2PNetwork network;

  public SafeFuture<Void> fetchBatch(UInt64 startSlot, int batchSize) {
    return network.requestBlocksByRange(
      peer,
      startSlot,
      UInt64.valueOf(batchSize)
    ).thenCompose(blocks ->
      chainDataClient.importHistoricalBlocks(blocks)
    );
  }
}
```

**Teku 特色**:

- 可选启用：`--reconstruct-historic-states=true`
- 低优先级：不阻塞 Forward Sync
- 批量导入：默认 64 blocks/batch

---

## 3.3 数据流向

### 3.3.1 Forward Sync 数据流

```
Gossipsub Topic: /eth2/beacon_block
        ↓
  Network Layer (Eth2P2PNetwork)
        ↓
  BeaconBlockTopicHandler
        ↓
  BlockValidator (验证签名、时间等)
        ↓
  ForwardSync.onGossipBlock()
        ↓
  BlockManager.importBlock()
        ↓
  BlockImporter (状态转换)
        ↓
  RecentChainData.updateHead()
        ↓
  EventBus.publish(ChainHeadEvent)
```

### 3.3.2 Req/Resp 数据流

```
Peer Request: BeaconBlocksByRange
        ↓
  RpcRequestHandler
        ↓
  BeaconBlocksByRangeMessageHandler
        ↓
  CombinedChainDataClient.getBlocksByRange()
        ↓
  Database Query (RocksDB)
        ↓
  Stream Response (RpcResponseListener)
        ↓
  Peer (流式返回)
```

---

## 3.4 与 P2P 模块协同

### 3.4.1 网络接口抽象

```java
public interface Eth2P2PNetwork {
  // Req/Resp 方法
  SafeFuture<List<SignedBeaconBlock>> requestBlocksByRange(
    Peer peer,
    UInt64 startSlot,
    UInt64 count
  );

  SafeFuture<List<SignedBeaconBlock>> requestBlocksByRoot(
    Peer peer,
    List<Bytes32> blockRoots
  );

  // Gossipsub 方法
  void subscribeToBlocksGossip(Consumer<SignedBeaconBlock> handler);
  void subscribeToAttestationsGossip(Consumer<Attestation> handler);

  // Peer 管理
  Stream<Peer> streamPeers();
  SafeFuture<PeerStatus> requestPeerStatus(Peer peer);
}
```

**设计优势**:

- 接口隔离：同步模块不依赖 libp2p 实现细节
- 易于测试：可以 Mock `Eth2P2PNetwork`
- 类型安全：泛型确保类型正确

---

### 3.4.2 异步请求处理

```java
public class FetchRecentBlocksService {
  private final Eth2P2PNetwork network;
  private final AsyncRunner asyncRunner;

  public SafeFuture<Void> fetchMissingBlocks(Bytes32 blockRoot) {
    return findPeerWithBlock(blockRoot)
      .thenCompose(peer ->
        network.requestBlocksByRoot(peer, List.of(blockRoot))
      )
      .thenCompose(blocks ->
        importBlocks(blocks)
      )
      .exceptionally(error -> {
        LOG.warn("Failed to fetch block {}", blockRoot, error);
        return null;
      });
  }

  private SafeFuture<Peer> findPeerWithBlock(Bytes32 blockRoot) {
    return asyncRunner.runAsync(() -> {
      return network.streamPeers()
        .filter(peer -> peer.hasBlock(blockRoot))
        .findFirst()
        .orElseThrow(() -> new RuntimeException("No peer has block"));
    });
  }
}
```

**异步链式调用**:

1. 查找 Peer → 2. 请求区块 → 3. 导入区块 → 4. 异常处理

---

## 3.5 配置与调优

### 3.5.1 SyncConfig 配置类

```java
public class SyncConfig {
  // Forward Sync 配置
  private int forwardSyncBatchSize = 50;              // 默认 50 blocks
  private int forwardSyncMaxPendingBatches = 5;       // 最多 5 个待处理批次
  private int forwardSyncMaxBlockImportsPerSecond = 250;  // 限速

  // Historical Sync 配置
  private int historicalSyncBatchSize = 64;           // 历史同步批量
  private boolean reconstructHistoricStates = false;  // 是否重建历史状态

  // Checkpoint Sync 配置
  private Optional<String> initialStateUrl = Optional.empty();

  // Peer 配置
  private int minPeers = 64;
  private int maxPeers = 100;

  // 超时配置
  private Duration blocksByRangeRequestTimeout = Duration.ofSeconds(10);
}
```

### 3.5.2 性能调优参数

| 参数                       | 默认值 | 说明                  | 调优建议             |
| -------------------------- | ------ | --------------------- | -------------------- |
| `forwardSyncBatchSize`     | 50     | Forward sync 批量大小 | 高带宽环境可增至 100 |
| `maxPendingBatches`        | 5      | 最大待处理批次        | 内存充足可增至 10    |
| `maxBlockImportsPerSecond` | 250    | 每秒最大导入数        | CPU 强劲可去除限制   |
| `maxPeers`                 | 100    | 最大连接 peer 数      | 公共节点可增至 200   |

---

## 3.6 监控与可观测性

### 3.6.1 Metrics 指标

Teku 使用 Micrometer + Prometheus：

```java
// 同步状态指标
@Gauge(name = "beacon_sync_is_syncing", description = "Whether node is syncing")
public int getSyncingStatus() {
  return syncService.isSyncActive() ? 1 : 0;
}

// 区块导入指标
@Counter(name = "beacon_sync_blocks_imported", description = "Blocks imported")
public void recordBlockImport() {
  blocksImportedCounter.increment();
}

// 区块导入耗时
@Timer(name = "beacon_sync_block_import_time", description = "Block import time")
public SafeFuture<BlockImportResult> importBlock(SignedBeaconBlock block) {
  return Timer.sample()
    .record(() -> blockImporter.importBlock(block));
}
```

**关键指标**:

- `beacon_sync_is_syncing` - 同步状态（0/1）
- `beacon_sync_head_slot` - 当前头部 slot
- `beacon_sync_blocks_imported_total` - 已导入区块数
- `beacon_sync_block_import_time_seconds` - 区块导入耗时分布

### 3.6.2 日志记录

```java
private static final Logger LOG = LogManager.getLogger();

// 结构化日志
LOG.info("Block imported successfully",
  kv("slot", block.getSlot()),
  kv("root", block.getRoot()),
  kv("parent", block.getParentRoot()),
  kv("proposer", block.getProposerIndex())
);

// 性能日志
LOG.debug("Block import took {}ms",
  duration.toMillis(),
  kv("slot", block.getSlot())
);
```

**日志级别**:

- `ERROR` - 导入失败、网络错误
- `WARN` - 无效区块、peer 超时
- `INFO` - 同步状态变更、批次完成
- `DEBUG` - 每个区块的详细信息
- `TRACE` - 网络消息、数据库查询

---

## 3.7 错误处理与容错

### 3.7.1 异常传播

```java
public SafeFuture<BlockImportResult> importBlock(SignedBeaconBlock block) {
  return SafeFuture.of(() -> {
    // 验证区块
    return validateBlock(block);
  })
  .thenCompose(validationResult -> {
    if (!validationResult.isValid()) {
      return SafeFuture.completedFuture(
        BlockImportResult.failed(validationResult.getReason())
      );
    }
    // 导入区块
    return doImportBlock(block);
  })
  .exceptionally(error -> {
    LOG.error("Block import failed", error);
    return BlockImportResult.failedWithException(error);
  });
}
```

### 3.7.2 重试策略

```java
public class FetchRecentBlocksService {
  private static final int MAX_RETRIES = 3;
  private static final Duration RETRY_DELAY = Duration.ofSeconds(2);

  public SafeFuture<Void> fetchBlockWithRetry(Bytes32 blockRoot) {
    return retryWithBackoff(
      () -> fetchBlock(blockRoot),
      MAX_RETRIES,
      RETRY_DELAY
    );
  }

  private <T> SafeFuture<T> retryWithBackoff(
      Supplier<SafeFuture<T>> operation,
      int maxRetries,
      Duration initialDelay) {

    return operation.get()
      .exceptionallyCompose(error -> {
        if (maxRetries <= 0) {
          return SafeFuture.failedFuture(error);
        }
        return asyncRunner.runAfterDelay(
          () -> retryWithBackoff(operation, maxRetries - 1, initialDelay.multipliedBy(2)),
          initialDelay
        );
      });
  }
}
```

**重试策略**:

- 指数退避：2s → 4s → 8s
- 最大重试次数：3 次
- 可配置：不同错误类型不同策略

---

## 3.8 与 Prysm 设计对比

| 维度         | Prysm (Go)                  | Teku (Java)                     |
| ------------ | --------------------------- | ------------------------------- |
| **架构风格** | CSP (Goroutines + Channels) | 事件驱动 (EventBus)             |
| **并发模型** | Goroutines (轻量)           | CompletableFuture + AsyncRunner |
| **错误处理** | 返回 error                  | SafeFuture.exceptionally()      |
| **状态通知** | Channel 广播                | 订阅-监听模式                   |
| **类型安全** | 接口 + 结构体               | 泛型 + 接口                     |
| **模块解耦** | 接口注入                    | EventBus + 依赖注入             |
| **测试友好** | Mock 接口                   | Mock 接口 + 依赖注入            |

**Teku 优势**:

- 类型安全：编译期泛型检查
- 异步流水线：Future 链式调用
- 企业级：成熟的 Java 生态

**Prysm 优势**:

- 轻量级：Goroutines 开销极小
- 简洁：Channel 语义清晰
- 性能：Go runtime 高效

---

## 3.9 本章总结

### 关键要点

1. Teku 采用完全异步、事件驱动架构
2. 核心服务：ForwardSync（实时）+ HistoricalSync（回填）
3. 异步流水线：SafeFuture 链式调用
4. 接口隔离：Eth2P2PNetwork 抽象网络层
5. 可观测性：Prometheus + 结构化日志

### 后续章节

- **第 7 章**: Req/Resp 协议实现（Teku）
- **第 8 章**: Status 协议（Teku 实现）
- **第 18 章**: Full Sync 实现细节（Teku）

---

**参考资源**:

- Teku 代码: `beacon/sync/src/main/java/tech/pegasys/teku/beacon/sync/`
- 配置参考: [code_references.md](./code_references.md)
- 官方文档: https://docs.teku.consensys.io/

---

**最后更新**: 2026-01-13
