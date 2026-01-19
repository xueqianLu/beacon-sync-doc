# 第 18 章: Full Sync

> 目标：聚焦“range sync 拉取 → 校验 → 提交处理”的 Nimbus 实现路径与关键参数。

## 关键实现

- 同步 worker 状态机与请求发起：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_manager.nim
- 服务端 blocks-by-range：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_protocol.nim

## 关键参数（Nimbus v25.12.0）

- `SyncWorkersCount = 10`、`StatusExpirationTime = 2min`：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_manager.nim

### 1) 关键参数与同步组件（workers / queue / peer pool）

来源：`beacon_chain/sync/sync_manager.nim`

```nim
const
	SyncWorkersCount* = 10
		## Number of sync workers to spawn

	StatusExpirationTime* = chronos.minutes(2)
		## Time time it takes for the peer's status information to expire.

	ConcurrentRequestsCount* = 1
		## Number of requests performed by one peer in single syncing step

type
	SyncManager*[A, B] = ref object
		pool: PeerPool[A, B]
		workers: array[SyncWorkersCount, SyncWorker[A, B]]
		notInSyncEvent: AsyncEvent
		resumeSyncEvent: AsyncEvent
		shutdownEvent: AsyncEvent
		queue: SyncQueue[A]
		responseTimeout: chronos.Duration
		maxHeadAge: uint64
		ident*: string
```

### 2) Range 拉取入口：worker 侧发起 BlocksByRange v2

Full Sync 的“拉取”动作最终落在 `beaconBlocksByRange_v2(peer, startSlot, count, step=1)`。

来源：`beacon_chain/sync/sync_manager.nim`

```nim
proc getBlocks[A, B](man: SyncManager[A, B], peer: A, req: SyncRequest[A]):
		Future[BeaconBlocksRes] {.async: (raises: [CancelledError], raw: true).} =
	doAssert(not(req.isEmpty()), "Request must not be empty!")
	debug "Requesting blocks from peer",
				request = req,
				peer_score = req.item.getScore(),
				peer_speed = req.item.netKbps(),
				sync_ident = man.ident,
				topics = "syncman"

	beaconBlocksByRange_v2(peer, req.data.slot, req.data.count, 1'u64)
```

> 结合第 9 章（服务端 `beaconBlocksByRange_v2`）：server 端会强制 `reqStep == 1`、`reqCount > 0`，并在发送每个 chunk 前做 quota 检查。

### 3) Status 刷新：过期或“快追上”时更新对端 status

Full Sync 过程中，Nimbus 会根据 status 年龄与同步区间位置决定是否调用 `peer.updateStatus()` 刷新对端 headSlot。

来源：`beacon_chain/sync/sync_manager.nim`

```nim
proc getOrUpdatePeerStatus[A, B](man: SyncManager[A, B], index: int, peer: A):
		Future[Result[Slot, string]] {.async: (raises: [CancelledError]).} =
	let
		headSlot = man.getLocalHeadSlot()
		wallSlot = man.getLocalWallSlot()
		peerSlot = peer.getHeadSlot()

	let
		peerStatusAge = Moment.now() - peer.getStatusLastTime()
		needsUpdate =
			peerStatusAge >= StatusExpirationTime or
			man.getFirstSlot() >= peerSlot

	if not(needsUpdate):
		return ok(peerSlot)

	man.workers[index].status = SyncWorkerStatus.UpdatingStatus

	if peerStatusAge < (StatusExpirationTime div 2):
		await sleepAsync((StatusExpirationTime div 2) - peerStatusAge)

	if not(await peer.updateStatus()):
		peer.updateScore(PeerScoreNoStatus)
		return err("Failed to get remote peer status")

	let newPeerSlot = peer.getHeadSlot()
	if peerSlot >= newPeerSlot:
		peer.updateScore(PeerScoreStaleStatus)
	else:
		peer.updateScore(PeerScoreGoodStatus)
	ok(newPeerSlot)
```

### 4) 单步同步（syncStep）：挑 peer → pop queue → 拉取 → 入队处理

来源：`beacon_chain/sync/sync_manager.nim`

```nim
proc syncStep[A, B](man: SyncManager[A, B], index: int, peer: A)
		{.async: (raises: [CancelledError]).} =
	let
		peerSlot = (await man.getOrUpdatePeerStatus(index, peer)).valueOr:
			return
		headSlot = man.getLocalHeadSlot()
		wallSlot = man.getLocalWallSlot()

	if man.remainingSlots() <= man.maxHeadAge:
		man.notInSyncEvent.clear()
		return

	if man.getFirstSlot() >= peerSlot:
		debug "Peer's head slot is lower then local head slot", peer = peer
		peer.updateScore(PeerScoreUseless)
		return

	man.queue.updateLastSlot(man.getLastSlot())

	var
		jobs: seq[Future[void].Raising([CancelledError])]
		requests: seq[SyncRequest[Peer]]

	for rindex in 0 ..< man.concurrentRequestsCount:
		man.workers[index].status = SyncWorkerStatus.Requesting
		let request = man.queue.pop(peerSlot, peer)
		if request.isEmpty():
			await sleepAsync(RESP_TIMEOUT_DUR)
			break

		requests.add(request)
		man.workers[index].status = SyncWorkerStatus.Downloading
		let data = (await man.getSyncBlockData(index, request)).valueOr:
			man.queue.push(requests)
			break

		man.workers[index].status = SyncWorkerStatus.Queueing
		let
			peerFinalized = peer.getFinalizedEpoch().start_slot()
			lastSlot = request.data.slot + request.data.count - 1
			maybeFinalized = lastSlot < peerFinalized
		jobs.add(man.queue.push(request, data.blocks, data.blobs, maybeFinalized, processCallback))

	if len(jobs) > 0:
		await allFutures(jobs)
```

### 5) Worker 循环（syncWorker）：从 PeerPool 获取 peer 并反复执行 syncStep

来源：`beacon_chain/sync/sync_manager.nim`

```nim
proc syncWorker[A, B](man: SyncManager[A, B], index: int)
		{.async: (raises: [CancelledError]).} =
	var peer: A = nil
	try:
		while true:
			man.workers[index].status = SyncWorkerStatus.Sleeping
			if not(man.resumeSyncEvent.isSet()):
				man.workers[index].status = SyncWorkerStatus.Paused
			await man.resumeSyncEvent.wait()

			await man.notInSyncEvent.wait()
			man.workers[index].status = SyncWorkerStatus.WaitingPeer
			peer = await man.pool.acquire()
			await man.syncStep(index, peer)
			man.pool.release(peer)
			peer = nil
	finally:
		if not(isNil(peer)):
			man.pool.release(peer)
```

### 6) 总控循环（syncLoop）：启动 workers + 维护 syncStatus（进度/速度/剩余时间）

来源：`beacon_chain/sync/sync_manager.nim`

```nim
proc startWorkers[A, B](man: SyncManager[A, B]) =
	for i in 0 ..< len(man.workers):
		man.workers[i].future = syncWorker[A, B](man, i)

proc syncLoop[A, B](man: SyncManager[A, B])
		{.async: (raises: [CancelledError]).} =
	man.resumeSyncEvent.fire()
	man.initQueue()
	man.startWorkers()

	proc averageSpeedTask() {.async: (raises: [CancelledError]).} =
		while true:
			man.avgSyncSpeed = 0
			man.insSyncSpeed = 0
			await man.resumeSyncEvent.wait()
			await man.notInSyncEvent.wait()
			const pollInterval = seconds(15)
			await sleepAsync(pollInterval)

	let averageSpeedTaskFut = averageSpeedTask()

	while true:
		let (map, sleeping, waiting, pending) = man.getWorkersStats()
		# ...progress/remaining/timeleft 计算...
		if man.resumeSyncEvent.isSet():
			man.syncStatus = timeleft.toTimeLeftString() & " (" &
											(done * 100).formatBiggestFloat(ffDecimal, 2) & "% ) " &
											man.avgSyncSpeed.formatBiggestFloat(ffDecimal, 4) &
											"slots/s (" & map & ":" & currentSlot & ")"
```

> 这一套结构对应常见的 Full Sync 分层：`PeerPool` 负责提供候选 peer；`SyncQueue` 负责“哪些 slot 需要拉取”；worker 把网络拉取结果入队，后续由 queue/processor 完成验证与写入。
