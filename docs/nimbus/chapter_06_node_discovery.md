# 第 6 章: 节点发现机制

> 本章聚焦 Nimbus 的 discovery 协议实现、ENR fork digest / subnet metadata 交互与 peer 候选筛选策略。

## 1) Bootstrap 节点来源：CLI 列表 + 文件

Nimbus 支持从 `enr:` 格式的 bootstrap 地址中解析 ENR，并允许从 `.txt/.enr` 文件加载（会忽略空行与注释）。

来源：`beacon_chain/networking/eth2_discovery.nim`

```nim
func parseBootstrapAddress*(address: string): Result[enr.Record, string] =
	let lowerCaseAddress = toLowerAscii(address)
	if lowerCaseAddress.startsWith("enr:"):
		let res = enr.Record.fromURI(address)
		if res.isOk():
			return ok res.value
		return err "Invalid bootstrap ENR: " & $res.error
	elif lowerCaseAddress.startsWith("enode:"):
		return err "ENode bootstrap addresses are not supported"
	else:
		return err "Ignoring unrecognized bootstrap address type"

proc loadBootstrapFile*(bootstrapFile: string,
												bootstrapEnrs: var seq[enr.Record]) =
	if bootstrapFile.len == 0: return
	let ext = splitFile(bootstrapFile).ext
	if cmpIgnoreCase(ext, ".txt") == 0 or cmpIgnoreCase(ext, ".enr") == 0:
		try:
			for ln in strippedLines(bootstrapFile):
				addBootstrapNode(ln, bootstrapEnrs)
		except IOError as e:
			error "Could not read bootstrap file", msg = e.msg
			quit 1
	else:
		error "Unknown bootstrap file format", ext
		quit 1
```

## 2) ENR 字段：forkId + attestation subnets

在创建 `Eth2Node` 时，Nimbus 会把本地的 `ENRForkID` 与 `metadata.attnets`（attestation subnets bitfield）编码进 ENR 字段，供 discovery 查询与筛选使用。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
discovery: Eth2DiscoveryProtocol.new(
	config, ip, tcpPort, udpPort, privKey,
	{
		enrForkIdField: SSZ.encode(enrForkId),
		enrAttestationSubnetsField: SSZ.encode(metadata.attnets)
	},
	rng),
```

## 3) fork digest 兼容性判断（ForkId compatibility）

Nimbus 在 discovery 阶段会过滤掉 fork digest 不一致的节点，并对“下一次 fork 版本/epoch”的关系做了进一步约束。

来源：`beacon_chain/networking/eth2_discovery.nim`

```nim
func isCompatibleForkId*(discoveryForkId: ENRForkID, peerForkId: ENRForkID): bool =
	if discoveryForkId.fork_digest == peerForkId.fork_digest:
		if discoveryForkId.next_fork_version < peerForkId.next_fork_version:
			true
		elif discoveryForkId.next_fork_version == peerForkId.next_fork_version:
			discoveryForkId.next_fork_epoch == peerForkId.next_fork_epoch
		else:
			false
	else:
		false
```

## 4) discovery 查询与候选筛选：forkId + subnets + minScore

`queryRandom` 会执行 `discoveryv5` 的随机查询，然后：

- 从 ENR 解码 `enrForkIdField`，并用 `isCompatibleForkId` 过滤。
- 解码 attestation/sync subnets 的 bitfield，与本地 wanted 子网交集打分。
- 最终返回满足 `minScore` 的候选，并进行 shuffle/sort（优先高分）。

来源：`beacon_chain/networking/eth2_discovery.nim`

```nim
proc queryRandom*(
		d: Eth2DiscoveryProtocol,
		forkId: ENRForkID,
		wantedAttnets: AttnetBits,
		wantedSyncnets: SyncnetBits,
		wantedCgcnets: CgcBits,
		minScore: int): Future[seq[Node]] {.async: (raises: [CancelledError]).} =
	let nodes = await d.queryRandom()

	var filtered: seq[(int, Node)]
	for n in nodes:
		var score: int = 0

		let eth2FieldBytes = n.record.get(enrForkIdField, seq[byte]).valueOr:
			continue
		let peerForkId = SSZ.decode(eth2FieldBytes, ENRForkID)
		if not forkId.isCompatibleForkId(peerForkId):
			continue

		let attnetsBytes = n.record.get(enrAttestationSubnetsField, seq[byte])
		if attnetsBytes.isOk():
			let attnetsNode = SSZ.decode(attnetsBytes.get(), AttnetBits)
			for i in 0..<ATTESTATION_SUBNET_COUNT:
				if wantedAttnets[i] and attnetsNode[i]:
					score += 1

		let syncnetsBytes = n.record.get(enrSyncSubnetsField, seq[byte])
		if syncnetsBytes.isOk():
			let syncnetsNode = SSZ.decode(syncnetsBytes.get(), SyncnetBits)
			for i in SyncSubcommitteeIndex:
				if wantedSyncnets[i] and syncnetsNode[i]:
					score += 10

		if score >= minScore:
			filtered.add((score, n))

	d.rng[].shuffle(filtered)
	return filtered.sortedByIt(-it[0]).mapIt(it[1])
```
