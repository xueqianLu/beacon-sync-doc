# 第11章：Gossipsub协议概述

## 11.1 Gossipsub简介

### 11.1.1 什么是Gossipsub

Gossipsub是一个基于发布/订阅模式的P2P消息传播协议，是libp2p的一部分。在以太坊2.0中，Gossipsub用于实时传播区块、attestation和其他共识消息。

**核心特点：**
- **高效广播**：消息快速传播到所有订阅者
- **冗余传播**：通过多条路径传播消息，提高可靠性
- **网状拓扑**：节点之间形成网状连接
- **主题订阅**：节点可以选择性地订阅感兴趣的主题

### 11.1.2 Gossipsub vs Req/Resp

| 特性 | Gossipsub | Req/Resp |
|------|-----------|----------|
| 通信模式 | 发布/订阅（一对多） | 请求/响应（一对一） |
| 用途 | 实时消息广播 | 历史数据同步 |
| 消息类型 | 最新的区块、attestation | 历史区块、状态 |
| 连接方式 | 持久订阅连接 | 临时请求连接 |
| 延迟 | 低延迟（实时） | 可接受延迟 |

## 11.2 Prysm中的Gossipsub实现

### 11.2.1 Service初始化

```go
// beacon-chain/p2p/service.go
type Service struct {
    host         host.Host
    pubsub       *pubsub.PubSub
    joinedTopics map[string]*pubsub.Topic
    cfg          *Config
}

func NewService(ctx context.Context, cfg *Config) (*Service, error) {
    s := &Service{
        cfg:          cfg,
        joinedTopics: make(map[string]*pubsub.Topic),
    }
    
    // 创建libp2p host
    h, err := libp2p.New(/* 配置选项 */)
    if err != nil {
        return nil, err
    }
    s.host = h
    
    // 创建gossipsub实例
    psOpts := []pubsub.Option{
        pubsub.WithMessageSignaturePolicy(pubsub.StrictSign),
        pubsub.WithNoAuthor(),
        pubsub.WithMessageIdFn(msgIDFunction),
        pubsub.WithSubscriptionFilter(s),
        pubsub.WithPeerOutboundQueueSize(pubsubQueueSize),
        pubsub.WithMaxMessageSize(maxMessageSize),
        pubsub.WithValidateQueueSize(validateQueueSize),
        pubsub.WithValidateThrottle(validateThrottle),
        pubsub.WithGossipSubParams(gossipSubParams()),
    }
    
    gs, err := pubsub.NewGossipSub(ctx, h, psOpts...)
    if err != nil {
        return nil, err
    }
    s.pubsub = gs
    
    return s, nil
}
```

### 11.2.2 GossipSub参数配置

```go
// beacon-chain/p2p/gossip_scoring_params.go
func gossipSubParams() pubsub.GossipSubParams {
    return pubsub.GossipSubParams{
        // 网格参数
        D:   6,  // 目标网格度（每个主题的对等节点数）
        Dlo: 5,  // 最小网格度
        Dhi: 12, // 最大网格度
        Dscore: 4, // 基于分数的额外对等节点数
        Dout: 2,   // 出站连接的最小数量
        
        // Gossip参数
        HistoryLength: 5,      // 消息ID历史长度（epoch数）
        HistoryGossip: 3,      // 用于gossip的历史长度
        Dlazy: 6,              // 延迟传播的对等节点数
        GossipFactor: 0.25,    // 随机gossip的对等节点比例
        
        // 心跳参数
        HeartbeatInterval: 700 * time.Millisecond, // 心跳间隔
        
        // 剪枝参数
        PruneBackoff: 60 * time.Second, // 剪枝后的退避时间
        PrunePeers: 16,                 // 每次剪枝的对等节点数
        
        // 连接管理
        GraftFloodThreshold:   10 * time.Second,
        OpportunisticGraftThreshold: 1, // 分数阈值
        OpportunisticGraftTicks: 60,    // 机会性嫁接的心跳周期
        
        // 消息缓存
        SeenMessagesTTL: 550 * 12 * time.Second, // 已见消息的TTL
    }
}
```

## 11.3 主题管理

### 11.3.1 主题命名规范

在以太坊2.0中，gossip主题遵循特定的命名格式：

```
/eth2/{fork_digest}/{topic_name}/{encoding}
```

**组成部分：**
- `fork_digest`: 4字节，标识当前分叉版本
- `topic_name`: 主题名称（如beacon_block, beacon_aggregate_and_proof等）
- `encoding`: 编码方式（通常是ssz_snappy）

### 11.3.2 主题类型

```go
// beacon-chain/p2p/topics.go
const (
    // 全局主题（所有节点订阅）
    BlockSubnetTopicFormat = "/eth2/%x/beacon_block/%s"
    AttestationSubnetTopicFormat = "/eth2/%x/beacon_attestation_%d/%s"
    AggregateAndProofSubnetTopicFormat = "/eth2/%x/beacon_aggregate_and_proof/%s"
    
    // 验证者相关主题
    ExitSubnetTopicFormat = "/eth2/%x/voluntary_exit/%s"
    ProposerSlashingSubnetTopicFormat = "/eth2/%x/proposer_slashing/%s"
    AttesterSlashingSubnetTopicFormat = "/eth2/%x/attester_slashing/%s"
    
    // 同步委员会主题（Altair后）
    SyncContributionAndProofSubnetTopicFormat = "/eth2/%x/sync_committee_contribution_and_proof/%s"
    SyncCommitteeSubnetTopicFormat = "/eth2/%x/sync_committee_%d/%s"
    
    // Blob相关主题（Deneb后）
    BlobSidecarSubnetTopicFormat = "/eth2/%x/blob_sidecar_%d/%s"
)
```

### 11.3.3 订阅主题

```go
// beacon-chain/p2p/pubsub.go
func (s *Service) JoinTopic(topic string, opts ...pubsub.TopicOpt) (*pubsub.Topic, error) {
    s.joinedTopicsLock.Lock()
    defer s.joinedTopicsLock.Unlock()
    
    // 检查是否已订阅
    if t, ok := s.joinedTopics[topic]; ok {
        return t, nil
    }
    
    // 加入主题
    t, err := s.pubsub.Join(topic, opts...)
    if err != nil {
        return nil, err
    }
    
    s.joinedTopics[topic] = t
    return t, nil
}

// 订阅主题并注册处理器
func (s *Service) SubscribeToTopic(topic string, validator wrappedVal) (*pubsub.Subscription, error) {
    // 加入主题
    t, err := s.JoinTopic(topic)
    if err != nil {
        return nil, err
    }
    
    // 注册验证器
    if err := s.pubsub.RegisterTopicValidator(topic, validator); err != nil {
        return nil, err
    }
    
    // 创建订阅
    sub, err := t.Subscribe()
    if err != nil {
        return nil, err
    }
    
    return sub, nil
}
```

### 11.3.4 动态订阅管理

```go
// beacon-chain/sync/subscriber.go
type RegularSync struct {
    cfg            *Config
    attestationSub *subManager // attestation子网订阅管理器
    syncCommSub    *subManager // 同步委员会订阅管理器
}

// 订阅所有必要的主题
func (r *RegularSync) registerSubscribers() {
    // 订阅beacon block
    r.subscribe(
        "/eth2/%x/beacon_block/%s",
        r.validateBeaconBlockPubSub,
        r.beaconBlockSubscriber,
    )
    
    // 订阅aggregate attestation
    r.subscribe(
        "/eth2/%x/beacon_aggregate_and_proof/%s",
        r.validateAggregateAndProof,
        r.beaconAggregateProofSubscriber,
    )
    
    // 订阅voluntary exit
    r.subscribe(
        "/eth2/%x/voluntary_exit/%s",
        r.validateVoluntaryExit,
        r.voluntaryExitSubscriber,
    )
    
    // 动态订阅attestation子网
    r.subscribeToAttestationSubnets()
    
    // 如果是验证者，订阅同步委员会
    if r.cfg.IsValidator {
        r.subscribeToSyncCommitteeSubnets()
    }
}

// 订阅attestation子网（动态）
func (r *RegularSync) subscribeToAttestationSubnets() {
    // Attestation被分散到64个子网中
    for i := uint64(0); i < attestationSubnetCount; i++ {
        topic := fmt.Sprintf("/eth2/%x/beacon_attestation_%d/%s", 
            r.cfg.ForkDigest, i, r.cfg.Encoding)
        
        // 根据需要动态订阅/取消订阅
        if r.shouldSubscribeSubnet(i) {
            r.attestationSub.subscribe(topic, i)
        }
    }
}
```

## 11.4 消息发布

### 11.4.1 发布消息

```go
// beacon-chain/p2p/broadcaster.go
func (s *Service) Broadcast(ctx context.Context, msg proto.Message) error {
    // 确定消息类型对应的主题
    topic := topicFromMessage(msg)
    
    // 序列化消息
    buf := new(bytes.Buffer)
    if _, err := s.cfg.Encoder.EncodeGossip(buf, msg); err != nil {
        return err
    }
    
    // 获取主题对象
    t, ok := s.joinedTopics[topic]
    if !ok {
        return fmt.Errorf("topic %s not joined", topic)
    }
    
    // 发布消息
    return t.Publish(ctx, buf.Bytes())
}
```

### 11.4.2 消息编码

```go
// beacon-chain/p2p/encoder/ssz.go
type SszNetworkEncoder struct{}

func (e SszNetworkEncoder) EncodeGossip(w io.Writer, msg interface{}) (int, error) {
    // SSZ序列化
    b, err := msg.(ssz.Marshaler).MarshalSSZ()
    if err != nil {
        return 0, err
    }
    
    // Snappy压缩
    compressed := snappy.Encode(nil, b)
    
    // 写入数据
    return w.Write(compressed)
}

func (e SszNetworkEncoder) DecodeGossip(b []byte, to interface{}) error {
    // Snappy解压
    decompressed, err := snappy.Decode(nil, b)
    if err != nil {
        return err
    }
    
    // SSZ反序列化
    return to.(ssz.Unmarshaler).UnmarshalSSZ(decompressed)
}
```

## 11.5 消息验证

### 11.5.1 验证器注册

```go
// beacon-chain/sync/validate_beacon_block.go
type wrappedVal func(context.Context, peer.ID, *pubsub.Message) pubsub.ValidationResult

func (r *RegularSync) validateBeaconBlockPubSub(ctx context.Context, pid peer.ID, msg *pubsub.Message) pubsub.ValidationResult {
    // 检查消息是否已经处理过
    if msg.ValidatorData != nil {
        return pubsub.ValidationAccept
    }
    
    // 解码消息
    blk := new(ethpb.SignedBeaconBlock)
    if err := r.cfg.P2P.Encoding().DecodeGossip(msg.Data, blk); err != nil {
        return pubsub.ValidationReject
    }
    
    // 基本验证
    if blk.Block == nil {
        return pubsub.ValidationReject
    }
    
    // 验证区块签名
    if err := r.validateBeaconBlockSignature(ctx, blk); err != nil {
        return pubsub.ValidationReject
    }
    
    // 验证区块是否来自正确的proposer
    if err := r.validateProposer(ctx, blk); err != nil {
        return pubsub.ValidationReject
    }
    
    // 验证区块时间是否合理
    if err := r.validateBlockTime(blk); err != nil {
        return pubsub.ValidationIgnore
    }
    
    // 检查父区块是否存在
    parentExists := r.cfg.BeaconDB.HasBlock(ctx, bytesutil.ToBytes32(blk.Block.ParentRoot))
    if !parentExists {
        // 父区块不存在，需要同步
        r.pendingQueueLock.Lock()
        r.insertBlockToPendingQueue(blk.Block.Slot, blk, bytesutil.ToBytes32(blk.Block.ParentRoot))
        r.pendingQueueLock.Unlock()
        return pubsub.ValidationIgnore
    }
    
    // 完整验证（状态转换）
    if err := r.validateBeaconBlock(ctx, blk); err != nil {
        return pubsub.ValidationReject
    }
    
    // 缓存验证结果
    msg.ValidatorData = blk
    
    return pubsub.ValidationAccept
}
```

### 11.5.2 验证流程

```
消息到达
   ↓
[快速检查]
• 消息大小
• 消息格式
• 基本字段
   ↓
[签名验证]
• 验证消息签名
• 验证proposer/attester
   ↓
[上下文验证]
• 检查时间窗口
• 检查父区块
• 检查状态一致性
   ↓
[完整验证]
• 状态转换验证
• fork choice更新
   ↓
[结果]
Accept/Reject/Ignore
```

### 11.5.3 验证结果

```go
// 验证结果类型
const (
    ValidationAccept pubsub.ValidationResult = iota // 接受并转发
    ValidationReject                                 // 拒绝并惩罚发送者
    ValidationIgnore                                 // 忽略但不惩罚
)
```

**返回策略：**
- **Accept**: 消息有效，转发给其他节点
- **Reject**: 消息无效（如签名错误），拒绝并可能降低发送者分数
- **Ignore**: 消息暂时无法验证（如父区块未知），不转发但不惩罚发送者

## 11.6 消息处理流程

### 11.6.1 订阅处理循环

```go
// beacon-chain/sync/subscriber.go
func (r *RegularSync) beaconBlockSubscriber(ctx context.Context, msg proto.Message) error {
    signed, ok := msg.(*ethpb.SignedBeaconBlock)
    if !ok {
        return fmt.Errorf("message is not type *ethpb.SignedBeaconBlock")
    }
    
    // 检查区块是否已经处理
    blockRoot, err := signed.Block.HashTreeRoot()
    if err != nil {
        return err
    }
    
    if r.cfg.BeaconDB.HasBlock(ctx, blockRoot) {
        return nil
    }
    
    // 处理区块
    return r.receiveBlock(ctx, signed, blockRoot)
}

func (r *RegularSync) receiveBlock(ctx context.Context, signed *ethpb.SignedBeaconBlock, blockRoot [32]byte) error {
    // 保存区块到数据库
    if err := r.cfg.BeaconDB.SaveBlock(ctx, signed); err != nil {
        return err
    }
    
    // 更新fork choice
    if err := r.cfg.ForkChoiceStore.ProcessBlock(ctx, signed.Block, blockRoot); err != nil {
        return err
    }
    
    // 触发状态转换
    if err := r.cfg.StateGen.SaveState(ctx, blockRoot, signed.Block.Slot); err != nil {
        return err
    }
    
    // 处理pending队列中依赖此区块的区块
    r.processPendingBlocks(ctx)
    
    return nil
}
```

### 11.6.2 Attestation处理

```go
// beacon-chain/sync/subscriber.go
func (r *RegularSync) committeeIndexBeaconAttestationSubscriber(ctx context.Context, msg proto.Message) error {
    att, ok := msg.(*ethpb.Attestation)
    if !ok {
        return errors.New("message is not type *ethpb.Attestation")
    }
    
    // 验证attestation的有效性
    if err := r.validateAttestation(ctx, att); err != nil {
        return err
    }
    
    // 添加到attestation池
    if err := r.cfg.AttPool.SaveUnaggregatedAttestation(att); err != nil {
        return err
    }
    
    // 更新fork choice
    r.cfg.ForkChoiceStore.ProcessAttestation(ctx, att)
    
    return nil
}
```

## 11.7 Peer分数系统

### 11.7.1 分数参数

Prysm实现了一个复杂的peer评分系统，用于激励良好行为和惩罚不良行为。

```go
// beacon-chain/p2p/gossip_scoring_params.go
func (s *Service) peerScoringParams() (*pubsub.PeerScoreParams, *pubsub.PeerScoreThresholds) {
    thresholds := &pubsub.PeerScoreThresholds{
        GossipThreshold:             -4000, // 低于此分数不转发gossip
        PublishThreshold:            -8000, // 低于此分数不接受发布
        GraylistThreshold:           -16000, // 低于此分数加入灰名单
        AcceptPXThreshold:           100,   // peer交换接受阈值
        OpportunisticGraftThreshold: 5,     // 机会性嫁接阈值
    }
    
    params := &pubsub.PeerScoreParams{
        Topics:        make(map[string]*pubsub.TopicScoreParams),
        TopicScoreCap: 32.72,
        AppSpecificScore: func(p peer.ID) float64 {
            return s.connectivityScore(p)
        },
        AppSpecificWeight: 1.0,
        
        // IP共置因子（防止女巫攻击）
        IPColocationFactorWeight:    -35.11,
        IPColocationFactorThreshold: 10,
        
        // 行为惩罚
        BehaviourPenaltyWeight: -15.92,
        BehaviourPenaltyDecay:  0.9857, // 每个epoch衰减
        
        DecayInterval: 12 * time.Second, // slot时间
        DecayToZero:   0.01,
        RetainScore:   100 * 12 * time.Second, // 保留分数时间
    }
    
    return params, thresholds
}
```

### 11.7.2 主题分数

```go
// 每个主题的评分参数
func (s *Service) topicScoreParams(topic string) *pubsub.TopicScoreParams {
    switch {
    case strings.Contains(topic, "beacon_block"):
        return s.blockTopicParams()
    case strings.Contains(topic, "beacon_aggregate_and_proof"):
        return s.aggregateTopicParams()
    case strings.Contains(topic, "beacon_attestation"):
        return s.attestationTopicParams()
    default:
        return s.defaultTopicParams()
    }
}

func (s *Service) blockTopicParams() *pubsub.TopicScoreParams {
    return &pubsub.TopicScoreParams{
        TopicWeight: 0.5, // 区块主题权重
        
        // 时间在网格中的分数
        TimeInMeshWeight:  0.03333,
        TimeInMeshQuantum: 12 * time.Second,
        TimeInMeshCap:     300, // 最多300个slot
        
        // 首次消息传递分数
        FirstMessageDeliveriesWeight: 1.1471,
        FirstMessageDeliveriesDecay:  0.9916,
        FirstMessageDeliveriesCap:    179, // 约1个epoch
        
        // 网格消息传递分数
        MeshMessageDeliveriesWeight:     -458.31,
        MeshMessageDeliveriesDecay:      0.9716,
        MeshMessageDeliveriesThreshold:  0.6849, // 60个slot约0.68个区块
        MeshMessageDeliveriesCap:        2.0547,
        MeshMessageDeliveriesActivation: 384 * time.Second, // 32个slot
        MeshMessageDeliveriesWindow:     2 * time.Second,
        
        // 网格失败惩罚
        MeshFailurePenaltyWeight: -458.31,
        MeshFailurePenaltyDecay:  0.9716,
        
        // 无效消息惩罚
        InvalidMessageDeliveriesWeight: -214.99,
        InvalidMessageDeliveriesDecay:  0.9971,
    }
}
```

### 11.7.3 分数更新

分数系统实时评估peer的行为：

```go
// 影响分数的因素
type PeerBehavior struct {
    // 正面因素
    TimeInMesh              time.Duration // 在mesh网络中的时间
    FirstMessageDeliveries  int          // 首次传递的消息数
    MeshMessageDeliveries   int          // 在mesh中传递的消息数
    
    // 负面因素
    InvalidMessages         int          // 无效消息数
    MeshMessageDeficit      int          // mesh消息不足
    IPColocation           int          // IP共置数量
    BehaviourPenalty       float64      // 行为惩罚
}
```

## 11.8 小结

Gossipsub协议是beacon链实时通信的核心：

1. **高效广播**：通过mesh网络快速传播新区块和attestation
2. **可靠传播**：多路径冗余确保消息到达
3. **动态订阅**：根据需要订阅/取消订阅主题
4. **严格验证**：多级验证确保消息有效性
5. **激励机制**：peer评分系统激励良好行为

在下一章中，我们将深入探讨各种初始同步策略。
