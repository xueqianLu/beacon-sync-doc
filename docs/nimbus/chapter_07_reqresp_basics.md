# 第 7 章: Req/Resp 协议基础

> 目标：从 Nimbus 的 wire 编解码与超时/限流出发，解释其 Req/Resp 基建如何支撑 Status/BlocksByRange/BlocksByRoot。

## 1. 消息编码与 chunking

Nimbus 在网络层实现了（对齐共识层规范的）SSZ + Snappy + length-prefix 的读写：

- 写入 chunk（含 response code + snappy framed）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim
- 读取 chunk（varint size + snappy 解压 + SSZ decode）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim

### 1.1 写入：response code + varint length + snappy framed

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc writeChunkSZ(
		conn: Connection,
		responseCode: Opt[ResponseCode],
		uncompressedLen: uint64,
		payloadSZ: openArray[byte],
		contextBytes: openArray[byte] = [],
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
	let uncompressedLenBytes = toBytes(uncompressedLen, Leb128)

	var
		data = newSeqUninit[byte](
			ord(responseCode.isSome) + contextBytes.len +
			uncompressedLenBytes.len + payloadSZ.len)
		pos = 0

	if responseCode.isSome:
		data.add(pos, [byte responseCode.get])
	data.add(pos, contextBytes)
	data.add(pos, uncompressedLenBytes.toOpenArray())
	data.add(pos, payloadSZ)
	conn.write(data)

proc writeChunk(
		conn: Connection,
		responseCode: Opt[ResponseCode],
		payload: openArray[byte],
		contextBytes: openArray[byte] = [],
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
	let uncompressedLenBytes = toBytes(payload.lenu64, Leb128)
	var
		data = newSeqUninit[byte](
			ord(responseCode.isSome) + contextBytes.len +
			uncompressedLenBytes.len +
			snappy.maxCompressedLenFramed(payload.len).int)
		pos = 0

	if responseCode.isSome:
		data.add(pos, [byte responseCode.get])
	data.add(pos, contextBytes)
	data.add(pos, uncompressedLenBytes.toOpenArray())
	let
		pre = pos
		written = snappy.compressFramed(payload, data.toOpenArray(pos, data.high))
			.expect("compression shouldn't fail with correctly preallocated buffer")
	data.setLen(pre + written)
	conn.write(data)
```

### 1.2 读取：varint size 前缀 + snappy framed 解压 + SSZ decode

读取侧核心点是：

- 先读 length-prefix（varint）
- 对 `size` 做上限与零值检查
- 使用 snappy framed 流解压得到 `size` 字节的明文
- 用 SSZ decode 还原为目标类型

来源：`beacon_chain/networking/eth2_network.nim`

```nim
func chunkMaxSize[T](): uint32 =
	when isFixedSize(T):
		uint32 fixedPortionSize(T)
	else:
		static: doAssert MAX_PAYLOAD_SIZE < high(uint32).uint64
		MAX_PAYLOAD_SIZE.uint32

proc readChunkPayload*(conn: Connection, peer: Peer, MsgType: type):
		Future[NetRes[MsgType]] {.async: (raises: [CancelledError]).} =
	let
		sm = now(chronos.Moment)
		size = ? await readVarint2(conn)

	const maxSize = chunkMaxSize[MsgType]()
	if size > maxSize:
		return neterr SizePrefixOverflow
	if size == 0:
		return neterr ZeroSizePrefix

	let
		dataRes = await conn.uncompressFramedStream(size.int)
		data = dataRes.valueOr:
			debug "Snappy decompression/read failed", msg = $dataRes.error, conn
			return neterr InvalidSnappyBytes

	peer.updateNetThroughput(now(chronos.Moment) - sm, uint64(10 + size))
	try:
		ok SSZ.decode(data, MsgType)
	except SerializationError:
		neterr InvalidSszBytes
```

## 2. 超时与 payload 上限

Nimbus 直接引用规范常量：

- `RESP_TIMEOUT = 10`、`MAX_PAYLOAD_SIZE = 10 * 1024 * 1024`：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/spec/datatypes/constants.nim

同时，snappy framed 的解压逻辑在网络层做了多处健壮性校验（header、frame size、CRC、reserved chunk types 等），避免构造型 payload 触发异常。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc uncompressFramedStream(conn: Connection, expectedSize: int):
		Future[Result[seq[byte], string]] {.async: (raises: [CancelledError]).} =
	var header: array[framingHeader.len, byte]
	try:
		await conn.readExactly(addr header[0], header.len)
	except LPStreamEOFError, LPStreamIncompleteError:
		return err "Unexpected EOF before snappy header"
	except LPStreamError as exc:
		return err "Unexpected error reading header: " & exc.msg

	if header != framingHeader:
		return err "Incorrect snappy header"

	var
		frameData = newSeqUninit[byte](maxCompressedFrameDataLen + 4)
		output = newSeqUninit[byte](expectedSize)
		written = 0

	while written < expectedSize:
		var frameHeader: array[4, byte]
		try:
			await conn.readExactly(addr frameHeader[0], frameHeader.len)
		except LPStreamEOFError, LPStreamIncompleteError:
			return err "Snappy frame header missing"
		except LPStreamError as exc:
			return err "Unexpected error reading frame header: " & exc.msg

		let (id, dataLen) = decodeFrameHeader(frameHeader)
		if dataLen > frameData.len:
			return err "Snappy frame too big"

		if dataLen > 0:
			try:
				await conn.readExactly(addr frameData[0], dataLen)
			except LPStreamEOFError, LPStreamIncompleteError:
				return err "Incomplete snappy frame"
			except LPStreamError as exc:
				return err "Unexpected error reading frame data: " & exc.msg

		if id == chunkCompressed:
			if dataLen < 6:
				return err "Compressed snappy frame too small"
			let
				crc = uint32.fromBytesLE frameData.toOpenArray(0, 3)
				uncompressed = snappy.uncompress(
					frameData.toOpenArray(4, dataLen - 1),
					output.toOpenArray(written, output.high)).valueOr:
						return err "Failed to decompress content"
			if maskedCrc(output.toOpenArray(written, written + uncompressed - 1)) != crc:
				return err "Snappy content CRC checksum failed"
			written += uncompressed
		elif id == chunkUncompressed:
			if dataLen < 5:
				return err "Uncompressed snappy frame too small"
			let uncompressed = dataLen - 4
			if uncompressed > maxUncompressedFrameDataLen.int:
				return err "Snappy frame size too large"
			if uncompressed > output.len - written:
				return err "Too much data"
			let crc = uint32.fromBytesLE frameData.toOpenArray(0, 3)
			if maskedCrc(frameData.toOpenArray(4, dataLen - 1)) != crc:
				return err "Snappy content CRC checksum failed"
			output[written..<written + uncompressed] = frameData.toOpenArray(4, dataLen - 1)
			written += uncompressed
		elif id < 0x80:
			return err "Invalid snappy chunk type"
		else:
			continue

	return ok output
```

## 2.1 Req/Resp 的限流（peer / network quota）

Nimbus 在网络层做了双层限流：

- peer quota：单 peer 的令牌桶
- network quota：全局网络级别的令牌桶

来源：`beacon_chain/networking/eth2_network.nim`

```nim
template awaitQuota*(
		peerParam: Peer, costParam: float, protocolIdParam: string) =
	let
		peer = peerParam
		cost = int(costParam)

	if not peer.quota.tryConsume(cost.int):
		let protocolId = protocolIdParam
		debug "Awaiting peer quota", peer, cost = cost, protocolId
		nbc_reqresp_messages_throttled.inc(1, [protocolId])
		await peer.quota.consume(cost.int)

template awaitQuota*(
		networkParam: Eth2Node, costParam: float, protocolIdParam: string) =
	let
		network = networkParam
		cost = int(costParam)

	if not network.quota.tryConsume(cost.int):
		let protocolId = protocolIdParam
		debug "Awaiting network quota", peer, cost = cost, protocolId = protocolId
		nbc_reqresp_messages_throttled.inc(1, [protocolId])
		await network.quota.consume(cost.int)

func allowedOpsPerSecondCost*(n: int): float =
	const replenishRate = (maxRequestQuota / fullReplenishTime.nanoseconds.float)
	(replenishRate * 1000000000'f / n.float)

const
	libp2pRequestCost = allowedOpsPerSecondCost(8)
		## Maximum number of libp2p requests per peer per second
```

## 3. 协议声明方式

Nimbus 使用 DSL 宏生成 client 侧请求函数与 server 侧 handler 绑定：

- 协议 DSL：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_protocol_dsl.nim
