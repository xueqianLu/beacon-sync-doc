# 第28章：测试策略

## 28.1 单元测试

### 28.1.1 同步服务测试

```go
// beacon-chain/sync/service_test.go
package sync

import (
    "context"
    "testing"
    "time"
    
    "github.com/prysmaticlabs/prysm/v4/testing/require"
    "github.com/prysmaticlabs/prysm/v4/testing/assert"
)

func TestService_StatusRPCHandler(t *testing.T) {
    tests := []struct {
        name          string
        localStatus   *p2ppb.Status
        remoteStatus  *p2ppb.Status
        expectedErr   error
        shouldConnect bool
    }{
        {
            name: "same chain",
            localStatus: &p2ppb.Status{
                ForkDigest:     []byte{1, 2, 3, 4},
                FinalizedRoot:  make([]byte, 32),
                FinalizedEpoch: 100,
                HeadRoot:       make([]byte, 32),
                HeadSlot:       1000,
            },
            remoteStatus: &p2ppb.Status{
                ForkDigest:     []byte{1, 2, 3, 4},
                FinalizedRoot:  make([]byte, 32),
                FinalizedEpoch: 100,
                HeadRoot:       make([]byte, 32),
                HeadSlot:       1000,
            },
            expectedErr:   nil,
            shouldConnect: true,
        },
        {
            name: "different fork",
            localStatus: &p2ppb.Status{
                ForkDigest:     []byte{1, 2, 3, 4},
                FinalizedRoot:  make([]byte, 32),
                FinalizedEpoch: 100,
                HeadRoot:       make([]byte, 32),
                HeadSlot:       1000,
            },
            remoteStatus: &p2ppb.Status{
                ForkDigest:     []byte{5, 6, 7, 8},
                FinalizedRoot:  make([]byte, 32),
                FinalizedEpoch: 100,
                HeadRoot:       make([]byte, 32),
                HeadSlot:       1000,
            },
            expectedErr:   ErrInvalidForkDigest,
            shouldConnect: false,
        },
        {
            name: "finalized epoch conflict",
            localStatus: &p2ppb.Status{
                ForkDigest:     []byte{1, 2, 3, 4},
                FinalizedRoot:  []byte{1},
                FinalizedEpoch: 100,
                HeadRoot:       make([]byte, 32),
                HeadSlot:       1000,
            },
            remoteStatus: &p2ppb.Status{
                ForkDigest:     []byte{1, 2, 3, 4},
                FinalizedRoot:  []byte{2},
                FinalizedEpoch: 100,
                HeadRoot:       make([]byte, 32),
                HeadSlot:       1000,
            },
            expectedErr:   ErrFinalizedRootMismatch,
            shouldConnect: false,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            ctx := context.Background()
            
            // 创建测试服务
            s := &Service{
                ctx:   ctx,
                chain: &mockChainService{status: tt.localStatus},
                peers: &mockPeersProvider{},
            }
            
            // 模拟peer发送status消息
            pid := peer.ID("test-peer")
            err := s.validateStatus(ctx, pid, tt.remoteStatus)
            
            if tt.expectedErr != nil {
                require.ErrorIs(t, err, tt.expectedErr)
            } else {
                require.NoError(t, err)
            }
            
            // 检查peer是否被连接
            if tt.shouldConnect {
                assert.Equal(t, peers.PeerConnected, s.peers.ConnectionState(pid))
            } else {
                assert.NotEqual(t, peers.PeerConnected, s.peers.ConnectionState(pid))
            }
        })
    }
}

func TestService_BeaconBlocksByRangeRequest(t *testing.T) {
    ctx := context.Background()
    
    // 创建测试区块
    blocks := make([]*ethpb.SignedBeaconBlock, 100)
    for i := 0; i < 100; i++ {
        blocks[i] = &ethpb.SignedBeaconBlock{
            Block: &ethpb.BeaconBlock{
                Slot: types.Slot(i),
            },
        }
    }
    
    // 创建测试服务
    s := &Service{
        ctx: ctx,
        cfg: &Config{
            DB: &mockDB{blocks: blocks},
        },
    }
    
    tests := []struct {
        name        string
        req         *p2ppb.BeaconBlocksByRangeRequest
        expectCount int
        expectErr   bool
    }{
        {
            name: "normal range",
            req: &p2ppb.BeaconBlocksByRangeRequest{
                StartSlot: 0,
                Count:     10,
                Step:      1,
            },
            expectCount: 10,
            expectErr:   false,
        },
        {
            name: "with step",
            req: &p2ppb.BeaconBlocksByRangeRequest{
                StartSlot: 0,
                Count:     10,
                Step:      2,
            },
            expectCount: 10,
            expectErr:   false,
        },
        {
            name: "exceeds max count",
            req: &p2ppb.BeaconBlocksByRangeRequest{
                StartSlot: 0,
                Count:     2000,
                Step:      1,
            },
            expectCount: 0,
            expectErr:   true,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            stream := &mockStream{}
            
            err := s.beaconBlocksByRangeRPCHandler(ctx, tt.req, stream)
            
            if tt.expectErr {
                require.Error(t, err)
            } else {
                require.NoError(t, err)
                assert.Equal(t, tt.expectCount, len(stream.sentBlocks))
            }
        })
    }
}
```

### 28.1.2 区块验证测试

```go
// beacon-chain/blockchain/process_block_test.go
func TestService_ProcessBlock(t *testing.T) {
    ctx := context.Background()
    
    tests := []struct {
        name      string
        block     *ethpb.SignedBeaconBlock
        preState  state.BeaconState
        wantErr   bool
        errString string
    }{
        {
            name: "valid block",
            block: &ethpb.SignedBeaconBlock{
                Block: &ethpb.BeaconBlock{
                    Slot:          100,
                    ProposerIndex: 1,
                    ParentRoot:    make([]byte, 32),
                    StateRoot:     make([]byte, 32),
                    Body:          &ethpb.BeaconBlockBody{},
                },
                Signature: make([]byte, 96),
            },
            preState: &mockBeaconState{slot: 99},
            wantErr:  false,
        },
        {
            name: "invalid slot",
            block: &ethpb.SignedBeaconBlock{
                Block: &ethpb.BeaconBlock{
                    Slot: 50, // slot在state之前
                },
            },
            preState:  &mockBeaconState{slot: 100},
            wantErr:   true,
            errString: "block slot is before current state",
        },
        {
            name: "invalid signature",
            block: &ethpb.SignedBeaconBlock{
                Block: &ethpb.BeaconBlock{
                    Slot:          100,
                    ProposerIndex: 1,
                },
                Signature: make([]byte, 96), // 无效签名
            },
            preState:  &mockBeaconState{slot: 99},
            wantErr:   true,
            errString: "signature verification failed",
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            s := &Service{
                ctx: ctx,
                cfg: &Config{
                    StateGen: &mockStateGen{states: map[[32]byte]state.BeaconState{
                        {}: tt.preState,
                    }},
                },
            }
            
            blockRoot, _ := tt.block.Block.HashTreeRoot()
            err := s.onBlock(ctx, tt.block, blockRoot)
            
            if tt.wantErr {
                require.Error(t, err)
                if tt.errString != "" {
                    assert.Contains(t, err.Error(), tt.errString)
                }
            } else {
                require.NoError(t, err)
            }
        })
    }
}
```

## 28.2 集成测试

### 28.2.1 端到端同步测试

```go
// beacon-chain/sync/sync_test.go
func TestSync_E2E(t *testing.T) {
    ctx := context.Background()
    
    // 创建genesis state
    genesisState, genesisBlock := createGenesisState(t)
    
    // 创建第一个节点（已同步）
    node1 := createTestNode(t, genesisState, genesisBlock)
    
    // 生成100个区块
    blocks := generateBlocks(t, node1, 100)
    for _, block := range blocks {
        require.NoError(t, node1.ReceiveBlock(ctx, block))
    }
    
    // 创建第二个节点（需要同步）
    node2 := createTestNode(t, genesisState, genesisBlock)
    
    // 连接两个节点
    connectNodes(t, node1, node2)
    
    // 等待同步完成
    timeout := time.After(30 * time.Second)
    ticker := time.NewTicker(100 * time.Millisecond)
    defer ticker.Stop()
    
    for {
        select {
        case <-timeout:
            t.Fatal("Sync timed out")
        case <-ticker.C:
            if node2.HeadSlot() == node1.HeadSlot() {
                // 同步完成
                assert.Equal(t, node1.HeadRoot(), node2.HeadRoot())
                return
            }
        }
    }
}

func TestCheckpointSync_E2E(t *testing.T) {
    ctx := context.Background()
    
    // 创建已运行的网络
    network := createTestNetwork(t, 4) // 4个节点
    
    // 运行到epoch 10
    advanceToEpoch(t, network, 10)
    
    // 获取checkpoint
    checkpoint := network.Nodes[0].FinalizedCheckpoint()
    
    // 创建新节点，使用checkpoint sync
    newNode := createTestNodeWithCheckpoint(t, checkpoint)
    
    // 连接到网络
    for _, node := range network.Nodes {
        connectNodes(t, newNode, node)
    }
    
    // 等待同步完成
    waitForSync(t, newNode, 30*time.Second)
    
    // 验证同步结果
    assert.Equal(t, network.Nodes[0].HeadSlot(), newNode.HeadSlot())
    assert.Equal(t, network.Nodes[0].HeadRoot(), newNode.HeadRoot())
}
```

### 28.2.2 网络分区测试

```go
// beacon-chain/sync/partition_test.go
func TestNetworkPartition(t *testing.T) {
    ctx := context.Background()
    
    // 创建6个节点的网络
    nodes := make([]*testNode, 6)
    for i := range nodes {
        nodes[i] = createTestNode(t, nil, nil)
    }
    
    // 连接形成两个分区
    // 分区1: 节点0,1,2
    // 分区2: 节点3,4,5
    connectNodes(t, nodes[0], nodes[1])
    connectNodes(t, nodes[1], nodes[2])
    connectNodes(t, nodes[3], nodes[4])
    connectNodes(t, nodes[4], nodes[5])
    
    // 在分区1中生成区块
    blocks1 := generateBlocks(t, nodes[0], 10)
    for _, block := range blocks1 {
        for i := 0; i < 3; i++ {
            require.NoError(t, nodes[i].ReceiveBlock(ctx, block))
        }
    }
    
    // 在分区2中生成不同的区块
    blocks2 := generateBlocks(t, nodes[3], 10)
    for _, block := range blocks2 {
        for i := 3; i < 6; i++ {
            require.NoError(t, nodes[i].ReceiveBlock(ctx, block))
        }
    }
    
    // 验证分区内一致
    assert.Equal(t, nodes[0].HeadRoot(), nodes[1].HeadRoot())
    assert.Equal(t, nodes[1].HeadRoot(), nodes[2].HeadRoot())
    assert.Equal(t, nodes[3].HeadRoot(), nodes[4].HeadRoot())
    assert.Equal(t, nodes[4].HeadRoot(), nodes[5].HeadRoot())
    
    // 验证分区间不同
    assert.NotEqual(t, nodes[0].HeadRoot(), nodes[3].HeadRoot())
    
    // 修复分区
    connectNodes(t, nodes[2], nodes[3])
    
    // 等待重新同步
    time.Sleep(5 * time.Second)
    
    // 验证所有节点达成一致
    headRoot := nodes[0].HeadRoot()
    for i := 1; i < 6; i++ {
        assert.Equal(t, headRoot, nodes[i].HeadRoot())
    }
}
```

## 28.3 性能测试

### 28.3.1 同步性能测试

```go
// beacon-chain/sync/benchmark_test.go
func BenchmarkSync_ProcessBlocks(b *testing.B) {
    ctx := context.Background()
    
    // 准备测试数据
    blocks := make([]*ethpb.SignedBeaconBlock, 1000)
    for i := range blocks {
        blocks[i] = generateRandomBlock(types.Slot(i))
    }
    
    service := createBenchmarkService(b)
    
    b.ResetTimer()
    b.ReportAllocs()
    
    for i := 0; i < b.N; i++ {
        for _, block := range blocks {
            if err := service.ProcessBlock(ctx, block); err != nil {
                b.Fatal(err)
            }
        }
    }
    
    // 报告性能指标
    blocksPerSec := float64(len(blocks)*b.N) / b.Elapsed().Seconds()
    b.ReportMetric(blocksPerSec, "blocks/sec")
}

func BenchmarkSync_ParallelValidation(b *testing.B) {
    ctx := context.Background()
    
    // 生成测试数据
    blocks := make([]*ethpb.SignedBeaconBlock, 100)
    for i := range blocks {
        blocks[i] = generateRandomBlock(types.Slot(i))
    }
    
    service := createBenchmarkService(b)
    
    b.ResetTimer()
    b.RunParallel(func(pb *testing.PB) {
        for pb.Next() {
            for _, block := range blocks {
                _ = service.ValidateBlock(ctx, block)
            }
        }
    })
}

func BenchmarkDB_BatchWrite(b *testing.B) {
    db := setupBenchmarkDB(b)
    defer db.Close()
    
    blocks := make([]*ethpb.SignedBeaconBlock, 1000)
    for i := range blocks {
        blocks[i] = generateRandomBlock(types.Slot(i))
    }
    
    b.ResetTimer()
    b.ReportAllocs()
    
    for i := 0; i < b.N; i++ {
        batch := db.NewBatch()
        for _, block := range blocks {
            batch.SaveBlock(context.Background(), block)
        }
        if err := batch.Commit(); err != nil {
            b.Fatal(err)
        }
    }
}
```

### 28.3.2 内存和CPU分析

```go
// beacon-chain/sync/profile_test.go
func TestSync_MemoryProfile(t *testing.T) {
    if testing.Short() {
        t.Skip("Skipping memory profile test in short mode")
    }
    
    // 启动CPU profiling
    cpuFile, err := os.Create("cpu.prof")
    require.NoError(t, err)
    defer cpuFile.Close()
    
    require.NoError(t, pprof.StartCPUProfile(cpuFile))
    defer pprof.StopCPUProfile()
    
    // 运行同步测试
    ctx := context.Background()
    service := createTestService(t)
    
    blocks := generateBlocks(t, service, 10000)
    
    // 记录初始内存
    var m1 runtime.MemStats
    runtime.ReadMemStats(&m1)
    
    // 处理区块
    for _, block := range blocks {
        require.NoError(t, service.ProcessBlock(ctx, block))
    }
    
    // 记录最终内存
    runtime.GC()
    var m2 runtime.MemStats
    runtime.ReadMemStats(&m2)
    
    // 报告内存使用
    t.Logf("Memory usage:")
    t.Logf("  Alloc: %d MB", (m2.Alloc-m1.Alloc)/1024/1024)
    t.Logf("  TotalAlloc: %d MB", (m2.TotalAlloc-m1.TotalAlloc)/1024/1024)
    t.Logf("  NumGC: %d", m2.NumGC-m1.NumGC)
    
    // 写入内存profile
    memFile, err := os.Create("mem.prof")
    require.NoError(t, err)
    defer memFile.Close()
    
    require.NoError(t, pprof.WriteHeapProfile(memFile))
}
```

## 28.4 模糊测试

### 28.4.1 区块验证模糊测试

```go
// beacon-chain/blockchain/fuzz_test.go
func FuzzProcessBlock(f *testing.F) {
    // 添加种子语料库
    f.Add(uint64(0), uint64(1), make([]byte, 32), make([]byte, 96))
    
    f.Fuzz(func(t *testing.T, slot uint64, proposerIndex uint64, parentRoot []byte, signature []byte) {
        ctx := context.Background()
        
        // 确保输入在有效范围内
        if slot > 1000000 {
            return
        }
        if proposerIndex > 1000 {
            return
        }
        if len(parentRoot) != 32 {
            return
        }
        if len(signature) != 96 {
            return
        }
        
        // 创建测试区块
        block := &ethpb.SignedBeaconBlock{
            Block: &ethpb.BeaconBlock{
                Slot:          types.Slot(slot),
                ProposerIndex: types.ValidatorIndex(proposerIndex),
                ParentRoot:    parentRoot,
                Body:          &ethpb.BeaconBlockBody{},
            },
            Signature: signature,
        }
        
        // 创建测试服务
        service := createFuzzTestService(t)
        
        // 处理区块（不应该panic）
        _ = service.ProcessBlock(ctx, block)
    })
}

func FuzzValidateAttestation(f *testing.F) {
    f.Add(uint64(0), uint64(0), uint64(0), make([]byte, 32), make([]byte, 96))
    
    f.Fuzz(func(t *testing.T, slot uint64, index uint64, beaconBlockRoot []byte, signature []byte) {
        if len(beaconBlockRoot) != 32 || len(signature) != 96 {
            return
        }
        
        att := &ethpb.Attestation{
            Data: &ethpb.AttestationData{
                Slot:            types.Slot(slot),
                CommitteeIndex:  types.CommitteeIndex(index),
                BeaconBlockRoot: beaconBlockRoot,
            },
            Signature: signature,
        }
        
        service := createFuzzTestService(t)
        _ = service.ValidateAttestation(context.Background(), att)
    })
}
```

这一章详细介绍了Prysm中的测试策略，包括单元测试、集成测试、性能测试和模糊测试。完善的测试体系是确保系统质量的关键。
