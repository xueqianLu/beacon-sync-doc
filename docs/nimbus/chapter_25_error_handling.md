# 第 25 章: Error Handling

> 目标：说明 Nimbus 在 req/resp 与 gossip 两条路径上的错误分类、超时与断连策略。

## Req/Resp 常见错误面

- 响应码解析与 error response：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim
- Status 校验失败与断连：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_protocol.nim

## 限流与配额（throttle）

- peer/network quota：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim
