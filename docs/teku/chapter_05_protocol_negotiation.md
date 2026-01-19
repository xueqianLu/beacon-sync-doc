# 第 5 章 协议协商

## 5.1 multistream-select 协议

### 5.1.1 为什么需要协议协商

在 P2P 网络中，peer 需要就使用的协议达成一致：

```
问题：
Peer A支持: /eth2/beacon_chain/req/status/2, /gossipsub/1.1.0
Peer B支持: /eth2/beacon_chain/req/status/2, /gossipsub/1.0.0

需要协商出双方都支持的协议版本
```

### 5.1.2 multistream-select 流程

```
Initiator                             Responder
    │                                      │
    ├───── /multistream/1.0.0 ────────────>│
    │                                      │
    │<──── /multistream/1.0.0 ─────────────┤
    │                                      │
    ├───── /protocol/name/version ────────>│
    │                                      │
    │<──── /protocol/name/version ─────────┤
    │     (或 na - 不支持)                 │
    │                                      │
    └──────────────────────────────────────┘

协议协商成功，开始应用层通信
```

**协议格式**:

```
/protocol-name/version/encoding

示例:
/eth2/beacon_chain/req/status/2/ssz_snappy
/eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy
```

---

## 5.2 Prysm 的协议注册

### 5.2.1 RPC 协议映射

```go
// 来自prysm/beacon-chain/p2p/rpc_topic_mappings.go
const (
    // Req/Resp协议ID前缀
    protocolPrefix = "/eth2/beacon_chain/req"
)

// RPCTopicMappings定义了所有支持的Req/Resp协议
var RPCTopicMappings = map[string]interface{}{
    // Status协议
    RPCStatusTopicV1:               &pb.Status{},

    // 区块请求协议
    RPCBlocksByRangeTopicV2:        &pb.BeaconBlocksByRangeRequest{},
    RPCBlocksByRootTopicV2:         &pb.BeaconBlocksByRootRequest{},

    // Blob请求协议 (Deneb+)
    RPCBlobSidecarsByRangeTopicV1:  &pb.BlobSidecarsByRangeRequest{},
    RPCBlobSidecarsByRootTopicV1:   &pb.BlobSidecarsByRootRequest{},

    // 元数据协议
    RPCMetaDataTopicV2:             &pb.MetadataRequest{},

    // Ping协议
    RPCPingTopicV1:                 &pb.Ping{},

    // Goodbye协议
    RPCGoodByeTopicV1:              &pb.Goodbye{},
}
```

### 5.2.2 协议版本定义

```go
// Status协议
const (
    RPCStatusTopicV1 = "/eth2/beacon_chain/req/status/1/ssz_snappy"
)

// BeaconBlocksByRange协议
const (
    // 注意：v1已废弃，v2是当前版本
    RPCBlocksByRangeTopicV2 = "/eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy"
)

// BeaconBlocksByRoot协议
const (
    RPCBlocksByRootTopicV2 = "/eth2/beacon_chain/req/beacon_blocks_by_root/2/ssz_snappy"
)

// BlobSidecars协议 (EIP-4844)
const (
    RPCBlobSidecarsByRangeTopicV1 = "/eth2/beacon_chain/req/blob_sidecars_by_range/1/ssz_snappy"
    RPCBlobSidecarsByRootTopicV1  = "/eth2/beacon_chain/req/blob_sidecars_by_root/1/ssz_snappy"
)

// MetaData协议
const (
    RPCMetaDataTopicV1 = "/eth2/beacon_chain/req/metadata/1/ssz_snappy"
    RPCMetaDataTopicV2 = "/eth2/beacon_chain/req/metadata/2/ssz_snappy"
)

// Ping协议
const (
    RPCPingTopicV1 = "/eth2/beacon_chain/req/ping/1/ssz_snappy"
)

// Goodbye协议
const (
    RPCGoodByeTopicV1 = "/eth2/beacon_chain/req/goodbye/1/ssz_snappy"
)
```

### 5.2.3 协议处理器注册

```go
// 来自prysm/beacon-chain/sync/rpc.go
func (s *Service) registerRPCHandlers() {
    // Status协议
    s.registerRPC(
        p2ptypes.RPCStatusTopicV1,
        s.statusRPCHandler,
    )

    // BlocksByRange协议
    s.registerRPC(
        p2ptypes.RPCBlocksByRangeTopicV2,
        s.beaconBlocksByRangeRPCHandler,
    )

    // BlocksByRoot协议
    s.registerRPC(
        p2ptypes.RPCBlocksByRootTopicV2,
        s.beaconBlocksRootRPCHandler,
    )

    // BlobSidecars协议
    s.registerRPC(
        p2ptypes.RPCBlobSidecarsByRangeTopicV1,
        s.blobSidecarsByRangeRPCHandler,
    )

    s.registerRPC(
        p2ptypes.RPCBlobSidecarsByRootTopicV1,
        s.blobSidecarsByRootRPCHandler,
    )

    // MetaData协议
    s.registerRPC(
        p2ptypes.RPCMetaDataTopicV2,
        s.metaDataHandler,
    )

    // Ping协议
    s.registerRPC(
        p2ptypes.RPCPingTopicV1,
        s.pingHandler,
    )

    // Goodbye协议
    s.registerRPC(
        p2ptypes.RPCGoodByeTopicV1,
        s.goodbyeRPCHandler,
    )
}

func (s *Service) registerRPC(
    topic string,
    handler network.StreamHandler,
) {
    // 设置stream处理器
    s.cfg.P2P.SetStreamHandler(topic, handler)
}
```

---

## 5.3 Gossipsub 主题协商

### 5.3.1 Gossipsub 主题映射

```go
// 来自prysm/beacon-chain/p2p/gossip_topic_mappings.go
var gossipTopicMappings = map[string]interface{}{
    // 核心主题
    GossipTypeMapping[GossipBlockMessage]:       &ethpb.SignedBeaconBlock{},
    GossipTypeMapping[GossipAggregateAndProofMessage]: &ethpb.SignedAggregateAttestationAndProof{},
    GossipTypeMapping[GossipAttestationMessage]: &ethpb.Attestation{},
    GossipTypeMapping[GossipExitMessage]:        &ethpb.SignedVoluntaryExit{},
    GossipTypeMapping[GossipAttesterSlashingMessage]: &ethpb.AttesterSlashing{},
    GossipTypeMapping[GossipProposerSlashingMessage]: &ethpb.ProposerSlashing{},

    // Altair新增
    GossipTypeMapping[GossipSyncCommitteeMessage]: &ethpb.SyncCommitteeMessage{},
    GossipTypeMapping[GossipContributionAndProofMessage]: &ethpb.SignedContributionAndProof{},

    // Deneb新增
    GossipTypeMapping[GossipBlobSidecarMessage]: &ethpb.BlobSidecar{},
}
```

### 5.3.2 主题格式

```go
// 来自prysm/beacon-chain/p2p/topics.go
const (
    // 主题格式: /eth2/{fork_digest}/{topic_name}/{encoding}
    GossipProtocolAndDigest = "/eth2/%x/%s"
)

// 构建gossip主题名
func GossipTopicName(forkDigest [4]byte, topicName string) string {
    return fmt.Sprintf(GossipProtocolAndDigest, forkDigest, topicName)
}

// 主题名称常量
const (
    // 区块主题
    BlockSubnetTopicFormat = "beacon_block"

    // 证明主题 (每个subnet一个)
    AttestationSubnetTopicFormat = "beacon_attestation_%d"  // %d = subnet ID

    // 聚合证明主题
    AttestationAggregateTopicFormat = "beacon_aggregate_and_proof"

    // Sync committee主题 (每个subnet一个)
    SyncCommitteeSubnetTopicFormat = "sync_committee_%d"  // %d = subnet ID

    // Sync committee contribution主题
    SyncContributionAndProofTopicFormat = "sync_committee_contribution_and_proof"

    // Blob sidecar主题 (每个subnet一个)
    BlobSidecarSubnetTopicFormat = "blob_sidecar_%d"  // %d = subnet ID

    // 其他主题
    ExitSubnetTopicFormat = "voluntary_exit"
    ProposerSlashingSubnetTopicFormat = "proposer_slashing"
    AttesterSlashingSubnetTopicFormat = "attester_slashing"
    BLSToExecutionChangeSubnetTopicFormat = "bls_to_execution_change"
)
```

### 5.3.3 主题订阅

```go
// 来自prysm/beacon-chain/sync/subscriber.go
func (s *Service) subscribeStaticWithSubnets() {
    // 订阅静态主题
    s.subscribeWithBase(s.staticTopics())

    // 订阅subnet主题
    s.subscribeToSubnets()
}

func (s *Service) staticTopics() []string {
    return []string{
        p2p.GossipTypeMapping[p2p.GossipBlockMessage],
        p2p.GossipTypeMapping[p2p.GossipAggregateAndProofMessage],
        p2p.GossipTypeMapping[p2p.GossipExitMessage],
        p2p.GossipTypeMapping[p2p.GossipProposerSlashingMessage],
        p2p.GossipTypeMapping[p2p.GossipAttesterSlashingMessage],
        p2p.GossipTypeMapping[p2p.GossipSyncCommitteeMessage],
        p2p.GossipTypeMapping[p2p.GossipContributionAndProofMessage],
        p2p.GossipTypeMapping[p2p.GossipBLSToExecutionChangeMessage],
    }
}

func (s *Service) subscribeToSubnets() {
    // 订阅attestation subnets
    for i := uint64(0); i < params.BeaconConfig().AttestationSubnetCount; i++ {
        s.subscribeToAttestationSubnet(i)
    }

    // 订阅sync committee subnets
    for i := uint64(0); i < params.BeaconConfig().SyncCommitteeSubnetCount; i++ {
        s.subscribeToSyncCommitteeSubnet(i)
    }

    // 订阅blob sidecar subnets (Deneb+)
    if params.DenebEnabled() {
        for i := uint64(0); i < params.BeaconConfig().BlobSidecarSubnetCount; i++ {
            s.subscribeToBlobSidecarSubnet(i)
        }
    }
}
```

---

## 5.4 编码协商(Encoding)

### 5.4.1 SSZ+Snappy 编码

以太坊共识层使用 SSZ 序列化和 Snappy 压缩：

```
编码流程:
对象 → SSZ序列化 → Snappy压缩 → 网络传输

解码流程:
网络数据 → Snappy解压 → SSZ反序列化 → 对象
```

### 5.4.2 编码器接口

```go
// 来自prysm/beacon-chain/p2p/encoder/network_encoding.go
type NetworkEncoding interface {
    // 解码
    DecodeGossip([]byte, proto.Message) error
    DecodeWithMaxLength(io.Reader, proto.Message) error

    // 编码
    EncodeGossip(proto.Message) ([]byte, error)
    EncodeWithMaxLength(io.Writer, proto.Message) (int, error)

    // 协议后缀
    ProtocolSuffix() string
}
```

### 5.4.3 SSZ+Snappy 实现

```go
// 来自prysm/beacon-chain/p2p/encoder/ssz.go
const (
    // 协议后缀
    ProtocolSuffixSSZSnappy = "ssz_snappy"
)

type SszNetworkEncoder struct{}

func (e *SszNetworkEncoder) ProtocolSuffix() string {
    return ProtocolSuffixSSZSnappy
}

// Gossip编码（带varint长度前缀）
func (e *SszNetworkEncoder) EncodeGossip(msg proto.Message) ([]byte, error) {
    // 1. SSZ序列化
    sszData, err := msg.MarshalSSZ()
    if err != nil {
        return nil, err
    }

    // 2. 验证大小
    if uint64(len(sszData)) > params.BeaconNetworkConfig().GossipMaxSize {
        return nil, fmt.Errorf("gossip message exceeds max size")
    }

    // 3. Snappy压缩
    compressed := snappy.Encode(nil, sszData)

    // 4. 添加varint长度前缀
    buf := new(bytes.Buffer)
    if _, err := buf.Write(proto.EncodeVarint(uint64(len(compressed)))); err != nil {
        return nil, err
    }
    if _, err := buf.Write(compressed); err != nil {
        return nil, err
    }

    return buf.Bytes(), nil
}

// Gossip解码
func (e *SszNetworkEncoder) DecodeGossip(b []byte, msg proto.Message) error {
    // 1. 读取varint长度
    length, err := readVarint(bytes.NewReader(b))
    if err != nil {
        return err
    }

    // 2. 验证长度
    if length > params.BeaconNetworkConfig().GossipMaxSize {
        return fmt.Errorf("gossip message too large")
    }

    // 3. Snappy解压
    decompressed, err := snappy.Decode(nil, b[varintSize:])
    if err != nil {
        return err
    }

    // 4. SSZ反序列化
    return msg.UnmarshalSSZ(decompressed)
}

// Req/Resp编码（无长度前缀，用于stream）
func (e *SszNetworkEncoder) EncodeWithMaxLength(
    w io.Writer,
    msg proto.Message,
) (int, error) {
    // 1. SSZ序列化
    sszData, err := msg.MarshalSSZ()
    if err != nil {
        return 0, err
    }

    // 2. Snappy压缩
    compressed := snappy.Encode(nil, sszData)

    // 3. 写入流
    return w.Write(compressed)
}

// Req/Resp解码
func (e *SszNetworkEncoder) DecodeWithMaxLength(
    r io.Reader,
    msg proto.Message,
) error {
    // 1. 读取压缩数据（带大小限制）
    limitedReader := io.LimitReader(r, int64(maxRpcSize))
    compressed, err := io.ReadAll(limitedReader)
    if err != nil {
        return err
    }

    // 2. Snappy解压
    decompressed, err := snappy.Decode(nil, compressed)
    if err != nil {
        return err
    }

    // 3. SSZ反序列化
    return msg.UnmarshalSSZ(decompressed)
}
```

### 5.4.4 大小限制

```go
// 来自prysm/config/params/network_config.go
const (
    // Gossip消息最大大小: 10 MiB
    GossipMaxSize = 10 * (1 << 20)

    // Req/Resp消息最大大小: 10 MiB
    MaxChunkSize = 10 * (1 << 20)
)
```

---

## 5.5 协议升级

### 5.5.1 版本演进

```
Phase 0 (Genesis):
  - /eth2/beacon_chain/req/status/1
  - /eth2/beacon_chain/req/beacon_blocks_by_range/1
  - /eth2/beacon_chain/req/beacon_blocks_by_root/1

Altair:
  - /eth2/beacon_chain/req/metadata/2  (新增sync committee字段)
  - /eth2/beacon_chain/req/beacon_blocks_by_range/2 (支持Altair区块)
  - /eth2/beacon_chain/req/beacon_blocks_by_root/2

Deneb (EIP-4844):
  - /eth2/beacon_chain/req/blob_sidecars_by_range/1 (新协议)
  - /eth2/beacon_chain/req/blob_sidecars_by_root/1 (新协议)
```

### 5.5.2 兼容性处理

```go
// 同时支持多个版本
func (s *Service) registerMultipleVersions() {
    // 注册v2 (当前版本)
    s.registerRPC(
        p2ptypes.RPCBlocksByRangeTopicV2,
        s.beaconBlocksByRangeRPCHandler,
    )

    // 可选：继续支持v1以保持向后兼容
    // 但通常会移除旧版本支持以简化代码
}

// 客户端按优先级尝试
func (s *Service) sendRequest(pid peer.ID, req proto.Message) error {
    // 优先尝试v2
    err := s.sendWithProtocol(pid, p2ptypes.RPCBlocksByRangeTopicV2, req)
    if err == nil {
        return nil
    }

    // 如果v2失败，可以降级到v1
    // (实际实现中通常不这么做，直接要求peer升级)
    return err
}
```

---

## 5.6 协议选择算法

### 5.6.1 选择策略

```go
// 来自multistream-select规范
// 优先选择最高版本的匹配协议

func selectProtocol(localProtocols, remoteProtocols []string) string {
    // 按版本号降序排序
    sort.Sort(sort.Reverse(sort.StringSlice(localProtocols)))

    // 找到第一个匹配的协议
    for _, local := range localProtocols {
        for _, remote := range remoteProtocols {
            if local == remote {
                return local
            }
        }
    }

    return "" // 无匹配协议
}
```

### 5.6.2 协议不匹配处理

```go
// 如果协议协商失败
func (s *Service) handleProtocolMismatch(pid peer.ID) {
    // 1. 记录日志
    log.WithField("peer", pid).Warn("Protocol negotiation failed")

    // 2. 降低peer评分
    s.cfg.P2P.Peers().Scorers().BadResponsesScorer().Increment(pid)

    // 3. 可能断开连接
    if score := s.cfg.P2P.Peers().Scorers().BadResponsesScorer().Score(pid); score < threshold {
        s.cfg.P2P.Disconnect(pid)
    }
}
```

---

## 5.7 小结

本章介绍了协议协商机制：

- **multistream-select**: 灵活的协议协商框架
- **RPC 协议**: 完整的 Req/Resp 协议集
- **Gossipsub 主题**: 结构化的主题命名
- **SSZ+Snappy 编码**: 高效的序列化和压缩
- **版本管理**: 平滑的协议升级路径
- **错误处理**: 优雅的协商失败处理

协议协商是 P2P 通信的基础，确保节点间能正确交互。

---

**下一章预告**: 第 6 章将深入讲解 discv5 节点发现机制。
