# 第 17 章: Initial Sync 概述

> 目标：从 Nimbus 的 SyncManager 出发说明 initial sync 的“worker + queue + range 请求”主干。

## 关键代码定位

- SyncManager：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_manager.nim
- SyncQueue：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_queue.nim
- BlocksByRange handler（服务端）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_protocol.nim
