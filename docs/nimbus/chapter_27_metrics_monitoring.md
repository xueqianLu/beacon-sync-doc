# 第 27 章: Metrics Monitoring

> 目标：汇总 Nimbus 在网络/同步/gossip 中暴露的关键指标（throttle、断连原因、队列丢弃等）。

## 关键代码定位

- networking metrics（含 req/resp throttle、gossipsub fanout）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim
- disconnect reason counter：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_protocol.nim
- gossip dropped counters：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/gossip_validation.nim

## 1) Gossip / ReqResp 指标声明（network 层）

Nimbus 在网络层集中声明了大量 gossip/reqresp 的 counters/gauges，便于将“流量、失败、限流、peer 数量”等关键面板做成统一视图。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
declareGauge nbc_peers,
	"number of connected peers"

declareCounter nbc_gossip_messages_received,
	"number of gossip messages received"

declareCounter nbc_gossip_messages_sent,
	"number of gossip messages sent"

declareCounter nbc_gossip_failed_snappy_decompression,
	"number of snappy decompression errors in gossip messages"

declareCounter nbc_gossip_failed_ssz_serialization,
	"number of SSZ serialization errors in gossip messages"

declareCounter nbc_reqresp_messages_received,
	"number of req/resp messages received"

declareCounter nbc_reqresp_messages_sent,
	"number of req/resp messages sent"

declareCounter nbc_reqresp_messages_failed,
	"number of req/resp messages that failed"

declareCounter nbc_reqresp_messages_throttled,
	"number of req/resp messages that were rate limited"
```

## 2) 队列满导致的丢弃（queue_full drops）

对于 gossip processing/validation 侧的背压，Nimbus 暴露了“队列满丢弃”的 counters，便于快速定位是 CPU/解码/验证慢，还是输入流量异常。

来源：`beacon_chain/gossip_processing/gossip_validation.nim`

```nim
declareCounter beacon_attestations_dropped_queue_full,
	"Number of gossip attestations dropped due to full queue"

declareCounter beacon_aggregates_dropped_queue_full,
	"Number of gossip aggregates dropped due to full queue"

declareCounter beacon_sync_messages_dropped_queue_full,
	"Number of gossip sync committee messages dropped due to full queue"

declareCounter beacon_contributions_dropped_queue_full,
	"Number of gossip contributions dropped due to full queue"
```

## 3) 断连原因统计（disconnect reason）

Nimbus 在 peer 协议层统计断连次数，并带上 `agent/reason` 标签，适合用来做“断连 top reasons”和“某类错误是否在爆发”的告警。

来源：`beacon_chain/networking/peer_protocol.nim`

```nim
declareCounter nbc_disconnects_count,
	"Number of peers disconnected",
	labels = ["agent", "reason"]
```

## 4) Fanout/mesh 观测（配合第 16 章）

Fanout/mesh 的健康度 gauges 定义在 network 层，并在周期性扫描 topic/subnet 状态时更新。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
declareGauge nbc_gossipsub_low_fanout,
	"numbers of topics with low fanout"

declareGauge nbc_gossipsub_good_fanout,
	"numbers of topics with good fanout"

declareGauge nbc_gossipsub_healthy_fanout,
	"numbers of topics with dHigh fanout"
```

> 建议面板组合：`nbc_peers` + `nbc_reqresp_messages_throttled` + `*_dropped_queue_full` + `nbc_gossipsub_*_fanout`，能覆盖“连接质量/限流/背压/topic 覆盖率”四条主线。
