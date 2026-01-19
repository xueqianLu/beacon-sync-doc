# 第 7 章: Teku Req/Resp 协议基础

## 7.1 Req/Resp 协议概述

### 7.1.1 协议模型

Teku 的 Req/Resp 实现完全基于异步 Future 模型：

```
Client                                Server
  │                                     │
  │──────── Request ─────────────────→ │
  │         (异步发送)                  │
  │                                    │ 处理请求
  │                                    │ (异步处理)
  │                                     │
  │←────── Response(s) ───────────────│
  │         (流式返回)                  │
  │                                     │
  │←────── Complete ──────────────────│
```

**Teku 特点**:

- 完全异步：基于 `SafeFuture<T>`
- 流式响应：`RpcResponseListener<T>`
- 类型安全：泛型指定请求/响应类型
- 资源高效：流式处理，无需缓存全部数据

---

## 7.2 核心接口设计

### 7.2.1 Eth2RpcMethod 接口

```java
package tech.pegasys.teku.networking.eth2.rpc.core;

public interface Eth2RpcMethod<TRequest, TResponse> {
  /**
   * 获取 RPC 方法的唯一标识符
   */
  String getId();

  /**
   * 获取协议版本（如 /eth2/beacon_chain/req/status/1/）
   */
  int getVersion();

  /**
   * 响应请求（服务端）
   */
  SafeFuture<Void> respond(
    TRequest request,
    RpcResponseListener<TResponse> listener
  );

  /**
   * 发送请求（客户端）
   */
  SafeFuture<Void> request(
    Peer peer,
    TRequest request,
    RpcResponseListener<TResponse> responseHandler
  );

  /**
   * 获取请求编码器
   */
  RpcRequestEncoder<TRequest> getRequestEncoder();

  /**
   * 获取响应编码器
   */
  RpcResponseEncoder<TResponse> getResponseEncoder();
}
```

**设计亮点**:

- 接口隔离：客户端/服务端方法分离
- 编码解耦：编码器可独立替换
- 泛型保证：编译期类型检查

---

### 7.2.2 RpcResponseListener 接口

```java
public interface RpcResponseListener<TResponse> {
  /**
   * 接收单个响应对象（可多次调用）
   */
  void respond(TResponse response);

  /**
   * 标记响应完成（成功）
   */
  void completeSuccessfully();

  /**
   * 标记响应失败
   */
  void completeWithError(RpcException error);
}
```

**流式响应示例**:

```java
// 服务端流式返回多个区块
public SafeFuture<Void> respondBlocks(
    BeaconBlocksByRangeRequest request,
    RpcResponseListener<SignedBeaconBlock> listener) {

  return chainDataClient
    .getBlocksByRange(request.getStartSlot(), request.getCount())
    .thenAccept(blocks -> {
      // 逐个发送区块
      for (SignedBeaconBlock block : blocks) {
        listener.respond(block);
      }
      // 标记完成
      listener.completeSuccessfully();
    })
    .exceptionally(error -> {
      listener.completeWithError(new RpcException(error));
      return null;
    });
}
```

---

## 7.3 编码与序列化

### 7.3.1 SSZ 编码器

```java
public class SszRpcRequestEncoder<T extends SszData>
    implements RpcRequestEncoder<T> {

  private final SszSchema<T> schema;

  @Override
  public Bytes encode(T request) {
    // SSZ 序列化
    return request.sszSerialize();
  }

  @Override
  public T decode(Bytes data) throws RpcException {
    try {
      // SSZ 反序列化
      return schema.sszDeserialize(data);
    } catch (Exception e) {
      throw new RpcException(
        RpcErrorCode.INVALID_REQUEST,
        "Failed to decode SSZ: " + e.getMessage()
      );
    }
  }
}
```

### 7.3.2 Snappy 压缩

```java
public class SnappyFramedEncoder implements RpcEncoder {
  private static final int MAX_COMPRESSED_SIZE = 10 * 1024 * 1024; // 10MB

  @Override
  public Bytes encode(Bytes data) throws RpcException {
    try {
      // Snappy 压缩
      byte[] compressed = Snappy.compress(data.toArray());

      if (compressed.length > MAX_COMPRESSED_SIZE) {
        throw new RpcException(
          RpcErrorCode.RESOURCE_EXHAUSTED,
          "Compressed data exceeds max size"
        );
      }

      return Bytes.wrap(compressed);
    } catch (IOException e) {
      throw new RpcException(RpcErrorCode.INTERNAL_ERROR, e);
    }
  }

  @Override
  public Bytes decode(Bytes data) throws RpcException {
    try {
      byte[] decompressed = Snappy.uncompress(data.toArray());
      return Bytes.wrap(decompressed);
    } catch (IOException e) {
      throw new RpcException(
        RpcErrorCode.INVALID_REQUEST,
        "Failed to decompress: " + e.getMessage()
      );
    }
  }
}
```

**编码流程**:

```
Request Object
    ↓
SSZ Serialize → Bytes
    ↓
Snappy Compress → Bytes
    ↓
Network Send
```

---

## 7.4 错误处理

### 7.4.1 RpcException 类型

```java
public class RpcException extends Exception {
  private final RpcErrorCode errorCode;
  private final String errorMessage;

  public enum RpcErrorCode {
    INVALID_REQUEST(1),         // 无效请求
    SERVER_ERROR(2),            // 服务器错误
    RESOURCE_EXHAUSTED(3),      // 资源耗尽
    RATE_LIMITED(128);          // 速率限制

    private final int code;
  }

  public RpcException(RpcErrorCode code, String message) {
    super(message);
    this.errorCode = code;
    this.errorMessage = message;
  }
}
```

### 7.4.2 错误响应处理

```java
public class RpcErrorHandler {
  private static final Logger LOG = LogManager.getLogger();

  public static void handleRequestError(
      RpcException error,
      RpcResponseListener<?> listener) {

    LOG.warn("RPC request failed",
      kv("errorCode", error.getErrorCode()),
      kv("message", error.getErrorMessage())
    );

    // 发送错误响应
    listener.completeWithError(error);

    // 可能断开 peer 连接（如果是严重错误）
    if (shouldDisconnectPeer(error)) {
      disconnectPeer();
    }
  }

  private static boolean shouldDisconnectPeer(RpcException error) {
    return error.getErrorCode() == RpcErrorCode.INVALID_REQUEST
        || error.getErrorCode() == RpcErrorCode.SERVER_ERROR;
  }
}
```

---

## 7.5 超时与重试

### 7.5.1 请求超时

```java
public class RpcRequestHandler {
  private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(10);
  private final AsyncRunner asyncRunner;

  public <TRequest, TResponse> SafeFuture<List<TResponse>> requestWithTimeout(
      Eth2RpcMethod<TRequest, TResponse> method,
      Peer peer,
      TRequest request) {

    List<TResponse> responses = new ArrayList<>();

    RpcResponseListener<TResponse> listener = new RpcResponseListener<>() {
      @Override
      public void respond(TResponse response) {
        responses.add(response);
      }

      @Override
      public void completeSuccessfully() {
        // 收集完成
      }

      @Override
      public void completeWithError(RpcException error) {
        throw new CompletionException(error);
      }
    };

    return method.request(peer, request, listener)
      .orTimeout(DEFAULT_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)
      .handle((result, error) -> {
        if (error instanceof TimeoutException) {
          LOG.warn("RPC request timeout", kv("peer", peer), kv("method", method.getId()));
          throw new RpcException(RpcErrorCode.RESOURCE_EXHAUSTED, "Request timeout");
        }
        return responses;
      });
  }
}
```

### 7.5.2 重试策略

```java
public class RpcRetryHandler {
  private static final int MAX_RETRIES = 3;
  private static final Duration INITIAL_BACKOFF = Duration.ofSeconds(1);

  public <T> SafeFuture<T> retryWithBackoff(
      Supplier<SafeFuture<T>> operation,
      int retriesLeft) {

    return operation.get()
      .exceptionallyCompose(error -> {
        if (retriesLeft <= 0 || !isRetriableError(error)) {
          return SafeFuture.failedFuture(error);
        }

        Duration backoff = INITIAL_BACKOFF.multipliedBy(
          (long) Math.pow(2, MAX_RETRIES - retriesLeft)
        );

        LOG.debug("Retrying RPC request",
          kv("retriesLeft", retriesLeft),
          kv("backoff", backoff)
        );

        return asyncRunner.runAfterDelay(
          () -> retryWithBackoff(operation, retriesLeft - 1),
          backoff
        );
      });
  }

  private boolean isRetriableError(Throwable error) {
    if (error instanceof RpcException) {
      RpcErrorCode code = ((RpcException) error).getErrorCode();
      return code == RpcErrorCode.RESOURCE_EXHAUSTED
          || code == RpcErrorCode.SERVER_ERROR;
    }
    return false;
  }
}
```

---

## 7.6 速率限制

### 7.6.1 Per-Peer 限流

```java
public class RpcRateLimiter {
  private final Map<Peer, RateLimiter> peerLimiters = new ConcurrentHashMap<>();
  private static final int REQUESTS_PER_SECOND = 5;

  public boolean allowRequest(Peer peer, String methodId) {
    RateLimiter limiter = peerLimiters.computeIfAbsent(
      peer,
      p -> RateLimiter.create(REQUESTS_PER_SECOND)
    );

    boolean allowed = limiter.tryAcquire();

    if (!allowed) {
      LOG.warn("Rate limit exceeded",
        kv("peer", peer),
        kv("method", methodId)
      );
    }

    return allowed;
  }

  public void onPeerDisconnected(Peer peer) {
    peerLimiters.remove(peer);
  }
}
```

### 7.6.2 全局限流

```java
public class GlobalRpcRateLimiter {
  private final RateLimiter globalLimiter;
  private static final int GLOBAL_REQUESTS_PER_SECOND = 100;

  public GlobalRpcRateLimiter() {
    this.globalLimiter = RateLimiter.create(GLOBAL_REQUESTS_PER_SECOND);
  }

  public boolean allowRequest() {
    return globalLimiter.tryAcquire(
      Duration.ofMillis(100).toNanos(),
      TimeUnit.NANOSECONDS
    );
  }
}
```

---

## 7.7 与 Prysm 对比

| 维度         | Prysm (Go)          | Teku (Java)        |
| ------------ | ------------------- | ------------------ |
| **响应模式** | Channel 流式        | Listener 回调      |
| **类型安全** | 接口 + 类型断言     | 泛型编译检查       |
| **异步处理** | Goroutine           | CompletableFuture  |
| **错误处理** | 返回 error          | RpcException       |
| **超时控制** | context.WithTimeout | Future.orTimeout() |
| **重试机制** | 手动循环            | 递归 Future        |
| **编码层**   | 独立函数            | 编码器接口         |

**Prysm 示例**:

```go
func (s *Service) sendRequest(peer *peer.Peer, req *pb.Request) error {
    stream, err := peer.Send(req)
    if err != nil {
        return err
    }

    for {
        resp, err := stream.Recv()
        if err == io.EOF {
            break
        }
        if err != nil {
            return err
        }
        handleResponse(resp)
    }
    return nil
}
```

**Teku 示例**:

```java
public SafeFuture<Void> sendRequest(Peer peer, Request req) {
  RpcResponseListener<Response> listener = new RpcResponseListener<>() {
    @Override
    public void respond(Response resp) {
      handleResponse(resp);
    }

    @Override
    public void completeSuccessfully() {
      // 完成
    }

    @Override
    public void completeWithError(RpcException error) {
      LOG.error("Request failed", error);
    }
  };

  return method.request(peer, req, listener);
}
```

---

## 7.8 性能优化

### 7.8.1 连接池管理

```java
public class RpcConnectionPool {
  private final Map<Peer, RpcStream> activeStreams = new ConcurrentHashMap<>();
  private static final int MAX_STREAMS_PER_PEER = 10;

  public SafeFuture<RpcStream> getOrCreateStream(Peer peer, String method) {
    return SafeFuture.of(() -> {
      RpcStream stream = activeStreams.computeIfAbsent(
        peer,
        p -> createNewStream(p, method)
      );

      if (!stream.isActive()) {
        activeStreams.remove(peer);
        return createNewStream(peer, method);
      }

      return stream;
    });
  }

  private RpcStream createNewStream(Peer peer, String method) {
    if (activeStreams.size() >= MAX_STREAMS_PER_PEER) {
      throw new RpcException(
        RpcErrorCode.RESOURCE_EXHAUSTED,
        "Max streams per peer exceeded"
      );
    }
    return peer.createStream(method);
  }
}
```

### 7.8.2 缓存优化

```java
public class RpcResponseCache {
  private final Cache<Bytes32, CachedResponse> cache;

  public RpcResponseCache() {
    this.cache = Caffeine.newBuilder()
      .maximumSize(1000)
      .expireAfterWrite(Duration.ofMinutes(5))
      .build();
  }

  public Optional<CachedResponse> get(Bytes32 key) {
    return Optional.ofNullable(cache.getIfPresent(key));
  }

  public void put(Bytes32 key, CachedResponse response) {
    cache.put(key, response);
  }
}
```

---

## 7.9 监控指标

```java
public class RpcMetrics {
  private final Counter requestsTotal;
  private final Counter requestsSuccess;
  private final Counter requestsFailed;
  private final Timer requestDuration;

  public RpcMetrics(MeterRegistry registry) {
    this.requestsTotal = Counter.builder("rpc_requests_total")
      .tag("method", "")
      .register(registry);

    this.requestsSuccess = Counter.builder("rpc_requests_success")
      .tag("method", "")
      .register(registry);

    this.requestsFailed = Counter.builder("rpc_requests_failed")
      .tag("method", "")
      .tag("error_code", "")
      .register(registry);

    this.requestDuration = Timer.builder("rpc_request_duration_seconds")
      .tag("method", "")
      .register(registry);
  }

  public void recordRequest(String method, Duration duration, boolean success) {
    requestsTotal.increment();

    if (success) {
      requestsSuccess.increment();
    } else {
      requestsFailed.increment();
    }

    requestDuration.record(duration);
  }
}
```

---

## 7.10 本章总结

### 关键要点

1. Teku Req/Resp 基于异步 Future + 流式监听器
2. `Eth2RpcMethod<TRequest, TResponse>` 泛型接口
3. `RpcResponseListener` 流式接收响应
4. SSZ + Snappy 编码/压缩
5. 完善的错误处理与重试机制
6. Per-Peer 和全局速率限制

### 后续章节

- **第 8 章**: Status 协议（Teku 实现）
- **第 9 章**: BeaconBlocksByRange（Teku 实现）
- **第 10 章**: BeaconBlocksByRoot（Teku 实现）

---

**参考资源**:

- Teku 代码: `networking/eth2/src/main/java/tech/pegasys/teku/networking/eth2/rpc/`
- [code_references.md](./code_references.md)
- [与 Prysm 对比](../../comparison/implementation_diff.md)

---

**最后更新**: 2026-01-13
