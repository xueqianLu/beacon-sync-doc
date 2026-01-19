# 第 12 章: 区块广播

> 本章聚焦 Nimbus 的区块 gossip 发布入口（topic 选择、编码、发布回调）以及与 block processor 的衔接。

## 1) 编码与发布（SSZ → Snappy framed → pubsub.publish）

来源：`beacon_chain/networking/eth2_network.nim`

```nim
func gossipEncode(msg: auto): seq[byte] =
	let uncompressed = SSZ.encode(msg)
	# This function only for messages we create. A message this large amounts to
	# an internal logic error.
	doAssert uncompressed.lenu64 <= MAX_PAYLOAD_SIZE

	snappy.encode(uncompressed)

proc broadcast(node: Eth2Node, topic: string, msg: seq[byte]):
		Future[SendResult] {.async: (raises: [CancelledError]).} =
	let peers = await node.pubsub.publish(topic, msg)

	# TODO remove workaround for sync committee BN/VC log spam
	if peers > 0 or find(topic, "sync_committee_") != -1:
		inc nbc_gossip_messages_sent
		ok()
	else:
		# Increments libp2p_gossipsub_failed_publish metric
		err("No peers on libp2p topic")

proc broadcast(node: Eth2Node, topic: string, msg: auto):
		Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
	# Avoid {.async.} copies of message while broadcasting
	broadcast(node, topic, gossipEncode(msg))
```

## 2) 区块广播入口：按 slot.epoch 选择 forkDigest + topic

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc broadcastBeaconBlock*(
		node: Eth2Node, blck: SomeForkySignedBeaconBlock):
		Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
	let topic = getBeaconBlocksTopic(
		node.forkDigestAtEpoch(blck.message.slot.epoch))
	node.broadcast(topic, blck)
```

> 这里体现了 Nimbus 的一个一致性点：topic 与 forkDigest 绑定到“消息的语境 epoch”（区块用 `slot.epoch`；部分消息用 wall epoch），从而与共识规范的 topic 规则对齐。
