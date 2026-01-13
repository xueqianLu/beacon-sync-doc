# Teku Beacon 同步模块代码参考指南

## Teku 代码库结构

### 核心同步模块路径

```
teku/
├── beacon/sync/                                        # 同步核心模块
│   └── src/main/java/tech/pegasys/teku/beacon/sync/
│       ├── SyncService.java                            # 同步服务接口
│       ├── DefaultSyncService.java                     # 默认同步服务实现
│       ├── DefaultSyncServiceFactory.java              # 服务工厂
│       ├── SyncConfig.java                             # 同步配置
│       ├── forward/                                    # Forward Sync (类似 Regular Sync)
│       │   ├── ForwardSyncService.java                 # Forward sync 服务
│       │   ├── ForwardSync.java                        # Forward sync 逻辑
│       │   └── BlockManager.java                       # 区块管理器
│       ├── gossip/                                     # Gossip 处理
│       │   ├── BlockProcessor.java                     # 区块处理器
│       │   └── FutureBlockProcessor.java               # 未来区块处理
│       ├── historical/                                 # 历史同步（Backfill）
│       │   ├── HistoricalBatchFetcher.java             # 批量获取器
│       │   └── ReconstructHistoricalStatesService.java # 历史状态重建
│       ├── fetch/                                      # 数据获取
│       │   ├── FetchBlockTask.java                     # 区块获取任务
│       │   └── FetchRecentBlocksService.java           # 最近区块获取
│       └── events/                                     # 同步事件
│           └── SyncStateTracker.java                   # 同步状态跟踪
│
├── networking/eth2/                                    # Eth2 网络层
│   └── src/main/java/tech/pegasys/teku/networking/eth2/
│       ├── Eth2P2PNetwork.java                         # P2P 网络接口
│       ├── Eth2P2PNetworkFactory.java                  # 网络工厂
│       ├── rpc/                                        # Req/Resp 协议实现
│       │   ├── core/
│       │   │   ├── Eth2RpcMethod.java                  # RPC 方法接口
│       │   │   ├── RpcRequestHandler.java              # 请求处理器
│       │   │   └── RpcResponseHandler.java             # 响应处理器
│       │   └── beaconchain/
│       │       ├── BeaconChainMethods.java             # Beacon 链方法
│       │       ├── methods/
│       │       │   ├── StatusMessageHandler.java       # Status 消息处理
│       │       │   ├── BeaconBlocksByRangeMessageHandler.java  # BlocksByRange
│       │       │   ├── BeaconBlocksByRootMessageHandler.java   # BlocksByRoot
│       │       │   ├── MetadataMessageHandler.java     # Metadata 消息
│       │       │   └── PingMessageHandler.java         # Ping 消息
│       │       └── metadata/
│       └── gossip/                                     # Gossipsub 实现
│           ├── GossipHandler.java                      # Gossip 处理器
│           ├── topics/                                 # Gossip 主题
│           │   ├── topichandlers/
│           │   │   ├── Eth2TopicHandler.java           # Topic 处理器基类
│           │   │   ├── BeaconBlockTopicHandler.java    # 区块 topic
│           │   │   └── BeaconAggregateAndProofTopicHandler.java # 聚合证明
│           │   └── validation/
│           │       ├── BlockValidator.java             # 区块验证
│           │       └── AttestationValidator.java       # 证明验证
│           └── scoring/                                # Peer 评分
│               └── PeerScorer.java                     # Peer 评分器
│
└── networking/p2p/                                     # P2P 基础设施
    └── src/main/java/tech/pegasys/teku/networking/p2p/
        ├── libp2p/                                     # libp2p 实现
        ├── discovery/                                  # 节点发现
        └── peer/                                       # Peer 管理
```

---

## 关键接口与类

### 1. 同步服务核心

#### SyncService 接口
```java
package tech.pegasys.teku.beacon.sync;

public interface SyncService extends Service {
  SafeFuture<SyncStatus> getSyncStatus();
  
  boolean isSyncActive();
  
  long subscribeToSyncChanges(SyncStatusListener listener);
  
  void unsubscribe(long subscriberId);
}
```

**特点**:
- 异步设计：返回 `SafeFuture<T>`
- 事件驱动：基于订阅-监听模式
- 类型安全：使用泛型和接口

#### DefaultSyncService 实现
```java
public class DefaultSyncService implements SyncService {
  private final ForwardSyncService forwardSyncService;
  private final HistoricalBatchFetcher historicalBatchFetcher;
  private final FetchRecentBlocksService recentBlockFetcher;
  
  @Override
  public SafeFuture<Void> start() {
    return SafeFuture.allOf(
      forwardSyncService.start(),
      historicalBatchFetcher.start()
    );
  }
}
```

**架构特点**:
- 组合模式：组合多个子服务
- 依赖注入：构造器注入所有依赖
- 异步启动：使用 `SafeFuture.allOf()`

---

### 2. Forward Sync（类似 Prysm Regular Sync）

#### ForwardSync 类
```java
public class ForwardSync {
  private final AsyncRunner asyncRunner;
  private final RecentChainData recentChainData;
  private final Eth2P2PNetwork p2pNetwork;
  
  public void onGossipBlock(SignedBeaconBlock block) {
    asyncRunner.runAsync(() -> processBlock(block));
  }
  
  private SafeFuture<BlockImportResult> processBlock(SignedBeaconBlock block) {
    return validateBlock(block)
      .thenCompose(this::importBlock);
  }
}
```

**设计特点**:
- 事件驱动：Gossip 区块触发处理
- 异步流水线：`SafeFuture` 链式调用
- 职责分离：验证和导入分离

---

### 3. Req/Resp 协议

#### BeaconBlocksByRangeMessageHandler
```java
public class BeaconBlocksByRangeMessageHandler 
    implements Eth2RpcMethod<BeaconBlocksByRangeRequestMessage, SignedBeaconBlock> {
  
  @Override
  public SafeFuture<Void> respond(
      BeaconBlocksByRangeRequestMessage request,
      RpcResponseListener<SignedBeaconBlock> listener) {
    
    return SafeFuture.of(() -> {
      UInt64 startSlot = request.getStartSlot();
      UInt64 count = request.getCount();
      
      return combinedChainDataClient
        .getBlocksByRange(startSlot, count)
        .thenAccept(blocks -> {
          blocks.forEach(listener::respond);
          listener.completeSuccessfully();
        });
    });
  }
}
```

**Teku 特色**:
- 响应式设计：`RpcResponseListener` 流式返回
- 异步处理：完全基于 Future
- 类型安全：泛型指定请求/响应类型

---

### 4. Gossipsub 实现

#### BeaconBlockTopicHandler
```java
public class BeaconBlockTopicHandler implements Eth2TopicHandler<SignedBeaconBlock> {
  private final BlockValidator blockValidator;
  private final ForwardSync forwardSync;
  
  @Override
  public SafeFuture<ValidationResult> handleMessage(
      Eth2PreparedGossipMessage message) {
    
    return SafeFuture.of(() -> {
      SignedBeaconBlock block = message.getMessage();
      
      return blockValidator.validate(block)
        .thenCompose(result -> {
          if (result.isValid()) {
            return forwardSync.onGossipBlock(block)
              .thenApply(__ -> ValidationResult.ACCEPT);
          }
          return SafeFuture.completedFuture(ValidationResult.REJECT);
        });
    });
  }
}
```

**验证流程**:
1. 解析消息 → 2. 验证区块 → 3. 导入处理 → 4. 返回验证结果

---

## 重要常量（与 Prysm 对比）

| 常量名称 | Teku 值 | Prysm 值 | 说明 |
|----------|---------|----------|------|
| **同步批量大小** | 50 | 64 | Teku 默认更小 |
| **Forward Sync Workers** | 10 | - | Teku 并发工作者 |
| **Historical Batch Size** | 64 | 64 | 历史同步批量一致 |
| **Max Request Blocks** | 1024 | 1024 | 协议规定一致 |
| **Peer Limit** | 100 | 45 | Teku 支持更多 peer |

**配置文件**: `SyncConfig.java`

```java
public class SyncConfig {
  public static final int DEFAULT_FORWARD_SYNC_BATCH_SIZE = 50;
  public static final int DEFAULT_FORWARD_SYNC_MAX_PENDING_BATCHES = 5;
  public static final int DEFAULT_FORWARD_SYNC_MAX_BLOCK_IMPORTS_PER_SECOND = 250;
  
  // 历史同步配置
  public static final int DEFAULT_HISTORICAL_SYNC_BATCH_SIZE = 64;
  
  // Checkpoint sync 配置
  private Optional<String> initialStateUrl = Optional.empty();
}
```

---

## Teku vs Prysm 架构对比

### 并发模型

**Prysm (Go)**:
```go
// Goroutines + Channels
go func() {
    for block := range blockCh {
        processBlock(block)
    }
}()
```

**Teku (Java)**:
```java
// CompletableFuture + AsyncRunner
asyncRunner.runAsync(() -> {
  return processBlock(block)
    .thenCompose(this::importBlock);
});
```

### 错误处理

**Prysm**:
```go
func syncBlocks() error {
    if err := fetchBlocks(); err != nil {
        return err
    }
    return nil
}
```

**Teku**:
```java
public SafeFuture<Void> syncBlocks() {
  return fetchBlocks()
    .exceptionally(error -> {
      LOG.error("Sync failed", error);
      return null;
    });
}
```

### 事件传递

**Prysm**: Channel 传递  
**Teku**: EventBus 发布-订阅

---

## 关键数据结构

### SyncStatus
```java
public class SyncStatus {
  private final UInt64 currentSlot;
  private final UInt64 headSlot;
  private final boolean isSyncing;
  private final boolean isOptimistic;
  
  public boolean isInSync() {
    return !isSyncing && headSlot.equals(currentSlot);
  }
}
```

### BlockImportResult
```java
public class BlockImportResult {
  private final BlockImportStatus status;
  private final Optional<FailureReason> failureReason;
  
  public enum BlockImportStatus {
    SUCCESSFUL,
    FAILED_UNKNOWN_PARENT,
    FAILED_INVALID_BLOCK,
    FAILED_WEAK_SUBJECTIVITY_CHECKS
  }
}
```

---

## 测试文件路径

### 同步模块测试
```
beacon/sync/src/test/java/tech/pegasys/teku/beacon/sync/
├── forward/
│   ├── ForwardSyncTest.java
│   └── BlockManagerTest.java
├── gossip/
│   └── BlockProcessorTest.java
└── historical/
    └── HistoricalBatchFetcherTest.java
```

### RPC 测试
```
networking/eth2/src/test/java/tech/pegasys/teku/networking/eth2/rpc/
├── beaconchain/methods/
│   ├── StatusMessageHandlerTest.java
│   ├── BeaconBlocksByRangeMessageHandlerTest.java
│   └── BeaconBlocksByRootMessageHandlerTest.java
```

---

## 监控指标（Metrics）

Teku 使用 Prometheus + Micrometer：

```java
// 同步指标
Gauge.builder("beacon.sync.status", () -> syncService.isSyncActive() ? 1 : 0)
  .register(meterRegistry);

Counter.builder("beacon.sync.blocks_imported")
  .tag("source", "forward")
  .register(meterRegistry);

Timer.builder("beacon.sync.block_import_time")
  .register(meterRegistry);
```

**指标名称**:
- `beacon_sync_status` - 同步状态
- `beacon_sync_blocks_imported_total` - 导入区块数
- `beacon_sync_block_import_time_seconds` - 区块导入耗时
- `beacon_sync_peer_count` - 同步 peer 数量

---

## 配置参数

### 命令行参数

```bash
# Checkpoint Sync
--initial-state=<URL>

# Forward Sync 配置
--Xforward-sync-batch-size=50
--Xforward-sync-max-pending-batches=5

# Historical Sync
--Xhistorical-sync-batch-size=64
--reconstruct-historic-states=false

# Peer 限制
--p2p-peer-lower-bound=64
--p2p-peer-upper-bound=100
```

### 配置文件 (teku.yaml)
```yaml
sync:
  initial-state: "https://checkpoint-sync.example.com"
  forward-sync:
    batch-size: 50
    max-pending-batches: 5
  historical-sync:
    enabled: true
    batch-size: 64
```

---

## 参考资源

- **Teku 官方文档**: https://docs.teku.consensys.io/
- **GitHub 仓库**: https://github.com/Consensys/teku
- **代码浏览**: 
  - 同步模块: `beacon/sync/src/main/java/`
  - 网络模块: `networking/eth2/src/main/java/`
- **架构设计**: 参考 Teku Architecture Decision Records (ADR)

---

**最后更新**: 2026-01-13  
**Teku 版本**: v24.12.0+  
**对应 Spec**: Deneb (+ Electra)
