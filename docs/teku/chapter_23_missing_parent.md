# 第 23 章: 缺失父块处理

本章介绍 Teku 如何检测和填补缺失的父块。

---

## 23.1 缺失检测

```java
public class MissingParentDetector {
  public boolean hasMissingParent(SignedBeaconBlock block) {
    Bytes32 parentRoot = block.getParentRoot();
    return !chainData.containsBlock(parentRoot);
  }
}
```

---

## 23.2 请求策略

```java
public class ParentBlockFetcher {
  public SafeFuture<SignedBeaconBlock> fetchParent(
      Bytes32 parentRoot) {
    
    return selectBestPeer()
      .thenCompose(peer -> 
        peer.requestBlocksByRoot(List.of(parentRoot))
      )
      .thenApply(blocks -> blocks.get(0));
  }
}
```

---

## 23.3 缓存管理

```java
public class PendingBlocksCache {
  private final Map<Bytes32, SignedBeaconBlock> pendingBlocks = 
    new ConcurrentHashMap<>();
  
  public void addPendingBlock(SignedBeaconBlock block) {
    pendingBlocks.put(block.getRoot(), block);
  }
  
  public void processPendingBlocks(Bytes32 parentRoot) {
    List<SignedBeaconBlock> ready = findBlocksWithParent(parentRoot);
    ready.forEach(this::importBlock);
  }
}
```

---

## 23.4 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| 检测 | receivedBlocksLastEpoch | hasMissingParent |
| 请求 | BeaconBlocksByRoot | requestBlocksByRoot |
| 缓存 | slotToPendingBlocks | PendingBlocksCache |
| 重试 | 3 次 | 指数退避 |

---

**最后更新**: 2026-01-13
