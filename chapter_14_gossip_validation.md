# 第14章 Gossip消息验证

## 14.1 验证流程概述

### 14.1.1 Pubsub验证机制

Gossipsub使用三层验证结果：

```go
// Validation results
const (
    pubsub.ValidationAccept  // 接受并转发
    pubsub.ValidationReject  // 拒绝并惩罚发送者
    pubsub.ValidationIgnore  // 忽略但不惩罚
)
```

### 14.1.2 验证流程

```
收到消息
    ↓
基础检查 (大小、格式等)
    ↓
签名验证
    ↓
语义验证 (时间、状态等)
    ↓
返回验证结果
```

## 14.2 Beacon区块验证

### 14.2.1 区块验证器

```go
// beacon-chain/sync/validate_beacon_block.go

// validateBeaconBlockPubSub validates beacon block from gossip.
func (s *Service) validateBeaconBlockPubSub(
    ctx context.Context,
    pid peer.ID,
    msg *pubsub.Message,
) pubsub.ValidationResult {
    // 1. 记录收到时间用于性能分析
    receivedTime := time.Now()
    
    // 2. 解码消息
    signed, err := s.decodeBlockMessage(msg.Data)
    if err != nil {
        log.WithError(err).Debug("Failed to decode block message")
        return pubsub.ValidationReject
    }
    
    block := signed.Block()
    blockRoot, err := block.HashTreeRoot()
    if err != nil {
        log.WithError(err).Error("Failed to compute block root")
        return pubsub.ValidationIgnore
    }
    
    // 3. 基础检查
    if result := s.validateBlockBasics(ctx, signed, blockRoot); result != pubsub.ValidationAccept {
        return result
    }
    
    // 4. 检查是否已seen
    if s.hasSeenBlockRoot(blockRoot) {
        return pubsub.ValidationIgnore
    }
    
    // 5. 验证提案者签名
    if err := s.validateBlockSignature(ctx, signed); err != nil {
        log.WithError(err).Debug("Block signature validation failed")
        return pubsub.ValidationReject
    }
    
    // 6. 状态转换验证
    if result := s.validateBlockStateTransition(ctx, signed); result != pubsub.ValidationAccept {
        return result
    }
    
    // 7. 执行payload验证 (post-merge)
    if block.Body().ExecutionPayload() != nil {
        if result := s.validateExecutionPayload(ctx, signed); result != pubsub.ValidationAccept {
            return result
        }
    }
    
    // 8. 标记为已seen
    s.setSeenBlockRoot(blockRoot)
    
    // 记录验证时间
    validationDuration := time.Since(receivedTime)
    log.WithFields(logrus.Fields{
        "slot":     block.Slot(),
        "root":     fmt.Sprintf("%#x", blockRoot),
        "duration": validationDuration,
    }).Debug("Block validation completed")
    
    return pubsub.ValidationAccept
}
```

### 14.2.2 基础检查

```go
// validateBlockBasics performs basic block validation.
func (s *Service) validateBlockBasics(
    ctx context.Context,
    signed interfaces.SignedBeaconBlock,
    blockRoot [32]byte,
) pubsub.ValidationResult {
    block := signed.Block()
    
    // 1. Slot范围检查
    currentSlot := s.cfg.Chain.CurrentSlot()
    blockSlot := block.Slot()
    
    // 区块不能来自未来
    if blockSlot > currentSlot {
        log.WithFields(logrus.Fields{
            "blockSlot":   blockSlot,
            "currentSlot": currentSlot,
        }).Debug("Block is from the future")
        return pubsub.ValidationIgnore
    }
    
    // 区块不能太旧（超过一个epoch）
    if currentSlot > blockSlot+params.BeaconConfig().SlotsPerEpoch {
        log.Debug("Block is too old")
        return pubsub.ValidationIgnore
    }
    
    // 2. 检查是否finalized
    finalizedEpoch := s.cfg.Chain.FinalizedCheckpoint().Epoch
    finalizedSlot := finalizedEpoch * params.BeaconConfig().SlotsPerEpoch
    
    if blockSlot <= finalizedSlot {
        log.Debug("Block is before finalized checkpoint")
        return pubsub.ValidationIgnore
    }
    
    // 3. 检查是否已在数据库中
    if s.cfg.BeaconDB.HasBlock(ctx, blockRoot) {
        return pubsub.ValidationIgnore
    }
    
    // 4. 检查提案者索引
    if block.ProposerIndex() >= primitives.ValidatorIndex(s.cfg.Chain.HeadValidatorsCount()) {
        log.WithField("proposerIndex", block.ProposerIndex()).
            Debug("Invalid proposer index")
        return pubsub.ValidationReject
    }
    
    return pubsub.ValidationAccept
}
```

### 14.2.3 签名验证

```go
// validateBlockSignature validates block proposer signature.
func (s *Service) validateBlockSignature(
    ctx context.Context,
    signed interfaces.SignedBeaconBlock,
) error {
    block := signed.Block()
    
    // 1. 获取提案者公钥
    proposerIndex := block.ProposerIndex()
    pubkey, err := s.cfg.Chain.ValidatorPubKey(proposerIndex)
    if err != nil {
        return errors.Wrap(err, "failed to get proposer public key")
    }
    
    // 2. 计算签名域
    domain, err := s.cfg.Chain.SigningDomain(
        params.BeaconConfig().DomainBeaconProposer,
        slots.ToEpoch(block.Slot()),
    )
    if err != nil {
        return errors.Wrap(err, "failed to get signing domain")
    }
    
    // 3. 计算签名根
    blockRoot, err := block.HashTreeRoot()
    if err != nil {
        return errors.Wrap(err, "failed to compute block root")
    }
    
    signingRoot, err := computeSigningRoot(blockRoot, domain)
    if err != nil {
        return errors.Wrap(err, "failed to compute signing root")
    }
    
    // 4. 验证签名
    signature := signed.Signature()
    if !signature.Verify(pubkey, signingRoot[:]) {
        return errors.New("signature verification failed")
    }
    
    return nil
}
```

### 14.2.4 状态转换验证

```go
// validateBlockStateTransition validates block state transition.
func (s *Service) validateBlockStateTransition(
    ctx context.Context,
    signed interfaces.SignedBeaconBlock,
) pubsub.ValidationResult {
    block := signed.Block()
    parentRoot := block.ParentRoot()
    
    // 1. 获取父区块
    if !s.cfg.BeaconDB.HasBlock(ctx, parentRoot) {
        // 父区块缺失，加入pending队列
        log.WithField("parentRoot", fmt.Sprintf("%#x", parentRoot)).
            Debug("Parent block not found, adding to pending queue")
        
        s.addBlockToPendingQueue(signed)
        return pubsub.ValidationIgnore
    }
    
    parentBlock, err := s.cfg.BeaconDB.Block(ctx, parentRoot)
    if err != nil {
        log.WithError(err).Error("Failed to get parent block")
        return pubsub.ValidationIgnore
    }
    
    // 2. 验证slot连续性
    if block.Slot() <= parentBlock.Block().Slot() {
        log.Debug("Block slot is not greater than parent slot")
        return pubsub.ValidationReject
    }
    
    // 3. 获取父状态
    parentState, err := s.cfg.StateGen.StateByRoot(ctx, parentRoot)
    if err != nil {
        log.WithError(err).Error("Failed to get parent state")
        return pubsub.ValidationIgnore
    }
    
    // 4. 快速状态转换验证（不保存状态）
    if err := s.validateStateTransition(ctx, parentState, signed); err != nil {
        log.WithError(err).Debug("State transition validation failed")
        return pubsub.ValidationReject
    }
    
    return pubsub.ValidationAccept
}

// validateStateTransition performs state transition validation.
func (s *Service) validateStateTransition(
    ctx context.Context,
    preState state.BeaconState,
    signed interfaces.SignedBeaconBlock,
) error {
    // 使用state transition来验证区块
    // 注意：这里不保存状态，只是验证
    _, err := transition.ExecuteStateTransition(
        ctx,
        preState,
        signed,
    )
    
    return err
}
```

## 14.3 Attestation验证

### 14.3.1 Attestation验证器

```go
// beacon-chain/sync/validate_attestation.go

// validateAttestation validates attestation from gossip subnet.
func (s *Service) validateAttestation(
    ctx context.Context,
    pid peer.ID,
    msg *pubsub.Message,
    subnet uint64,
) pubsub.ValidationResult {
    receivedTime := time.Now()
    
    // 1. 解码attestation
    att := &ethpb.Attestation{}
    if err := att.UnmarshalSSZ(msg.Data); err != nil {
        log.WithError(err).Debug("Failed to unmarshal attestation")
        return pubsub.ValidationReject
    }
    
    // 2. 基础检查
    if result := s.validateAttestationBasics(ctx, att, subnet); result != pubsub.ValidationAccept {
        return result
    }
    
    // 3. 检查是否已seen
    attRoot, err := att.Data.HashTreeRoot()
    if err != nil {
        return pubsub.ValidationIgnore
    }
    
    if s.hasSeenAttestation(attRoot) {
        return pubsub.ValidationIgnore
    }
    
    // 4. 验证聚合位
    if err := s.validateAggregationBits(att); err != nil {
        log.WithError(err).Debug("Aggregation bits validation failed")
        return pubsub.ValidationReject
    }
    
    // 5. 验证委员会索引
    if err := s.validateCommitteeIndex(ctx, att); err != nil {
        log.WithError(err).Debug("Committee index validation failed")
        return pubsub.ValidationReject
    }
    
    // 6. 验证签名
    if err := s.validateAttestationSignature(ctx, att); err != nil {
        log.WithError(err).Debug("Attestation signature validation failed")
        return pubsub.ValidationReject
    }
    
    // 7. 标记为已seen
    s.setSeenAttestation(attRoot)
    
    validationDuration := time.Since(receivedTime)
    log.WithFields(logrus.Fields{
        "slot":     att.Data.Slot,
        "duration": validationDuration,
    }).Debug("Attestation validation completed")
    
    return pubsub.ValidationAccept
}
```

### 14.3.2 Attestation基础检查

```go
// validateAttestationBasics performs basic attestation checks.
func (s *Service) validateAttestationBasics(
    ctx context.Context,
    att *ethpb.Attestation,
    subnet uint64,
) pubsub.ValidationResult {
    // 1. Slot范围检查
    currentSlot := s.cfg.Chain.CurrentSlot()
    attSlot := att.Data.Slot
    
    // Attestation必须在当前或前一个epoch
    if attSlot+params.BeaconConfig().SlotsPerEpoch < currentSlot {
        log.Debug("Attestation is too old")
        return pubsub.ValidationIgnore
    }
    
    // Attestation不能来自未来
    if attSlot > currentSlot {
        log.Debug("Attestation is from the future")
        return pubsub.ValidationIgnore
    }
    
    // 2. 验证子网分配
    expectedSubnet := computeSubnetForAttestation(
        att.Data.CommitteeIndex,
        att.Data.Slot,
    )
    
    if expectedSubnet != subnet {
        log.WithFields(logrus.Fields{
            "expected": expectedSubnet,
            "actual":   subnet,
        }).Debug("Attestation on wrong subnet")
        return pubsub.ValidationReject
    }
    
    // 3. 验证target epoch
    targetEpoch := att.Data.Target.Epoch
    slotEpoch := slots.ToEpoch(attSlot)
    
    if targetEpoch != slotEpoch {
        log.Debug("Target epoch does not match slot epoch")
        return pubsub.ValidationReject
    }
    
    // 4. 验证LMD vote (beacon block root)
    blockRoot := bytesutil.ToBytes32(att.Data.BeaconBlockRoot)
    if !s.cfg.BeaconDB.HasBlock(ctx, blockRoot) && 
       !s.cfg.ForkChoiceStore.HasNode(blockRoot) {
        // 区块未知，可能需要同步
        log.WithField("blockRoot", fmt.Sprintf("%#x", blockRoot)).
            Debug("Attestation references unknown block")
        return pubsub.ValidationIgnore
    }
    
    return pubsub.ValidationAccept
}
```

### 14.3.3 聚合位验证

```go
// validateAggregationBits validates attestation aggregation bits.
func (s *Service) validateAggregationBits(att *ethpb.Attestation) error {
    // 1. 检查aggregation bits不为空
    if att.AggregationBits.Count() == 0 {
        return errors.New("attestation has no aggregation bits set")
    }
    
    // 2. 对于单个attestation (gossip)，应该只有一个bit被设置
    if att.AggregationBits.Count() != 1 {
        return fmt.Errorf("expected exactly 1 aggregation bit, got %d",
            att.AggregationBits.Count())
    }
    
    // 3. 检查长度是否匹配委员会大小
    committeeSize, err := s.cfg.Chain.CommitteeSize(
        att.Data.Slot,
        att.Data.CommitteeIndex,
    )
    if err != nil {
        return errors.Wrap(err, "failed to get committee size")
    }
    
    if att.AggregationBits.Len() != committeeSize {
        return fmt.Errorf("aggregation bits length %d does not match committee size %d",
            att.AggregationBits.Len(), committeeSize)
    }
    
    return nil
}
```

### 14.3.4 Attestation签名验证

```go
// validateAttestationSignature validates attestation signature.
func (s *Service) validateAttestationSignature(
    ctx context.Context,
    att *ethpb.Attestation,
) error {
    // 1. 获取attestation委员会
    committee, err := s.cfg.Chain.Committee(
        att.Data.Slot,
        att.Data.CommitteeIndex,
    )
    if err != nil {
        return errors.Wrap(err, "failed to get committee")
    }
    
    // 2. 获取attester的索引
    setBits := att.AggregationBits.BitIndices()
    if len(setBits) != 1 {
        return errors.New("expected exactly one attester")
    }
    
    attesterIndex := committee[setBits[0]]
    
    // 3. 获取attester公钥
    pubkey, err := s.cfg.Chain.ValidatorPubKey(attesterIndex)
    if err != nil {
        return errors.Wrap(err, "failed to get validator public key")
    }
    
    // 4. 计算签名域
    domain, err := s.cfg.Chain.SigningDomain(
        params.BeaconConfig().DomainBeaconAttester,
        att.Data.Target.Epoch,
    )
    if err != nil {
        return errors.Wrap(err, "failed to get signing domain")
    }
    
    // 5. 计算签名根
    dataRoot, err := att.Data.HashTreeRoot()
    if err != nil {
        return errors.Wrap(err, "failed to compute attestation data root")
    }
    
    signingRoot, err := computeSigningRoot(dataRoot, domain)
    if err != nil {
        return errors.Wrap(err, "failed to compute signing root")
    }
    
    // 6. 验证签名
    sig, err := bls.SignatureFromBytes(att.Signature)
    if err != nil {
        return errors.Wrap(err, "failed to parse signature")
    }
    
    if !sig.Verify(pubkey, signingRoot[:]) {
        return errors.New("signature verification failed")
    }
    
    return nil
}
```

## 14.4 聚合Attestation验证

### 14.4.1 聚合证明验证器

```go
// beacon-chain/sync/validate_aggregate_proof.go

// validateAggregateAndProof validates aggregate attestation.
func (s *Service) validateAggregateAndProof(
    ctx context.Context,
    pid peer.ID,
    msg *pubsub.Message,
) pubsub.ValidationResult {
    // 1. 解码消息
    aggregate := &ethpb.SignedAggregateAttestationAndProof{}
    if err := aggregate.UnmarshalSSZ(msg.Data); err != nil {
        return pubsub.ValidationReject
    }
    
    agg := aggregate.Message
    att := agg.Aggregate
    
    // 2. 基础检查
    if result := s.validateAggregateBasics(ctx, agg); result != pubsub.ValidationAccept {
        return result
    }
    
    // 3. 检查是否已seen
    attRoot, err := att.Data.HashTreeRoot()
    if err != nil {
        return pubsub.ValidationIgnore
    }
    
    // 使用aggregator index作为seen key的一部分
    seenKey := fmt.Sprintf("%x-%d", attRoot, agg.AggregatorIndex)
    if s.hasSeenAggregate(seenKey) {
        return pubsub.ValidationIgnore
    }
    
    // 4. 验证聚合者索引
    if err := s.validateAggregatorIndex(ctx, agg); err != nil {
        log.WithError(err).Debug("Aggregator index validation failed")
        return pubsub.ValidationReject
    }
    
    // 5. 验证selection proof
    if err := s.validateSelectionProof(ctx, agg); err != nil {
        log.WithError(err).Debug("Selection proof validation failed")
        return pubsub.ValidationReject
    }
    
    // 6. 验证聚合签名
    if err := s.validateAggregateSignature(ctx, att); err != nil {
        log.WithError(err).Debug("Aggregate signature validation failed")
        return pubsub.ValidationReject
    }
    
    // 7. 验证聚合者签名
    if err := s.validateAggregatorSignature(ctx, aggregate); err != nil {
        log.WithError(err).Debug("Aggregator signature validation failed")
        return pubsub.ValidationReject
    }
    
    // 8. 标记为已seen
    s.setSeenAggregate(seenKey)
    
    return pubsub.ValidationAccept
}
```

### 14.4.2 验证聚合者资格

```go
// validateAggregatorIndex validates that the aggregator is in the committee.
func (s *Service) validateAggregatorIndex(
    ctx context.Context,
    agg *ethpb.AggregateAttestationAndProof,
) error {
    att := agg.Aggregate
    
    // 1. 获取委员会
    committee, err := s.cfg.Chain.Committee(
        att.Data.Slot,
        att.Data.CommitteeIndex,
    )
    if err != nil {
        return errors.Wrap(err, "failed to get committee")
    }
    
    // 2. 验证聚合者在委员会中
    found := false
    for _, index := range committee {
        if index == agg.AggregatorIndex {
            found = true
            break
        }
    }
    
    if !found {
        return fmt.Errorf("aggregator index %d not in committee", agg.AggregatorIndex)
    }
    
    return nil
}

// validateSelectionProof validates aggregator selection proof.
func (s *Service) validateSelectionProof(
    ctx context.Context,
    agg *ethpb.AggregateAttestationAndProof,
) error {
    // 1. 获取聚合者公钥
    pubkey, err := s.cfg.Chain.ValidatorPubKey(agg.AggregatorIndex)
    if err != nil {
        return errors.Wrap(err, "failed to get aggregator public key")
    }
    
    // 2. 计算签名域
    domain, err := s.cfg.Chain.SigningDomain(
        params.BeaconConfig().DomainSelectionProof,
        slots.ToEpoch(agg.Aggregate.Data.Slot),
    )
    if err != nil {
        return errors.Wrap(err, "failed to get signing domain")
    }
    
    // 3. 计算签名根 (slot)
    slotRoot, err := ssz.HashTreeRoot(agg.Aggregate.Data.Slot)
    if err != nil {
        return errors.Wrap(err, "failed to compute slot root")
    }
    
    signingRoot, err := computeSigningRoot(slotRoot, domain)
    if err != nil {
        return errors.Wrap(err, "failed to compute signing root")
    }
    
    // 4. 验证selection proof签名
    sig, err := bls.SignatureFromBytes(agg.SelectionProof)
    if err != nil {
        return errors.Wrap(err, "failed to parse selection proof")
    }
    
    if !sig.Verify(pubkey, signingRoot[:]) {
        return errors.New("selection proof verification failed")
    }
    
    // 5. 验证是否被选为聚合者
    modulo := max(1, uint64(len(committee))/params.BeaconConfig().TargetAggregatorsPerCommittee)
    hashBytes := hashutil.Hash(agg.SelectionProof)
    
    if binary.LittleEndian.Uint64(hashBytes[:8])%modulo != 0 {
        return errors.New("validator not selected as aggregator")
    }
    
    return nil
}
```

### 14.4.3 聚合签名验证

```go
// validateAggregateSignature validates the aggregate attestation signature.
func (s *Service) validateAggregateSignature(
    ctx context.Context,
    att *ethpb.Attestation,
) error {
    // 1. 获取委员会
    committee, err := s.cfg.Chain.Committee(
        att.Data.Slot,
        att.Data.CommitteeIndex,
    )
    if err != nil {
        return errors.Wrap(err, "failed to get committee")
    }
    
    // 2. 收集所有attester的公钥
    setBits := att.AggregationBits.BitIndices()
    pubkeys := make([]bls.PublicKey, len(setBits))
    
    for i, bitIndex := range setBits {
        validatorIndex := committee[bitIndex]
        pubkey, err := s.cfg.Chain.ValidatorPubKey(validatorIndex)
        if err != nil {
            return errors.Wrapf(err, "failed to get public key for validator %d", validatorIndex)
        }
        pubkeys[i] = pubkey
    }
    
    // 3. 聚合公钥
    aggregatedPubkey := bls.AggregatePublicKeys(pubkeys)
    
    // 4. 计算签名域
    domain, err := s.cfg.Chain.SigningDomain(
        params.BeaconConfig().DomainBeaconAttester,
        att.Data.Target.Epoch,
    )
    if err != nil {
        return errors.Wrap(err, "failed to get signing domain")
    }
    
    // 5. 计算签名根
    dataRoot, err := att.Data.HashTreeRoot()
    if err != nil {
        return errors.Wrap(err, "failed to compute attestation data root")
    }
    
    signingRoot, err := computeSigningRoot(dataRoot, domain)
    if err != nil {
        return errors.Wrap(err, "failed to compute signing root")
    }
    
    // 6. 验证聚合签名
    sig, err := bls.SignatureFromBytes(att.Signature)
    if err != nil {
        return errors.Wrap(err, "failed to parse signature")
    }
    
    if !sig.Verify(aggregatedPubkey, signingRoot[:]) {
        return errors.New("aggregate signature verification failed")
    }
    
    return nil
}
```

## 14.5 验证缓存优化

### 14.5.1 Seen缓存

```go
// beacon-chain/sync/seen_cache.go

// SeenCache caches seen message roots to avoid reprocessing.
type SeenCache struct {
    blocks      *lru.Cache
    attestations *lru.Cache
    aggregates  *lru.Cache
}

// NewSeenCache creates a new seen cache.
func NewSeenCache() *SeenCache {
    return &SeenCache{
        blocks:       lru.New(seenBlockSize),
        attestations: lru.New(seenAttestationSize),
        aggregates:   lru.New(seenAggregateSize),
    }
}

// hasSeenBlockRoot checks if block root was seen.
func (s *Service) hasSeenBlockRoot(root [32]byte) bool {
    s.seenBlockLock.RLock()
    defer s.seenBlockLock.RUnlock()
    
    _, seen := s.seenBlockCache.Get(root)
    return seen
}

// setSeenBlockRoot marks block root as seen.
func (s *Service) setSeenBlockRoot(root [32]byte) {
    s.seenBlockLock.Lock()
    defer s.seenBlockLock.Unlock()
    
    s.seenBlockCache.Add(root, true)
}
```

### 14.5.2 签名验证批处理

```go
// beacon-chain/sync/batch_verify.go

// BatchVerifier batches signature verifications.
type BatchVerifier struct {
    ctx        context.Context
    signatures []bls.Signature
    pubkeys    []bls.PublicKey
    messages   [][32]byte
    results    []chan error
}

// Add adds a signature verification to the batch.
func (bv *BatchVerifier) Add(
    sig bls.Signature,
    pubkey bls.PublicKey,
    message [32]byte,
) <-chan error {
    resultChan := make(chan error, 1)
    
    bv.signatures = append(bv.signatures, sig)
    bv.pubkeys = append(bv.pubkeys, pubkey)
    bv.messages = append(bv.messages, message)
    bv.results = append(bv.results, resultChan)
    
    return resultChan
}

// Verify performs batch verification.
func (bv *BatchVerifier) Verify() {
    // 批量验证所有签名
    valid := bls.VerifyMultipleSignatures(
        bv.signatures,
        bv.messages,
        bv.pubkeys,
    )
    
    // 返回结果
    for i, resultChan := range bv.results {
        if valid[i] {
            resultChan <- nil
        } else {
            resultChan <- errors.New("signature verification failed")
        }
        close(resultChan)
    }
}
```

## 14.6 本章小结

本章详细介绍了Gossip消息验证机制：

1. **验证流程**：基础检查 → 签名验证 → 语义验证
2. **区块验证**：Slot检查、签名验证、状态转换验证
3. **Attestation验证**：子网验证、委员会验证、签名验证
4. **聚合证明验证**：聚合者资格、selection proof、聚合签名
5. **性能优化**：Seen缓存、批量签名验证

这些验证机制确保了gossip网络中消息的有效性和安全性。
