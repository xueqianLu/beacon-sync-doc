# 附录：业务 7 – Regular Sync 日常同步

本页展示 Regular Sync 在节点已完成 Initial / Checkpoint Sync 后，如何通过 Gossipsub 接收新区块、处理缺失父块，并通过 maintainSync 保持与网络头部对齐的完整流程。

---

## 业务 7：Regular Sync 日常同步

### 主流程

![业务 7：Regular Sync 主线](img/business7_regular_sync_flow.png)

> 更详细的 Regular Sync 行为说明参见：
>
> - 第 21 章 Regular Sync 概述
> - 第 22 章 Block Processing Pipeline
