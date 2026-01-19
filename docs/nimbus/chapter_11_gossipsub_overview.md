# 第 11 章: Gossipsub 概述

> 目标：标注 Nimbus 在网络层如何集成 gossipsub，以及它如何处理 message size / snappy 解压与 topic 相关逻辑。

## 关键代码定位

- pubsub/gossipsub 集成与消息编解码（含 `MAX_PAYLOAD_SIZE` 限制）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim

## 1) Gossip 消息大小上限（gossipMaxSize）

Nimbus 在解压 gossip 消息前，会基于消息类型计算最大允许的解压后大小，并确保不超过 `MAX_PAYLOAD_SIZE`。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
func chunkMaxSize[T](): uint32 =
	when isFixedSize(T):
		uint32 fixedPortionSize(T)
	else:
		static: doAssert MAX_PAYLOAD_SIZE < high(uint32).uint64
		MAX_PAYLOAD_SIZE.uint32

template gossipMaxSize(T: untyped): uint32 =
	const maxSize = static:
		when isFixedSize(T):
			fixedPortionSize(T).uint32
		elif T is bellatrix.SignedBeaconBlock or T is capella.SignedBeaconBlock or
				 T is deneb.SignedBeaconBlock or T is electra.SignedBeaconBlock or
				 T is fulu.SignedBeaconBlock or T is fulu.DataColumnSidecar or
				 T is gloas.SignedBeaconBlock or T is gloas.DataColumnSidecar:
			MAX_PAYLOAD_SIZE
		elif T is phase0.Attestation or T is phase0.AttesterSlashing or
				 T is phase0.SignedAggregateAndProof or T is phase0.SignedBeaconBlock or
				 T is electra.SignedAggregateAndProof or T is electra.Attestation or
				 T is electra.AttesterSlashing or T is altair.SignedBeaconBlock or
				 T is SomeForkyLightClientObject:
			MAX_PAYLOAD_SIZE
		else:
			{.fatal: "unknown type " & name(T).}
	static: doAssert maxSize <= MAX_PAYLOAD_SIZE
	maxSize.uint32
```

## 2) GossipSub 初始化与 msgIdProvider（snappy decode + gossipId）

Nimbus 在 `createEth2Node` 初始化 GossipSub，msgIdProvider 会先尝试对消息做 snappy 解压（上限为 `MAX_PAYLOAD_SIZE`），再计算 `gossipId`。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
func msgIdProvider(m: messages.Message): Result[seq[byte], ValidationResult] =
	try:
		# This doesn't have to be a tight bound, just enough to avoid denial of service attacks.
		let decoded = snappy.decode(m.data, static(MAX_PAYLOAD_SIZE.uint32))
		ok(gossipId(decoded, phase0Prefix, m.topic))
	except CatchableError:
		err(ValidationResult.Reject)

let
	params = GossipSubParams.init(
		floodPublish = true,
		d = 8,
		dLow = 6,
		dHigh = 12,
		dOut = 6 div 2,
		heartbeatInterval = chronos.milliseconds(700),
		historyLength = 6,
		historyGossip = 3,
		fanoutTTL = chronos.seconds(60),
		disconnectBadPeers = true,
		directPeers = directPeers,
	)
	pubsub = GossipSub.init(
		switch = switch,
		msgIdProvider = msgIdProvider,
		# We process messages in the validator, so we don't need data callbacks
		triggerSelf = false,
		sign = false,
		verifySignature = false,
		anonymize = true,
		maxMessageSize = static(MAX_PAYLOAD_SIZE.int),
		parameters = params,
	)
```

## 3) 校验入口（addValidator）：snappy decode → SSZ decode → 业务校验

Nimbus 的 gossipsub validator 在 `eth2_network.nim` 做通用解码与指标统计，然后调用具体消息类型的 `msgValidator`（业务校验逻辑通常在 `gossip_processing/*`）。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
func addValidator*[MsgType](node: Eth2Node, topic: string, msgValidator: ValidationSyncProc[MsgType]) =
	proc execValidator(topic: string, message: GossipMsg): Future[ValidationResult] {.raises: [].} =
		inc nbc_gossip_messages_received
		trace "Validating incoming gossip message", len = message.data.len, topic

		var decompressed = snappy.decode(message.data, gossipMaxSize(MsgType))
		let res = if decompressed.len > 0:
			try:
				let decoded = SSZ.decode(decompressed, MsgType)
				decompressed = newSeq[byte](0) # release memory before validating
				msgValidator(decoded, message.fromPeer)
			except SerializationError:
				inc nbc_gossip_failed_ssz
				ValidationResult.Reject
		else:
			inc nbc_gossip_failed_snappy
			ValidationResult.Reject

		newValidationResultFuture(res)

	node.validTopics.incl topic
	node.pubsub.addValidator(topic, execValidator)
```
