# 第4章 libp2p网络栈

## 4.1 libp2p架构概述

### 4.1.1 为什么选择libp2p

libp2p是一个模块化的P2P网络栈，被以太坊共识层采用：

```
优势：
✅ 模块化设计：可组合的协议栈
✅ 多传输支持：TCP、QUIC、WebSocket
✅ 连接复用：mplex/yamux
✅ 安全通信：Noise加密
✅ 内容路由：DHT支持
✅ 发布订阅：Gossipsub协议
✅ NAT穿透：AutoNAT、Circuit Relay
```

### 4.1.2 libp2p核心组件

```
┌─────────────────────────────────────────────┐
│            libp2p Protocol Stack             │
├─────────────────────────────────────────────┤
│                                              │
│  ┌──────────────────────────────────────┐  │
│  │  Application Layer (Beacon Node)     │  │
│  └──────────────┬───────────────────────┘  │
│                 │                            │
│  ┌──────────────┴───────────────────────┐  │
│  │     Protocols                         │  │
│  │  - Req/Resp (Request/Response)       │  │
│  │  - Gossipsub (Publish/Subscribe)     │  │
│  │  - Identify                           │  │
│  │  - Ping                               │  │
│  └──────────────┬───────────────────────┘  │
│                 │                            │
│  ┌──────────────┴───────────────────────┐  │
│  │     Stream Multiplexing              │  │
│  │  - mplex                              │  │
│  │  - yamux                              │  │
│  └──────────────┬───────────────────────┘  │
│                 │                            │
│  ┌──────────────┴───────────────────────┐  │
│  │     Security Layer                    │  │
│  │  - Noise                              │  │
│  │  - TLS                                │  │
│  └──────────────┬───────────────────────┘  │
│                 │                            │
│  ┌──────────────┴───────────────────────┐  │
│  │     Transport Layer                   │  │
│  │  - TCP                                │  │
│  │  - QUIC                               │  │
│  │  - WebSocket                          │  │
│  └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

---

## 4.2 Prysm的libp2p实现

### 4.2.1 P2P Service结构

```go
// 来自prysm/beacon-chain/p2p/service.go
type Service struct {
    // 核心组件
    ctx                      context.Context
    cancel                   context.CancelFunc
    cfg                      *Config
    host                     host.Host          // libp2p host
    pubsub                   *pubsub.PubSub     // Gossipsub实例
    peers                    *peers.Status       // Peer管理器
    
    // Discovery
    dv5Listener              ListenerRebooter    // discv5节点发现
    
    // 网络配置
    privKey                  *ecdsa.PrivateKey   // 节点私钥
    addrFilter               *multiaddr.Filters  // 地址过滤器
    ipLimiter                *leakybucket.Collector // IP限速器
    
    // 元数据
    metaData                 metadata.Metadata   // 节点元数据
    genesisTime              time.Time           // 创世时间
    genesisValidatorsRoot    []byte              // 创世验证者根
    
    // Gossipsub主题
    joinedTopics             map[string]*pubsub.Topic
    joinedTopicsLock         sync.RWMutex
    
    // Subnet相关
    subnetsLock              map[uint64]*sync.RWMutex
    activeValidatorCount     uint64
    custodyInfo              *custodyInfo
    
    // 状态
    started                  bool
    isPreGenesis             bool
    startupErr               error
}
```

### 4.2.2 配置选项

```go
// 来自prysm/beacon-chain/p2p/config.go
type Config struct {
    // 网络地址
    HostAddress     string
    HostDNS         string
    LocalIP         string
    
    // 端口配置
    TCPPort         uint
    UDPPort         uint
    QUICPort        uint
    
    // Peer限制
    MaxPeers        uint
    MinimumPeers    uint
    
    // 连接管理
    StaticPeers     []string
    Discv5BootStrapAddrs []string
    RelayNodeAddr   string
    
    // Discovery配置
    NoDiscovery     bool
    DiscoveryDir    string
    PingInterval    time.Duration
    
    // 其他
    DB              db.ReadOnlyDatabase
    ClockWaiter     startup.ClockWaiter
    IPColocationWhitelist []string
}
```

### 4.2.3 初始化流程

```go
// 来自prysm/beacon-chain/p2p/service.go
func NewService(ctx context.Context, cfg *Config) (*Service, error) {
    ctx, cancel := context.WithCancel(ctx)
    
    // 1. 验证配置
    validateConfig(cfg)
    
    // 2. 生成或加载私钥
    privKey, err := privKey(cfg)
    if err != nil {
        return nil, errors.Wrap(err, "failed to generate p2p private key")
    }
    
    // 3. 加载元数据
    metaData, err := metaDataFromDB(ctx, cfg.DB)
    if err != nil {
        log.WithError(err).Error("Failed to create peer metadata")
        return nil, err
    }
    
    // 4. 配置地址过滤器
    addrFilter, err := configureFilter(cfg)
    if err != nil {
        return nil, err
    }
    
    // 5. 创建IP限速器
    ipLimiter := leakybucket.NewCollector(
        ipLimit, 
        ipBurst, 
        30*time.Second, 
        true, // deleteEmptyBuckets
    )
    
    // 6. 创建service实例
    s := &Service{
        ctx:                   ctx,
        cancel:                cancel,
        cfg:                   cfg,
        privKey:               privKey,
        metaData:              metaData,
        addrFilter:            addrFilter,
        ipLimiter:             ipLimiter,
        isPreGenesis:          true,
        joinedTopics:          make(map[string]*pubsub.Topic),
        subnetsLock:           make(map[uint64]*sync.RWMutex),
        peerDisconnectionTime: cache.New(1*time.Second, 1*time.Minute),
    }
    
    // 7. 构建libp2p选项
    ipAddr := prysmnetwork.IPAddr()
    opts, err := s.buildOptions(ipAddr, s.privKey)
    if err != nil {
        return nil, errors.Wrap(err, "failed to build p2p options")
    }
    
    // 8. 配置mplex超时
    configureMplex()
    
    // 9. 创建libp2p host
    h, err := libp2p.New(opts...)
    if err != nil {
        return nil, errors.Wrap(err, "failed to create p2p host")
    }
    s.host = h
    
    // 10. 初始化Gossipsub
    psOpts := s.pubsubOptions()
    setPubSubParameters()
    
    gs, err := pubsub.NewGossipSub(s.ctx, s.host, psOpts...)
    if err != nil {
        return nil, errors.Wrap(err, "failed to create p2p pubsub")
    }
    s.pubsub = gs
    
    // 11. 初始化peer管理器
    s.peers = peers.NewStatus(ctx, &peers.StatusConfig{
        PeerLimit:             int(s.cfg.MaxPeers),
        IPColocationWhitelist: s.cfg.IPColocationWhitelist,
        ScorerParams: &scorers.Config{
            BadResponsesScorerConfig: &scorers.BadResponsesScorerConfig{
                Threshold:     maxBadResponses,
                DecayInterval: time.Hour,
            },
        },
    })
    
    // 12. 初始化数据映射
    types.InitializeDataMaps()
    
    return s, nil
}
```

---

## 4.3 libp2p Options构建

### 4.3.1 buildOptions方法

```go
// 来自prysm/beacon-chain/p2p/options.go
func (s *Service) buildOptions(ip net.IP, priKey *ecdsa.PrivateKey) ([]libp2p.Option, error) {
    cfg := s.cfg
    listen, err := multiAddressBuilder(ip, cfg.TCPPort)
    if err != nil {
        return nil, errors.Wrap(err, "failed to build TCP multiaddr")
    }
    
    options := []libp2p.Option{
        // 1. 私钥
        privKeyOption(priKey),
        
        // 2. 监听地址
        libp2p.ListenAddrs(listen),
        
        // 3. 用户代理
        libp2p.UserAgent(version.BuildData()),
        
        // 4. 连接管理器
        libp2p.ConnectionManager(s.connectionManager()),
        
        // 5. 传输协议
        libp2p.Transport(tcp.NewTCPTransport),
        
        // 6. 多路复用
        libp2p.Muxer("/mplex/6.7.0", mplex.DefaultTransport),
        
        // 7. 安全层
        libp2p.Security(noise.ID, noise.New),
        
        // 8. NAT穿透
        libp2p.NATPortMap(),
        
        // 9. Connection Gater
        libp2p.ConnectionGater(s),
        
        // 10. 带宽报告
        libp2p.BandwidthReporter(s.bandwidthCounter),
    }
    
    // 添加QUIC支持（如果启用）
    if features.Get().EnableQUIC {
        quicListen, err := multiAddressBuilderWithProtocol(ip, quic, cfg.QUICPort)
        if err != nil {
            return nil, errors.Wrap(err, "failed to build QUIC multiaddr")
        }
        options = append(options, 
            libp2p.ListenAddrs(quicListen),
            libp2p.Transport(libp2pquic.NewTransport),
        )
    }
    
    // 如果配置了HostAddress，添加外部地址公告
    if cfg.HostAddress != "" {
        options = append(options, libp2p.AddrsFactory(
            func([]ma.Multiaddr) []ma.Multiaddr {
                external, err := multiAddressBuilder(
                    net.ParseIP(cfg.HostAddress), 
                    cfg.TCPPort,
                )
                if err != nil {
                    log.WithError(err).Error("Unable to create external multiaddress")
                    return nil
                }
                return []ma.Multiaddr{external}
            },
        ))
    }
    
    return options, nil
}
```

### 4.3.2 连接管理器

```go
func (s *Service) connectionManager() *connmgr.BasicConnMgr {
    // 配置连接限制
    lowWater := int(s.cfg.MaxPeers) * 2 / 3
    highWater := int(s.cfg.MaxPeers)
    gracePeriod := 30 * time.Second
    
    mgr, err := connmgr.NewConnManager(
        lowWater,       // 低水位
        highWater,      // 高水位
        connmgr.WithGracePeriod(gracePeriod),
    )
    
    if err != nil {
        log.WithError(err).Error("Failed to create connection manager")
        return nil
    }
    
    return mgr
}
```

---

## 4.4 传输层协议

### 4.4.1 TCP传输

TCP是默认且最广泛使用的传输协议：

```go
// TCP配置
import (
    "github.com/libp2p/go-libp2p"
    tcp "github.com/libp2p/go-tcp-transport"
)

// 添加TCP传输
libp2p.Transport(tcp.NewTCPTransport)
```

**特点**:
- ✅ 可靠传输
- ✅ 广泛支持
- ✅ 经过充分测试
- ❌ 需要建立连接
- ❌ 头部开销较大

### 4.4.2 QUIC传输

QUIC是基于UDP的现代传输协议：

```go
// 来自prysm/beacon-chain/p2p/options.go
if features.Get().EnableQUIC {
    quicListen, err := multiAddressBuilderWithProtocol(
        ip, 
        quic, 
        cfg.QUICPort,
    )
    if err != nil {
        return nil, errors.Wrap(err, "failed to build QUIC multiaddr")
    }
    
    options = append(options,
        // 监听QUIC端口
        libp2p.ListenAddrs(quicListen),
        // 添加QUIC传输
        libp2p.Transport(libp2pquic.NewTransport),
    )
}
```

**QUIC优势**:
- ✅ 0-RTT连接建立
- ✅ 内置加密(TLS 1.3)
- ✅ 多路复用无阻塞
- ✅ 连接迁移支持
- ✅ 更好的拥塞控制

**Multiaddr格式**:
```
TCP:  /ip4/192.168.1.1/tcp/9000/p2p/16Uiu2HAm...
QUIC: /ip4/192.168.1.1/udp/9001/quic/p2p/16Uiu2HAm...
```

### 4.4.3 多地址(Multiaddr)构建

```go
// 来自prysm/beacon-chain/p2p/utils.go
type internetProtocol int

const (
    tcp internetProtocol = iota
    udp
    quic
)

func multiAddressBuilder(ipAddr net.IP, port uint) (ma.Multiaddr, error) {
    return multiAddressBuilderWithProtocol(ipAddr, tcp, port)
}

func multiAddressBuilderWithProtocol(
    ipAddr net.IP,
    protocol internetProtocol,
    port uint,
) (ma.Multiaddr, error) {
    // 确定IP版本
    ipVersion := "ip4"
    if ipAddr.To4() == nil {
        ipVersion = "ip6"
    }
    
    // 构建协议字符串
    var protoStr string
    switch protocol {
    case tcp:
        protoStr = "tcp"
    case udp:
        protoStr = "udp"
    case quic:
        protoStr = "udp/quic"
    default:
        return nil, errors.New("invalid protocol")
    }
    
    // 构建multiaddr
    addrStr := fmt.Sprintf("/%s/%s/%s/%d", ipVersion, ipAddr, protoStr, port)
    return ma.NewMultiaddr(addrStr)
}

func multiAddressBuilderWithID(
    ipAddr net.IP,
    protocol internetProtocol,
    port uint,
    id peer.ID,
) (ma.Multiaddr, error) {
    addr, err := multiAddressBuilderWithProtocol(ipAddr, protocol, port)
    if err != nil {
        return nil, err
    }
    
    // 添加peer ID
    return addr.Encapsulate(ma.StringCast("/p2p/" + id.String()))
}
```

---

## 4.5 多路复用(Multiplexing)

### 4.5.1 为什么需要多路复用

多路复用允许在单个连接上并发多个独立的stream：

```
单连接多流：
┌─────────────────────────────────┐
│     TCP/QUIC Connection         │
├─────────────────────────────────┤
│  Stream 1: Status Request       │
│  Stream 2: BlocksByRange        │
│  Stream 3: Gossipsub: /beacon_block │
│  Stream 4: Gossipsub: /attestation  │
└─────────────────────────────────┘

优势：
✅ 减少连接数
✅ 避免TCP慢启动
✅ 并发请求不阻塞
✅ 降低延迟
```

### 4.5.2 mplex配置

```go
// 来自prysm/beacon-chain/p2p/options.go
const (
    // mplex的最大消息大小
    maxMplexMessageSize = 10 * (1 << 20) // 10 MiB
)

func configureMplex() {
    // 设置mplex参数
    mplex.MaxMessageSize = maxMplexMessageSize
}

// 在buildOptions中添加
options := []libp2p.Option{
    // ...
    libp2p.Muxer("/mplex/6.7.0", mplex.DefaultTransport),
    // ...
}
```

**mplex参数**:
```go
type MplexTransport struct {
    MaxMessageSize int  // 单个消息最大大小
}
```

### 4.5.3 yamux支持

yamux是另一个流行的多路复用协议：

```go
// 可选：同时支持yamux
libp2p.Muxer("/yamux/1.0.0", yamux.DefaultTransport)
```

**mplex vs yamux对比**:
```
特性            mplex           yamux
─────────────────────────────────────────
复杂度          简单             中等
性能            快速             快速
窗口控制        无               有
优先级          无               支持
内存使用        低               中等
以太坊采用      主要             备选
```

---

## 4.6 安全层(Noise Protocol)

### 4.6.1 Noise加密

Noise是libp2p采用的安全传输协议：

```go
// 来自prysm/beacon-chain/p2p/options.go
import (
    noise "github.com/libp2p/go-libp2p/p2p/security/noise"
)

options := []libp2p.Option{
    // ...
    libp2p.Security(noise.ID, noise.New),
    // ...
}
```

**Noise特点**:
- ✅ 轻量级握手
- ✅ 前向安全
- ✅ 相互认证
- ✅ 加密传输
- ✅ 低延迟

### 4.6.2 握手流程

```
Noise XX handshake:
                                
Initiator                    Responder
    │                            │
    ├──── Ephemeral Key ────────>│
    │                            │
    │<──── Ephemeral Key + Auth ─┤
    │                            │
    ├──── Auth + Payload ───────>│
    │                            │
    └────────────────────────────┘
    
每个消息都包含DH交换的结果，
最终双方都验证了对方的静态公钥
```

### 4.6.3 加密后的通信

```
明文消息 → Noise加密 → 网络传输 → Noise解密 → 明文消息

所有应用层协议(Req/Resp, Gossipsub)
都在Noise加密层之上运行
```

---

## 4.7 Connection Gater

### 4.7.1 连接守门人角色

Connection Gater控制哪些连接可以被接受：

```go
// 来自prysm/beacon-chain/p2p/connection_gater.go
// Service实现了ConnectionGater接口
func (s *Service) InterceptPeerDial(p peer.ID) bool {
    // 1. 检查是否是bad peer
    if s.peers.IsBad(p) != nil {
        return false
    }
    
    // 2. 检查是否超过peer限制
    if s.isPeerAtLimit(all) {
        return false
    }
    
    return true
}

func (s *Service) InterceptAddrDial(p peer.ID, addr ma.Multiaddr) bool {
    // 1. 应用地址过滤器
    if !s.addrFilter.AddrBlocked(addr) {
        return false
    }
    
    // 2. 检查IP限速
    ip, err := manet.ToIP(addr)
    if err != nil {
        return false
    }
    
    if !s.ipLimiter.Add(ip.String(), 1) {
        return false
    }
    
    return true
}

func (s *Service) InterceptAccept(addrs network.ConnMultiaddrs) bool {
    // 接受入站连接的检查
    return !s.isPeerAtLimit(inbound)
}
```

### 4.7.2 IP限速

```go
// 使用leaky bucket算法限制每个IP的连接速率
const (
    ipLimit = 5     // 每个IP最多5个连接
    ipBurst = 10    // 突发最多10个连接
)

ipLimiter := leakybucket.NewCollector(
    ipLimit,
    ipBurst,
    30*time.Second,  // 清理间隔
    true,            // 删除空bucket
)
```

---

## 4.8 小结

本章介绍了Prysm使用的libp2p网络栈：

✅ **架构设计**: 模块化、可扩展的P2P框架
✅ **传输层**: TCP主导，QUIC作为高性能选项
✅ **多路复用**: mplex实现单连接多流
✅ **安全通信**: Noise协议提供加密和认证
✅ **连接管理**: Connection Gater和限速保护
✅ **配置灵活**: 丰富的选项支持各种部署场景

libp2p为Beacon节点提供了坚实的网络基础，下一章将介绍协议协商机制。

---

**下一章预告**: 第5章将详细讲解multistream-select协议协商机制。

---

## 4.9 与同步模块的集成

### 4.9.1 为同步提供的核心能力

libp2p为同步模块提供了关键的网络能力：

```go
// Sync模块依赖的P2P能力
type SyncDependencies struct {
    // 1. Peer管理
    GetConnectedPeers()    // Initial sync选择peers
    GetPeerStatus()        // 检查peer的chain状态
    ScorePeer()            // 根据响应质量评分
    
    // 2. 请求/响应
    SendRPCRequest()       // 发送BlocksByRange等请求
    HandleRPCResponse()    // 处理返回的blocks
    
    // 3. 实时消息
    SubscribeToTopic()     // 订阅beacon_block主题
    ReceiveGossipMsg()     // 接收实时区块
    
    // 4. 流管理
    OpenStream()           // 打开与peer的stream
    CloseStream()          // 关闭stream
    MultiplexStreams()     // 在单连接上复用多个请求
}
```

### 4.9.2 同步场景下的libp2p使用

```go
// Initial Sync使用示例
func (s *InitialSync) syncFromPeers() {
    // 1. 使用Connection Manager限制并发
    for _, peer := range selectedPeers {
        // libp2p确保不会超过连接限制
        s.p2p.RequestBlocks(peer, startSlot, count)
    }
    
    // 2. 使用mplex并发多个请求到同一peer
    // 同时请求blocks、blobs和attestations
    go s.p2p.Send(peer, blocksReq)
    go s.p2p.Send(peer, blobsReq)
    // mplex确保两个请求不会互相阻塞
    
    // 3. 使用Noise确保数据安全
    // 所有同步数据都通过加密通道传输
}

// Regular Sync使用示例
func (s *RegularSync) receiveBlocks() {
    // 1. 通过Gossipsub接收实时区块
    s.p2p.Subscribe("/eth2/beacon_block", handler)
    
    // 2. 当检测到父块缺失时
    // 使用Req/Resp快速获取
    missingBlock := s.p2p.Send(peer, BlocksByRootReq)
    
    // 3. libp2p的Connection Gater保护
    // 恶意peer会被自动阻止
}
```

### 4.9.3 性能优化示例

```go
// libp2p优化同步性能
const (
    // TCP Keepalive避免连接超时
    TCPKeepAlive = 15 * time.Second
    
    // QUIC的0-RTT减少延迟
    // 特别适合频繁请求的initial sync
    
    // mplex的大消息支持
    // 单个请求可以传输大批量blocks
    MaxMplexMessageSize = 10 * 1024 * 1024  // 10MB
)

// 批量请求优化
func (s *Service) batchSync() {
    // 利用mplex在单连接上并发32个请求
    sem := make(chan struct{}, 32)
    for _, batch := range batches {
        sem <- struct{}{}
        go func(b *Batch) {
            defer func() { <-sem }()
            // 每个请求使用独立的stream
            s.p2p.RequestBlocks(peer, b.start, b.count)
        }(batch)
    }
}
```

### 4.9.4 libp2p在不同同步阶段的作用

```
┌──────────────────────────────────────────────────────┐
│     libp2p在同步各阶段的作用                         │
├──────────────────────────────────────────────────────┤
│                                                       │
│  Initial Sync阶段:                                   │
│  ┌────────────────────────────────────────┐         │
│  │ 1. 通过discv5发现大量peers             │         │
│  │ 2. 建立多个TCP/QUIC连接                │         │
│  │ 3. 使用mplex并发请求blocks             │         │
│  │ 4. Connection Manager管理连接数        │         │
│  │ 5. Noise加密保护传输安全               │         │
│  └────────────────────────────────────────┘         │
│                                                       │
│  Regular Sync阶段:                                   │
│  ┌────────────────────────────────────────┐         │
│  │ 1. 通过Gossipsub实时接收blocks         │         │
│  │ 2. 维持与关键peers的长连接             │         │
│  │ 3. 按需使用Req/Resp获取缺失数据        │         │
│  │ 4. Connection Gater过滤低质量peers     │         │
│  └────────────────────────────────────────┘         │
│                                                       │
│  Checkpoint Sync阶段:                                │
│  ┌────────────────────────────────────────┐         │
│  │ 1. 快速连接到trusted peers             │         │
│  │ 2. 使用QUIC减少握手延迟                │         │
│  │ 3. 并发请求checkpoint state和blocks    │         │
│  └────────────────────────────────────────┘         │
│                                                       │
└──────────────────────────────────────────────────────┘
```

---

**更新小结**: libp2p不仅提供网络基础设施，更是同步模块的强大后盾，使其能高效、安全地完成各种同步任务。
