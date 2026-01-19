# 第 10 章: BeaconBlocksByRoot

> 目标：说明 Nimbus 在 blocks-by-root 中如何强制请求上限并逐个返回可用 block。

## 服务端处理

- `beacon_blocks_by_root` v2 handler：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_protocol.nim

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

	let
		dag = peer.networkState.dag
		count = blockRoots.len

	var
		found = 0
		bytes: seq[byte]

	for i in 0..<count:
		let blockRef = dag.getBlockRef(blockRoots[i]).valueOr:
			continue

		if dag.getBlockSZ(blockRef.bid, bytes):
			let uncompressedLen = uncompressedLenFramed(bytes).valueOr:
				warn "Cannot read block size, database corrupt?", bytes = bytes.len(), blck = shortLog(blockRef)
				continue

			# TODO extract from libp2pProtocol
			peer.awaitQuota(blockResponseCost, "beacon_blocks_by_root/2")
			peer.network.awaitQuota(blockResponseCost, "beacon_blocks_by_root/2")

			await response.writeBytesSZ(
				uncompressedLen, bytes,
				peer.network.forkDigestAtEpoch(blockRef.slot.epoch).data)
			inc found

	debug "Block root request done", peer, roots = blockRoots.len, count, found
```

## 与“缺块补齐”的关系

Nimbus 还有一个更偏“补齐/抓取”的 RequestManager，会聚合 roots 并并行向多个 peer 发起 ByRoot：

- `SYNC_MAX_REQUESTED_BLOCKS = 32`（Nimbus 内部更保守的请求批大小）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/request_manager.nim

> 该设计把“协议允许的上限（MAX_REQUEST_BLOCKS=1024）”与“同步内部调度的保守批大小（32）”分离：服务端按规范上限接收请求，同步侧按更小批量并行调度以控制负载与失败重试成本。
