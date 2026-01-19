# 以太坊客户端同步机制对比

本目录包含不同以太坊共识层客户端在同步机制实现上的对比分析。

## 对比维度

- [同步策略对比](./sync_strategies.md) - Initial Sync、Regular Sync 策略差异
- [实现差异分析](./implementation_diff.md) - 代码架构、设计模式对比
- [性能基准测试](./performance_benchmark.md) - 同步速度、资源占用对比
- [协议实现对比](./protocol_comparison.md) - Req/Resp、Gossipsub 实现细节

## 当前覆盖客户端

- [Prysm](../docs/prysm/) - Go 实现
- [Teku](../docs/teku/) - Java 实现（28/45）
- [Lighthouse](../docs/lighthouse/) - Rust 实现（28/45）
- Nimbus - Nim 实现（计划中）
- Lodestar - TypeScript 实现（计划中）

---

**最后更新**: 2026-01-19
