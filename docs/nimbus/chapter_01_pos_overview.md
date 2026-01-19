# 第 1 章: PoS 共识机制概述

> 本章为通用内容，Nimbus 侧实现差异较少。

- 建议先阅读共享内容：[../../shared/README.md](../../shared/README.md)
- 本章补充 Nimbus 在配置/预设上的工程化细节（如 preset 选择与网络参数加载）。

## 1) `--network` 选择与网络元数据加载

Nimbus 的 `conf` 层提供了 `loadEth2Network`：若 CLI 指定了 `--network` 就加载对应网络；否则在 mainnet/gnosis 构建里会选择默认网络；对于非 mainnet/gnosis 的“其他构建”（例如测试 preset）则会强制要求显式指定网络。

来源：`beacon_chain/conf.nim`

```nim
proc loadEth2Network*(eth2Network: Option[string]): Eth2NetworkMetadata =
	let metadata =
		if eth2Network.isSome:
			getMetadataForNetwork(eth2Network.get)
		else:
			when IsGnosisSupported:
				getMetadataForNetwork("gnosis")
			elif IsMainnetSupported:
				getMetadataForNetwork("mainnet")
			else:
				fatal "Must specify network on non-mainnet node"
				quit 1

	network_name.set(2, labelValues = [metadata.cfg.name()])
	metadata
```

## 2) RuntimeConfig 的获取（按网络选择）

在 networking 层，`getRuntimeConfig` 会根据 `eth2Network` 选择对应网络的 metadata，并返回 `metadata.cfg`。当未显式指定网络时，常规 Nimbus mainnet/gnosis 构建会默认返回 mainnet/gnosis 的 runtime config；而“非标准构建”则退化为 `defaultRuntimeConfig`。

来源：`beacon_chain/networking/network_metadata.nim`

```nim
proc getRuntimeConfig*(eth2Network: Option[string]): RuntimeConfig =
	let metadata =
		if eth2Network.isSome:
			getMetadataForNetwork(eth2Network.get)
		else:
			when IsMainnetSupported:
				mainnetMetadata
			elif IsGnosisSupported:
				gnosisMetadata
			else:
				return defaultRuntimeConfig

	metadata.cfg
```

## 3) 备注：baked-in genesis（构建产物差异）

Nimbus 的部分构建会包含“baked-in genesis state”（用于快速启动/减少外部依赖），并在 `network_metadata.nim` 中通过 `bakedBytes` 等模板按 networkName 选择。

来源：`beacon_chain/networking/network_metadata.nim`

```nim
template bakedBytes*(metadata: GenesisMetadata): auto =
	case metadata.networkName
	of "mainnet":
		when IsMainnetSupported:
			bakedInGenesisStateAsBytes mainnet
		else:
			raiseAssert availableOnlyInMainnetBuild
	of "sepolia":
		when IsMainnetSupported:
			bakedInGenesisStateAsBytes sepolia
		else:
			raiseAssert availableOnlyInMainnetBuild
	else:
		raiseAssert "The baked network metadata should use one of the name above"
```
