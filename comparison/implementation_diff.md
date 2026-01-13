# 实现差异分析

## 编程语言与范式

### Prysm (Go)

```go
// Go 风格：接口 + 结构体
type Service struct {
    cfg *config
    chain blockchainService
    p2p p2p.P2P
}

func (s *Service) Start() error {
    // 启动逻辑
}
```

**特点**:
- 并发模型: Goroutines + Channels
- 错误处理: 显式返回 error
- 依赖注入: 构造函数注入

### Teku (Java)

```java
// Java 风格：类 + 接口
public class SyncService {
    private final AsyncRunner asyncRunner;
    private final Eth2P2PNetwork network;
    
    public SafeFuture<Void> start() {
        // 启动逻辑返回 Future
    }
}
```

**特点**:
- 并发模型: CompletableFuture + EventBus
- 错误处理: 异常 + Optional
- 依赖注入: 构造器注入（类型安全）

---

## 架构模式

| 维度 | Prysm | Teku |
|------|-------|------|
| **并发模型** | CSP (Goroutines) | Future/Promise |
| **事件传递** | Channel | EventBus |
| **状态管理** | 共享内存 + Mutex | 不可变对象 |
| **错误传播** | 返回值 | 异常 + Result |

---

## 代码组织

### Prysm

```
sync/
├── service.go          # 主服务
├── rpc_*.go           # RPC 处理器（按协议分文件）
├── validate_*.go      # 验证逻辑
└── initial-sync/      # 子模块
```

### Teku

```
sync/
├── forward/           # Forward sync（按功能分包）
│   ├── ForwardSyncService.java
│   └── BlockManager.java
├── gossip/            # Gossip 处理
└── historical/        # 历史同步
```

---

## 性能优化手段

### Prysm
- 批量签名验证（BLS batching）
- Goroutine 池复用
- Zero-copy 序列化

### Teku
- 异步流水线（CompletableFuture chains）
- 事件驱动避免阻塞
- JVM 优化（G1GC）

---

**最后更新**: 2026-01-13
