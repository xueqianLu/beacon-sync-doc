# 第 14 章: Gossip Validation

> 目标：说明 Nimbus 如何对入站 gossip 执行 Accept/Ignore/Reject，并如何把“缺依赖/无效分叉”等情况映射为 quarantine 行为。

## 关键实现

- Gossip 校验核心：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/gossip_processing/gossip_validation.nim

### 1) ValidationResult 的返回形态（Accept / Ignore / Reject）

Nimbus 把校验结果建模为：`Result.ok` 代表 `Accept`；`Result.err` 里携带 `Ignore/Reject` 与可读错误信息。

来源：`beacon_chain/gossip_processing/gossip_validation.nim`

```nim
type
	ValidationError* = (ValidationResult, cstring)

template errIgnore*(msg: cstring): untyped =
	err((ValidationResult.Ignore, msg))
template errReject*(msg: cstring): untyped =
	err((ValidationResult.Reject, msg))
```

### 2) 缺依赖 root 的 quarantine：missing 先 Ignore；若被判定无效则 Reject

这段逻辑很好地体现了“暂缺依赖”和“已知无效”两类情况的区别：

- missing root：先 quarantine 并 `Ignore`（等待依赖到齐）
- unviable fork：`Ignore`（不会进一步传播/处理）
- invalid：`Reject`（明确无效）

来源：`beacon_chain/gossip_processing/gossip_validation.nim`

```nim
template addMissingValid(
		quarantine: var Quarantine, root: Eth2Digest, prefix: static string
): untyped =
	let missing = quarantine.addMissing(root)
	if missing.isOk:
		errIgnore(cstring(prefix & " not found"))
	else:
		case missing.error
		of UnviableKind.UnviableFork:
			errIgnore(cstring(prefix & " from unviable fork"))
		of UnviableKind.Invalid:
			errReject(cstring(prefix & " invalid"))
```

## 常见校验范式（Nimbus 侧）

- `Ignore`：更多用于“暂时缺依赖/时序不满足/未来消息”等场景（例如 missing root）
- `Reject`：用于明确违反规则或可判定为无效的消息
