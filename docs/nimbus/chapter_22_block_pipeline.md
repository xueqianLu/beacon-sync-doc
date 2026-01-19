# 第 22 章: Block Pipeline

> 本章聚焦 Nimbus 的“入站消息 → 校验 → quarantine → processor → DAG/数据库”的流水线结构，重点放在**区块/sidecar**在 gossip 与同步场景下如何进入处理队列，并最终落到 ChainDAG 与数据库。

## 关键代码定位

- Gossip validation：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/gossip_validation.nim
- Block processor：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/block_processor.nim
- Eth2 processor：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/eth2_processor.nim

## 0) 总览：从“看起来正确”到“写入 DAG/DB”

Nimbus 的流水线可以用一句话概括：

1) `Eth2Processor` 接收 gossipsub 入站消息并做**gossip validation**（尽量无副作用）。
2) 对通过验证的消息，将其送入 `BlockProcessor`（带 backpressure/队列）。
3) `BlockProcessor` 执行更重的验证、处理缺父/缺 sidecar 的 quarantine、做（可能的）EL 校验，并最终写入 DAG/DB。

下面的片段分别对应这三段链路。

## 1) 入站入口：`Eth2Processor.processSignedBeaconBlock`

`Eth2Processor` 在完成基础检查（例如 genesis 之后）后，会调用 `dag.validateBeaconBlock(...)` 做 gossip validation；通过后将 block（以及必要时的 sidecar）交给 `blockProcessor.enqueueBlock(...)`。

来源：`beacon_chain/gossip_processing/eth2_processor.nim`

```nim
proc processSignedBeaconBlock*(
		self: var Eth2Processor, src: MsgSource,
		signedBlock: ForkySignedBeaconBlock,
		maybeFinalized: bool = false): ValidationRes =
	...
	self.dag.validateBeaconBlock(self.quarantine, signedBlock, wallTime, {}).isOkOr:
		debug "Dropping block", err = error
		self.blockProcessor[].dumpInvalidBlock(signedBlock)
		beacon_blocks_dropped.inc(1, [$error[0]])
		return err(error)

	trace "Block validated"

	...

	self.blockProcessor.enqueueBlock(
		src, signedBlock, sidecarsOpt, maybeFinalized, validationDur)

	beacon_blocks_received.inc()
	beacon_block_delay.observe(delay.toFloatSeconds())

	ok()
```

## 2) quarantine（入站侧）：block 到了但 sidecar 还没到

Nimbus 会在入站时尝试从 sidecar quarantine（例如 `blobQuarantine`）里取出与该 block 匹配的 sidecar。如果取不到，会把 block 标记为“sidecarless”并先放进 quarantine，等待后续 sidecar 抵达再继续处理。

来源：`beacon_chain/gossip_processing/eth2_processor.nim`

```nim
elif consensusFork in ConsensusFork.Deneb .. ConsensusFork.Electra:
	let sidecarsOpt = self.blobQuarantine[].popSidecars(signedBlock.root, signedBlock)
	if sidecarsOpt.isNone():
		self.quarantine[].addSidecarless(signedBlock)
		return ok()
```

> 这一步把“网络乱序到达”的复杂性挡在 `BlockProcessor` 外部：只有当 block + 必要 sidecar 齐了，才会进入后续更重的处理。

## 3) processor（入站到处理）：`enqueueBlock` 与“只处理 head 以后的块”

`enqueueBlock` 会把 finalized head 之前的块作为 backfill 快速路径处理；否则进入常规队列（异步任务）。

来源：`beacon_chain/gossip_processing/block_processor.nim`

```nim
proc enqueueBlock*(
		self: ref BlockProcessor,
		src: MsgSource,
		blck: ForkySignedBeaconBlock,
		sidecarsOpt: SomeOptSidecars,
		maybeFinalized = false,
		validationDur = Duration(),
) =
	if blck.message.slot <= self.consensusManager.dag.finalizedHead.slot:
		discard self[].storeBackfillBlock(blck, sidecarsOpt)
		return

	discard self.addBlock(src, blck, sidecarsOpt, maybeFinalized, validationDur)
```

## 4) `storeBlock`：写入 DAG/数据库的主入口（重验证 + optimistic/EL）

Nimbus 在 `storeBlock` 的注释里明确它是“所有未验证区块的主入口”，无论来源是 gossip 还是同步请求。

来源：`beacon_chain/gossip_processing/block_processor.nim`

```nim
proc storeBlock(
		self: ref BlockProcessor,
		src: MsgSource,
		wallTime: BeaconTime,
		signedBlock: ForkySignedBeaconBlock,
		sidecarsOpt: SomeOptSidecars,
		maybeFinalized: bool,
		queueTick: Moment,
		validationDur: Duration,
): Future[Result[BlockRef, VerifierError]] {.async: (raises: [CancelledError]).} =
	## storeBlock is the main entry point for unvalidated blocks
	## - all untrusted blocks, regardless of origin, pass through here.
	...
	let parent = ?dag.checkHeadBlock(signedBlock)
	...
	let blck =
		?dag.addHeadBlockWithParent(
			self.verifier,
			signedBlock,
			parent,
			optimisticStatus,
			onBlockAdded(dag, consensusFork, src, wallTime, ap, vm),
		)
	...
```

从“pipeline 的切分点”来看：

- `Eth2Processor`：做 gossip validation（尽量无副作用）+ 入队。
- `BlockProcessor.storeBlock`：做重验证/依赖处理/（必要时）EL 校验，最终写入 DAG/DB。

## 5) quarantine（处理侧）：父块到来后把“解除孤儿”的块重新入队

当某个父块被成功写入 DAG 后，`BlockProcessor` 会从 quarantine 中把依赖它的块取出，重新走一遍 `enqueueBlock`。

来源：`beacon_chain/gossip_processing/block_processor.nim`

```nim
proc enqueueQuarantine(self: ref BlockProcessor, parent: BlockRef) =
	let
		dag = self.consensusManager[].dag
		quarantine = self.consensusManager[].quarantine

	for quarantined in quarantine[].pop(parent.root):
		debug "Block from quarantine", parent, quarantined = shortLog(quarantined.root)
		...
		self.enqueueBlock(MsgSource.gossip, forkyBlck, sidecarsOpt)
```

## 6) backpressure：`addBlock` 强调“只处理一个”

为了避免并发处理区块导致的状态竞争，Nimbus 把 `addBlock` 定义为“只允许一个区块在处理”的入口（调用方需要为并发/背压负责）。

来源：`beacon_chain/gossip_processing/block_processor.nim`

```nim
proc addBlock*(
		self: ref BlockProcessor,
		src: MsgSource,
		blck: ForkySignedBeaconBlock,
		sidecarsOpt: SomeOptSidecars,
		maybeFinalized = false,
		validationDur = Duration(),
): Future[Result[void, VerifierError]] {.async: (raises: [CancelledError]).} =
	## Enqueue a Gossip-validated block for consensus verification - only one
	## block at a time gets processed
	# Backpressure:
	#   Callers that don't await the returned future are responsible for implementing
	#   their own backpressure handling
	...
```

## 7) 小结

- 入站侧：`Eth2Processor` 负责 gossip validation，并把 block/sidecar 组装好后投递到 `BlockProcessor`。
- 处理侧：`BlockProcessor.storeBlock` 是落库/入 DAG 的核心入口；缺依赖会进入 quarantine，依赖满足后重入队。
- 并发控制：`addBlock` 明确强调一次只处理一个块，避免状态竞争。
