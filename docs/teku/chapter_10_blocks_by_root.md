# 第 10 章: Teku BeaconBlocksByRoot 实现

## 10.1 协议定义

### 10.1.1 协议标识
```
/eth2/beacon_chain/req/beacon_blocks_by_root/2/ssz_snappy
```

### 10.1.2 请求消息

```java
public class BeaconBlocksByRootRequest implements SszData {
  private final List<Bytes32> blockRoots;
  
  public static final int MAX_REQUEST_BLOCKS = 128;
  
  public BeaconBlocksByRootRequest(List<Bytes32> blockRoots) {
    this.blockRoots = blockRoots.stream()
      .limit(MAX_REQUEST_BLOCKS)
      .collect(Collectors.toList());
  }
}
```

---

## 10.2 服务端实现

```java
public class BeaconBlocksByRootMessageHandler 
    implements Eth2RpcMethod<BeaconBlocksByRootRequest, SignedBeaconBlock> {
  
  private final CombinedChainDataClient chainDataClient;
  
  @Override
  public SafeFuture<Void> respond(
      BeaconBlocksByRootRequest request,
      RpcResponseListener<SignedBeaconBlock> listener) {
    
    if (request.getBlockRoots().isEmpty()) {
      listener.completeSuccessfully();
      return SafeFuture.COMPLETE;
    }
    
    return chainDataClient
      .getBlocksByRoots(request.getBlockRoots())
      .thenAccept(blocks -> {
        blocks.forEach(listener::respond);
        listener.completeSuccessfully();
      })
      .exceptionally(error -> {
        listener.completeWithError(
          new RpcException(RpcErrorCode.SERVER_ERROR, error.getMessage())
        );
        return null;
      });
  }
}
```

---

## 10.3 客户端使用

### 10.3.1 获取缺失父块

```java
public class MissingParentFetcher {
  public SafeFuture<SignedBeaconBlock> fetchMissingParent(
      Peer peer,
      Bytes32 parentRoot) {
    
    BeaconBlocksByRootRequest request = 
      new BeaconBlocksByRootRequest(List.of(parentRoot));
    
    List<SignedBeaconBlock> blocks = new ArrayList<>();
    
    return network.requestBlocksByRoot(peer, request, 
      new CollectingListener(blocks)
    ).thenApply(__ -> {
      if (blocks.isEmpty()) {
        throw new RuntimeException("Block not found: " + parentRoot);
      }
      return blocks.get(0);
    });
  }
}
```

### 10.3.2 批量获取

```java
public SafeFuture<List<SignedBeaconBlock>> fetchBlocksByRoots(
    Peer peer,
    List<Bytes32> roots) {
  
  // 分批请求（每批最多 128 个）
  List<SafeFuture<List<SignedBeaconBlock>>> batchFutures = 
    new ArrayList<>();
  
  for (int i = 0; i < roots.size(); i += MAX_REQUEST_BLOCKS) {
    List<Bytes32> batch = roots.subList(
      i, 
      Math.min(i + MAX_REQUEST_BLOCKS, roots.size())
    );
    
    BeaconBlocksByRootRequest request = 
      new BeaconBlocksByRootRequest(batch);
    
    List<SignedBeaconBlock> batchBlocks = new ArrayList<>();
    SafeFuture<Void> future = network.requestBlocksByRoot(
      peer, 
      request, 
      new CollectingListener(batchBlocks)
    );
    
    batchFutures.add(future.thenApply(__ -> batchBlocks));
  }
  
  return SafeFuture.allOf(batchFutures.toArray(new SafeFuture[0]))
    .thenApply(__ -> {
      List<SignedBeaconBlock> allBlocks = new ArrayList<>();
      batchFutures.forEach(f -> allBlocks.addAll(f.join()));
      return allBlocks;
    });
}
```

---

## 10.4 使用场景

### 10.4.1 缺失父块处理
```java
// Gossip 收到区块但父块缺失
if (block.getParentRoot() not in chain) {
  fetchMissingParent(peer, block.getParentRoot());
}
```

### 10.4.2 Fork Choice 更新
```java
// 根据 attestation 获取区块
List<Bytes32> attestedRoots = getAttestedBlockRoots(attestations);
fetchBlocksByRoots(peer, attestedRoots);
```

### 10.4.3 Checkpoint 验证
```java
// 验证 checkpoint 区块
Bytes32 checkpointRoot = checkpoint.getRoot();
fetchBlocksByRoots(peer, List.of(checkpointRoot));
```

---

## 10.5 与 BeaconBlocksByRange 对比

| 特性 | BlocksByRange | BlocksByRoot |
|------|---------------|--------------|
| **请求方式** | slot 范围 | block root 列表 |
| **响应顺序** | 按 slot 有序 | 无序 |
| **最大数量** | 1024 | 128 |
| **使用场景** | 批量同步 | 补齐缺失块 |
| **性能** | 高吞吐 | 低延迟 |

---

## 10.6 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| **最大请求数** | 128 | 128 |
| **缓存策略** | LRU | Caffeine |
| **并发控制** | Semaphore | AsyncRunner |
| **错误处理** | 返回 error | RpcException |

---

## 10.7 本章总结

✅ BeaconBlocksByRoot 用于根据 root 获取指定区块  
✅ 主要用于补齐缺失父块、fork choice 更新  
✅ 最大支持 128 个 root 批量请求  
✅ 响应无序，需要客户端排序处理

**下一章**: Gossipsub 概述

---

**最后更新**: 2026-01-13
