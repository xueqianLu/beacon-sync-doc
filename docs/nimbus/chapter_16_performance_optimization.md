# 第 16 章: 性能优化（Gossipsub）

> 本章聚焦 Nimbus 对 gossipsub fanout/mesh 的观测与调参（包含相关 metrics）。

## 1) Fanout/mesh 健康度指标（low/good/healthy fanout）

Nimbus 在网络层声明了 fanout 相关 gauge，并在计算“哪些 subnets 不健康”时更新它们。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
declareGauge nbc_gossipsub_low_fanout,
	"numbers of topics with low fanout"

declareGauge nbc_gossipsub_good_fanout,
	"numbers of topics with good fanout"

declareGauge nbc_gossipsub_healthy_fanout,
	"numbers of topics with dHigh fanout"
```

## 2) 计算低 fanout subnets（getLowSubnets / findLowSubnets）

这段逻辑把“topic subscription peers”与“mesh peers / outbound peers”结合起来，给出需要重点补强的 subnet 集合，并同步更新 fanout gauges。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc getLowSubnets(node: Eth2Node, epoch: Epoch): (AttnetBits, SyncnetBits, CgcBits) =
	nbc_gossipsub_low_fanout.set(0)
	nbc_gossipsub_good_fanout.set(0)
	nbc_gossipsub_healthy_fanout.set(0)

	template findLowSubnets(topicNameGenerator: untyped, SubnetIdType: type, totalSubnets: static int): auto =
		var
			lowOutgoingSubnets: BitArray[totalSubnets]
			notHighOutgoingSubnets: BitArray[totalSubnets]
			belowDSubnets: BitArray[totalSubnets]
			belowDOutSubnets: BitArray[totalSubnets]

		for subNetId in 0 ..< totalSubnets:
			let topic = topicNameGenerator(node.forkId.fork_digest, SubnetIdType(subNetId))

			if node.pubsub.gossipsub.peers(topic) < node.pubsub.parameters.dLow:
				lowOutgoingSubnets.setBit(subNetId)

			if node.pubsub.gossipsub.peers(topic) < node.pubsub.parameters.dHigh:
				notHighOutgoingSubnets.setBit(subNetId)

			# Not subscribed
			if topic notin node.pubsub.mesh: continue

			if node.pubsub.mesh.peers(topic) < node.pubsub.parameters.dLow:
				belowDSubnets.setBit(subNetId)

			let outPeers = node.pubsub.mesh.getOrDefault(topic).countIt(it.outbound)
			if outPeers < node.pubsub.parameters.dOut:
				belowDOutSubnets.setBit(subNetId)

		nbc_gossipsub_low_fanout.inc(int64(lowOutgoingSubnets.countOnes()))
		nbc_gossipsub_good_fanout.inc(int64(
			notHighOutgoingSubnets.countOnes() - lowOutgoingSubnets.countOnes()
		))
		nbc_gossipsub_healthy_fanout.inc(int64(
			totalSubnets - notHighOutgoingSubnets.countOnes()))

		if lowOutgoingSubnets.countOnes() > 0:
			lowOutgoingSubnets
		elif belowDSubnets.countOnes() > 0:
			belowDSubnets
		elif belowDOutSubnets.countOnes() > 0:
			belowDOutSubnets
		else:
			notHighOutgoingSubnets

	return (
		findLowSubnets(getAttestationTopic, SubnetId, ATTESTATION_SUBNET_COUNT.int),
		# ...sync committee / data column sidecars...
	)
```

> 这套指标更偏“运营视角”：用 gauges 快速回答“当前有多少 subnet topic 的 fanout 不健康”，并为后续订阅/连接策略提供依据。
