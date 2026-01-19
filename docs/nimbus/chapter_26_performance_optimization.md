# 第 26 章: 性能优化（Sync & Networking）

> 本章聚焦 Nimbus 在同步与网络侧的性能手段：限流配额（quota）、负载上限（MAX_PAYLOAD_SIZE）、并行度与批处理（workers / concurrentRequestsCount）、以及退避等待策略（避免空转/风暴）。

## 1) 双层配额：peer quota + network quota（Req/Resp 限流）

Nimbus 在网络对象与单个 peer 上都维护了 TokenBucket 配额，用于对高带宽/高频请求进行节流。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
type
	Eth2Node* = ref object
		# ...
		quota: TokenBucket ## Global quota mainly for high-bandwidth stuff

	Peer* = ref object
		# ...
		quota*: TokenBucket
```

配额的“等待式节流”封装在 `awaitQuota` 中：先尝试消费；如果失败就记录 throttled 指标并 `await consume()`（让请求在配额恢复后继续，而不是直接拒绝）。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
const
	maxRequestQuota = 1000000
	maxGlobalQuota = 2 * maxRequestQuota
		## Roughly, this means we allow 2 peers to sync from us at a time
	fullReplenishTime = 5.seconds

template awaitQuota*(peerParam: Peer, costParam: float, protocolIdParam: string) =
	let
		peer = peerParam
		cost = int(costParam)

	if not peer.quota.tryConsume(cost.int):
		let protocolId = protocolIdParam
		debug "Awaiting peer quota", peer, cost = cost, protocolId = protocolId
		nbc_reqresp_messages_throttled.inc(1, [protocolId])
		await peer.quota.consume(cost.int)

template awaitQuota*(networkParam: Eth2Node, costParam: float, protocolIdParam: string) =
	let
		network = networkParam
		cost = int(costParam)

	if not network.quota.tryConsume(cost.int):
		let protocolId = protocolIdParam
		debug "Awaiting network quota", peer, cost = cost, protocolId = protocolId
		nbc_reqresp_messages_throttled.inc(1, [protocolId])
		await network.quota.consume(cost.int)
```

配额的初始化分别发生在 node 与 peer 构造处：全局 `maxGlobalQuota` 以及每个 peer 的 `maxRequestQuota`。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
quota: TokenBucket.new(maxGlobalQuota, fullReplenishTime)

quota: TokenBucket.new(maxRequestQuota.int, fullReplenishTime)
```

## 2) 负载上限：MAX_PAYLOAD_SIZE（解码/反序列化前置保护）

Nimbus 在读取 Req/Resp chunk 时，先用 varint 读出 size，再用 `MAX_PAYLOAD_SIZE`（以及消息类型的 `chunkMaxSize`）进行约束，避免超大 payload 造成内存/CPU 压力。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
func chunkMaxSize[T](): uint32 =
	when isFixedSize(T):
		uint32 fixedPortionSize(T)
	else:
		static: doAssert MAX_PAYLOAD_SIZE < high(uint32).uint64
		MAX_PAYLOAD_SIZE.uint32

proc readChunkPayload*(conn: Connection, peer: Peer,
											 MsgType: type): Future[NetRes[MsgType]]
											 {.async: (raises: [CancelledError]).} =
	let
		sm = now(chronos.Moment)
		size = ? await readVarint2(conn)

	const maxSize = chunkMaxSize[MsgType]()
	if size > maxSize:
		return neterr SizePrefixOverflow
	if size == 0:
		return neterr ZeroSizePrefix

	# The `size.int` conversion is safe because `size` is bounded to `MAX_PAYLOAD_SIZE`
	let
		dataRes = await conn.uncompressFramedStream(size.int)
		data = dataRes.valueOr:
			debug "Snappy decompression/read failed", msg = $dataRes.error, conn
			return neterr InvalidSnappyBytes

	peer.updateNetThroughput(now(chronos.Moment) - sm,
													 uint64(10 + size))
	try:
		ok SSZ.decode(data, MsgType)
```

## 3) 同步并行度与批处理：workers + concurrentRequestsCount

Nimbus 的 full sync 通过多个 worker 并行推进（默认 10 个），每个 worker 在一次 step 里最多发起 `concurrentRequestsCount` 个请求（默认 1）。

来源：`beacon_chain/sync/sync_manager.nim`

```nim
const
	SyncWorkersCount* = 10
		## Number of sync workers to spawn

	ConcurrentRequestsCount* = 1  # Higher values require reviewing `pending == 0`
		## Number of requests performed by one peer in single syncing step
```

核心的“批处理 + 退避等待”发生在 step 内：如果 `SyncQueue.pop()` 返回空请求（例如 peer head 太低或暂时无可下载 slot），worker 会 `sleepAsync(RESP_TIMEOUT_DUR)` 避免 tight loop；当请求失败时，会把已取出的 requests 退回队列。

来源：`beacon_chain/sync/sync_manager.nim`

```nim
for rindex in 0 ..< man.concurrentRequestsCount:
	man.workers[index].status = SyncWorkerStatus.Requesting
	let request = man.queue.pop(peerSlot, peer)
	if request.isEmpty():
		debug "Empty request received from queue", peer = peer
		await sleepAsync(RESP_TIMEOUT_DUR)
		break

	requests.add(request)
	man.workers[index].status = SyncWorkerStatus.Downloading

	let data = (await man.getSyncBlockData(index, request)).valueOr:
		debug "Failed to get block data", peer = peer, reason = error
		man.queue.push(requests)
		break

	man.workers[index].status = SyncWorkerStatus.Queueing
	jobs.add(man.queue.push(request, data.blocks, data.blobs, maybeFinalized, processCallback))

if len(jobs) > 0:
	await allFutures(jobs)
```

## 4) 请求边界：MAX_REQUEST_BLOCKS（避免超大批次）

在 blocks-by-root 等 handler 处，Nimbus 通过 SSZ `List[..., Limit MAX_REQUEST_BLOCKS]` 的类型约束，确保请求规模受 spec 常量限制，从而把“最坏情况”锁死在可控范围。

来源：`beacon_chain/sync/sync_protocol.nim`

```nim
proc beaconBlocksByRoot_v2(
		peer: Peer,
		# Please note that the SSZ list here ensures that the
		# spec constant MAX_REQUEST_BLOCKS is enforced:
		blockRoots: BlockRootsList,
		response: MultipleChunksResponse[
			ref ForkedSignedBeaconBlock, Limit MAX_REQUEST_BLOCKS]
) {.async, libp2pProtocol("beacon_blocks_by_root", 2).} =
	if blockRoots.len == 0:
		raise newException(InvalidInputsError, "No blocks requested")
```

另外在 sync 侧的返回类型上也显式带了 `Limit MAX_REQUEST_BLOCKS`，把“每次下载/处理的上限”贯彻到接口层。

来源：`beacon_chain/sync/sync_manager.nim`

```nim
BeaconBlocksRes =
	NetRes[List[ref ForkedSignedBeaconBlock, Limit MAX_REQUEST_BLOCKS]]
```

---

小结：Nimbus 的性能控制思路更偏“系统工程化”：用硬上限（payload/request limits）+ 软节流（token bucket + await）+ 并行流水线（workers/queue）组合，在吞吐与稳定性之间做可观测、可调的折中。
