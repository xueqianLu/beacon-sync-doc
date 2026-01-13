# 附录：业务 7 – Regular Sync 日常同步

本页展示 Teku 完成 Initial Sync 后的日常同步流程，包括实时跟踪、父块请求和追赶机制。

---

## 业务 7：Regular Sync 日常同步

### 主流程

![业务 7：Regular Sync 主线](../../img/teku/business7_regular_sync_flow.png)

**核心机制**：
1. **Gossipsub 实时接收**：订阅 beacon_block 主题
2. **定期 Head 检查**：每 12 秒检查是否落后
3. **缺失父块处理**：自动请求 missing parent
4. **自动追赶**：落后超过 1 epoch 触发批量同步

**Teku 特点**：
```java
public class RegularSyncService {
  public void start() {
    // 1. 订阅 Gossipsub
    gossipNetwork.subscribe(
      GossipTopics.BEACON_BLOCK,
      this::onBeaconBlock
    );
    
    // 2. 启动定期检查
    scheduler.scheduleAtFixedRate(
      this::checkHead,
      12, 12, TimeUnit.SECONDS
    );
  }
  
  private void checkHead() {
    UInt64 headLag = calculateHeadLag();
    
    if (headLag.isGreaterThan(SLOTS_PER_EPOCH)) {
      // 触发追赶
      forwardSyncService.syncRange(
        chainData.getHeadSlot(),
        chainData.getCurrentSlot()
      );
    }
  }
}
```

---

## 流程图源文件

PlantUML 源文件：`img/teku/business7_regular_sync_flow.puml`

---

**最后更新**: 2026-01-13  
**参考章节**: [第 21 章：Regular Sync 概述](./chapter_21_regular_sync.md)
