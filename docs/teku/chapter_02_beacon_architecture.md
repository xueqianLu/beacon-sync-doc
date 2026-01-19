# 第 2 章 Beacon 节点架构概览

## 2.1 Beacon 节点的职责与功能

### 2.1.1 核心职责

Beacon 节点是以太坊 PoS 网络的完整参与者，主要职责包括：

```
┌─────────────────────────────────────┐
│        Beacon Node 核心职责          │
├─────────────────────────────────────┤
│ ✓ 维护Beacon Chain状态              │
│ ✓ 处理区块和证明                    │
│ ✓ 执行状态转换                      │
│ ✓ 参与P2P网络通信                   │
│ ✓ 与执行层客户端通信                │
│ ✓ 为验证者提供API服务               │
│ ✓ 同步历史和最新数据                │
│ ✓ 维护Fork Choice                   │
└─────────────────────────────────────┘

### 2.1.3 执行层交易路径流程图

下图以流程图的形式展示了执行层交易从用户或应用发起、进入执行客户端交易池，经由本地打包或 MEV / PBS 路径生成 ExecutionPayload，最终被共识层封装进 Beacon 区块并在网络中传播直至被其他节点执行的完整路径：

![业务 3：执行层交易主线](img/business3_execution_flow.png)

关于执行层交易子流程（提交、打包与 MEV、执行）的更详细拆分，可参考附录中的同步流程图章节：

- 附录：同步相关流程图总览（业务 3：执行层交易 → 打包 → 执行）
```

### 2.1.2 节点类型

#### 全节点 (Full Node)

- 存储完整的 Beacon Chain 历史
- 验证所有区块和证明
- 可以为其他节点提供数据服务

#### 轻节点 (Light Client)

- 只跟踪区块头和同步委员会
- 通过同步委员会签名验证链的有效性
- 资源需求低，适合移动设备

#### 归档节点 (Archive Node)

- 保存所有历史状态
- 支持历史状态查询
- 存储需求最大

---

## 2.2 核心组件架构

### 2.2.1 整体架构图

```
┌─────────────────────────────────────────────────────────┐
│                   Beacon Node                            │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐    ┌──────────────┐   ┌───────────┐ │
│  │  RPC/gRPC    │    │   REST API   │   │  Metrics  │ │
│  │    Server    │    │    Server    │   │  Exporter │ │
│  └──────┬───────┘    └──────┬───────┘   └─────┬─────┘ │
│         │                    │                  │       │
│  ┌──────┴────────────────────┴──────────────────┴────┐ │
│  │              Application Layer                     │ │
│  ├───────────────────────────────────────────────────┤ │
│  │                                                    │ │
│  │  ┌─────────────┐  ┌──────────────┐              │ │
│  │  │ Blockchain  │  │     Sync     │              │ │
│  │  │   Service   │←→│    Service   │←─────┐       │ │
│  │  └──────┬──────┘  └──────┬───────┘      │       │ │
│  │         │                 │              │       │ │
│  │  ┌──────┴──────────┬─────┴───────┐      │       │ │
│  │  │                 │             │      │       │ │
│  │  │  Fork Choice    │  State      │      │       │ │
│  │  │                 │  Transition │      │       │ │
│  │  └─────────────────┴─────────────┘      │       │ │
│  │                                          │       │ │
│  │  ┌──────────────────────────────────────┘       │ │
│  │  │                                               │ │
│  │  │  ┌─────────────┐     ┌──────────────┐       │ │
│  │  └─→│  P2P Layer  │←───→│  Execution   │       │ │
│  │     │  (libp2p)   │     │  Layer Client│       │ │
│  │     └──────┬──────┘     └──────────────┘       │ │
│  │            │                                     │ │
│  │     ┌──────┴──────┐                            │ │
│  │     │   Database  │                            │ │
│  │     │  (BoltDB/   │                            │ │
│  │     │   BadgerDB) │                            │ │
│  │     └─────────────┘                            │ │
│  └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 2.2.2 Prysm 代码结构

```
prysm/beacon-chain/
├── node/                    # 节点初始化和配置
│   ├── node.go             # 主节点结构
│   └── registration.go     # 服务注册
│
├── blockchain/             # 区块链核心服务
│   ├── service.go         # Blockchain服务主入口
│   ├── chain_info.go      # 链信息查询
│   ├── process_block.go   # 区块处理
│   ├── process_attestation.go  # 证明处理
│   └── forkchoice/        # Fork选择实现
│
├── sync/                   # 同步模块（本书重点）
│   ├── service.go         # 同步服务主入口
│   ├── initial-sync/      # 初始同步
│   ├── rpc_*.go          # Req/Resp协议实现
│   ├── subscriber_*.go   # Gossipsub订阅
│   ├── validate_*.go     # 消息验证
│   └── pending_*.go      # 待处理队列
│
├── p2p/                   # P2P网络层
│   ├── service.go        # P2P服务
│   ├── discovery.go      # 节点发现
│   ├── gossip_*.go       # Gossipsub实现
│   └── encoder.go        # 编解码器
│
├── db/                    # 数据库层
│   ├── kv/               # Key-Value存储
│   └── slasherkv/        # Slasher数据库
│
├── rpc/                   # RPC服务
│   ├── prysm/v1alpha1/   # gRPC API
│   └── eth/v1/           # 标准REST API
│
├── state/                 # 状态管理
│   ├── state-native/     # 原生状态实现
│   └── stategen/         # 状态生成器
│
├── execution/            # 执行层交互
│   ├── engine_client.go  # Engine API客户端
│   └── types/            # 执行层类型
│
└── forkchoice/           # Fork选择
    └── doubly-linked-tree/  # 优化的树结构
```

---

## 2.3 同步模块在整体架构中的位置

### 2.3.1 同步模块的角色

同步模块是 Beacon 节点的**数据获取和验证引擎**：

```
外部网络          Sync Service          内部服务
   │                  │                    │
   │  ┌──────────────┤                    │
   ├──┤ P2P Network  │                    │
   │  └──────┬───────┘                    │
   │         │                             │
   │         │ 1.接收区块/证明             │
   │         ↓                             │
   │  ┌──────────────┐                    │
   │  │   Validate   │                    │
   │  │   & Queue    │                    │
   │  └──────┬───────┘                    │
   │         │                             │
   │         │ 2.验证通过                 │
   │         ↓                             │
   │  ┌──────────────┐   3.处理完成      │
   │  │  Blockchain  │───────────────────→│
   │  │   Service    │                    │
   │  └──────────────┘                    │
```

### 2.3.2 同步模块的输入输出

#### 输入源

1. **P2P 网络**

   - Gossipsub 广播的区块和证明
   - Req/Resp 请求的历史数据
   - Peer 发现和状态交换

2. **本地触发**
   - 检测到缺失父块
   - Fork 选择更新需要
   - 定时同步检查

#### 输出目标

1. **Blockchain Service**

   - 验证通过的区块
   - 聚合后的证明
   - Fork 选择更新请求

2. **Database**

   - 持久化区块数据
   - 缓存中间状态
   - 索引元数据

3. **P2P Layer**
   - 转发 gossip 消息
   - 响应数据请求
   - 更新 peer 评分

---

## 2.4 与其他模块的交互关系

### 2.4.1 与 Blockchain Service 的交互

#### Service 结构

```go
// 来自prysm/beacon-chain/blockchain/service.go
type Service struct {
    cfg *config

    // 核心组件
    forkChoiceStore  forkchoice.ForkChoicer
    attPool          attestations.Pool
    slashingPool     slashings.PoolManager
    exitPool         voluntaryexits.PoolManager

    // 通知机制
    blockNotifier  blockNotifier
    stateNotifier  stateNotifier

    // 状态
    headSlot    primitives.Slot
    headRoot    [32]byte
    headState   state.BeaconState

    // 同步相关
    isOptimistic bool  // 是否处于乐观同步模式
}
```

#### 交互流程

```go
// Sync模块处理完区块后通知Blockchain
func (s *SyncService) processBlock(block SignedBeaconBlock) error {
    // 1. 基本验证
    if err := s.validateBlock(block); err != nil {
        return err
    }

    // 2. 提交给blockchain service
    blockRoot, err := block.Block().HashTreeRoot()
    if err != nil {
        return err
    }

    // 3. blockchain service处理区块
    return s.cfg.chain.ReceiveBlock(ctx, block, blockRoot)
}
```

```go
// Blockchain service处理区块
func (s *Service) ReceiveBlock(
    ctx context.Context,
    block interfaces.SignedBeaconBlock,
    blockRoot [32]byte,
) error {
    // 1. 状态转换
    preState, err := s.getBlockPreState(ctx, block.Block())
    if err != nil {
        return err
    }

    postState, err := transition.ExecuteStateTransition(ctx, preState, block)
    if err != nil {
        return err
    }

    // 2. 更新fork choice
    if err := s.forkChoiceStore.ProcessBlock(ctx,
        block.Block().Slot(),
        blockRoot,
        block.Block().ParentRoot(),
        postState.CurrentJustifiedCheckpoint().Epoch,
        postState.FinalizedCheckpoint().Epoch,
    ); err != nil {
        return err
    }

    // 3. 保存到数据库
    if err := s.cfg.BeaconDB.SaveBlock(ctx, block); err != nil {
        return err
    }

    // 4. 更新head
    return s.updateHead(ctx, blockRoot)
}
```

### 2.4.2 与 P2P 网络层的交互

#### P2P Service 结构

```go
// 来自prysm/beacon-chain/p2p/service.go
type Service struct {
    host       host.Host       // libp2p host
    pubsub     *pubsub.PubSub  // gossipsub
    dv5Listener Listener       // discv5节点发现

    peers      *peers.Status   // peer管理
    cfg        *Config
}
```

#### Gossipsub 订阅

```go
// Sync模块订阅区块主题
func (s *Service) subscribeToBlocks() {
    topic := "/eth2/%x/beacon_block"
    sub, err := s.cfg.P2P.SubscribeToTopic(topic)
    if err != nil {
        log.Error(err)
        return
    }

    // 处理接收到的消息
    go func() {
        for {
            msg, err := sub.Next(s.ctx)
            if err != nil {
                return
            }

            // 验证和处理
            go s.validateBeaconBlockPubSub(s.ctx, msg)
        }
    }()
}
```

#### Req/Resp 通信

```go
// 请求BeaconBlocksByRange
func (s *Service) sendBeaconBlocksByRangeRequest(
    ctx context.Context,
    pid peer.ID,
    req *pb.BeaconBlocksByRangeRequest,
) ([]interfaces.SignedBeaconBlock, error) {
    stream, err := s.cfg.P2P.Send(ctx, req,
        p2ptypes.BeaconBlocksByRangeMessageName, pid)
    if err != nil {
        return nil, err
    }
    defer stream.Close()

    // 读取响应
    blocks := make([]interfaces.SignedBeaconBlock, 0, req.Count)
    for {
        block, err := ReadChunkedBlock(stream, s.cfg.Chain)
        if err == io.EOF {
            break
        }
        if err != nil {
            return nil, err
        }
        blocks = append(blocks, block)
    }

    return blocks, nil
}
```

### 2.4.3 与数据库层的交互

#### 数据库接口

```go
// 来自prysm/beacon-chain/db/iface/interface.go
type ReadOnlyDatabase interface {
    // 区块查询
    Block(ctx context.Context, blockRoot [32]byte) (interfaces.SignedBeaconBlock, error)
    Blocks(ctx context.Context, f *filters.QueryFilter) ([]interfaces.SignedBeaconBlock, error)
    BlockRoots(ctx context.Context, f *filters.QueryFilter) ([][32]byte, error)

    // 状态查询
    State(ctx context.Context, blockRoot [32]byte) (state.BeaconState, error)
    HeadBlock(ctx context.Context) (interfaces.SignedBeaconBlock, error)

    // Checkpoint查询
    JustifiedCheckpoint(ctx context.Context) (*ethpb.Checkpoint, error)
    FinalizedCheckpoint(ctx context.Context) (*ethpb.Checkpoint, error)
}

type Database interface {
    ReadOnlyDatabase

    // 区块保存
    SaveBlock(ctx context.Context, block interfaces.SignedBeaconBlock) error
    SaveBlocks(ctx context.Context, blocks []interfaces.SignedBeaconBlock) error

    // 状态保存
    SaveState(ctx context.Context, state state.BeaconState, blockRoot [32]byte) error

    // Checkpoint保存
    SaveJustifiedCheckpoint(ctx context.Context, checkpoint *ethpb.Checkpoint) error
    SaveFinalizedCheckpoint(ctx context.Context, checkpoint *ethpb.Checkpoint) error
}
```

#### 同步模块使用数据库

```go
// 检查区块是否存在
func (s *Service) hasBlock(root [32]byte) bool {
    return s.cfg.BeaconDB.HasBlock(s.ctx, root)
}

// 获取父块
func (s *Service) getParentBlock(block interfaces.SignedBeaconBlock) (interfaces.SignedBeaconBlock, error) {
    parentRoot := block.Block().ParentRoot()
    return s.cfg.BeaconDB.Block(s.ctx, parentRoot)
}

// 批量保存区块
func (s *Service) saveBlocks(blocks []interfaces.SignedBeaconBlock) error {
    return s.cfg.BeaconDB.SaveBlocks(s.ctx, blocks)
}
```

### 2.4.4 与 Fork Choice 的交互

#### Fork Choice 接口

```go
// 来自prysm/beacon-chain/forkchoice/types.go
type ForkChoicer interface {
    // 处理新区块
    ProcessBlock(ctx context.Context,
        slot primitives.Slot,
        blockRoot [32]byte,
        parentRoot [32]byte,
        justifiedEpoch primitives.Epoch,
        finalizedEpoch primitives.Epoch,
    ) error

    // 处理证明
    ProcessAttestation(ctx context.Context,
        attestationIndices []uint64,
        blockRoot [32]byte,
        targetEpoch primitives.Epoch,
    ) error

    // 获取head
    Head(ctx context.Context) ([32]byte, error)

    // 获取权重
    Weight(root [32]byte) (uint64, error)

    // 获取祖先
    AncestorRoot(ctx context.Context, root [32]byte, slot primitives.Slot) ([32]byte, error)
}
```

#### Sync 更新 Fork Choice

```go
// 处理区块后更新fork choice
func (s *Service) updateForkChoice(block interfaces.SignedBeaconBlock, postState state.BeaconState) error {
    blockRoot, err := block.Block().HashTreeRoot()
    if err != nil {
        return err
    }

    return s.cfg.ForkChoiceStore.ProcessBlock(
        s.ctx,
        block.Block().Slot(),
        blockRoot,
        block.Block().ParentRoot(),
        postState.CurrentJustifiedCheckpoint().Epoch,
        postState.FinalizedCheckpoint().Epoch,
    )
}
```

---

## 2.5 同步模块内部结构

### 2.5.1 Service 结构

```go
// 来自prysm/beacon-chain/sync/service.go
type Service struct {
    cfg                  *config
    ctx                  context.Context
    cancel               context.CancelFunc

    // 核心组件
    chain                blockchainService   // blockchain服务
    p2p                  p2p.P2P            // P2P网络
    db                   db.Database        // 数据库
    initialSync          *initialsync.Service  // 初始同步服务

    // 队列管理
    blockNotifier        blockNotifier
    pendingQueueLock     sync.RWMutex
    slotToPendingBlocks  map[primitives.Slot]interfaces.SignedBeaconBlock
    seenPendingBlocks    map[[32]byte]bool

    pendingAttsLock      sync.RWMutex
    pendingAtts          []*ethpb.SignedAggregateAttestationAndProof

    // 速率限制
    rateLimiter          *leakybucket.Collector

    // 批量验证
    blkRootToPendingAtts map[[32]byte][]interfaces.SignedBeaconBlock
    signatureChan        chan *signatureVerifier

    // 状态
    chainStarted         bool
    validateDuties       bool
}
```

### 2.5.2 配置结构

```go
type config struct {
    // 核心服务
    P2P                  p2p.P2P
    Chain                blockchainService
    DB                   db.Database
    AttPool              attestations.Pool
    ExitPool             voluntaryexits.PoolManager
    SlashingPool         slashings.PoolManager

    // 同步配置
    InitialSync          Checker
    StateNotifier        statefeed.Notifier
    BlockNotifier        blockfeed.Notifier

    // 功能开关
    EnableBackfillSync   bool

    // 其他
    StateGen             *stategen.State
    SlasherAttestationsFeed *event.Feed
    SlasherBlockHeadersFeed *event.Feed
}
```

---

## 2.6 小结

本章详细介绍了 Beacon 节点的架构：

- **节点职责**: 维护状态、处理区块、参与网络、提供服务
- **组件架构**: 分层设计，职责清晰，模块化
- **同步位置**: 作为数据获取引擎，连接 P2P 和 Blockchain
- **模块交互**:

- Blockchain Service: 区块处理和 fork choice
- P2P Layer: Gossipsub 和 Req/Resp 通信
- Database: 数据持久化
- Fork Choice: 链头选择

理解这个架构是深入学习同步模块的关键，下一章将聚焦同步模块的设计目标和策略。

---

**下一章预告**: 第 3 章将详细讨论同步模块的设计目标、挑战和解决方案。
