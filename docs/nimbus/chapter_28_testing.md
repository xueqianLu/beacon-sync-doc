# 第 28 章: Testing

> 目标：给出 Nimbus 在同步/网络/gossip 相关的测试入口，方便读者对照文档与实现。

## 推荐测试入口

- Sync manager：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/test_sync_manager.nim
- Gossip validation：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/test_gossip_validation.nim
- Networking fixtures：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/consensus_spec/test_fixture_networking.nim
- Network metadata：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/tests/test_network_metadata.nim
