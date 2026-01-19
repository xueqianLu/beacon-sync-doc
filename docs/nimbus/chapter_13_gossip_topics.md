# 第 13 章: Gossip Topics

> 本章聚焦 Nimbus 的 topic 命名、订阅策略，以及 subnet/topic 参数配置。

## 关键代码定位

- topic 参数：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/topic_params.nim

## 1) TopicParams：不同 topic 的评分参数配置

Nimbus 将 gossipsub 的 topic 评分参数集中在 `topic_params.nim`（例如 block topic、attestation subnet topic、sync committee subnet topic）。

来源：`beacon_chain/networking/topic_params.nim`

```nim
func getBlockTopicParams*(timeParams: TimeParams): TopicParams =
	let meshInfo =
		MeshMessageInfo.init(timeParams.epochsDuration(5), 3.0'f64,
												 timeParams.epochsDuration(1))
	timeParams.topicParams(
		BeaconBlockWeight, 1.0'f64, timeParams.epochsDuration(20),
		Opt.some(meshInfo))

func getAttestationSubnetTopicParams*(
		timeParams: TimeParams, validatorsCount: uint64): TopicParams =
	let
		committeesPerSlot = get_committee_count_per_slot(validatorsCount)
		multipleBurstsPerSubnetPerEpoch =
			committeesPerSlot >= 2 * ATTESTATION_SUBNET_COUNT div SLOTS_PER_EPOCH
		topicWeight = 1.0'f64 / float64(ATTESTATION_SUBNET_COUNT)
		messageRate =
			float64(validatorsCount) / float64(ATTESTATION_SUBNET_COUNT) /
			float64(SLOTS_PER_EPOCH)
		firstMessageDecayTime =
			if multipleBurstsPerSubnetPerEpoch: timeParams.epochsDuration(1)
			else: timeParams.epochsDuration(4)
		meshMessageDecayTime =
			if multipleBurstsPerSubnetPerEpoch: timeParams.epochsDuration(4)
			else: timeParams.epochsDuration(16)
	# ...mesh activation/caps...
	timeParams.topicParams(topicWeight, messageRate, firstMessageDecayTime, Opt.some(meshInfo))
```

## 2) Subnet topic 的订阅：Attestation subnets

订阅时会根据 `forkDigest` 与 `subnet_id` 组合得到 topic（topic 构造函数来自同目录的 topic 命名模块），并绑定 `TopicParams`。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc subscribeAttestationSubnets*(
		node: Eth2Node, subnets: AttnetBits, forkDigest: ForkDigest,
		topicParams: TopicParams) =
	for subnet_id, enabled in subnets:
		if enabled:
			node.subscribe(getAttestationTopic(
				forkDigest, SubnetId(subnet_id)), topicParams)

proc unsubscribeAttestationSubnets*(
		node: Eth2Node, subnets: AttnetBits, forkDigest: ForkDigest) =
	for subnet_id, enabled in subnets:
		if enabled:
			node.unsubscribe(getAttestationTopic(forkDigest, SubnetId(subnet_id)))
```
