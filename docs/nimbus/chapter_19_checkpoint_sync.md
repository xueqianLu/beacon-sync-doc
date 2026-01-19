# 第 19 章: Checkpoint Sync

> 本章聚焦 Nimbus（nimbus-eth2 v25.12.0）在“弱主观性（Weak Subjectivity）边界”之外如何引导节点安全启动，并梳理其 checkpoint/anchor（可信起点）相关实现路径。

Nimbus 这里的“checkpoint sync / long-range sync”不是单一开关，而是由以下几类输入共同决定：

- 用户显式提供弱主观性 checkpoint（用来做安全性校验）。
- 节点是否从一个“finalized checkpoint state（SSZ 状态快照）”启动。
- 是否配置外部 Beacon API（trusted node sync / anchor）。
- `SyncOverseer` 在启动时根据“是否仍处在 WS period”分流同步策略。

## 1) 弱主观性 checkpoint：CLI 参数与解析格式

Nimbus 通过 `--weak-subjectivity-checkpoint` 接收弱主观性 checkpoint，格式要求为 `block_root:epoch_number`。

来源：`beacon_chain/conf.nim`

```nim
weakSubjectivityCheckpoint* {.
	desc: "Weak subjectivity checkpoint in the format block_root:epoch_number"
	name: "weak-subjectivity-checkpoint" .}: Option[Checkpoint]

func parseCmdArg*(T: type Checkpoint, input: string): T
								 {.raises: [ValueError].} =
	let sepIdx = find(input, ':')
	if sepIdx == -1 or sepIdx == input.len - 1:
		raise newException(ValueError,
			"The weak subjectivity checkpoint must be provided in the `block_root:epoch_number` format")
	var root: Eth2Digest
	hexToByteArrayStrict(input.toOpenArray(0, sepIdx - 1), root.data)
	T(root: root, epoch: parseBiggestUInt(input[sepIdx + 1 .. ^1]).Epoch)
```

这个 checkpoint 的用途是“安全边界校验”：节点启动后会用当前链头状态与 wall-clock slot 调用 `is_within_weak_subjectivity_period`，如果 checkpoint 已经“过期（stale）”，Nimbus 会直接退出，避免在 WS 边界外继续依赖不可信历史。

## 2) 以“finalized checkpoint state（SSZ 状态）”初始化数据库

Nimbus 支持通过 `--finalized-checkpoint-state` 指定“近期 finalized 的状态快照（SSZ）”，用于空数据库启动时的初始化。实现上会：

- 从文件读取并 SSZ 解码为 `ForkedHashedBeaconState`。
- 强制要求该 state 对应 epoch slot（`slot.is_epoch`），否则拒绝。
- 只有在 DB 尚未初始化时才允许从 checkpoint state 启动；若 DB 已存在则直接报错退出。

来源：`beacon_chain/nimbus_beacon_node.nim`

```nim
let checkpointState = if config.finalizedCheckpointState.isSome:
	let checkpointStatePath = config.finalizedCheckpointState.get.string
	let tmp = try:
		newClone(readSszForkedHashedBeaconState(
			cfg, readAllBytes(checkpointStatePath).tryGet()))
	except SszError as err:
		fatal "Checkpoint state loading failed",
					err = formatMsg(err, checkpointStatePath)
		return Opt.none(BeaconNode)

	if not getStateField(tmp[], slot).is_epoch:
		fatal "--finalized-checkpoint-state must point to a state for an epoch slot",
					slot = getStateField(tmp[], slot)
		return Opt.none(BeaconNode)
	tmp
else:
	nil

...

if not ChainDAGRef.isInitialized(db).isOk():
	...
	if not checkpointState.isNil:
		if genesisState.isNil or
				getStateField(checkpointState[], slot) != GENESIS_SLOT:
			ChainDAGRef.preInit(db, checkpointState[])
elif not checkpointState.isNil:
	fatal "A database already exists, cannot start from given checkpoint",
				dataDir = config.dataDir
	return Opt.none(BeaconNode)
```

从同步模块视角理解：这条路径相当于“手动注入一个可信的 finalized 状态起点”，后续再进入 forward sync/backfill 等常规流程收敛。

## 3) anchor/trusted 起点：external Beacon API + trusted root/stateId

除了本地 SSZ checkpoint state，Nimbus 也支持在“数据库为空”时通过外部 Beacon API 进行 trusted node sync。这里的 anchor 由两类输入决定：

- `stateId`（例如 `"finalized"`）。
- `trustedBlockRoot`（近期可信 finalized block root）。

来源：`beacon_chain/nimbus_beacon_node.nim`

```nim
proc doRunTrustedNodeSync(
		db: BeaconChainDB,
		metadata: Eth2NetworkMetadata,
		databaseDir: string,
		eraDir: string,
		restUrl: string,
		stateId: Option[string],
		trustedBlockRoot: Option[Eth2Digest],
		backfill: bool,
		reindex: bool,
		genesisState: ref ForkedHashedBeaconState,
) {.async: (raises: [CancelledError]).} =
	let syncTarget =
		if stateId.isSome:
			if trustedBlockRoot.isSome:
				warn "Ignoring `trustedBlockRoot`, `stateId` is set",
					stateId, trustedBlockRoot
			TrustedNodeSyncTarget(
				kind: TrustedNodeSyncKind.StateId,
				stateId: stateId.get)
		elif trustedBlockRoot.isSome:
			TrustedNodeSyncTarget(
				kind: TrustedNodeSyncKind.TrustedBlockRoot,
				trustedBlockRoot: trustedBlockRoot.get)
		else:
			TrustedNodeSyncTarget(
				kind: TrustedNodeSyncKind.StateId,
				stateId: "finalized")

	await db.doTrustedNodeSync(
		metadata.cfg,
		databaseDir,
		eraDir,
		restUrl,
		syncTarget,
		backfill,
		reindex,
		genesisState)
```

这段逻辑体现了 Nimbus 对 anchor 的优先级处理：如果 `stateId` 明确给定，则会忽略 `trustedBlockRoot`（并记录 warn）；两者都不提供时，默认用 `"finalized"`。

## 4) 启动时的弱主观性校验：stale 直接退出

节点启动后如果配置了 `--weak-subjectivity-checkpoint`，Nimbus 会进行一次 WS 校验；若 checkpoint stale 则直接退出。

来源：`beacon_chain/nimbus_beacon_node.nim`

```nim
proc checkWeakSubjectivityCheckpoint(
		dag: ChainDAGRef,
		wsCheckpoint: Checkpoint,
		beaconClock: BeaconClock) =
	let
		currentSlot = beaconClock.currentSlot
		isCheckpointStale = not is_within_weak_subjectivity_period(
			dag.cfg, currentSlot, dag.headState, wsCheckpoint)

	if isCheckpointStale:
		error "Weak subjectivity checkpoint is stale",
					currentSlot, checkpoint = wsCheckpoint,
					headStateSlot = getStateField(dag.headState, slot)
		quit 1
```

同时 Nimbus 也会检查 backfill（历史回填）数据库的 tail 是否还在 WS period 内；若不在则清空重置（避免继续使用过期的“非最终确定历史”）。

来源：`beacon_chain/nimbus_beacon_node.nim`

```nim
if res.handle.isSome() and res.tail().isSome():
	if not(isSlotWithinWeakSubjectivityPeriod(dag, res.tail.get().slot())):
		notice "Backfill database is outdated (outside of weak subjectivity period), resetting database",
					 path = config.databaseDir(),
					 tail = shortLog(res.tail)
		res.clear().isOkOr:
			fatal "Unable to reset backfill database",
						path = config.databaseDir(), reason = error
			return Opt.none(BeaconNode)
```

## 5) SyncOverseer：WS period 内/外分流 + long-range sync 模式

在 Nimbus 的同步编排中，`SyncOverseer.mainLoop` 会先判断当前是否仍处在 WS period：

- **在 WS period 内**：可以启动 forward sync，并按需做 backfill。
- **在 WS period 外**：若 `LongRangeSyncMode.Lenient`，会“仅启动 forward sync”；若 `LongRangeSyncMode.Light`，则进入“untrusted download + state rebuild + 再启动 forward sync”的流程。

### 5.1 WS period 判断（以 headState 构造 checkpoint）

来源：`beacon_chain/sync/sync_overseer.nim`

```nim
proc isWithinWeakSubjectivityPeriod(
		overseer: SyncOverseerRef, slot: Slot): bool =
	let
		dag = overseer.consensusManager.dag
		currentSlot = overseer.getWallSlot()
		checkpoint = Checkpoint(
			epoch:
				getStateField(dag.headState, slot).epoch(),
			root:
				getStateField(dag.headState, latest_block_header).state_root)
	is_within_weak_subjectivity_period(
		dag.cfg, currentSlot, dag.headState, checkpoint)
```

### 5.2 WS period 外的分支（Lenient vs Light）

来源：`beacon_chain/sync/sync_overseer.nim`

```nim
if overseer.isWithinWeakSubjectivityPeriod(currentSlot):
	overseer.syncKind = SyncKind.ForwardSync
	overseer.forwardSync.start()
	if dag.needsBackfill():
		overseer.syncKind = SyncKind.TrustedNodeSync
		asyncSpawn overseer.startBackfillTask()
	return
else:
	if dag.needsBackfill():
		error "Trusted node sync started too long time ago"
		quit 1

	if overseer.config.longRangeSync == LongRangeSyncMode.Lenient:
		overseer.syncKind = SyncKind.ForwardSync
		overseer.forwardSync.start()
		return

	if overseer.config.longRangeSync == LongRangeSyncMode.Light:
		...
		if isUntrustedBackfillEmpty(clist):
			overseer.untrustedInProgress = true
			overseer.syncKind = SyncKind.UntrustedSyncInit
			await overseer.initUntrustedSync()
		overseer.syncKind = SyncKind.UntrustedSyncDownload
		overseer.untrustedSync.start()
		await overseer.untrustedSync.join()

		notice "Start state rebuilding process"
		let blockProcessingFut = overseer.blockProcessingLoop()
		overseer.syncKind = SyncKind.UntrustedSyncRebuild
		await overseer.rebuildState()
		...
		overseer.syncKind = SyncKind.ForwardSync
		overseer.forwardSync.start()
```

从文档角度理解：`Light` 模式把 WS period 外的同步拆成两段——先下载一段不完全可信的历史（untrusted），再本地重建状态，最后回到 forward sync 完成收敛。

## 6) 小结：Nimbus 的 checkpoint/anchor 组合拳

- `--weak-subjectivity-checkpoint`：提供一个安全边界的校验锚点（stale 直接退出）。
- `--finalized-checkpoint-state`：允许空库从“可信 finalized state”直接起步（同时要求 epoch slot）。
- `--external-beacon-api-url` + `--trusted-block-root`/`stateId`：允许通过外部 API 做 trusted node sync，快速获得可信起点。
- `SyncOverseer` 的 `Light/Lenient` long-range sync 模式：在 WS period 外决定是“宽松继续”还是“先 untrusted + rebuild 再进入 forward sync”。
