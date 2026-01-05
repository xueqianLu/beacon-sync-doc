# 第7章 Req/Resp协议基础

## 7.1 请求-响应模型

### 7.1.1 模型概述

Req/Resp（Request-Response）是以太坊Beacon Chain使用的点对点请求-响应通信协议。与广播式的Gossipsub不同，Req/Resp用于节点间的直接数据交换。

**核心特点**：
- **单播通信**：一对一的直接连接
- **同步语义**：请求方等待响应
- **流式传输**：支持分块响应
- **超时控制**：防止无限等待

**典型使用场景**：
```
节点A需要历史区块
    ↓
发起BeaconBlocksByRange请求
    ↓
节点B接收并验证请求
    ↓
流式返回区块数据
    ↓
节点A处理响应
```

### 7.1.2 协议层次

Req/Resp构建在libp2p协议栈之上：

```
┌─────────────────────────────────────┐
│    应用层协议                        │
│  (Status, BeaconBlocksByRange等)    │
├─────────────────────────────────────┤
│    Req/Resp框架                     │
│  (请求/响应处理, 编码/解码)          │
├─────────────────────────────────────┤
│    libp2p Stream                    │
│  (双向字节流)                        │
├─────────────────────────────────────┤
│    Multiplexer (mplex/yamux)        │
│  (多路复用)                          │
├─────────────────────────────────────┤
│    Security (Noise)                 │
│  (加密握手)                          │
├─────────────────────────────────────┤
│    Transport (TCP/QUIC)             │
│  (网络传输)                          │
└─────────────────────────────────────┘
```

### 7.1.3 交互流程

```
请求方                                 响应方
  │                                      │
  │  1. 建立Stream                       │
  ├─────────────────────────────────────>│
  │                                      │
  │  2. 发送请求                         │
  ├─────────────────────────────────────>│
  │                                      │
  │                              3. 验证请求
  │                                      │
  │  4. 响应数据块1                      │
  │<─────────────────────────────────────┤
  │                                      │
  │  5. 响应数据块2                      │
  │<─────────────────────────────────────┤
  │                                      │
  │  6. ...更多数据块...                 │
  │<─────────────────────────────────────┤
  │                                      │
  │  7. 关闭Stream                       │
  │<─────────────────────────────────────┤
  │                                      │
```

### 7.1.4 Prysm实现：RPC包结构

```go
// beacon-chain/p2p/rpc.go
package p2p

import (
    "context"
    "io"
    
    libp2pcore "github.com/libp2p/go-libp2p/core"
    "github.com/libp2p/go-libp2p/core/network"
)

// RPCHandler 处理RPC请求的函数类型
type RPCHandler func(
    ctx context.Context,
    msg interface{},
    stream libp2pcore.Stream,
) error

// Service 包含RPC服务所需的组件
type Service struct {
    host        libp2pcore.Host
    cfg         *Config
    peers       *peers.Status
    rateLimiter *limiter
}
```

### 7.1.5 请求发送实现

```go
// beacon-chain/p2p/sender.go
package p2p

// SendRequest 发送RPC请求
func (s *Service) SendRequest(
    ctx context.Context,
    req interface{},
    protocol string,
    peerID peer.ID,
) (interface{}, error) {
    
    // 1. 打开新Stream
    stream, err := s.host.NewStream(
        ctx,
        peerID,
        protocol,
    )
    if err != nil {
        return nil, err
    }
    defer stream.Close()
    
    // 2. 设置超时
    deadline := time.Now().Add(respTimeout)
    if err := stream.SetDeadline(deadline); err != nil {
        return nil, err
    }
    
    // 3. 编码并发送请求
    if err := s.encoding.EncodeWithMaxLength(
        stream,
        req,
    ); err != nil {
        return nil, err
    }
    
    // 4. 关闭写端（发送完成信号）
    if err := stream.CloseWrite(); err != nil {
        return nil, err
    }
    
    // 5. 读取响应
    return s.readResponse(ctx, stream)
}
```

### 7.1.6 请求处理实现

```go
// beacon-chain/p2p/handler.go
package p2p

// registerRPCHandlers 注册所有RPC处理器
func (s *Service) registerRPCHandlers() {
    // Status协议
    s.registerRPC(
        RPCStatusTopicV1,
        s.statusRPCHandler,
    )
    
    // BeaconBlocksByRange协议
    s.registerRPC(
        RPCBlocksByRangeTopicV2,
        s.beaconBlocksByRangeRPCHandler,
    )
    
    // BeaconBlocksByRoot协议
    s.registerRPC(
        RPCBlocksByRootTopicV2,
        s.beaconBlocksByRootRPCHandler,
    )
    
    // Ping协议
    s.registerRPC(
        RPCPingTopicV1,
        s.pingHandler,
    )
    
    // Goodbye协议
    s.registerRPC(
        RPCGoodByeTopicV1,
        s.goodbyeRPCHandler,
    )
    
    // MetaData协议
    s.registerRPC(
        RPCMetaDataTopicV2,
        s.metadataRPCHandler,
    )
}

// registerRPC 注册单个RPC处理器
func (s *Service) registerRPC(
    topic string,
    handler RPCHandler,
) {
    s.host.SetStreamHandler(
        protocol.ID(topic),
        func(stream network.Stream) {
            // 包装处理器，添加通用逻辑
            s.handleRPC(stream, handler)
        },
    )
}

// handleRPC 处理RPC请求的通用逻辑
func (s *Service) handleRPC(
    stream network.Stream,
    handler RPCHandler,
) {
    ctx := context.Background()
    defer stream.Close()
    
    // 1. 设置超时
    deadline := time.Now().Add(respTimeout)
    if err := stream.SetDeadline(deadline); err != nil {
        log.WithError(err).Error("Failed to set deadline")
        return
    }
    
    // 2. 速率限制检查
    if s.rateLimiter.excess(
        stream.Conn().RemotePeer(),
        stream.Protocol(),
    ) {
        log.Debug("Rate limit exceeded")
        return
    }
    
    // 3. 解码请求
    msg, err := s.decodeRequest(stream)
    if err != nil {
        log.WithError(err).Error("Failed to decode request")
        return
    }
    
    // 4. 调用具体处理器
    if err := handler(ctx, msg, stream); err != nil {
        log.WithError(err).Error("Handler failed")
        return
    }
}
```

---

## 7.2 协议标识符

### 7.2.1 协议ID格式

每个Req/Resp协议都有唯一的协议标识符：

```
/eth2/beacon_chain/req/<protocol_name>/<version>/[encoding]

组成部分：
- /eth2/beacon_chain/req: 固定前缀
- <protocol_name>: 协议名称
- <version>: 版本号（如1, 2）
- [encoding]: 编码方式（如ssz_snappy）
```

### 7.2.2 常用协议ID

```go
// beacon-chain/p2p/types/rpc.go
const (
    // Status协议 - v1
    RPCStatusTopicV1 = "/eth2/beacon_chain/req/status/1/ssz_snappy"
    
    // BeaconBlocksByRange - v2 (支持Deneb)
    RPCBlocksByRangeTopicV2 = "/eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy"
    
    // BeaconBlocksByRoot - v2
    RPCBlocksByRootTopicV2 = "/eth2/beacon_chain/req/beacon_blocks_by_root/2/ssz_snappy"
    
    // BlobSidecarsByRange - v1 (EIP-4844)
    RPCBlobSidecarsByRangeTopicV1 = "/eth2/beacon_chain/req/blob_sidecars_by_range/1/ssz_snappy"
    
    // BlobSidecarsByRoot - v1
    RPCBlobSidecarsByRootTopicV1 = "/eth2/beacon_chain/req/blob_sidecars_by_root/1/ssz_snappy"
    
    // Ping - v1
    RPCPingTopicV1 = "/eth2/beacon_chain/req/ping/1/ssz_snappy"
    
    // Goodbye - v1
    RPCGoodByeTopicV1 = "/eth2/beacon_chain/req/goodbye/1/ssz_snappy"
    
    // MetaData - v2
    RPCMetaDataTopicV2 = "/eth2/beacon_chain/req/metadata/2/ssz_snappy"
)
```

### 7.2.3 版本演进

**BeaconBlocksByRange版本变化**：
```
v1: /eth2/beacon_chain/req/beacon_blocks_by_range/1/ssz_snappy
    - 支持Phase 0和Altair
    
v2: /eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy
    - 支持Bellatrix (Merge)
    - 支持Capella
    - 支持Deneb (EIP-4844)
```

**协议选择逻辑**：
```go
// beacon-chain/p2p/encoder/network_encoding.go
func (s *Service) protocolForEpoch(epoch primitives.Epoch) string {
    // Deneb之后使用v2
    if epoch >= params.BeaconConfig().DenebForkEpoch {
        return RPCBlocksByRangeTopicV2
    }
    // Bellatrix之后使用v2
    if epoch >= params.BeaconConfig().BellatrixForkEpoch {
        return RPCBlocksByRangeTopicV2
    }
    // Phase 0/Altair使用v1
    return RPCBlocksByRangeTopicV1
}
```

---

## 7.3 编码策略（SSZ + Snappy）

### 7.3.1 SSZ编码

**SSZ (Simple Serialize)** 是以太坊2.0的标准序列化格式。

**特点**：
- 固定长度字段
- 确定性编码
- 高效的Merkle化
- 支持向后兼容

**示例**：
```go
// Status消息的SSZ编码
type Status struct {
    ForkDigest     [4]byte           `ssz-size:"4"`
    FinalizedRoot  [32]byte          `ssz-size:"32"`
    FinalizedEpoch primitives.Epoch  `ssz:"uint64"`
    HeadRoot       [32]byte          `ssz-size:"32"`
    HeadSlot       primitives.Slot   `ssz:"uint64"`
}

// SSZ编码
data, err := status.MarshalSSZ()

// SSZ解码
var status Status
err := status.UnmarshalSSZ(data)
```

### 7.3.2 Snappy压缩

**Snappy** 是Google开发的快速压缩算法。

**优势**：
- 压缩速度快
- 解压速度快
- 适度的压缩率
- 低CPU开销

**压缩流程**：
```
原始数据 → SSZ编码 → Snappy压缩 → 网络传输
                ↓
            带长度前缀的帧
```

### 7.3.3 编码实现

```go
// beacon-chain/p2p/encoder/ssz.go
package encoder

import (
    "io"
    "github.com/golang/snappy"
    "github.com/prysmaticlabs/prysm/v5/encoding/ssz"
)

// SszNetworkEncoder SSZ+Snappy编码器
type SszNetworkEncoder struct{}

// EncodeWithMaxLength 编码并写入stream
func (e SszNetworkEncoder) EncodeWithMaxLength(
    w io.Writer,
    msg interface{},
) error {
    // 1. SSZ序列化
    sszData, err := ssz.Marshal(msg)
    if err != nil {
        return err
    }
    
    // 2. 检查大小限制
    if uint64(len(sszData)) > maxChunkSize {
        return errors.New("message too large")
    }
    
    // 3. Snappy压缩
    compressed := snappy.Encode(nil, sszData)
    
    // 4. 写入长度前缀（varint编码）
    length := uint64(len(compressed))
    if err := writeVarint(w, length); err != nil {
        return err
    }
    
    // 5. 写入压缩数据
    _, err = w.Write(compressed)
    return err
}

// DecodeWithMaxLength 从stream解码
func (e SszNetworkEncoder) DecodeWithMaxLength(
    r io.Reader,
    msg interface{},
) error {
    // 1. 读取长度前缀
    length, err := readVarint(r)
    if err != nil {
        return err
    }
    
    // 2. 检查大小限制
    if length > maxChunkSize {
        return errors.New("message too large")
    }
    
    // 3. 读取压缩数据
    compressed := make([]byte, length)
    if _, err := io.ReadFull(r, compressed); err != nil {
        return err
    }
    
    // 4. Snappy解压
    sszData, err := snappy.Decode(nil, compressed)
    if err != nil {
        return err
    }
    
    // 5. SSZ反序列化
    return ssz.Unmarshal(sszData, msg)
}
```

### 7.3.4 分块编码

对于流式响应，每个数据块单独编码：

```
响应块1:
┌────────────┬──────────────────┐
│ 长度varint │  Snappy(SSZ(块1)) │
└────────────┴──────────────────┘

响应块2:
┌────────────┬──────────────────┐
│ 长度varint │  Snappy(SSZ(块2)) │
└────────────┴──────────────────┘

...

结束标记: Stream关闭
```

**实现**：
```go
// 发送多个响应块
func sendBlocks(stream network.Stream, blocks []*Block) error {
    encoder := &SszNetworkEncoder{}
    
    for _, block := range blocks {
        // 每个块单独编码和发送
        if err := encoder.EncodeWithMaxLength(
            stream,
            block,
        ); err != nil {
            return err
        }
    }
    
    // 关闭stream表示响应结束
    return stream.Close()
}
```

---

## 7.4 错误处理

### 7.4.1 错误类型

Req/Resp定义了标准错误码：

```go
// beacon-chain/p2p/types/error.go
const (
    // 成功
    ResponseCodeSuccess = 0
    
    // 通用错误
    ResponseCodeInvalidRequest = 1
    
    // 服务器错误
    ResponseCodeServerError = 2
    
    // 资源不可用
    ResponseCodeResourceUnavailable = 3
)

type ErrorResponse struct {
    Code    uint8
    Message []byte // 错误描述，最大256字节
}
```

### 7.4.2 错误响应格式

```
错误响应:
┌──────────┬────────────┬──────────────────┐
│ 错误码   │ 消息长度   │  错误消息         │
│ (1字节)  │ (varint)   │  (最多256字节)    │
└──────────┴────────────┴──────────────────┘
```

### 7.4.3 错误处理实现

```go
// beacon-chain/p2p/rpc_error.go

// WriteErrorResponse 写入错误响应
func WriteErrorResponse(
    stream network.Stream,
    code uint8,
    msg string,
) error {
    // 截断消息到256字节
    msgBytes := []byte(msg)
    if len(msgBytes) > 256 {
        msgBytes = msgBytes[:256]
    }
    
    // 写入错误码
    if _, err := stream.Write([]byte{code}); err != nil {
        return err
    }
    
    // 写入消息长度
    if err := writeVarint(stream, uint64(len(msgBytes))); err != nil {
        return err
    }
    
    // 写入错误消息
    _, err := stream.Write(msgBytes)
    return err
}

// ReadErrorResponse 读取错误响应
func ReadErrorResponse(stream network.Stream) error {
    // 读取错误码
    codeBuf := make([]byte, 1)
    if _, err := io.ReadFull(stream, codeBuf); err != nil {
        return err
    }
    code := codeBuf[0]
    
    // 如果成功，返回nil
    if code == ResponseCodeSuccess {
        return nil
    }
    
    // 读取消息长度
    length, err := readVarint(stream)
    if err != nil {
        return err
    }
    
    if length > 256 {
        return errors.New("error message too long")
    }
    
    // 读取错误消息
    msgBuf := make([]byte, length)
    if _, err := io.ReadFull(stream, msgBuf); err != nil {
        return err
    }
    
    // 返回错误
    return &RPCError{
        Code:    code,
        Message: string(msgBuf),
    }
}

type RPCError struct {
    Code    uint8
    Message string
}

func (e *RPCError) Error() string {
    switch e.Code {
    case ResponseCodeInvalidRequest:
        return "Invalid request: " + e.Message
    case ResponseCodeServerError:
        return "Server error: " + e.Message
    case ResponseCodeResourceUnavailable:
        return "Resource unavailable: " + e.Message
    default:
        return fmt.Sprintf("Error %d: %s", e.Code, e.Message)
    }
}
```

### 7.4.4 常见错误场景

```go
// 请求验证失败
if !isValidRequest(req) {
    return WriteErrorResponse(
        stream,
        ResponseCodeInvalidRequest,
        "Invalid slot range",
    )
}

// 资源不可用
if !hasRequestedBlocks(req) {
    return WriteErrorResponse(
        stream,
        ResponseCodeResourceUnavailable,
        "Blocks not available",
    )
}

// 内部错误
if err := processRequest(req); err != nil {
    return WriteErrorResponse(
        stream,
        ResponseCodeServerError,
        "Failed to process request",
    )
}
```

### 7.4.5 超时和重试

```go
// beacon-chain/p2p/sender.go

const (
    // 响应超时
    respTimeout = 10 * time.Second
    
    // 重试次数
    maxRetries = 3
    
    // 退避基准时间
    baseBackoff = 1 * time.Second
)

// SendWithRetry 带重试的请求发送
func (s *Service) SendWithRetry(
    ctx context.Context,
    req interface{},
    protocol string,
    peerID peer.ID,
) (interface{}, error) {
    var lastErr error
    
    for attempt := 0; attempt < maxRetries; attempt++ {
        // 指数退避
        if attempt > 0 {
            backoff := baseBackoff * time.Duration(1<<uint(attempt-1))
            select {
            case <-time.After(backoff):
            case <-ctx.Done():
                return nil, ctx.Err()
            }
        }
        
        // 尝试发送请求
        resp, err := s.SendRequest(ctx, req, protocol, peerID)
        if err == nil {
            return resp, nil
        }
        
        lastErr = err
        
        // 检查是否应该重试
        if !shouldRetry(err) {
            break
        }
    }
    
    return nil, lastErr
}

func shouldRetry(err error) bool {
    // 网络错误可以重试
    if errors.Is(err, network.ErrReset) {
        return true
    }
    
    // 超时可以重试
    if os.IsTimeout(err) {
        return true
    }
    
    // 其他错误不重试
    return false
}
```

---

## 7.5 最佳实践

### 7.5.1 请求验证

```go
// 在处理器开始时验证请求
func (s *Service) beaconBlocksByRangeRPCHandler(
    ctx context.Context,
    msg interface{},
    stream libp2pcore.Stream,
) error {
    req, ok := msg.(*pb.BeaconBlocksByRangeRequest)
    if !ok {
        return WriteErrorResponse(
            stream,
            ResponseCodeInvalidRequest,
            "Invalid message type",
        )
    }
    
    // 验证参数
    if err := validateBlocksByRangeRequest(req); err != nil {
        return WriteErrorResponse(
            stream,
            ResponseCodeInvalidRequest,
            err.Error(),
        )
    }
    
    // 继续处理...
}
```

### 7.5.2 资源限制

```go
const (
    // 最大请求大小
    maxChunkSize = 1 << 20 // 1MB
    
    // 最大响应块数
    maxRequestBlocks = 1024
    
    // 速率限制
    rateLimit = 50 // 每秒最多50个请求
)

// 检查请求大小
if req.Count > maxRequestBlocks {
    return errors.New("too many blocks requested")
}
```

### 7.5.3 优雅关闭

```go
// 正确关闭stream
defer func() {
    if err := stream.Close(); err != nil {
        log.WithError(err).Debug("Failed to close stream")
    }
}()

// 发送完成后关闭写端
if err := stream.CloseWrite(); err != nil {
    return err
}
```

---

## 本章小结

本章介绍了Req/Resp协议的基础知识：

✅ **请求-响应模型** - 点对点通信机制
✅ **协议标识符** - 版本管理和协议选择
✅ **编码策略** - SSZ序列化 + Snappy压缩
✅ **错误处理** - 标准错误码和错误响应
✅ **Prysm实现** - 核心代码和最佳实践

下一章将深入讲解Status协议的实现细节。

---

**相关章节**：
- [第5章：协议协商](./chapter_05_protocol_negotiation.md)
- [第8章：Status协议](./chapter_08_status_protocol.md)
- [第9章：BeaconBlocksByRange](./chapter_09_blocks_by_range.md)
