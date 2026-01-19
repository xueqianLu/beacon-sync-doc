# 第 9 章: Teku BeaconBlocksByRange 实现

## 9.1 协议定义

### 9.1.1 协议标识

```
/eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy
```

### 9.1.2 请求消息结构

```java
public class BeaconBlocksByRangeRequest implements SszData {
  private final UInt64 startSlot;
  private final UInt64 count;
  private final UInt64 step;  // 固定为 1

  public static final int MAX_REQUEST_BLOCKS = 1024;

  public BeaconBlocksByRangeRequest(UInt64 startSlot, UInt64 count) {
    this.startSlot = startSlot;
    this.count = count.min(UInt64.valueOf(MAX_REQUEST_BLOCKS));
    this.step = UInt64.ONE;
  }
}
```

---

## 9.2 服务端实现

### 9.2.1 BeaconBlocksByRangeMessageHandler

```java
public class BeaconBlocksByRangeMessageHandler
    implements Eth2RpcMethod<BeaconBlocksByRangeRequest, SignedBeaconBlock> {

  private final CombinedChainDataClient chainDataClient;
  private final RpcRateLimiter rateLimiter;

  @Override
  public SafeFuture<Void> respond(
      BeaconBlocksByRangeRequest request,
      RpcResponseListener<SignedBeaconBlock> listener) {

    // 验证请求
    if (!isValidRequest(request)) {
      listener.completeWithError(
        new RpcException(RpcErrorCode.INVALID_REQUEST, "Invalid range")
      );
      return SafeFuture.COMPLETE;
    }

    // 速率限制检查
    if (!rateLimiter.allowBlocksByRange(request.getCount())) {
      listener.completeWithError(
        new RpcException(RpcErrorCode.RATE_LIMITED, "Rate limit exceeded")
      );
      return SafeFuture.COMPLETE;
    }

    // 流式返回区块
    return chainDataClient
      .getBlocksByRange(request.getStartSlot(), request.getCount())
      .thenAccept(blocks -> {
        LOG.debug("Sending blocks",
          kv("start", request.getStartSlot()),
          kv("count", blocks.size())
        );

        // 逐个发送区块
        for (SignedBeaconBlock block : blocks) {
          listener.respond(block);
        }

        listener.completeSuccessfully();
      })
      .exceptionally(error -> {
        LOG.error("Failed to get blocks by range", error);
        listener.completeWithError(
          new RpcException(RpcErrorCode.SERVER_ERROR, error.getMessage())
        );
        return null;
      });
  }

  private boolean isValidRequest(BeaconBlocksByRangeRequest request) {
    // 检查 count 不超过限制
    if (request.getCount().isGreaterThan(UInt64.valueOf(MAX_REQUEST_BLOCKS))) {
      return false;
    }

    // 检查 step 必须为 1
    if (!request.getStep().equals(UInt64.ONE)) {
      return false;
    }

    // 检查 startSlot 不在未来
    UInt64 currentSlot = chainDataClient.getCurrentSlot();
    if (request.getStartSlot().isGreaterThan(currentSlot)) {
      return false;
    }

    return true;
  }
}
```

---

## 9.3 客户端使用

### 9.3.1 批量获取区块

```java
public class BlockFetcher {
  private final Eth2P2PNetwork network;
  private final AsyncRunner asyncRunner;

  public SafeFuture<List<SignedBeaconBlock>> fetchBlockRange(
      Peer peer,
      UInt64 startSlot,
      UInt64 count) {

    List<SignedBeaconBlock> blocks = Collections.synchronizedList(
      new ArrayList<>()
    );

    BeaconBlocksByRangeRequest request =
      new BeaconBlocksByRangeRequest(startSlot, count);

    RpcResponseListener<SignedBeaconBlock> listener =
      new CollectingListener(blocks);

    return network.requestBlocksByRange(peer, request, listener)
      .thenApply(__ -> blocks)
      .orTimeout(10, TimeUnit.SECONDS);
  }

  private static class CollectingListener
      implements RpcResponseListener<SignedBeaconBlock> {

    private final List<SignedBeaconBlock> blocks;

    @Override
    public void respond(SignedBeaconBlock block) {
      blocks.add(block);
    }

    @Override
    public void completeSuccessfully() {
      LOG.info("Received {} blocks", blocks.size());
    }

    @Override
    public void completeWithError(RpcException error) {
      LOG.error("Failed to fetch blocks", error);
      throw new CompletionException(error);
    }
  }
}
```

### 9.3.2 分批获取大范围

```java
public class BatchBlockFetcher {
  private static final int BATCH_SIZE = 64;

  public SafeFuture<List<SignedBeaconBlock>> fetchLargeRange(
      Peer peer,
      UInt64 startSlot,
      UInt64 endSlot) {

    List<SignedBeaconBlock> allBlocks = new ArrayList<>();
    UInt64 currentSlot = startSlot;

    // 分批请求
    List<SafeFuture<List<SignedBeaconBlock>>> batchFutures =
      new ArrayList<>();

    while (currentSlot.isLessThan(endSlot)) {
      UInt64 batchCount = endSlot.minus(currentSlot)
        .min(UInt64.valueOf(BATCH_SIZE));

      SafeFuture<List<SignedBeaconBlock>> batchFuture =
        fetchBlockRange(peer, currentSlot, batchCount);

      batchFutures.add(batchFuture);
      currentSlot = currentSlot.plus(batchCount);
    }

    // 等待所有批次完成
    return SafeFuture.allOf(batchFutures.toArray(new SafeFuture[0]))
      .thenApply(__ -> {
        batchFutures.forEach(future ->
          allBlocks.addAll(future.join())
        );
        return allBlocks;
      });
  }
}
```

---

## 9.4 验证与处理

### 9.4.1 响应验证

```java
public class BlockRangeValidator {
  public ValidationResult validateBlockRange(
      List<SignedBeaconBlock> blocks,
      UInt64 expectedStartSlot) {

    if (blocks.isEmpty()) {
      return ValidationResult.valid();
    }

    // 验证起始 slot
    if (!blocks.get(0).getSlot().equals(expectedStartSlot)) {
      return ValidationResult.invalid(
        "First block slot mismatch"
      );
    }

    // 验证连续性
    for (int i = 1; i < blocks.size(); i++) {
      SignedBeaconBlock prev = blocks.get(i - 1);
      SignedBeaconBlock curr = blocks.get(i);

      // 检查 parent_root
      if (!curr.getParentRoot().equals(prev.getRoot())) {
        return ValidationResult.invalid(
          "Parent root mismatch at slot " + curr.getSlot()
        );
      }

      // 检查 slot 递增
      if (curr.getSlot().isLessThanOrEqualTo(prev.getSlot())) {
        return ValidationResult.invalid(
          "Slot not increasing"
        );
      }
    }

    return ValidationResult.valid();
  }
}
```

### 9.4.2 批量导入

```java
public class BlockImportBatcher {
  private final BlockImporter blockImporter;
  private final AsyncRunner asyncRunner;

  public SafeFuture<Void> importBlockRange(
      List<SignedBeaconBlock> blocks) {

    // 按批次导入
    List<SafeFuture<BlockImportResult>> importFutures =
      new ArrayList<>();

    for (SignedBeaconBlock block : blocks) {
      SafeFuture<BlockImportResult> importFuture =
        blockImporter.importBlock(block)
          .exceptionally(error -> {
            LOG.warn("Failed to import block",
              kv("slot", block.getSlot()),
              kv("error", error.getMessage())
            );
            return BlockImportResult.failed(error);
          });

      importFutures.add(importFuture);
    }

    return SafeFuture.allOf(importFutures.toArray(new SafeFuture[0]))
      .thenAccept(__ -> {
        long successCount = importFutures.stream()
          .filter(f -> f.join().isSuccessful())
          .count();

        LOG.info("Imported blocks",
          kv("total", blocks.size()),
          kv("success", successCount)
        );
      });
  }
}
```

---

## 9.5 性能优化

### 9.5.1 并行获取

```java
public class ParallelBlockFetcher {
  private final Eth2P2PNetwork network;
  private final PeerSelector peerSelector;
  private static final int MAX_PARALLEL_REQUESTS = 5;

  public SafeFuture<List<SignedBeaconBlock>> fetchInParallel(
      UInt64 startSlot,
      UInt64 endSlot) {

    // 选择多个 peer
    List<Peer> peers = peerSelector.selectBestPeers(MAX_PARALLEL_REQUESTS);

    if (peers.isEmpty()) {
      return SafeFuture.failedFuture(
        new RuntimeException("No peers available")
      );
    }

    // 计算每个 peer 的负载
    UInt64 totalSlots = endSlot.minus(startSlot);
    UInt64 slotsPerPeer = totalSlots.dividedBy(peers.size());

    List<SafeFuture<List<SignedBeaconBlock>>> fetchFutures =
      new ArrayList<>();

    UInt64 currentStart = startSlot;
    for (int i = 0; i < peers.size(); i++) {
      Peer peer = peers.get(i);
      UInt64 fetchEnd = (i == peers.size() - 1)
        ? endSlot
        : currentStart.plus(slotsPerPeer);

      SafeFuture<List<SignedBeaconBlock>> future =
        fetchBlockRange(peer, currentStart, fetchEnd.minus(currentStart));

      fetchFutures.add(future);
      currentStart = fetchEnd;
    }

    // 合并结果
    return SafeFuture.allOf(fetchFutures.toArray(new SafeFuture[0]))
      .thenApply(__ -> {
        List<SignedBeaconBlock> allBlocks = new ArrayList<>();
        fetchFutures.forEach(f -> allBlocks.addAll(f.join()));
        return allBlocks;
      });
  }
}
```

### 9.5.2 缓存优化

```java
public class BlockRangeCache {
  private final Cache<RangeKey, List<SignedBeaconBlock>> cache;

  public BlockRangeCache() {
    this.cache = Caffeine.newBuilder()
      .maximumSize(100)
      .expireAfterWrite(Duration.ofMinutes(5))
      .build();
  }

  public Optional<List<SignedBeaconBlock>> get(
      UInt64 startSlot,
      UInt64 count) {
    RangeKey key = new RangeKey(startSlot, count);
    return Optional.ofNullable(cache.getIfPresent(key));
  }

  public void put(
      UInt64 startSlot,
      UInt64 count,
      List<SignedBeaconBlock> blocks) {
    RangeKey key = new RangeKey(startSlot, count);
    cache.put(key, blocks);
  }

  private record RangeKey(UInt64 startSlot, UInt64 count) {}
}
```

---

## 9.6 监控指标

```java
public class BlocksByRangeMetrics {
  private final Counter requestsTotal;
  private final Counter blocksReceived;
  private final Timer requestDuration;
  private final Histogram blocksPerRequest;

  public void recordRequest(
      UInt64 count,
      Duration duration,
      int blocksReceived) {

    requestsTotal.increment();
    this.blocksReceived.increment(blocksReceived);
    requestDuration.record(duration);
    blocksPerRequest.record(blocksReceived);
  }
}
```

---

## 9.7 与 Prysm 对比

| 维度         | Prysm       | Teku               |
| ------------ | ----------- | ------------------ |
| **批量大小** | 64 blocks   | 50 blocks (可配置) |
| **并发请求** | Round-Robin | 多 peer 并行       |
| **响应模式** | Channel 流  | Listener 回调      |
| **验证**     | 同步验证    | 异步 Future        |
| **缓存**     | LRU         | Caffeine           |

---

## 9.8 使用场景

### 9.8.1 Initial Sync

```java
// Forward sync 使用 BlocksByRange
forwardSyncService.sync(startSlot, targetSlot);
```

### 9.8.2 Historical Backfill

```java
// 历史同步回填
historicalBatchFetcher.fetchHistoricalBlocks(
  genesis,
  checkpointSlot
);
```

### 9.8.3 缺失区块补齐

```java
// 补齐缺失的区块
fetchMissingBlocks(gapStartSlot, gapEndSlot);
```

---

## 9.9 本章总结

- BeaconBlocksByRange 用于批量获取连续区块
- Teku 采用流式响应 + 异步 Future
- 支持多 peer 并行获取提升效率
- 完善的验证、缓存和监控机制

**下一章**: BeaconBlocksByRoot 实现

---

**最后更新**: 2026-01-13
