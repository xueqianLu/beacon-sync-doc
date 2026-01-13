# 第 25 章: 错误处理机制

本章介绍 Teku 中全面的错误处理策略。

---

## 25.1 错误分类

```java
public enum ErrorType {
  NETWORK_ERROR,      // 网络连接问题
  VALIDATION_ERROR,   // 验证失败
  STATE_ERROR,        // 状态计算错误
  TIMEOUT_ERROR,      // 超时
  RESOURCE_ERROR      // 资源不足
}
```

---

## 25.2 异常处理策略

```java
public class ErrorHandler {
  public <T> SafeFuture<T> handleError(
      Throwable error,
      Supplier<SafeFuture<T>> fallback) {
    
    if (error instanceof TimeoutException) {
      return fallback.get(); // 重试
    } else if (error instanceof ValidationException) {
      LOG.warn("Validation failed", error);
      return SafeFuture.failedFuture(error);
    } else {
      LOG.error("Unexpected error", error);
      return SafeFuture.failedFuture(error);
    }
  }
}
```

---

## 25.3 重试逻辑

```java
public class RetryPolicy {
  public <T> SafeFuture<T> withRetry(
      Supplier<SafeFuture<T>> operation,
      int maxRetries) {
    
    return operation.get()
      .exceptionallyCompose(error -> {
        if (maxRetries > 0 && isRetriable(error)) {
          Duration backoff = calculateBackoff(maxRetries);
          return asyncRunner.runAfterDelay(
            () -> withRetry(operation, maxRetries - 1),
            backoff
          );
        }
        return SafeFuture.failedFuture(error);
      });
  }
}
```

---

## 25.4 降级策略

```java
public class FallbackManager {
  public SafeFuture<SyncResult> syncWithFallback() {
    return optimisticSync.sync()
      .exceptionallyCompose(error -> {
        LOG.warn("Optimistic sync failed, falling back to full sync");
        return fullSync.sync();
      });
  }
}
```

---

## 25.5 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| 错误类型 | error interface | ErrorType enum |
| 重试 | 手动循环 | SafeFuture 递归 |
| 降级 | if-else | exceptionallyCompose |
| 日志 | logrus | log4j |

---

**最后更新**: 2026-01-13
