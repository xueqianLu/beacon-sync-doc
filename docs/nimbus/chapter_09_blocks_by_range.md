# 第 9 章: BeaconBlocksByRange

> 目标：解释 Nimbus 如何处理 blocks-by-range（服务端），以及它如何施加限流/边界条件（step、count、可用窗口）。

## 服务端处理

- `beacon_blocks_by_range` v2 handler：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/sync/sync_protocol.nim

来源：`beacon_chain/sync/sync_protocol.nim`

```nim
proc beaconBlocksByRange_v2(
		peer: Peer,
		startSlot: Slot,
		reqCount: uint64,
		reqStep: uint64,
		response: MultipleChunksResponse[
			ref ForkedSignedBeaconBlock, Limit MAX_REQUEST_BLOCKS]
) {.async, libp2pProtocol("beacon_blocks_by_range", 2).} =
	trace "got range request", peer, startSlot, count = reqCount
	# https://github.com/ethereum/consensus-specs/pull/2856
	if reqStep != 1:
		raise newException(InvalidInputsError, "Step size must be 1")
	if reqCount == 0:
		raise newException(InvalidInputsError, "Empty range requested")

	var blocks: array[MAX_REQUEST_BLOCKS.int, BlockId]
	let dag = peer.networkState.dag
	if startSlot < dag.backfill.slot:
		# Peers that are unable to reply to block requests within the
		# `MIN_EPOCHS_FOR_BLOCK_REQUESTS` epoch range SHOULD respond with
		# error code `3: ResourceUnavailable`.
		raise newException(ResourceUnavailableError, BlocksUnavailable)

	let
		count = int min(reqCount, blocks.lenu64)
		endIndex = count - 1
		startIndex = dag.getBlockRange(startSlot, blocks.toOpenArray(0, endIndex))

	var
		found = 0
		bytes: seq[byte]

	for i in startIndex..endIndex:
		if dag.getBlockSZ(blocks[i], bytes):
			let uncompressedLen = uncompressedLenFramed(bytes).valueOr:
				warn "Cannot read block size, database corrupt?", bytes = bytes.len(), blck = shortLog(blocks[i])
				continue

			# TODO extract from libp2pProtocol
			peer.awaitQuota(blockResponseCost, "beacon_blocks_by_range/2")
			peer.network.awaitQuota(blockResponseCost, "beacon_blocks_by_range/2")

			await response.writeBytesSZ(
				uncompressedLen, bytes,
				peer.network.forkDigestAtEpoch(blocks[i].slot.epoch).data)
			inc found

	if found == 0 and startSlot < dag.horizon:
		raise newException(ResourceUnavailableError, BlocksUnavailable)
	debug "Block range request done", peer, startSlot, count
```

## 关键行为点（v25.12.0）

- `reqStep` 必须为 1（否则 InvalidInputsError）
- `reqCount` 为空直接报错
- 当请求 slot 早于 backfill 可用范围时，返回 ResourceUnavailable（对齐 spec 对 `MIN_EPOCHS_FOR_BLOCK_REQUESTS` 的要求）
- 每个响应 chunk 在发送前会做 peer/network quota 检查（配额成本见 `blockResponseCost`）

> 注意：上面最后的 `found == 0 and startSlot < dag.horizon` 分支用于区分“确定为空”（slots 已知为空）与“不可用/未 backfill”（对早于 horizon 的 slot，如果未找到任何 block，会返回 ResourceUnavailable）。

## 协议上限

- `MAX_REQUEST_BLOCKS = 1024`（规范常量）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/spec/datatypes/constants.nim
