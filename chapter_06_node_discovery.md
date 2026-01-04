# 第6章 节点发现机制(discv5)

## 6.1 discv5概述

### 6.1.1 为什么需要节点发现

在去中心化P2P网络中，节点需要自动发现其他节点：

```
问题：
- 节点启动时如何找到peers？
- 如何发现新加入的节点？
- 如何维护健康的peer连接？

解决：
使用discv5 (Discovery v5) 协议进行节点发现
```

### 6.1.2 discv5特点

```
┌───────────────────────────────────────┐
│        discv5 Discovery Protocol       │
├───────────────────────────────────────┤
│                                        │
│  ✅ 基于Kademlia DHT                   │
│  ✅ UDP传输，低延迟                    │
│  ✅ ENR (Ethereum Node Record)        │
│  ✅ Topic-based discovery             │
│  ✅ 加密的节点查询                     │
│  ✅ NAT穿透支持                       │
│                                        │
└───────────────────────────────────────┘
```

---

## 6.2 ENR (Ethereum Node Record)

### 6.2.1 ENR结构

ENR是节点的身份卡片，包含连接所需的所有信息：

```
ENR格式 (RLP编码):
[
    signature,     // 签名(保证真实性)
    seq,           // 序列号(用于更新)
    k1: v1,        // 键值对
    k2: v2,
    ...
]

必需字段:
- id: 身份方案("v4")
- secp256k1: 公钥
- ip: IP地址
- tcp: TCP端口
- udp: UDP端口

可选字段:
- eth2: Fork版本信息
- attnets: Attestation subnet bitvector
- syncnets: Sync committee subnet bitvector
- quic: QUIC端口(如果支持)
```

### 6.2.2 ENR创建

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) createLocalNode(
    privKey *ecdsa.PrivateKey,
    ipAddr net.IP,
    udpPort, tcpPort, quicPort int,
) (*enode.LocalNode, error) {
    // 1. 打开节点数据库
    db, err := enode.OpenDB(s.cfg.DiscoveryDir)
    if err != nil {
        return nil, errors.Wrap(err, "could not open node's peer database")
    }
    
    // 2. 创建本地节点
    localNode := enode.NewLocalNode(db, privKey)
    
    // 3. 设置IP地址
    ipEntry := enr.IP(ipAddr)
    localNode.Set(ipEntry)
    
    // 4. 设置UDP端口
    udpEntry := enr.UDP(udpPort)
    localNode.Set(udpEntry)
    
    // 5. 设置TCP端口
    tcpEntry := enr.TCP(tcpPort)
    localNode.Set(tcpEntry)
    
    // 6. 设置QUIC端口（如果启用）
    if features.Get().EnableQUIC {
        quicEntry := quicProtocol(quicPort)
        localNode.Set(quicEntry)
    }
    
    // 7. 设置fallback地址
    localNode.SetFallbackIP(ipAddr)
    localNode.SetFallbackUDP(udpPort)
    
    // 8. 添加以太坊2.0特定字段
    currentSlot := slots.CurrentSlot(s.genesisTime)
    currentEpoch := slots.ToEpoch(currentSlot)
    current := params.GetNetworkScheduleEntry(currentEpoch)
    next := params.NextNetworkScheduleEntry(currentEpoch)
    
    if err := updateENR(localNode, current, next); err != nil {
        return nil, errors.Wrap(err, "could not add eth2 fork version entry to enr")
    }
    
    // 9. 初始化subnet信息
    localNode = initializeAttSubnets(localNode)
    localNode = initializeSyncCommSubnets(localNode)
    
    // 10. 添加custody group count (Fulu+)
    if params.FuluEnabled() {
        custodyGroupCount, err := s.CustodyGroupCount(s.ctx)
        if err != nil {
            return nil, errors.Wrap(err, "could not retrieve custody group count")
        }
        custodyGroupCountEntry := peerdas.Cgc(custodyGroupCount)
        localNode.Set(custodyGroupCountEntry)
    }
    
    // 11. 设置外部地址（如果配置）
    if s.cfg != nil && s.cfg.HostAddress != "" {
        hostIP := net.ParseIP(s.cfg.HostAddress)
        if hostIP.To4() == nil && hostIP.To16() == nil {
            return nil, errors.Errorf("invalid host address: %s", s.cfg.HostAddress)
        }
        localNode.SetFallbackIP(hostIP)
        localNode.SetStaticIP(hostIP)
    }
    
    log.WithFields(logrus.Fields{
        "seq": localNode.Seq(),
        "id":  localNode.ID(),
    }).Debug("Local node created")
    
    return localNode, nil
}
```

### 6.2.3 ENR更新

```go
// ENR序列号自动递增
func (s *Service) updateENR() {
    // 更新subnet信息会自动增加序列号
    localNode := s.dv5Listener.LocalNode()
    
    // 设置新的attestation subnet bitvector
    bitV := computeAttestationSubnets()
    localNode.Set(enr.WithEntry("attnets", &bitV))
    
    // 序列号自动递增
    log.WithField("newSeq", localNode.Seq()).Debug("ENR updated")
}
```

---

## 6.3 Prysm的discv5实现

### 6.3.1 启动discv5监听器

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) startDiscoveryV5(
    addr net.IP,
    privKey *ecdsa.PrivateKey,
) (*listenerWrapper, error) {
    // 创建监听器工厂函数
    createListener := func() (*discover.UDPv5, error) {
        return s.createListener(addr, privKey)
    }
    
    // 创建包装的监听器（支持重启）
    wrappedListener, err := newListener(createListener)
    if err != nil {
        return nil, errors.Wrap(err, "create listener")
    }
    
    record := wrappedListener.Self()
    log.WithFields(logrus.Fields{
        "ENR": record.String(),
        "seq": record.Seq(),
    }).Info("Started discovery v5")
    
    return wrappedListener, nil
}

func (s *Service) createListener(
    ipAddr net.IP,
    privKey *ecdsa.PrivateKey,
) (*discover.UDPv5, error) {
    // 1. 确定绑定IP
    var bindIP net.IP
    switch udpVersionFromIP(ipAddr) {
    case udp4:
        bindIP = net.IPv4zero  // 0.0.0.0
    case udp6:
        bindIP = net.IPv6zero  // ::
    default:
        return nil, errors.New("invalid ip provided")
    }
    
    // 如果指定了本地IP，使用它
    if s.cfg.LocalIP != "" {
        ipAddr = net.ParseIP(s.cfg.LocalIP)
        if ipAddr == nil {
            return nil, errors.New("invalid local ip provided")
        }
        bindIP = ipAddr
    }
    
    // 2. 创建UDP地址
    udpAddr := &net.UDPAddr{
        IP:   bindIP,
        Port: int(s.cfg.UDPPort),
    }
    
    // 3. 监听UDP端口
    conn, err := net.ListenUDP("udp", udpAddr)
    if err != nil {
        return nil, errors.Wrap(err, "could not listen to UDP")
    }
    
    // 4. 创建本地节点
    localNode, err := s.createLocalNode(
        privKey,
        ipAddr,
        int(s.cfg.UDPPort),
        int(s.cfg.TCPPort),
        int(s.cfg.QUICPort),
    )
    if err != nil {
        return nil, errors.Wrap(err, "create local node")
    }
    
    // 5. 解析bootnode ENRs
    bootNodes := make([]*enode.Node, 0, len(s.cfg.Discv5BootStrapAddrs))
    for _, addr := range s.cfg.Discv5BootStrapAddrs {
        bootNode, err := enode.Parse(enode.ValidSchemes, addr)
        if err != nil {
            return nil, errors.Wrap(err, "could not bootstrap addr")
        }
        bootNodes = append(bootNodes, bootNode)
    }
    
    // 6. 配置discv5
    dv5Cfg := discover.Config{
        PrivateKey:              privKey,
        Bootnodes:               bootNodes,
        PingInterval:            s.cfg.PingInterval,
        NoFindnodeLivenessCheck: s.cfg.DisableLivenessCheck,
    }
    
    // 7. 启动discv5监听器
    listener, err := discover.ListenV5(conn, localNode, dv5Cfg)
    if err != nil {
        return nil, errors.Wrap(err, "could not listen to discV5")
    }
    
    return listener, nil
}
```

### 6.3.2 监听器包装器（支持重启）

```go
// 来自prysm/beacon-chain/p2p/discovery.go
type listenerWrapper struct {
    mu              sync.RWMutex
    listener        *discover.UDPv5
    listenerCreator func() (*discover.UDPv5, error)
}

func (l *listenerWrapper) Self() *enode.Node {
    l.mu.RLock()
    defer l.mu.RUnlock()
    return l.listener.Self()
}

func (l *listenerWrapper) Close() {
    l.mu.RLock()
    defer l.mu.RUnlock()
    l.listener.Close()
}

func (l *listenerWrapper) Lookup(id enode.ID) []*enode.Node {
    l.mu.RLock()
    defer l.mu.RUnlock()
    return l.listener.Lookup(id)
}

func (l *listenerWrapper) RandomNodes() enode.Iterator {
    l.mu.RLock()
    defer l.mu.RUnlock()
    return l.listener.RandomNodes()
}

func (l *listenerWrapper) Ping(node *enode.Node) error {
    l.mu.RLock()
    defer l.mu.RUnlock()
    _, err := l.listener.Ping(node)
    return err
}

// 重启监听器（用于恢复连接性）
func (l *listenerWrapper) RebootListener() error {
    l.mu.Lock()
    defer l.mu.Unlock()
    
    // 关闭当前监听器
    l.listener.Close()
    
    // 创建新的监听器
    newListener, err := l.listenerCreator()
    if err != nil {
        return err
    }
    
    l.listener = newListener
    return nil
}
```

---

## 6.4 节点查找

### 6.4.1 监听新节点

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) listenForNewNodes() {
    const (
        thresholdLimit = 5
        searchPeriod   = 20 * time.Second
    )
    
    connectivityTicker := time.NewTicker(1 * time.Minute)
    thresholdCount := 0
    
    for {
        select {
        case <-s.ctx.Done():
            return
            
        case <-connectivityTicker.C:
            // 检查连接性，必要时重启监听器
            if !features.Get().EnableDiscoveryReboot {
                continue
            }
            
            if !s.isBelowOutboundPeerThreshold() {
                thresholdCount = 0
                continue
            }
            
            thresholdCount++
            if thresholdCount > thresholdLimit {
                outBoundCount := len(s.peers.OutboundConnected())
                log.WithField("outboundConnectionCount", outBoundCount).
                    Warn("Rebooting discovery listener, reached threshold.")
                    
                if err := s.dv5Listener.RebootListener(); err != nil {
                    log.WithError(err).Error("Could not reboot listener")
                    continue
                }
                thresholdCount = 0
            }
            
        default:
            // 检查peer限制
            if s.isPeerAtLimit(all) {
                log.Trace("Not looking for peers, at peer limit")
                time.Sleep(pollingPeriod)
                continue
            }
            
            // 返回早期检查
            if s.dv5Listener == nil {
                return
            }
            
            // 查找并拨号peers
            func() {
                ctx, cancel := context.WithTimeout(s.ctx, searchPeriod)
                defer cancel()
                
                if err := s.findAndDialPeers(ctx); err != nil && 
                    !errors.Is(err, context.DeadlineExceeded) {
                    log.WithError(err).Error("Failed to find and dial peers")
                }
            }()
        }
    }
}
```

### 6.4.2 查找Peers

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) findPeers(
    ctx context.Context,
    missingPeerCount uint,
) ([]*enode.Node, error) {
    // 1. 创建随机节点迭代器
    iterator := s.dv5Listener.RandomNodes()
    
    // 2. 当context取消时关闭迭代器
    go func() {
        <-ctx.Done()
        iterator.Close()
    }()
    
    // 3. 查找节点
    nodeByNodeID := make(map[enode.ID]*enode.Node)
    for missingPeerCount > 0 && iterator.Next() {
        if ctx.Err() != nil {
            peersToDial := make([]*enode.Node, 0, len(nodeByNodeID))
            for _, node := range nodeByNodeID {
                peersToDial = append(peersToDial, node)
            }
            return peersToDial, ctx.Err()
        }
        
        node := iterator.Node()
        
        // 4. 去重：保留更高seq的节点
        existing, ok := nodeByNodeID[node.ID()]
        if ok && existing.Seq() >= node.Seq() {
            continue
        }
        
        // 5. 应用过滤器
        if !s.filterPeer(node) {
            if ok {
                delete(nodeByNodeID, existing.ID())
                missingPeerCount++
            }
            continue
        }
        
        // 6. 添加有效节点
        nodeByNodeID[node.ID()] = node
        missingPeerCount--
    }
    
    // 7. 转换为切片
    peersToDial := make([]*enode.Node, 0, len(nodeByNodeID))
    for _, node := range nodeByNodeID {
        peersToDial = append(peersToDial, node)
    }
    
    return peersToDial, nil
}
```

### 6.4.3 Peer过滤器

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) filterPeer(node *enode.Node) bool {
    // 1. 忽略nil节点
    if node == nil {
        return false
    }
    
    // 2. 忽略无IP地址的节点
    if node.IP() == nil {
        return false
    }
    
    // 3. 转换为peer info
    peerData, multiAddrs, err := convertToAddrInfo(node)
    if err != nil {
        log.WithError(err).WithField("node", node.String()).
            Debug("Could not convert to peer data")
        return false
    }
    
    if peerData == nil || len(multiAddrs) == 0 {
        return false
    }
    
    // 4. 忽略bad peers
    if s.peers.IsBad(peerData.ID) != nil {
        return false
    }
    
    // 5. 忽略已活跃的peers
    if s.peers.IsActive(peerData.ID) {
        // 更新已知peer的ENR
        s.peers.UpdateENR(node.Record(), peerData.ID)
        return false
    }
    
    // 6. 忽略已连接的peers
    if s.host.Network().Connectedness(peerData.ID) == network.Connected {
        return false
    }
    
    // 7. 忽略未准备好拨号的peers
    if !s.peers.IsReadyToDial(peerData.ID) {
        return false
    }
    
    // 8. 验证fork digest匹配
    nodeENR := node.Record()
    if s.genesisValidatorsRoot != nil {
        if err := compareForkENR(
            s.dv5Listener.LocalNode().Node().Record(),
            nodeENR,
        ); err != nil {
            log.WithError(err).Trace("Fork ENR mismatches between peer and local node")
            return false
        }
    }
    
    // 9. 优先选择QUIC地址
    multiAddr := multiAddrs[0]
    
    // 10. 添加peer到管理器
    s.peers.Add(nodeENR, peerData.ID, multiAddr, network.DirUnknown)
    
    return true
}
```

---

## 6.5 Bootnode连接

### 6.5.1 连接到Bootnodes

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) connectToBootnodes() error {
    nodes := make([]*enode.Node, 0, len(s.cfg.Discv5BootStrapAddrs))
    
    // 解析bootnode地址
    for _, addr := range s.cfg.Discv5BootStrapAddrs {
        bootNode, err := enode.Parse(enode.ValidSchemes, addr)
        if err != nil {
            return err
        }
        
        // 检查TCP端口是否设置
        if err := bootNode.Record().Load(enr.WithEntry("tcp", new(enr.TCP))); err != nil {
            if !enr.IsNotFound(err) {
                log.WithError(err).Error("Could not retrieve tcp port")
            }
            continue
        }
        
        nodes = append(nodes, bootNode)
    }
    
    // 转换为multiaddr并连接
    multiAddresses := convertToMultiAddr(nodes)
    s.connectWithAllPeers(multiAddresses)
    
    return nil
}
```

### 6.5.2 主网Bootnodes示例

```go
// 主网bootnode ENRs (示例)
var mainnetBootnodes = []string{
    // Prysm bootnodes
    "enr:-Ku4QImhMc1z8yCiNJ1TyUxdcfNucje3BGwEHzodEZUan8PherEo4sF7pPHPSIB1NNuSg5fZy7qFsjmUKs2ea1Whi0EBh2F0dG5ldHOIAAAAAAAAAACEZXRoMpD1pf1CAAAAAP__________gmlkgnY0gmlwhAMKsQGJc2VjcDI1NmsxoQJf1fG8mQNqxmEPxUMmHYXb1z6jR0YO1tjXaQ4_N0D0P4N0Y3CCIyiDdWRwgiMo",
    
    // Lighthouse bootnodes
    "enr:-Le4QPUXJS2BTORXxyx2Ia-9ae4YqA_JWX3ssj4E_J-3z1A-HmFGrU8BpvpqhNabayXeOZ2Nq_sbeDgtzMJpLLnXFgAChGV0aDKQtTA_KgAAAAD__________4JpZIJ2NIJpcISsaa0ZiXNlY3AyNTZrMaEDHAD2JKYevx89W0CcFJFiskdcEzkH_Wdv9iW42qLK79ODdWRwgiMohHVkcDaCI4I",
    
    // Teku bootnodes
    "enr:-KG4QOtcP9X1FbIMOe17QNMKqDxCpm14jcX5tiOE4_TyMrFqbmhPZHK_ZPG2Gxb1GE2xdtodOfx9-cgvNtxnRyHEmC0Dhx F0dG5ldHOI__________-EZXRoMpD9EMUfAAAAAAD__________4JpZIJ2NIJpcIQDE8KdiXNlY3AyNTZrMaEDhpehBDbZjM_L9ek699Y7vhUJ-eAdMyQW_Fil522Y0fODdGNwgiMog3VkcIIjKA",
}
```

---

## 6.6 Subnet发现

### 6.6.1 持续subnet刷新

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) RefreshPersistentSubnets() {
    // 早期返回检查
    if s.dv5Listener == nil || !s.isInitialized() {
        return
    }
    
    // 获取当前epoch
    currentSlot := slots.CurrentSlot(s.genesisTime)
    currentEpoch := slots.ToEpoch(currentSlot)
    
    // 获取节点ID
    nodeID := s.dv5Listener.LocalNode().ID()
    record := s.dv5Listener.Self().Record()
    
    // 初始化持续subnets
    if err := initializePersistentSubnets(nodeID, currentEpoch); err != nil {
        log.WithError(err).Error("Could not initialize persistent subnets")
        return
    }
    
    // 计算attestation subnet bitvector
    bitV := bitfield.NewBitvector64()
    attestationCommittees := cache.SubnetIDs.GetAllSubnets()
    for _, idx := range attestationCommittees {
        bitV.SetBitAt(idx, true)
    }
    
    // 获取记录中的attestation subnet
    inRecordBitV, err := attBitvector(record)
    if err != nil {
        log.WithError(err).Error("Could not retrieve att bitfield")
        return
    }
    
    // 获取元数据中的attestation subnet
    inMetadataBitV := s.Metadata().AttnetsBitfield()
    
    // 检查是否需要更新
    isBitVUpToDate := bytes.Equal(bitV, inRecordBitV) && 
                      bytes.Equal(bitV, inMetadataBitV)
    
    // Altair后还需要检查sync committee subnets
    altairForkEpoch := params.BeaconConfig().AltairForkEpoch
    if currentEpoch+1 >= altairForkEpoch {
        bitS := bitfield.Bitvector4{byte(0x00)}
        syncCommittees := cache.SyncSubnetIDs.GetAllSubnets(currentEpoch)
        for _, idx := range syncCommittees {
            bitS.SetBitAt(idx, true)
        }
        
        inRecordBitS, err := syncBitvector(record)
        if err != nil {
            log.WithError(err).Error("Could not retrieve sync bitfield")
            return
        }
        
        currentBitSInMetadata := s.Metadata().SyncnetsBitfield()
        isBitSUpToDate := bytes.Equal(bitS, inRecordBitS) && 
                          bytes.Equal(bitS, currentBitSInMetadata)
        
        if !isBitVUpToDate || !isBitSUpToDate {
            // 更新ENR和元数据
            if err := s.updateSubnetRecordWithMetadataV2(bitV, bitS, custodyGroupCount); err != nil {
                log.WithError(err).Error("Failed to update subnet record")
            }
            
            // Ping所有peers
            s.pingPeersAndLogEnr()
        }
        return
    }
    
    // Phase 0行为
    if !isBitVUpToDate {
        if err := s.updateSubnetRecordWithMetadata(bitV); err != nil {
            log.WithError(err).Error("Failed to update subnet record")
        }
        s.pingPeersAndLogEnr()
    }
}
```

---

## 6.7 连接管理

### 6.7.1 拨号Peers

```go
// 来自prysm/beacon-chain/p2p/discovery.go
func (s *Service) dialPeers(
    ctx context.Context,
    maxConcurrentDials int,
    peersToDial []*enode.Node,
) int {
    // 转换为multiaddrs
    multiAddrs := convertToMultiAddr(peersToDial)
    addrInfos, err := peer.AddrInfosFromP2pAddrs(multiAddrs...)
    if err != nil {
        log.WithError(err).Error("Could not convert to peer address info")
        return 0
    }
    
    // 限制并发拨号数
    dialedCount := 0
    semaphore := make(chan struct{}, maxConcurrentDials)
    
    var wg sync.WaitGroup
    for _, info := range addrInfos {
        // 检查是否已取消
        select {
        case <-ctx.Done():
            wg.Wait()
            return dialedCount
        case semaphore <- struct{}{}:
        }
        
        wg.Add(1)
        go func(info peer.AddrInfo) {
            defer wg.Done()
            defer func() { <-semaphore }()
            
            if err := s.connectWithPeer(ctx, info); err != nil {
                log.WithError(err).Tracef("Could not connect with peer %s", info.ID)
                return
            }
            
            dialedCount++
        }(info)
    }
    
    wg.Wait()
    return dialedCount
}

func (s *Service) connectWithPeer(ctx context.Context, info peer.AddrInfo) error {
    // 忽略自己
    if info.ID == s.host.ID() {
        return nil
    }
    
    // 检查是否是bad peer
    if err := s.Peers().IsBad(info.ID); err != nil {
        return errors.Wrap(err, "bad peer")
    }
    
    // 带超时拨号
    ctx, cancel := context.WithTimeout(ctx, maxDialTimeout)
    defer cancel()
    
    if err := s.host.Connect(ctx, info); err != nil {
        s.downscorePeer(info.ID, "connectionError")
        return errors.Wrap(err, "peer connect")
    }
    
    return nil
}
```

### 6.7.2 Peer限制检查

```go
func (s *Service) isPeerAtLimit(direction connectivityDirection) bool {
    maxPeers := int(s.cfg.MaxPeers)
    
    // 入站连接检查（包含缓冲）
    if direction == inbound {
        maxPeers += highWatermarkBuffer
        maxInbound := s.peers.InboundLimit() + highWatermarkBuffer
        inboundCount := len(s.peers.InboundConnected())
        
        if inboundCount >= maxInbound {
            return true
        }
    }
    
    // 总peer数检查
    peerCount := len(s.host.Network().Peers())
    activePeerCount := len(s.Peers().Active())
    
    return activePeerCount >= maxPeers || peerCount >= maxPeers
}

func (s *Service) isBelowOutboundPeerThreshold() bool {
    maxPeers := int(s.cfg.MaxPeers)
    inBoundLimit := s.Peers().InboundLimit()
    
    if maxPeers < inBoundLimit {
        return false
    }
    
    outboundFloor := maxPeers - inBoundLimit
    outBoundThreshold := outboundFloor / 2
    outBoundCount := len(s.Peers().OutboundConnected())
    
    return outBoundCount < outBoundThreshold
}
```

---

## 6.8 小结

本章深入讲解了discv5节点发现机制：

✅ **ENR**: 节点的自描述记录
✅ **discv5协议**: 基于Kademlia的DHT
✅ **节点查找**: 随机节点迭代器
✅ **Peer过滤**: 多层验证确保质量
✅ **Bootnode**: 网络引导节点
✅ **Subnet发现**: 动态的subnet管理
✅ **连接管理**: 智能的拨号和限制

discv5是P2P网络的发现引擎，确保节点能找到合适的peers。

---

## 🎉 第二部分完成！

至此，我们完成了P2P网络层基础（第4-6章）：
- **第4章**: libp2p网络栈
- **第5章**: 协议协商
- **第6章**: 节点发现机制

这三章详细介绍了Prysm如何构建P2P网络基础设施，为后续的Req/Resp和Gossipsub协议打下基础。

**已完成章节总览**:
- 第1-2章: 基础概念与架构
- 第4-6章: P2P网络层基础 ✨新完成
- 第17-20章: 初始同步
- 第21-24章: Regular Sync

**下一步**: 第三部分 Req/Resp协议域（第7-12章）
