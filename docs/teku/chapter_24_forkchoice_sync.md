# 第 24 章: Fork 选择与同步

本章介绍 Fork choice 算法与同步的集成。

---

## 24.1 LMD-GHOST 算法

```java
public class ForkChoice {
  public Bytes32 computeHead() {
    // 1. 获取 justified checkpoint
    Checkpoint justified = chainData.getJustifiedCheckpoint();
    
    // 2. 从 justified root 开始
    Bytes32 head = justified.getRoot();
    
    // 3. 应用 LMD-GHOST
    while (hasChildren(head)) {
      head = selectChildByWeight(head);
    }
    
    return head;
  }
  
  private Bytes32 selectChildByWeight(Bytes32 parent) {
    List<Bytes32> children = getChildren(parent);
    return children.stream()
      .max(Comparator.comparing(this::getWeight))
      .orElse(parent);
  }
}
```

---

## 24.2 Attestation 处理

```java
public class AttestationProcessor {
  public void onAttestation(Attestation attestation) {
    Bytes32 blockRoot = attestation.getData().getBeaconBlockRoot();
    UInt64 weight = calculateWeight(attestation);
    
    forkChoice.onAttestation(blockRoot, weight);
  }
}
```

---

## 24.3 Head 更新流程

```java
public class HeadUpdater {
  public SafeFuture<Void> updateHead() {
    return SafeFuture.of(() -> {
      Bytes32 newHead = forkChoice.computeHead();
      
      if (!newHead.equals(currentHead)) {
        reorg(currentHead, newHead);
        currentHead = newHead;
      }
      
      return null;
    });
  }
}
```

---

## 24.4 Reorg 处理

```java
public class ReorgHandler {
  public void handleReorg(Bytes32 oldHead, Bytes32 newHead) {
    LOG.warn("Chain reorg detected",
      kv("oldHead", oldHead),
      kv("newHead", newHead)
    );
    
    // 1. 回滚到公共祖先
    Bytes32 commonAncestor = findCommonAncestor(oldHead, newHead);
    rollbackTo(commonAncestor);
    
    // 2. 应用新分支
    applyBranch(commonAncestor, newHead);
    
    // 3. 更新 head
    chainData.updateHead(newHead);
  }
}
```

---

## 24.5 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| 算法 | ProtoArray | ForkChoice |
| 权重计算 | 内置 | 委托给 Spec |
| Reorg 处理 | UpdateHead | ReorgHandler |
| 性能 | 高效 | 高效 |

---

**最后更新**: 2026-01-13
