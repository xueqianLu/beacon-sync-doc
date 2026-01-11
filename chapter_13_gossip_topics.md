# 第 13 章 Gossipsub 主题订阅

## 13.1 Beacon 区块主题

### 13.0 Beacon 区块与 Attestation 流程图

为了更直观地理解 Gossipsub 主题在区块与 Attestation 传播中的作用，可以先参考下面的两张主流程图：

- 区块从提议、通过 beacon_block 主题广播，到被其他节点接收并进入 Block Pipeline：

![业务 1：区块主线](img/business1_block_flow.png)

- Attestation 从验证者本地生成、经子网主题广播，到被其他节点接收与处理：

![业务 2：Attestation 主线](img/business2_attestation_flow.png)

更细粒度的子流程（例如区块生成/接收子流程、Attestation 广播/验证子流程）可以在附录中的同步流程图章节中查看：

- 附录：同步相关流程图总览（业务 1 与 业务 2）

### 13.1.1 主题定义

```go
// beacon-chain/p2p/topics.go

const (
    // GossipBlockMessage is the topic for beacon block messages
    GossipBlockMessage = "/eth2/%x/beacon_block"

    // GossipAggregateAndProofMessage is the topic for aggregate attestations
    GossipAggregateAndProofMessage = "/eth2/%x/beacon_aggregate_and_proof"

    // GossipAttestationMessage is the topic for attestations
    GossipAttestationMessage = "/eth2/%x/beacon_attestation_%d"
)

// BlockTopic returns the beacon block topic.
func (p *Service) BlockTopic() string {
    digest, err := p.currentForkDigest()
    if err != nil {
        log.WithError(err).Error("Failed to get fork digest")
        return ""
    }
    return fmt.Sprintf(GossipBlockMessage, digest)
}
```

### 13.1.2 订阅 beacon 区块主题

```go
// beacon-chain/sync/subscriber.go

// subscribeToBlocks subscribes to beacon block gossip topic.
func (s *Service) subscribeToBlocks() error {
    topic := s.cfg.P2P.BlockTopic()

    // 创建订阅
    sub, err := s.cfg.P2P.PubSub().Subscribe(topic)
    if err != nil {
        return errors.Wrapf(err, "failed to subscribe to topic %s", topic)
    }

    s.blockSub = sub

    // 启动消息处理goroutine
    go s.beaconBlockSubscriber(s.ctx, sub)

    log.WithField("topic", topic).Info("Subscribed to beacon block topic")
    return nil
}

// beaconBlockSubscriber processes messages from block topic.
func (s *Service) beaconBlockSubscriber(
    ctx context.Context,
    sub *pubsub.Subscription,
) {
    defer sub.Cancel()

    for {
        msg, err := sub.Next(ctx)
        if err != nil {
            if err == ctx.Err() {
                log.Debug("Context cancelled, stopping block subscriber")
                return
            }
            log.WithError(err).Error("Failed to get next message")
            continue
        }

        // 处理消息
        if err := s.handleBeaconBlockMessage(ctx, msg); err != nil {
            log.WithError(err).Debug("Failed to handle beacon block message")
            tracing.AnnotateError(span, err)
        }
    }
}
```

## 13.2 Attestation 主题

### 13.2.1 Attestation 子网

以太坊信标链使用 64 个 attestation 子网来分散 gossip 流量：

```go
// beacon-chain/p2p/subnets.go

const (
    // AttestationSubnetCount is the number of attestation subnets.
    AttestationSubnetCount = 64
)

// AttestationTopic returns attestation topic for specific subnet.
func (p *Service) AttestationTopic(subnet uint64) string {
    if subnet >= AttestationSubnetCount {
        log.Errorf("Invalid subnet %d", subnet)
        return ""
    }

    digest, err := p.currentForkDigest()
    if err != nil {
        log.WithError(err).Error("Failed to get fork digest")
        return ""
    }

    return fmt.Sprintf(GossipAttestationMessage, digest, subnet)
}

// SubscribeToAttestationSubnets subscribes to attestation subnets.
func (s *Service) SubscribeToAttestationSubnets(subnets []uint64) error {
    for _, subnet := range subnets {
        if err := s.subscribeToAttestationSubnet(subnet); err != nil {
            return errors.Wrapf(err, "failed to subscribe to subnet %d", subnet)
        }
    }
    return nil
}

// subscribeToAttestationSubnet subscribes to a single attestation subnet.
func (s *Service) subscribeToAttestationSubnet(subnet uint64) error {
    topic := s.cfg.P2P.AttestationTopic(subnet)

    // 检查是否已订阅
    s.subnetLock.Lock()
    if _, exists := s.attestationSubs[subnet]; exists {
        s.subnetLock.Unlock()
        return nil
    }

    // 创建订阅
    sub, err := s.cfg.P2P.PubSub().Subscribe(topic)
    if err != nil {
        s.subnetLock.Unlock()
        return errors.Wrapf(err, "failed to subscribe to topic %s", topic)
    }

    s.attestationSubs[subnet] = sub
    s.subnetLock.Unlock()

    // 启动处理goroutine
    go s.attestationSubscriber(s.ctx, sub, subnet)

    log.WithFields(logrus.Fields{
        "subnet": subnet,
        "topic":  topic,
    }).Info("Subscribed to attestation subnet")

    return nil
}
```

### 13.2.2 动态子网管理

节点根据验证者职责动态订阅/取消订阅 attestation 子网：

```go
// beacon-chain/sync/subnet_manager.go

// SubnetManager manages attestation subnet subscriptions.
type SubnetManager struct {
    ctx              context.Context
    sync             *Service
    subnetsToTrack   map[uint64]time.Time  // subnet -> expiration time
    persistentSubnets []uint64              // 持久订阅的子网
    lock             sync.RWMutex
}

// UpdateSubnetSubscriptions updates subnet subscriptions based on duties.
func (sm *SubnetManager) UpdateSubnetSubscriptions(
    epoch primitives.Epoch,
    duties []*ethpb.DutiesResponse_Duty,
) error {
    sm.lock.Lock()
    defer sm.lock.Unlock()

    // 计算需要订阅的子网
    requiredSubnets := make(map[uint64]time.Time)

    for _, duty := range duties {
        if duty.AttesterSlot == 0 {
            continue
        }

        // 计算attestation子网
        subnet := computeSubnetForAttestation(
            duty.CommitteeIndex,
            duty.AttesterSlot,
        )

        // 设置订阅到期时间（提前1个epoch订阅，延后1个epoch取消）
        expirationTime := computeExpirationTime(duty.AttesterSlot)
        requiredSubnets[subnet] = expirationTime
    }

    // 添加持久订阅
    for _, subnet := range sm.persistentSubnets {
        requiredSubnets[subnet] = time.Now().Add(24 * time.Hour)
    }

    // 订阅新子网
    for subnet, expTime := range requiredSubnets {
        if existingExp, exists := sm.subnetsToTrack[subnet]; exists {
            // 更新到期时间
            if expTime.After(existingExp) {
                sm.subnetsToTrack[subnet] = expTime
            }
            continue
        }

        // 新订阅
        if err := sm.sync.subscribeToAttestationSubnet(subnet); err != nil {
            log.WithError(err).Warnf("Failed to subscribe to subnet %d", subnet)
            continue
        }

        sm.subnetsToTrack[subnet] = expTime
    }

    // 清理过期订阅
    now := time.Now()
    for subnet, expTime := range sm.subnetsToTrack {
        if now.After(expTime) {
            sm.unsubscribeFromSubnet(subnet)
            delete(sm.subnetsToTrack, subnet)
        }
    }

    return nil
}

// computeSubnetForAttestation computes attestation subnet.
func computeSubnetForAttestation(
    committeeIndex primitives.CommitteeIndex,
    slot primitives.Slot,
) uint64 {
    committeesPerSlot := params.BeaconConfig().MaxCommitteesPerSlot

    // 公式: (committeeIndex + slot % committeesPerSlot) % AttestationSubnetCount
    return uint64((committeeIndex + primitives.CommitteeIndex(slot%committeesPerSlot)) %
        primitives.CommitteeIndex(AttestationSubnetCount))
}
```

### 13.2.3 持久子网订阅

为了维护网络健康，每个节点需要持久订阅一些随机子网：

```go
// beacon-chain/p2p/subnets.go

// maintainPersistentSubnets maintains persistent subnet subscriptions.
func (s *Service) maintainPersistentSubnets() {
    ticker := time.NewTicker(params.BeaconNetworkConfig().EpochsPerRandomSubnetSubscription)
    defer ticker.Stop()

    // 初始化持久子网
    s.updatePersistentSubnets()

    for {
        select {
        case <-s.ctx.Done():
            return
        case <-ticker.C:
            s.updatePersistentSubnets()
        }
    }
}

// updatePersistentSubnets updates the set of persistent subnets.
func (s *Service) updatePersistentSubnets() {
    // 每个节点持久订阅 RandomSubnetsPerValidator 个子网
    numSubnets := params.BeaconNetworkConfig().RandomSubnetsPerValidator

    // 使用节点ID作为随机源确保稳定性
    nodeID := s.cfg.PeerID
    seed := hashutil.Hash([]byte(nodeID.String()))

    // 生成随机子网列表
    persistentSubnets := make([]uint64, numSubnets)
    for i := uint64(0); i < numSubnets; i++ {
        subnet := binary.LittleEndian.Uint64(seed[i*8:(i+1)*8]) % AttestationSubnetCount
        persistentSubnets[i] = subnet
    }

    log.WithField("subnets", persistentSubnets).Info("Updated persistent subnets")

    // 订阅持久子网
    for _, subnet := range persistentSubnets {
        if err := s.subscribeToAttestationSubnet(subnet); err != nil {
            log.WithError(err).Warnf("Failed to subscribe to persistent subnet %d", subnet)
        }
    }

    s.persistentSubnets = persistentSubnets
}
```

## 13.3 聚合 Attestation 主题

### 13.3.1 聚合证明主题

```go
// beacon-chain/sync/subscriber.go

// subscribeToAggregateAndProof subscribes to aggregate attestation topic.
func (s *Service) subscribeToAggregateAndProof() error {
    topic := s.cfg.P2P.AggregateAndProofTopic()

    // 创建订阅
    sub, err := s.cfg.P2P.PubSub().Subscribe(topic)
    if err != nil {
        return errors.Wrapf(err, "failed to subscribe to topic %s", topic)
    }

    s.aggregateSub = sub

    // 启动处理goroutine
    go s.aggregateAndProofSubscriber(s.ctx, sub)

    log.WithField("topic", topic).Info("Subscribed to aggregate and proof topic")
    return nil
}

// aggregateAndProofSubscriber processes aggregate attestation messages.
func (s *Service) aggregateAndProofSubscriber(
    ctx context.Context,
    sub *pubsub.Subscription,
) {
    defer sub.Cancel()

    for {
        msg, err := sub.Next(ctx)
        if err != nil {
            if err == ctx.Err() {
                return
            }
            log.WithError(err).Error("Failed to get next aggregate message")
            continue
        }

        // 处理聚合证明
        if err := s.handleAggregateAndProof(ctx, msg); err != nil {
            log.WithError(err).Debug("Failed to handle aggregate and proof")
        }
    }
}
```

## 13.4 其他 Gossip 主题

### 13.4.1 退出和削减主题

```go
// beacon-chain/sync/subscriber.go

// subscribeToVoluntaryExits subscribes to voluntary exit messages.
func (s *Service) subscribeToVoluntaryExits() error {
    topic := s.cfg.P2P.VoluntaryExitTopic()
    sub, err := s.cfg.P2P.PubSub().Subscribe(topic)
    if err != nil {
        return errors.Wrap(err, "failed to subscribe to voluntary exits")
    }

    go s.voluntaryExitSubscriber(s.ctx, sub)
    return nil
}

// subscribeToProposerSlashings subscribes to proposer slashing messages.
func (s *Service) subscribeToProposerSlashings() error {
    topic := s.cfg.P2P.ProposerSlashingTopic()
    sub, err := s.cfg.P2P.PubSub().Subscribe(topic)
    if err != nil {
        return errors.Wrap(err, "failed to subscribe to proposer slashings")
    }

    go s.proposerSlashingSubscriber(s.ctx, sub)
    return nil
}

// subscribeToAttesterSlashings subscribes to attester slashing messages.
func (s *Service) subscribeToAttesterSlashings() error {
    topic := s.cfg.P2P.AttesterSlashingTopic()
    sub, err := s.cfg.P2P.PubSub().Subscribe(topic)
    if err != nil {
        return errors.Wrap(err, "failed to subscribe to attester slashings")
    }

    go s.attesterSlashingSubscriber(s.ctx, sub)
    return nil
}
```

### 13.4.2 同步委员会主题

```go
// beacon-chain/sync/subscriber_sync_committee.go

// subscribeToSyncCommitteeTopics subscribes to sync committee topics.
func (s *Service) subscribeToSyncCommitteeTopics() error {
    // 订阅sync committee消息主题
    if err := s.subscribeToSyncCommitteeMessages(); err != nil {
        return err
    }

    // 订阅sync committee contribution主题
    if err := s.subscribeToSyncCommitteeContributions(); err != nil {
        return err
    }

    return nil
}

// subscribeToSyncCommitteeMessages subscribes to sync committee message topics.
func (s *Service) subscribeToSyncCommitteeMessages() error {
    // Sync committee有多个子网
    for i := uint64(0); i < params.BeaconConfig().SyncCommitteeSubnetCount; i++ {
        topic := s.cfg.P2P.SyncCommitteeTopic(i)

        sub, err := s.cfg.P2P.PubSub().Subscribe(topic)
        if err != nil {
            return errors.Wrapf(err, "failed to subscribe to sync committee subnet %d", i)
        }

        go s.syncCommitteeMessageSubscriber(s.ctx, sub, i)

        log.WithField("subnet", i).Debug("Subscribed to sync committee subnet")
    }

    return nil
}
```

## 13.5 主题订阅管理

### 13.5.1 订阅生命周期

```go
// beacon-chain/sync/subscriber.go

// registerSubscribers registers all gossip topic subscribers.
func (s *Service) registerSubscribers() {
    // 核心主题（始终订阅）
    s.subscribeToBlocks()
    s.subscribeToAggregateAndProof()
    s.subscribeToVoluntaryExits()
    s.subscribeToProposerSlashings()
    s.subscribeToAttesterSlashings()

    // 动态主题（根据需要订阅）
    go s.manageAttestationSubnets()

    // Altair后的主题
    if s.cfg.Chain.GenesisTime().Add(
        time.Duration(params.BeaconConfig().AltairForkEpoch) *
        time.Duration(params.BeaconConfig().SlotsPerEpoch) *
        time.Duration(params.BeaconConfig().SecondsPerSlot) * time.Second,
    ).Before(time.Now()) {
        s.subscribeToSyncCommitteeTopics()
    }
}

// unregisterSubscribers cancels all subscriptions.
func (s *Service) unregisterSubscribers() {
    s.subnetLock.Lock()
    defer s.subnetLock.Unlock()

    // 取消区块订阅
    if s.blockSub != nil {
        s.blockSub.Cancel()
    }

    // 取消聚合证明订阅
    if s.aggregateSub != nil {
        s.aggregateSub.Cancel()
    }

    // 取消attestation子网订阅
    for subnet, sub := range s.attestationSubs {
        sub.Cancel()
        log.WithField("subnet", subnet).Debug("Unsubscribed from attestation subnet")
    }

    log.Info("All gossip subscriptions cancelled")
}
```

## 13.6 主题验证器

### 13.6.1 注册验证器

每个 gossip 主题都需要注册一个验证器来验证收到的消息：

```go
// beacon-chain/sync/validate_beacon_blocks.go

// registerGossipValidators registers validators for all gossip topics.
func (s *Service) registerGossipValidators() error {
    // 注册区块验证器
    if err := s.registerBlockValidator(); err != nil {
        return err
    }

    // 注册attestation验证器
    if err := s.registerAttestationValidators(); err != nil {
        return err
    }

    // 注册其他验证器...

    return nil
}

// registerBlockValidator registers block topic validator.
func (s *Service) registerBlockValidator() error {
    topic := s.cfg.P2P.BlockTopic()

    // 注册验证函数
    if err := s.cfg.P2P.PubSub().RegisterTopicValidator(
        topic,
        s.validateBeaconBlockPubSub,
        pubsub.WithValidatorTimeout(pubsubMessageTimeout),
        pubsub.WithValidatorConcurrency(pubsubValidatorConcurrency),
    ); err != nil {
        return errors.Wrap(err, "failed to register block validator")
    }

    log.WithField("topic", topic).Info("Registered block validator")
    return nil
}
```

## 13.7 本章小结

本章详细介绍了 Gossipsub 主题订阅机制：

1. **Beacon 区块主题**：接收最新的 beacon 区块
2. **Attestation 子网**：64 个子网分散 attestation 流量
3. **动态订阅管理**：根据验证者职责动态订阅/取消订阅
4. **持久子网**：维护网络健康的随机持久订阅
5. **聚合证明主题**：接收聚合后的 attestation
6. **其他主题**：退出、削减、同步委员会等
7. **主题验证器**：每个主题的消息验证逻辑

这些主题订阅是 beacon 节点与网络保持同步的关键机制。
