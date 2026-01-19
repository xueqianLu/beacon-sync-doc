# 第 21 章: Regular Sync 概述

> 目标：说明 Nimbus 在常态同步中如何结合 gossip（主通道）与 req/resp（补齐/回填）保持 head 跟进。

## 关键代码定位

- Gossip 校验与处理：
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/gossip_validation.nim
  - https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/block_processor.nim
- 缺块补齐（ByRoot 聚合 + 并行请求）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/request_manager.nim
