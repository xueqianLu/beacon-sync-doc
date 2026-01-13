# 附录：业务 6 – Initial Sync 启动与模式选择

本页展示 Teku 节点启动时如何选择合适的 Initial Sync 模式（Full Sync / Checkpoint Sync / Optimistic Sync）。

---

## 业务 6：Initial Sync 启动与模式选择

### 主流程

![业务 6：Initial Sync 主线](../../img/teku/business6_initial_sync_flow.png)

**关键决策点**：
1. 是否配置了 Checkpoint？→ Checkpoint Sync
2. EL 是否同步完成？→ Optimistic Sync / Full Sync
3. 是否有可用 Peers？→ 开始同步 / 等待连接

**Teku 特点**：
```java
public class SyncModeSelector {
  public SyncMode selectMode() {
    // 1. 检查 Checkpoint 配置
    if (config.getInitialStateUrl().isPresent() || 
        config.getInitialStatePath().isPresent()) {
      return SyncMode.CHECKPOINT_SYNC;
    }
    
    // 2. 检查 EL 状态
    return executionEngine.getStatus()
      .thenApply(status -> {
        if (status.isSyncing()) {
          return SyncMode.OPTIMISTIC_SYNC;
        } else {
          return SyncMode.FULL_SYNC;
        }
      });
  }
}
```

---

## 流程图源文件

PlantUML 源文件：`img/teku/business6_initial_sync_flow.puml`

---

**最后更新**: 2026-01-13  
**参考章节**: [第 18-20 章：Initial Sync 实现](./chapter_18_full_sync.md)
