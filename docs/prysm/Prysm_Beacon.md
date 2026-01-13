# Prysm Beacon 同步模块分析

分析使用的代码版本是 prysm:v5.2.0   
[https://github.com/OffchainLabs/prysm/tree/v5.2.0](https://github.com/OffchainLabs/prysm/tree/v5.2.0) 

# 出块流程

## 出块触发

Prysm 分为两个服务，

- beacon-chain：主要的beacon节点服务，功能包括beacon state的存储和管理, p2p 网络, 数据同步 等等.  
- validator: 主要管理验证者的私钥，通过定时器定时触发检查需要验证者执行的操作，例如 出块, 投票等等.

所以, 出块的起始位置是在 validator 上触发的. 

validator 运行了一个协程，协程入口 [https://github.com/OffchainLabs/prysm/blob/v5.2.0/validator/client/runner.go\#L38](https://github.com/OffchainLabs/prysm/blob/v5.2.0/validator/client/runner.go#L38) ，主要功能有两个：

- 使用定时器定时，在每个slot开始时检查每个验证者需要执行的任务，并执行相应的任务.  
- 监听接收到的 HeadEvent, 更新当前最新的slot.

在slot开始时，validator 调用beacon-chain的接口, 获取他所管理的验证者在当前slot的任务,并在 performRoles 方法中执行这些任务。如果validator管理了多个验证者的私钥，那么每个任务是并发执行的, 等到所有任务执行完成后, performRoles 才会退出. performRoles 方法的上下文ctx 限制了所有任务执行的超时时间为 slotend.  
performRoles 方法的代码如下，这里的 v.ProposeBlock 是一个slot出块的开始位置.  
[https://github.com/OffchainLabs/prysm/blob/v5.2.0/validator/client/runner.go\#L229](https://github.com/OffchainLabs/prysm/blob/v5.2.0/validator/client/runner.go#L229)

| func performRoles(slotCtx context.Context, allRoles map\[\[48\]byte\]\[\]iface.ValidatorRole, v iface.Validator, slot primitives.Slot, wg \*sync.WaitGroup, span trace.Span) {   for pubKey, roles := range allRoles {      wg.Add(len(roles))      for \_, role := range roles {         go func(role iface.ValidatorRole, pubKey \[fieldparams.BLSPubkeyLength\]byte) {            defer wg.Done()            switch role {            case iface.RoleAttester:               v.SubmitAttestation(slotCtx, slot, pubKey)          case iface.RoleProposer:             v.ProposeBlock(slotCtx, slot, pubKey)            case iface.RoleAggregator:               v.SubmitAggregateAndProof(slotCtx, slot, pubKey)            case iface.RoleSyncCommittee:               v.SubmitSyncCommitteeMessage(slotCtx, slot, pubKey)            case iface.RoleSyncCommitteeAggregator:               v.SubmitSignedContributionAndProof(slotCtx, slot, pubKey)            case iface.RoleUnknown:               log.WithField("pubkey", fmt.Sprintf("%\#x", bytesutil.Trunc(pubKey\[:\]))).Trace("No active roles, doing nothing")            default:               log.Warnf("Unhandled role %v", role)            }         }(role, pubKey)      }   }   // Wait for all processes to complete, then report span complete.   go func() {      wg.Wait()      defer span.End()      defer func() {         if err := recover(); err \!= nil { // catch any panic in logging            log.WithField("error", err).               Error("Panic occurred when logging validator report. This" \+                  " should never happen\! Please file a report at github.com/prysmaticlabs/prysm/issues/new")         }      }()      // Log performance in the previous slot      v.LogSubmittedAtts(slot)      v.LogSubmittedSyncCommitteeMessages()      if err := v.LogValidatorGainsAndLosses(slotCtx, slot); err \!= nil {         log.WithError(err).Error("Could not report validator's rewards/penalties")      }   }()} |
| :---- |

## 出块流程

出块的整个过程是 validator 驱动的，分别在validator 和 beacon-chain 两个服务间完成的，下面分别分析.

### 出块流程-Validator

validator 出块的过程在这个函数中, [https://github.com/OffchainLabs/prysm/blob/v5.2.0/validator/client/propose.go\#L46](https://github.com/OffchainLabs/prysm/blob/v5.2.0/validator/client/propose.go#L46) 

简单概括包含一下几步：

- Prepare: 生成 randaoReveal 和 Graffiti  
- GetBeaconBlock: 从beacon-chain 获取组装的区块数据  
- SignBlock: 对区块进行签名  
- ProposeBlock: 将签名后的区块交给 beacon-chain 继续处理

上面的步骤中，任意一个步骤发生了错误，都会导致本次出块失败, 并且不会重试.

### 出块流程-BeaconChain

beacon-chain 被动的由 validator 调用，参与了区块生成的两个步骤, GetBeaconBlock 和 ProposeBlock.

GetBeaconBlock 方法包含以下几个步骤： [https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/rpc/prysm/v1alpha1/validator/proposer.go\#L50](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/rpc/prysm/v1alpha1/validator/proposer.go#L50)

- 如果当前正在同步，那么将立即返回，不能出块  
- 制作区块，填充基础数据(slot, Graffiti, randaoReveal, parentRoot, proposerIndex)  
- 打包Deposit和Attestation  
- 获取并打包执行层数据([https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/rpc/prysm/v1alpha1/validator/proposer\_execution\_payload.go\#L180-L187](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/rpc/prysm/v1alpha1/validator/proposer_execution_payload.go#L180-L187) )  
- 计算state root

其中执行层数据包含以下内容

| message ExecutionPayloadDeneb { bytes parent\_hash           \= 1 \[(ethereum.eth.ext.ssz\_size) \= "32"\]; bytes fee\_recipient         \= 2 \[(ethereum.eth.ext.ssz\_size) \= "20"\]; bytes state\_root            \= 3 \[(ethereum.eth.ext.ssz\_size) \= "32"\]; bytes receipts\_root         \= 4 \[(ethereum.eth.ext.ssz\_size) \= "32"\]; bytes logs\_bloom            \= 5 \[(ethereum.eth.ext.ssz\_size) \= "logs\_bloom.size"\]; bytes prev\_randao           \= 6 \[(ethereum.eth.ext.ssz\_size) \= "32"\]; uint64 block\_number         \= 7; uint64 gas\_limit            \= 8; uint64 gas\_used             \= 9; uint64 timestamp            \= 10; bytes extra\_data            \= 11 \[(ethereum.eth.ext.ssz\_max) \= "extra\_data.size"\]; bytes base\_fee\_per\_gas      \= 12 \[(ethereum.eth.ext.ssz\_size) \= "32"\]; bytes block\_hash            \= 13 \[(ethereum.eth.ext.ssz\_size) \= "32"\]; repeated bytes transactions \= 14 \[(ethereum.eth.ext.ssz\_size) \= "?,?", (ethereum.eth.ext.ssz\_max)  \= "1048576,1073741824"\]; // MAX\_WITHDRAWALS\_PER\_PAYLOAD repeated Withdrawal withdrawals \= 15 \[(ethereum.eth.ext.ssz\_max) \= "withdrawal.size"\]; uint64 blob\_gas\_used  \= 16; uint64 excess\_blob\_gas  \= 17;} |
| :---- |

ProposeBlock 方法包含以下几个步骤:  
[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/rpc/prysm/v1alpha1/validator/proposer.go\#L264](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/rpc/prysm/v1alpha1/validator/proposer.go#L264)

- 广播区块到网络(使用的是pub-sub模型，并非遍历所有peer逐个发送)  
- 将区块存到本地链上并调用执行层执行区块([https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive\_block.go\#L64](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive_block.go#L64) )  
- 广播Blob  
- 将Blob存储到本地 ([https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive\_blob.go\#L16](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive_blob.go#L16) )

# 区块执行

## 共识层

当执行最新的区块时，共识层主要更新的是BeaconState.  
[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive\_block.go\#L64](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive_block.go#L64) 

* 验证者注册表 (Registry): 更新验证者的状态（激活、退出、被罚没）。  
* 余额 (Balances):  
  * 计算并更新所有验证者的余额。  
  * 奖励（Attestation rewards, Sync committee rewards）。  
  * 惩罚（因离线或作恶扣除的 ETH）。  
* 随机数 (RANDAO): 混合新区块中的随机数揭示值，更新全局随机数种子（用于选出下一个 slot 的提议者）。  
* 最终确定性检查点 (Checkpoints):  
  * 更新 JustifiedCheckpoint 和 FinalizedCheckpoint。  
  * 这是 Casper FFG 共识算法的核心，决定了哪些区块已经不可逆转。  
* 分叉选择存储 (Fork Choice Store):  
  * 更新 LMD-GHOST 树的权重。  
  * 将新块设为新的 Head，后续的投票将基于此块进行。

## 执行层

执行层按顺序执行区块中的交易，更新statedb, 生成交易收据,日志等, 以及完成交易池交易的变更.

State的更新

- 账户余额 (Account Balances):  
  - 扣除: 发送方账户扣除 Value \+ GasUsed \* GasPrice。  
  - 增加: 接收方账户增加 Value。  
  - Coinbase: 矿工费（Priority Fee）打入验证者指定的 Fee Recipient 地址。  
- Nonce 值: 发送方账户的 Nonce \+1（防止重放攻击）。  
- 智能合约存储 (Storage Root): 如果交易调用了合约并改变了状态变量（如 ERC20 转账改变了余额映射），合约对应的 Storage Trie 会更新。  
- 合约代码 (Code): 如果是合约创建交易，新合约的代码会被写入。

区块/交易数据

- Receipts (交易收据): 生成并存储每笔交易的执行结果（成功/失败）、消耗的Gas 量。  
- Logs (日志/布隆过滤器): 提取交易执行过程中 emit 的事件（Event），更新区块头的 Bloom Filter，供外部索引查询。

交易池

- 移除已打包交易  
- 如果是链重组，则进行交易回滚与复活  
- BaseFee 重新定价  
- 交易 pending/Queue 状态的更新

新区块的执行步骤：

执行层中, 有承上启下作用的方法是 newPayload, 当beacon收到新区块后，会通过接口调用执行层的 NewPayload 验证执行层数据的正确性，执行层在这个接口下处理区块, 但是并不会将Head更新.  
[https://github.com/ethereum/go-ethereum/blob/v1.16.1/eth/catalyst/api.go\#L660](https://github.com/ethereum/go-ethereum/blob/v1.16.1/eth/catalyst/api.go#L660) 

当共识层达成共识，确定了HeadSlot之后，再通过ForkChoiceUpdate 告知执行层更新Head区块.  
[https://github.com/ethereum/go-ethereum/blob/v1.16.1/eth/catalyst/api.go\#L223](https://github.com/ethereum/go-ethereum/blob/v1.16.1/eth/catalyst/api.go#L223) 

# 

# 区块同步

## 初始同步(initial sync)

触发场景：

- 通常用于新建的beacon节点，将自己同步到一个可信的状态. 共识层和执行层都需要进行初始同步.  
- **在prysm中, 有一个独立的线程定时检测当前节点的HeadSlot 所在的epoch (计作 syncedEpoch)，和所有peer中最高的epoch(可以是尚未finalized, 计作 highestEpoch). 如果 highestEpoch \> (syncedEpoch \+1), 那么也会触发 initial sync.**  
  [https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/rpc\_status.go\#L91](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/rpc_status.go#L91) 

 

### 共识层同步

共识层初始同步采用的策略是 checkpoint sync, beacon-chain 启动时通过 \--checkpoint-sync-url 下载受信任的 BeaconState（包含验证者集合、最新随机数等），以此 State 为基础，仅下载和验证该 Checkpoint 之后的区块.

[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/initial-sync/round\_robin.go\#L43](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/initial-sync/round_robin.go#L43) 

通常共识层的初始同步在几分钟内就可以完成，但是在执行层同步结束之前，它还不能执行出块和投票等操作，只能乐观的认为新的区块是正确的，并暂存起来.

等到执行层同步完成之后，共识层就可以验证每个区块内的交易，也可以进行出块和生产投票.

同步的区块的执行:   
[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive\_block.go\#L291](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/blockchain/receive_block.go#L291) 

#### Peer的选择

共识层定期更新peer的chain status信息, 包含以下内容：  
message Status {  
	bytes fork\_digest \= 1;  
bytes finalized\_root \= 2;  
uint64 finalized\_epoch \= 3;  
bytes head\_root \= 4;  
uint64 head\_slot \= 5;  
}

同步模块使用两个方法来选择同步的目标和可使用的peer列表：

* **BestFinalized**: 在已连接的peer中，找出与自己相同或更高且被最多peer “认同”的 finalized epoch（多数/复数投票），并返回该 epoch 及满足该 epoch 的peer列表（按 finalized epoch 和 head slot 排序并限制数量）。  
* **BestNonFinalized**: 在已连接的peer中，找出比自己更高且被至少 MinPeers 支持的 epoch（基于peer的 head slot 映射到 epoch），返回该 epoch 及满足该 epoch 的peer列表（按 head slot 排序）。

伪代码如下，详细代码见 [https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/p2p/peers/status.go\#L714-L807](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/p2p/peers/status.go#L714-L807) 

| // BestFinalized(maxPeers, ourFinalizedEpoch)func BestFinalized(maxPeers int, ourFinalizedEpoch Epoch) (Epoch, \[\]PeerID) {   connected := ConnectedPeers()   // 统计每个 finalized epoch 的投票数，并保存每个 pid 的 finalized epoch 与 head slot   votes := map\[Epoch\]int{}   pidEpoch := map\[PeerID\]Epoch{}   pidHead := map\[PeerID\]Slot{}   candidates := \[\]PeerID{}   for \_, pid := range connected {       cs, err := ChainState(pid)       if err \!= nil { continue }       if cs.FinalizedEpoch \>= ourFinalizedEpoch {           votes\[cs.FinalizedEpoch\]++           pidEpoch\[pid\] \= cs.FinalizedEpoch           pidHead\[pid\] \= cs.HeadSlot           candidates \= append(candidates, pid)       }   }   // 选出投票最多的 epoch（相同票数时取更高的 epoch）   var target Epoch   var maxVotes int   for e, c := range votes {       if c \> maxVotes || (c \== maxVotes && e \> target) {           maxVotes \= c           target \= e       }   }   // 按 (finalized epoch desc, head slot desc) 排序候选对等点   sort candidates by (pidEpoch\[pid\] desc, pidHead\[pid\] desc)   // 仅保留 finalized epoch \>= target 的对等点   keep := filter candidates where pidEpoch\[pid\] \>= target   // 限制数量到 maxPeers   if len(keep) \> maxPeers { keep \= keep\[:maxPeers\] }   return target, keep}// BestNonFinalized(minPeers, ourHeadEpoch)func BestNonFinalized(minPeers int, ourHeadEpoch Epoch) (Epoch, \[\]PeerID) {   connected := ConnectedPeers()   // 将我们的 epoch 转为 slot 方便比较   ourHeadSlot := SlotsPerEpoch \* ourHeadEpoch   votes := map\[Epoch\]int{}   pidEpoch := map\[PeerID\]Epoch{}   pidHead := map\[PeerID\]Slot{}   candidates := \[\]PeerID{}   for \_, pid := range connected {       cs, err := ChainState(pid)       if err \!= nil { continue }       if cs.HeadSlot \> ourHeadSlot {           e := SlotToEpoch(cs.HeadSlot)           votes\[e\]++           pidEpoch\[pid\] \= e           pidHead\[pid\] \= cs.HeadSlot           candidates \= append(candidates, pid)       }   }   // 找到满足 votes \>= minPeers 的最高 epoch   var target Epoch   for e, c := range votes {       if c \>= minPeers && e \> target {           target \= e       }   }   // 按 head slot 降序排序候选对等点   sort candidates by pidHead\[pid\] desc   // 仅保留 epoch \>= target 的对等点   keep := filter candidates where pidEpoch\[pid\] \>= target   return target, keep} |
| :---- |

Initial 同步时，blockfetcher 将同步任务拆分成多个分片任务，逐步的进行处理。  
假设当前需要从 slot \= 1000 同步到 slot=4000, 那可能会分片成 300个任务，每个请求只索取 10个连续的区块数据.   
300个任务不是一次性全并发的，而是按照先后顺序，有四个分片任务会同时进行处理。  
每个分片任务在没完成的情况下，每隔200毫秒触发一次。  
每个分片任务的处理是独立的，每次都会使用 BestFinalized/BestNonFinalized 方法筛选最优的同步目标以及peer列表，并且会判断筛选出的peer的数量，如果低于MinPeers 会一直等待。然后blockfetcher使用轮询的方式向peer请求区块，如果请求不成功，则向下一个peer进行请求；如果请求成功，则立即返回数据并进行处理。处理成功后，分片任务完成。

总结：单一的作恶节点虚报自己的finalizedEpoch/HeadSlot是无效的，beacon节点会从多个peer中找到最被认可的finalizedEpoch/HeadSlot. 并且同步时，会等peer数量足够时才开始请求数据。如果作恶节点不正常的将数据同步给peer，那么同步者会很快从其他peer拉取数据,不会造成什么影响。

### 执行层同步

执行层初始同步可以有 full sync, snap sync, fast sync 三种模式. 执行层同步的目标区块是由共识层决定的.

- full sync: 从 创世区块 开始，下载每一个区块, 完整执行所有交易，重放所有状态变化, 得到当前世界状态（state trie）  
- snap sync: 下载chunk/segment的方式同步完整的state.  
- fast sync: 下载trie node 的方式同步完整的state. 已经逐渐被snap sync 替代.

snap sync 和 fast sync 的功能相同，但是 snap sync速度更快，是执行层默认的同步方式.

### 共识层和执行层同步的协同

共识层和执行层的同步关系为 “CL 导航，EL 动力，乐观解耦”。  
为了解决 CL 同步快、EL 同步慢（需下载庞大状态树）导致的阻塞问题，CL的同步模式是乐观同步.

- CL 先行：beacon-chain 快速同步到最新区块头，验证共识（签名、随机数），标记区块为 Optimistic。  
- EL 滞后：beacon-chain 将区块载荷（Payload）发给 EL。EL 因还在同步历史状态（Snap Sync），回复 SYNCING。  
- 保持乐观：Prysm 收到 SYNCING 后，不中断同步，继续假设该链有效并跟随。  
- 最终汇合：EL 完成状态同步后，验证待处理的载荷。若有效（VALID），Prysm 将状态更新为完全有效。

关联性：

- 主导权：CL 决定链的方向（分叉选择 LMD-GHOST）。EL 必须跟随 CL 指定的 Head 进行同步。  
- 有效性门槛：只有 EL 验证通过（交易合法、Gas 正确），CL 才会最终确认该区块为 Finalized。

## 历史回填(Backfill Sync)

Backfill Sync 用于补全 beacon节点 checkpoint 之前的历史数据.  
节点完成 Checkpoint Sync 并追上最新网络 Head，进入稳定运行状态之后, 采用倒序的方式从 Checkpoint 向 Genesis 下载历史区块.  
backfill sync 的优先级很低，如果实时同步受阻，backfill 会自动暂停.

https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/backfill/worker.go\#L46

## 常规同步(Regular Sync)

常规同步是当节点短暂离线或断网后重新连接时触发。

触发：beacon节点通过 P2P 握手时的 Status 消息和运行时的 Gossip 广播来实时监控 Peer 的高度。一旦发现某个 Peer 的 HeadSlot 显著高于本地的 HeadSlot（通常有一个小的容差阈值）.

[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/rpc\_status.go\#L29](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/rpc_status.go#L29) 

同步策略：prysm 采用并发且分批的轮训策略，而不是只从一个peer上同步数据.  
拉取缺失的区块时，使用StartSlot \+ Count 参数范围请求.

处理: 将并发下载的区块按照区块的ParentRoot排序, 然后串行处理.

# 同步和出块

### 同步和出块的互斥性

当节点处于 Syncing 模式（is\_optimistic 为 true 或 sync\_distance 较大）时，节点不会尝试出块或证明。这是为了防止在错误的分叉上投票导致被罚没（Slashing）。

当节点已同步，但在出块前一瞬间收到新区块时，出块逻辑不会被打断，新收到的区块会放到队列中等待处理.

# Beacon 节点的peer 是否会周期性变化

Beacon 节点的peer 是存在动态变化的, 导致peer变化的主要有以下几个机制.

### **子网漫游 (Subnet Roaming)**

这是 Beacon 节点 Peer 变动最主要的原因。

* **机制：** 在以太坊 PoS 中，验证者（Validators）被随机分配到不同的 **委员会（Committees）** 中，这些委员会在特定的 **子网（Subnets）** 上进行聚合签名（Attestation）。  
* **周期性：** 验证者的子网分配是短期的（通常持续几个 Epoch）。  
* **过程：** 当一个节点管理的验证者被分配到新的子网时，该节点必须**主动寻找并连接**属于该子网的 Peer，以便及时广播和接收投票。这意味着节点必须断开一些旧的、不再需要的连接，腾出位置给新子网的 Peer。这就在事实上造成了周期性的 Peer 更替。

参数：

[https://github.com/OffchainLabs/prysm/blob/v5.2.0/config/params/config.go\#L16](https://github.com/OffchainLabs/prysm/blob/v5.2.0/config/params/config.go#L16) 

| 参数 | 值 | 说明 |
| :---- | :---- | :---- |
| EpochsPerSubnetSubscription | 256 | 每个subnet的订阅周期 |
| SubnetsPerNode | 2 | 每个节点订阅的持久化subnet数量 |
| AttestationSubnetCount | 64 | 总attestation subnet 数量 |

p2p 子网:

[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/p2p/subnets.go\#L131](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/p2p/subnets.go#L131) 

### **Gossipsub 评分 (Peer Scoring)**

以太坊共识层使用 **Gossipsub v1.1** 作为消息传播协议，它内置了一套复杂的评分系统。

* **评分维度：** 节点会根据 Peer 的表现打分。  
  * *传递消息是否及时？*  
  * *消息是否有效？*  
  * *是否在该节点关注的 Topic（主题/子网）里？*  
* **动态调整 (Gossipsub Heartbeat)：**  
  * **Grafting (嫁接):** 如果一个 Peer 分数高且有用，节点会主动建立/保持与其的网状（Mesh）连接。  
  * **Pruning (修剪):** 如果一个 Peer 分数低（例如只吸血不贡献，或者发送垃圾消息），或者节点连接数已满，Gossipsub 会定期（通过 Heartbeat）切断与其的网状连接。

### **被动轮换**

* **最大连接数 (Max Peers)：** 节点通常设置有最大 Peer 数量限制（例如 Lighthouse 或 Prysm 默认为 50-100 左右）。一旦达到上限，新 Peer 想要进来，或者为了连接高优先级的子网 Peer，旧的 Peer 就可能被“踢掉”。  
* **Discovery v5 (Discv5)：** 即使连接满了，节点的发现协议（Discovery）仍在后台运行，维护一个可连接节点的路由表（DHT）。一旦有空位，新的节点就会补入。

# 

# 

# 多客户端处理 future block 

参数：

- gossip 时钟容忍度: MaximumGossipClockDisparity=500毫秒  
- 容忍区块的提前时间: earlyBlockProcessingTolerance \= slots.MultiplySlotBy(2)  
- 容忍投票的提前时间: earlyAttestationProcessingTolerance \= params.BeaconConfig().MaximumGossipClockDisparityDuration()

prysm:

[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/service.go\#L70-L74](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/service.go#L70-L74)

区块验证：

[https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/validate\_beacon\_blocks.go\#L132-L136](https://github.com/OffchainLabs/prysm/blob/v5.2.0/beacon-chain/sync/validate_beacon_blocks.go#L132-L136) 

处理流程：

收到区块

   │

   ▼

┌──────────────────────────────────────┐

│ 检查: block.slot \> current\_slot \+ 2? │

└──────────────────────────────────────┘

   │ 是                        │ 否

   ▼                          ▼

┌──────────┐     ┌─────────────────────────────────────────────┐

│ 忽略区块  │     │ 检查: slotTime \> currentTime \+ 500ms?       │

└──────────┘     └─────────────────────────────────────────────┘

                     │ 是                           │ 否

                     ▼                             ▼

              ┌─────────────────┐           ┌────────────────┐

              │ 加入pending队列  │           │ 立即处理区块    │

              └─────────────────┘           └────────────────┘

                     │

                     ▼

              ┌──────────────────────────┐

              │ 周期性检查(每slot 3次)    │

              │ 当slot时间到达后处理      │

              └──────────────────────────┘

结论：beacon 接收future block, 但是在验证区块时，区块的时间不能超过当前节点时间2个slot的时长. 

# Attestation 的处理流程

## 1\. 入口与调度

Attestation 的处理不是由网络接收事件驱动的，而是由与 Slot 时钟同步的后台协程驱动的。

* 调度器: spawnProcessAttestationsRoutine  
  * 使用 SlotTicker 在 Slot 内的特定间隔触发事件。  
* 触发器: UpdateHead  
  * 在特定时间点调用（例如：Slot 开始时，重组检查时间）  
  * 获取 ForkChoiceStore 锁以确保处理期间的一致性。

## 2\. 批量处理流程 (processAttestations)

processAttestations 函数（位于 receive\_attestation.go）是将 Attestation 应用于分叉选择的主循环。  
允许的时间差: disparity 包括 Gossip(500ms) 和重组延迟(2s)。

### 处理步骤

获取待处理列表:

* 从 AttPool (或 AttestationCache) 中获取所有标记为 ForkchoiceAttestations 的 Attestation。

遍历: 对于每个 Attestation a:  
A. 未来检查 (时间验证):

* 计算 nextSlot \= a.GetData().Slot \+ 1。  
* 调用 slots.VerifyTime(..., nextSlot, disparity)。  
* 逻辑: 根据规范，Attestation 只有在其 Slot 过去之后（即进入下一个 Slot）才能被分叉选择处理。  
* 动作: 如果时间条件不满足（Attestation 来自未来或当前 Slot），循环 continue。该 Attestation 保留在池中等待下一个周期。

B. 依赖检查:

* 检查 BeaconDB 是否具有 BeaconBlockRoot 的状态摘要 (HasStateSummary)。  
* 检查本地是否存在该区块 (hasBlock)。  
* 动作: 如果缺少依赖项，循环 continue。该 Attestation 保留在池中等待同步。

C. 从池中移除:

* 一旦检查 A 和 B 通过，调用 DeleteForkchoiceAttestation。  
* 注意: 从此时起，无论后续验证成功还是失败，该 Attestation 都会从池中移除。

D. Checkpoint Epoch 验证:

* 调用 helpers.VerifyCheckpointEpoch。检查投票Target对应的epoch是否有效，如果无效，跳过处理。(判断有效的方法：epoch \= currentEpoch 或  epoch \= prevEpoch)

E. 执行:

* 调用 s.receiveAttestationNoPubsub(ctx, a, disparity)。  
* 错误被记录为警告，但不会停止循环。

## 3\. 核心处理逻辑 (receiveAttestationNoPubsub \-\> OnAttestation)

receiveAttestationNoPubsub 是一个包装器，它调用 process\_attestation.go 中的 OnAttestation。

### 详细步骤:

基础验证:

* 检查 nil Attestation。  
* 验证 Slot 和 Target Epoch 的一致性。

前置状态获取:

* s.getAttPreState(ctx, tgt): 获取与 Attestation 的 Target Checkpoint 对应的 BeaconState。这对于验证委员会和签名至关重要。

逻辑验证:

* verifyAttTargetEpoch: 验证 Target Epoch 是否在范围内（当前或上一个 Epoch）。  
* s.verifyBeaconBlock: 验证引用的 Beacon Block 是否已知且不来自未来。  
* slots.VerifyTime: 二次时间检查。

委员会计算与转换:

* helpers.AttestationCommitteesFromState: 计算该 Slot 的验证者委员会。  
* attestation.ConvertToIndexed: 将原始 Attestation（位字段）转换为 IndexedAttestation（验证者索引列表）。

索引验证:

* attestation.IsValidAttestationIndices: 检查索引越界和委员会规则。

应用于分叉选择:  
\*   这是最后一步，将验证者投票应用于 LMD-GHOST 算法。  
\*   根据证明索引更新目标区块的权重。

## **4\. 处理“未来”的 Attestation**

系统显式处理到达“太早”（即在其自己的 Slot 期间）的 Attestation，方法是延迟它们。

* 机制: 在 processAttestations 循环内，slots.VerifyTime 检查确保 now \>= start\_time(attestation.slot \+ 1)。  
* 结果: 如果 Attestation “来自未来”（或者严格来说，“来自当前 Slot”，对于分叉选择包含来说太早），它将在当前循环迭代中被跳过，但不会从池中删除。一旦时间足够推进，它将被后续的 UpdateHead 调用拾取。

# 多客户端SSZ解析一致性

流程检测工具（佳轩）

### 

**第一部分：出块 \+ gossip 调用步骤**

### **步骤 1：本地 proposer 构造区块骨架**

1. **Validator 线程 → Beacon ：**

   * 调用 `get_beacon_block() 获取原始区块`

2. **Beacon → Execution：**  
- **调用执行层的接口 ForkChoiceUpdate 获取当前 parent\_block\_root 下的pid(excution payload id).**

3. **Execution → Consensus Core：返回 pid, status**  
   * 执行层返回payload id以及payload的状态信息(VALID/INVALID/INVALID\_TERMINAL\_BLOCK), VALID 表示有效.

4. **Beacon ：构造 `BeaconBlock`**  
   * 调用本地执行层的接口 GetPayload(pid) 获取执行层数据 **ExecutionPayloadEnvelope**  
   * **调用外部Builder获取执行层负载(来自不同的mev协议)**  
   * **通过比较本地负载和第三方负载的收益，选择最优的负载.**  
   * 把 **ExecutionPayload** 放入 B`eaconBlockBody` 中

      **5\.  Beacon \<-\> Validator:** 

- beacon 将构建的原始 BeaconBlock 返回给 validator  
- validator 对区块进行签名生成 SignedBeaconBlock  
- validator 将SignedBeaconBlock 传给Beacon 去广播

### **步骤 2：`beacon_block` gossip 发布与传播**

5. **Beacon → Gossip Layer：publish(beacon\_block, SignedBeaconBlock)**

   * 对应 Phase0 的 `beacon_block` global topic 定义；此 topic 在 Altair/Bellatrix/Capella/Deneb/Electra/Fulu 中多次「type 升级」但语义不变：统一通过 `/eth2/ForkDigest/beacon_block/ssz_snappy` gossip。

6. **Gossip Layer → Network I/O：**

   * 将 block 序列化为 SSZ-snappy，封装到 gossipsub 消息里，使用 Phase0/Altair 的 `message-id` 规则（Altair 开始引入 topic+data 的 hash）。

7. **Network I/O → Peers：**

   * 通过 libp2p gossipsub 发送给 `beacon_block` topic 的邻居。

**接收方：**

8. **Peers 的 Network I/O → Gossip Layer：**

   * 收到 `beacon_block` 消息后，先按 topic 派发。

9. **beacon\_block handler：**

   * 使用当前 fork 的验证规则：

     * Phase0：基础签名、时序、parent 已知等；  
       p2p-interface-phase0

     * Bellatrix/Capella/Deneb：增加/更新 `execution_payload` / `blob_kzg_commitments` 长度等校验（在 Gloas 之前）；

     * Fulu/Electra：对 `blob_kzg_commitments` 使用 `get_blob_parameters(epoch).max_blobs_per_block`；

10. **handler → Beacon：**

    * 合法的话，把 block 放入链数据库、更新 fork choice（Gasper/LMD-GHOST）。

并行性：`beacon_block` handler 与其他 topic handler（attestation、sidecar 等）完全并行。

### **步骤 3：执行层 生成 ExecutionPayload & Envelope**

11. **Execution：**

    * 执行层打包交易并执行，将执行后的State和区块信息包含在 ExecutePayloadEnvelope 中返回给共识层。（包含执行层的 ParentHash,FeeRecipient,StateRoot,ReceiptsRoot,Number,Transactions 等等 ）

**第二部分：Attestation \+ Payload Attestation 调用步骤**

![][image1]  
图 3：Attestation \+ Payload Attestation 调用关系

### **普通 Attestation（Phase0 起）**

19. **Validator → Consensus Core：**

    * 获取 committee 信息、head block root 等（validator spec）。

20. **Validator → Gossip Layer：publish(beacon\_attestation\_{subnet\_id}, Attestation)**

    * 对应 Phase0 attestation subnets。  
      p2p-interface-phase0

    * 后续在 Deneb/Electra/Gloas 中只是「type、index 规则」的轻微扩展：

      * Deneb：扩展 gossip 时间窗口（EIP-7045）；  
        p2p-interface-deneb

      * Electra：引入 `SingleAttestation` 等，要求 `attestation.data.index != 0`、attester 必须在 committee 中。  
        p2p-interface-electra

21. **Peers gossip handler：**

    * 按 Phase0/Electra 的规则检查 slot 范围、签名、index、committee 成员等；

22. **handler → Consensus Core：**

    * 更新 fork choice 权重（LMD-GHOST），影响 head block 选择。

**第三部分：Req/Resp 同步调用步骤**

![][image2]

                                            图 4：Req/Resp 同步（Blocks / Envelopes / Sidecars）

**并行性：**

* 每一种协议（blocks / envelopes / sidecars）各跑自己的 stream & 协程；

* 每个协议本身还可以对不同 peers 同时开 stream；

* 唯一硬约束是规范里常见的 `MAX_CONCURRENT_REQUESTS`（例如每 peer 每协议最多并发 2 个请求），这是 Req/Resp 层控制的。

这里主要对应 **Phase0 的 Req/Resp 通用框架 \+ Deneb/Fulu/Gloas 新协议**。

### **分支 A：BlocksByRange/Root（所有 fork 累积）**

27. **Sync Manager 发现缺块 → Req/Resp Layer：**

    * 选择一个 peer，构造 `/beacon_blocks_by_range/2/` 请求（Altair 之后的 v2）。

28. **Req/Resp → Network I/O：**

    * 打开 stream、写入 SSZ-snappy 编码的 `(start_slot, count)`。  
      p2p-interface-phase0

29. **Peer 端：**

    * 按 Phase0 Req/Resp 响应模式：逐个 response\_chunk 返回 block。  
      p2p-interface-phase0

    * 每个 chunk 的 SSZ 类型由 `fork_version` → `SignedBeaconBlock` 映射表决定（Capella/Deneb/Electra/Fulu/Gloas 都给出了表格）。

30. **本地 Req/Resp → Sync Manager → Consensus Core：**

    * 逐块入队，由共识线程做 proposer 签名检查、state transition 等。

### **分支 B：BlobSidecarsByRange/Root（Deneb）**

31. **Sync Manager：**

    * 根据缺失 blob，发送 `/blob_sidecars_by_range/1/` 或 `/blob_sidecars_by_root/1/` 请求（Deneb 新增）。  
      p2p-interface-deneb

32. **Peer：**

    * 遵守 Deneb 中的配置：`MAX_REQUEST_BLOB_SIDECARS`、`MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS` 等。  
      p2p-interface-deneb

33. **handler → Consensus Core：**

    * 验证 `BlobSidecar`、调用 `verify_blob_sidecar_inclusion_proof` 等，最终把 blob 与 `BeaconBlock` 绑定。  
      p2p-interface-deneb

### **分支 C：DataColumnSidecarsByRange/Root（Fulu \+ Gloas 修改结构）**

34. **Sync Manager：**

    * Fulu 添加了 `/data_column_sidecars_by_range/1/` & `/data_column_sidecars_by_root/1/`，用 `DataColumnsByRootIdentifier` 描述请求。  
      p2p-interface-fulu

35. **Peer：**

    * 返回 `DataColumnSidecar` 列表（Fulu/Gloas 版本的容器）。

36. **本地：**

    * 先用 `verify_data_column_sidecar` 做基础校验；

    * 再根据 Fulu 版的 inclusion proof 或 Gloas 版的「hash(kzg\_commitments) 与 bid.blob\_kzg\_commitments\_root 比对」做强校验。

https://www.mermaidchart.com/app/projects/cf6c9c0f-7fa0-42fa-8728-ef68c3acd1d4/diagrams/11bfe75f-f112-479c-9a8b-21e28c3c1f87/version/v0.1/edit

[image1]: <data:image/png;base64,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>

[image2]: <data:image/png;base64,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>