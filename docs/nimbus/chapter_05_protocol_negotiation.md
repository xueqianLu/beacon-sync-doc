# 第 5 章: 协议协商

> 本章聚焦 Nimbus 的协议 DSL 如何生成协议 ID（含版本号）并挂载到 libp2p switch。

## 关键代码定位

- 协议 DSL（Req/Resp 声明与生成）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_protocol_dsl.nim
- Req/Resp 协议 ID、挂载与收发实现：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim

## 1) Req/Resp 协议 ID 的基本形态

Nimbus 统一使用 `requestPrefix + <name>/<version> + requestSuffix` 组成 Req/Resp 的 codec/protocol ID。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
const
	requestPrefix = "/eth2/beacon_chain/req/"
	requestSuffix = "/ssz_snappy"
```

## 2) 用 pragma 标注协议名与版本（`libp2pProtocol`）

在 handler proc 上，Nimbus 通过 pragma 形式标注 `name/version`，并在 DSL/后端生成阶段读取这些 pragma 来生成 codec 名称。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
template libp2pProtocol*(name: string, version: int) {.pragma.}
```

## 3) 从 proc pragma 推导出 codecName（协议 ID）

`getRequestProtoName` 会从 proc 的 `libp2pProtocol(name, version)` pragma 中取出 name/version，并拼出完整的 `"/eth2/beacon_chain/req/<name>/<version>/ssz_snappy"`。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc getRequestProtoName(fn: NimNode): NimNode =
	let pragmas = fn.pragma
	if pragmas.kind == nnkPragma and pragmas.len > 0:
		for pragma in pragmas:
			try:
				if pragma.len > 0 and $pragma[0] == "libp2pProtocol":
					let protoName = $(pragma[1])
					let protoVer = $(pragma[2].intVal)
					return newLit(requestPrefix & protoName & "/" & protoVer & requestSuffix)
			except Exception as exc: raiseAssert exc.msg
	return newLit("")
```

## 4) DSL 生成 protocolInfo + registrations

在 `eth2_protocol_dsl.nim` 中，协议 DSL 会生成 `protocolInfo`（run-time data）以及发送/接收/注册代码（`outProcRegistrations`），并把 peer connect/disconnect 的 handler 与 protocolInfo 绑定。

来源：`beacon_chain/networking/eth2_protocol_dsl.nim`

```nim
result.add quote do:
	var `protocolInfoVarObj` = `protocolInit`
	let `protocolInfoVar` = addr `protocolInfoVarObj`

	template protocolInfo*(`PROTO`: type `protocolName`): auto = `protocolInfoVar`

result.add p.outSendProcs,
					 p.outRecvProcs,
					 p.outProcRegistrations

result.add newCall(p.backend.setEventHandlers,
									 protocolInfoVar,
									 nameOrNil p.onPeerConnected,
									 nameOrNil p.onPeerDisconnected)
```

## 5) 生成的 handler 如何挂载到 libp2p switch

在 `eth2_network.nim` 的 backend 实现中，每个消息会生成一个 `protocol mounter`，调用 `mount network.switch, LPProtocol.new(codecs=@[codecName], handler=...)` 完成挂载。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
mount `networkVar`.switch,
			LPProtocol.new(
				codecs = @[`codecNameLit`], handler = snappyThunk)
```

最后，`registerProtocol` 会遍历该 protocol 的 messages，调用每条消息的 `protocolMounter`，把所有 handler 安装到 switch 上。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc registerProtocol*(node: Eth2Node, Proto: type, state: Proto.NetworkState) =
	let proto = Proto.protocolInfo()
	node.protocols.add(proto)
	node.protocolStates.setLen(max(proto.index + 1, node.protocolStates.len))
	node.protocolStates[proto.index] = state

	for msg in proto.messages:
		if msg.protocolMounter != nil:
			msg.protocolMounter node
```
