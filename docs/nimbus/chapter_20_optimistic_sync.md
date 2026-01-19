# 第 20 章: Optimistic Sync

> 本章聚焦 Nimbus（nimbus-eth2 v25.12.0）在合并（Bellatrix）之后的“Optimistic Sync”实现：当执行层（EL）暂不可用或对 payload 只返回 `SYNCING/ACCEPTED` 时，CL 如何继续导入区块、如何在 forkchoiceUpdated/newPayload 后把区块从“未验证”推进为“有效/失效”，以及如何对外暴露 `execution_optimistic` 状态。

## 1) 配置入口：无 EL 仍可“乐观同步”

Nimbus 提供 `--no-el`，明确允许不连接执行层运行；此时节点会“保持 optimistic synced”，并且无法执行验证者职责。

来源：`beacon_chain/conf.nim`

```nim
noEl* {.
	defaultValue: false
	desc: "Don't use an EL. The node will remain optimistically synced and won't be able to perform validator duties"
	name: "no-el" .}: bool

optimistic* {.
	hidden # deprecated > 22.12
	desc: "Run the node in optimistic mode, allowing it to optimistically sync without an execution client (flag deprecated, always on)"
	name: "optimistic".}: Option[bool]
```

> 这也解释了 Nimbus 的一个重要定位：**optimistic 行为在实现上被当作常态（always on）**，即使你有 EL，也会经历从 `NOT_VALIDATED` 过渡到 `VALID/INVALIDATED` 的状态机。

## 2) 核心数据结构：`OptimisticStatus` 与 `BlockRef`

Nimbus 用一个简化版的 optimistic 状态枚举来表达“执行有效性”：

- `NOT_VALIDATED`：EL 未确认（或仅返回 syncing/accepted）。
- `VALID`：EL 确认有效。
- `INVALIDATED`：EL 确认无效（或认为应视为无效）。

同时，`BlockRef` 会携带 `executionBlockHash` 与 `optimisticStatus`。

来源：`beacon_chain/consensus_object_pools/block_dag.nim`

```nim
type
	OptimisticStatus* {.pure.} = enum
		# A simplified version of `PayloadStatusV1`
		# https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.6/sync/optimistic.md#helpers
		notValidated = "NOT_VALIDATED"
		valid = "VALID"
		invalidated = "INVALIDATED"

	BlockRef* = ref object
		bid*: BlockId
		executionBlockHash*: Opt[Eth2Digest]
		optimisticStatus*: OptimisticStatus
```

对于 post-merge（Bellatrix 及以后）区块，Nimbus 会把 `execution_payload.block_hash` 放进 `executionBlockHash`，并允许它以 `notValidated` 的状态进入 DAG。

来源：`beacon_chain/consensus_object_pools/block_dag.nim`

```nim
func init*(
		T: type BlockRef, root: Eth2Digest, optimisticStatus: OptimisticStatus,
		blck: bellatrix.SomeBeaconBlock | bellatrix.TrustedBeaconBlock |
					capella.SomeBeaconBlock | capella.TrustedBeaconBlock |
					deneb.SomeBeaconBlock | deneb.TrustedBeaconBlock |
					electra.SomeBeaconBlock | electra.TrustedBeaconBlock |
					fulu.SomeBeaconBlock | fulu.TrustedBeaconBlock): BlockRef =
	BlockRef.init(
		root, Opt.some blck.body.execution_payload.block_hash, optimisticStatus, blck.slot
	)
```

## 3) `is_optimistic`：对外判断规则

Nimbus 的 `ChainDAGRef.is_optimistic` 规则很直接：只要该 block 的 `optimisticStatus != VALID` 就认为是 optimistic；同时如果 block 存在于 DB 但暂时不可通过 `BlockRef` 访问（例如 orphan 或 DB 轻微不一致），会“保守地”把它当作 optimistic。

来源：`beacon_chain/consensus_object_pools/blockchain_dag.nim`

```nim
func is_optimistic*(dag: ChainDAGRef, bid: BlockId): bool =
	let blck =
		if bid.slot <= dag.finalizedHead.slot:
			dag.finalizedHead.blck
		else:
			dag.getBlockRef(bid.root).valueOr:
				# The block is part of the DB but is not reachable via `BlockRef`;
				# Report it as optimistic until it becomes reachable or gets deleted
				return true
	blck.optimisticStatus != OptimisticStatus.valid
```

## 4) 区块导入：CL 侧最小校验 + EL 返回状态映射

### 4.1 先在 CL 侧做“必须的结构校验”，再以 `NOT_VALIDATED` 进入 DAG

当 block 是 execution block 时，Nimbus 会先在 CL 侧做一些必须校验（例如 tx 不能为空、执行 block hash 需匹配、Deneb 后还会校验 versioned hashes），以避免明显垃圾数据。

来源：`beacon_chain/gossip_processing/block_processor.nim`

```nim
proc verifyPayload(
		self: ref BlockProcessor, signedBlock: ForkySignedBeaconBlock
): Result[OptimisticStatus, VerifierError] =
	const consensusFork = typeof(signedBlock).kind
	elif consensusFork >= ConsensusFork.Bellatrix:
		if signedBlock.message.is_execution_block:
			template payload(): auto =
				signedBlock.message.body.execution_payload

			if payload.transactions.anyIt(it.len == 0):
				return err(VerifierError.Invalid)
			if payload.block_hash != signedBlock.message.compute_execution_block_hash():
				return err(VerifierError.Invalid)
			when consensusFork >= ConsensusFork.Deneb:
				let blobsRes = signedBlock.message.is_valid_versioned_hashes
				if blobsRes.isErr:
					return err(VerifierError.Invalid)

			ok OptimisticStatus.notValidated
		else:
			ok OptimisticStatus.valid
```

> 这一点很关键：**optimistic 不等于完全不校验**，Nimbus 会先做一轮“成本低但能挡垃圾”的 CL 侧校验。

### 4.2 EL 的 `PayloadExecutionStatus` 映射到 `OptimisticStatus`

来源：`beacon_chain/consensus_object_pools/consensus_manager.nim`

```nim
func to*(v: PayloadExecutionStatus, T: type OptimisticStatus): T =
	case v
	of PayloadExecutionStatus.valid:
		OptimisticStatus.valid
	of PayloadExecutionStatus.syncing, PayloadExecutionStatus.accepted:
		OptimisticStatus.notValidated
	of invalid, invalid_block_hash:
		OptimisticStatus.invalidated
```

### 4.3 导入主流程：`storeBlock` 选择 optimisticStatus，然后更新 head/执行头

来源：`beacon_chain/gossip_processing/block_processor.nim`

```nim
let
	optimisticStatusRes =
		...
		elif consensusFork >= ConsensusFork.Bellatrix:
			func shouldRetry(): bool =
				not dag.is_optimistic(dag.head.bid)
			await self.consensusManager.elManager.getExecutionValidity(
				signedBlock, deadline, shouldRetry())

let optimisticStatus = ?(optimisticStatusRes or verifyPayload(self, signedBlock))
if OptimisticStatus.invalidated == optimisticStatus:
	return err(VerifierError.Invalid)

let blck =
	?dag.addHeadBlockWithParent(
		self.verifier,
		signedBlock,
		parent,
		optimisticStatus,
		onBlockAdded(dag, consensusFork, src, wallTime, ap, vm),
	)

let previousExecutionValid = dag.head.executionValid
self.consensusManager[].updateHead(wallSlot)

if optimisticStatusRes.isSome():
	await self.consensusManager.updateExecutionHead(
		deadline, retry = previousExecutionValid, self.getBeaconTime)
```

这里体现了 Nimbus 的两阶段思路：

1) 先把区块作为 `NOT_VALIDATED` 导入（通过 CL 最小校验与签名/状态机校验）。
2) 再通过 EL 的 `newPayload` / `forkchoiceUpdated` 把它推进到 `VALID/INVALIDATED`。

## 5) `forkchoiceUpdated`：何时用“optimistic head”去驱动 EL

Nimbus 的 `ConsensusManager` 会维护一个“optimistic head”（携带 `execution_block_hash`），并在满足一定条件时，用它去调用 `forkchoiceUpdated`（而不是用 forkchoice 选出来的 head）。

来源：`beacon_chain/consensus_object_pools/consensus_manager.nim`

```nim
func shouldSyncOptimistically*(
		optimisticSlot, dagSlot, wallSlot: Slot): bool =
	const minProgress = 8 * SLOTS_PER_EPOCH
	if optimisticSlot < dagSlot or optimisticSlot - dagSlot < minProgress:
		return false

	const maxAge = 2 * SLOTS_PER_EPOCH
	if optimisticSlot < max(wallSlot, maxAge.Slot) - maxAge:
		return false

	true
```

当决定“应 optimistic sync”时，Nimbus 会把 `forkchoiceUpdated` 的 payload head 指向 optimistic head，并根据 EL 返回更新 `optimisticHeadStatus`。

来源：`beacon_chain/consensus_object_pools/consensus_manager.nim`

```nim
if self[].shouldSyncOptimistically(wallSlot):
	let status = await self.forkchoiceUpdated(
		self.optimisticHead.bid.slot, self.optimisticHead.execution_block_hash,
		head.safeExecutionBlockHash, head.finalizedExecutionBlockHash,
		deadline, false,
	)

	self.optimisticHeadStatus = status.to(OptimisticStatus)

	case self.optimisticHeadStatus
	of OptimisticStatus.valid, OptimisticStatus.notValidated:
		true
	of OptimisticStatus.invalidated:
		warn "Light execution payload invalid - the execution client or the light client data is faulty",
			payloadExecutionStatus = status,
			optimisticBlockHash = self.optimisticHead.execution_block_hash
		false
```

> 这段逻辑把“optimistic head 的可信程度”与“是否继续走 optimistic 分支”直接绑定：一旦被判定为 `INVALIDATED`，会进入恢复/重选 head 的逻辑。

## 6) `OptimisticProcessor`：只做最小过滤，把验证交给 sync committee

Nimbus 还有一个专门的 `OptimisticProcessor`：它会过滤“slot 太超前/非 execution block”等无关数据，并且只允许一次一个的 backpressure；但它并不把区块当作“已验证可转发”，而是明确返回 `errIgnore("Validation delegated to sync committee")`。

来源：`beacon_chain/gossip_processing/optimistic_processor.nim`

```nim
proc validateBeaconBlock(
		self: OptimisticProcessor,
		signed_beacon_block: ForkySignedBeaconBlock,
		wallTime: BeaconTime): Result[void, ValidationError] =
	if not (signed_beacon_block.message.slot <=
			(wallTime + MAXIMUM_GOSSIP_CLOCK_DISPARITY).slotOrZero(self.timeParams)):
		return errIgnore("BeaconBlock: slot too high")

	if not signed_beacon_block.message.is_execution_block():
		return errIgnore("BeaconBlock: no execution block")

	ok()

proc processSignedBeaconBlock*(
		self: OptimisticProcessor,
		signedBlock: ForkySignedBeaconBlock): ValidationRes =
	...
	let v = self.validateBeaconBlock(signedBlock, wallTime)
	if v.isErr:
		return err(v.error)

	if self.processFut == nil:
		self.processFut = self.optimisticVerifier(
			ForkedSignedBeaconBlock.init(signedBlock))

	return errIgnore("Validation delegated to sync committee")
```

## 7) light client optimistic update：作为 optimistic 信号源之一

Nimbus 会处理 `LightClientOptimisticUpdate`，并用计数器记录接收/丢弃数量。

来源：`beacon_chain/gossip_processing/eth2_processor.nim`

```nim
proc processLightClientOptimisticUpdate*(
		self: var Eth2Processor, src: MsgSource,
		optimistic_update: ForkedLightClientOptimisticUpdate
): Result[void, ValidationError] =
	let
		wallTime = self.getCurrentBeaconTime()
		v = validateLightClientOptimisticUpdate(
			self.lightClientPool[], self.dag, optimistic_update, wallTime)
	if v.isOk():
		beacon_light_client_optimistic_update_received.inc()
	else:
		beacon_light_client_optimistic_update_dropped.inc(1, [$v.error[0]])
	v
```

## 8) 对外暴露：事件对象的 `execution_optimistic`

### 8.1 JSON 字段名：`execution_optimistic`

来源：`beacon_chain/consensus_object_pools/block_pools_types.nim`

```nim
HeadChangeInfoObject* = object
	...
	optimistic* {.serializedFieldName: "execution_optimistic".}: Opt[bool]

EventBeaconBlockObject* = object
	slot*: Slot
	block_root* {.serializedFieldName: "block".}: Eth2Digest
	optimistic* {.serializedFieldName: "execution_optimistic".}: Opt[bool]
```

### 8.2 事件填充：由 `dag.is_optimistic(...)` 计算

来源：`beacon_chain/nimbus_beacon_node.nim`

```nim
proc onBlockAdded(data: ForkedTrustedSignedBeaconBlock) =
	let optimistic =
		if node.currentSlot().epoch() >= dag.cfg.BELLATRIX_FORK_EPOCH:
			Opt.some node.dag.is_optimistic(data.toBlockId())
		else:
			Opt.none(bool)
	node.eventBus.blocksQueue.emit(
		EventBeaconBlockObject.init(data, optimistic))

proc onHeadChanged(data: HeadChangeInfoObject) =
	let eventData =
		if node.currentSlot().epoch() >= dag.cfg.BELLATRIX_FORK_EPOCH:
			var res = data
			res.optimistic = Opt.some node.dag.is_optimistic(
				BlockId(slot: data.slot, root: data.block_root))
			res
		else:
			data
	node.eventBus.headQueue.emit(eventData)
```

这也意味着：对外观察 Nimbus 是否“optimistic”，并不依赖某个单一开关，而是由 DAG 中 block 的 `optimisticStatus` 动态决定。

## 9) 恢复与安全阀：避免“已知无效 payload”被再次乐观导入

Nimbus 提供了一个隐藏的调试参数 `--debug-invalidate-block-root`，用于把某些 root 在 EL 返回 `SYNCING/ACCEPTED` 时直接当作 INVALID（避免重启后再次把已知无效分支乐观导入 fork choice）。

来源：`beacon_chain/conf.nim`

```nim
invalidBlockRoots* {.
	hidden
	desc: "List of beacon block roots that, if the EL responds with SYNCING/ACCEPTED, are treated as if their execution payload was INVALID"
	name: "debug-invalidate-block-root" .}: seq[Eth2Digest]
```

## 10) 小结

- Nimbus 把 optimistic 同步当作 Bellatrix 之后的默认工作方式：`NOT_VALIDATED → VALID/INVALIDATED` 是常态状态机。
- CL 侧会做一轮必须校验（交易非空、execution block hash、Deneb versioned hashes 等），再允许以 `NOT_VALIDATED` 导入。
- `ConsensusManager` 决定何时用“optimistic head”驱动 `forkchoiceUpdated`，并根据 EL 返回更新 optimistic 状态。
- `execution_optimistic` 字段由 `dag.is_optimistic(...)` 统一计算并贯穿 block/head/reorg/finalization 事件。
