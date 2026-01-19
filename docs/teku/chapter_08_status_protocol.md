# 第 8 章: Teku Status 协议实现

## 8.1 Status 协议概述

Status 协议是 Eth2 节点间握手的第一步，用于交换节点状态信息。

### 8.1.1 协议标识

```
/eth2/beacon_chain/req/status/1/ssz_snappy
```

### 8.1.2 消息结构

```java
public class StatusMessage implements SszData {
  private final Bytes4 forkDigest;
  private final Bytes32 finalizedRoot;
  private final UInt64 finalizedEpoch;
  private final Bytes32 headRoot;
  private final UInt64 headSlot;

  // Getters...
}
```

---

## 8.2 StatusMessageHandler 实现

```java
public class StatusMessageHandler
    implements Eth2RpcMethod<StatusMessage, StatusMessage> {

  private final RecentChainData recentChainData;
  private final PeerManager peerManager;

  @Override
  public String getId() {
    return "/eth2/beacon_chain/req/status/1/";
  }

  @Override
  public SafeFuture<Void> respond(
      StatusMessage request,
      RpcResponseListener<StatusMessage> listener) {

    return SafeFuture.of(() -> {
      // 验证请求
      if (!isValidStatus(request)) {
        listener.completeWithError(
          new RpcException(RpcErrorCode.INVALID_REQUEST, "Invalid status")
        );
        return null;
      }

      // 获取本地状态
      StatusMessage ourStatus = getCurrentStatus();

      // 发送响应
      listener.respond(ourStatus);
      listener.completeSuccessfully();

      return null;
    });
  }

  private StatusMessage getCurrentStatus() {
    return new StatusMessage(
      recentChainData.getCurrentForkInfo().getForkDigest(),
      recentChainData.getFinalizedCheckpoint().getRoot(),
      recentChainData.getFinalizedCheckpoint().getEpoch(),
      recentChainData.getBestBlockRoot().orElse(Bytes32.ZERO),
      recentChainData.getHeadSlot()
    );
  }

  private boolean isValidStatus(StatusMessage status) {
    // 验证 fork digest
    if (!isCompatibleForkDigest(status.getForkDigest())) {
      return false;
    }

    // 验证 slot/epoch 一致性
    if (status.getHeadSlot().isLessThan(
        status.getFinalizedEpoch().times(SLOTS_PER_EPOCH))) {
      return false;
    }

    return true;
  }
}
```

---

## 8.3 握手流程

### 8.3.1 客户端发起握手

```java
public class PeerHandshaker {
  private final StatusMessageHandler statusHandler;

  public SafeFuture<PeerStatus> handshake(Peer peer) {
    StatusMessage ourStatus = statusHandler.getCurrentStatus();

    return statusHandler.request(peer, ourStatus,
      new StatusResponseListener(peer)
    ).thenApply(__ -> {
      LOG.info("Handshake successful", kv("peer", peer));
      return PeerStatus.CONNECTED;
    });
  }

  private class StatusResponseListener
      implements RpcResponseListener<StatusMessage> {

    private final Peer peer;
    private StatusMessage peerStatus;

    @Override
    public void respond(StatusMessage response) {
      this.peerStatus = response;

      // 检查兼容性
      if (!isCompatible(response)) {
        throw new IncompatiblePeerException(
          "Fork digest mismatch: " + response.getForkDigest()
        );
      }

      // 更新 peer 状态
      peer.updateStatus(response);
    }

    @Override
    public void completeSuccessfully() {
      LOG.debug("Status exchange complete",
        kv("peer", peer),
        kv("peerHead", peerStatus.getHeadSlot())
      );
    }

    @Override
    public void completeWithError(RpcException error) {
      LOG.warn("Status exchange failed",
        kv("peer", peer),
        kv("error", error.getMessage())
      );
      peer.disconnect("Status handshake failed");
    }
  }
}
```

### 8.3.2 兼容性检查

```java
public class ForkCompatibilityChecker {
  private final ForkInfo currentFork;

  public boolean isCompatible(StatusMessage peerStatus) {
    // 检查 fork digest
    if (!peerStatus.getForkDigest().equals(currentFork.getForkDigest())) {
      LOG.warn("Incompatible fork",
        kv("ourFork", currentFork.getForkDigest()),
        kv("peerFork", peerStatus.getForkDigest())
      );
      return false;
    }

    // 检查 finalized checkpoint
    if (peerStatus.getFinalizedEpoch().isGreaterThan(
        currentFork.getFinalizedEpoch().plus(WEAK_SUBJECTIVITY_PERIOD))) {
      LOG.warn("Peer too far ahead",
        kv("peerEpoch", peerStatus.getFinalizedEpoch())
      );
      return false;
    }

    return true;
  }
}
```

---

## 8.4 与 Prysm 对比

| 特性       | Prysm          | Teku                |
| ---------- | -------------- | ------------------- |
| 握手触发   | 连接建立后立即 | 连接建立后立即      |
| 状态验证   | 同步验证       | 异步 Future         |
| 不兼容处理 | 立即断开       | 异常 + 断开         |
| 状态更新   | Peer 结构体    | Peer.updateStatus() |

---

## 8.5 本章总结

- Status 协议用于节点握手和兼容性检查
- Teku 使用异步 Future + Listener 模式
- 包含 fork digest、finalized、head 状态
- 不兼容 peer 立即断开连接

**下一章**: BeaconBlocksByRange 实现

---

**最后更新**: 2026-01-13
