# 第 28 章: 测试与调试

本章介绍 Teku 同步模块的测试策略。

---

## 28.1 单元测试

```java
@Test
void shouldImportValidBlock() {
  SignedBeaconBlock block = createValidBlock();
  
  BlockImportResult result = blockImporter
    .importBlock(block)
    .join();
  
  assertThat(result.isSuccessful()).isTrue();
}
```

---

## 28.2 集成测试

```java
@Test
void shouldSyncFromPeer() {
  // 启动本地节点
  BeaconNode node = startNode();
  
  // 连接到 peer
  Peer peer = connectToPeer();
  
  // 执行同步
  SyncResult result = node.syncFrom(peer).join();
  
  assertThat(result.isSuccess()).isTrue();
}
```

---

## 28.3 性能测试

```java
@Benchmark
public void benchmarkBlockImport() {
  SignedBeaconBlock block = generateBlock();
  blockImporter.importBlock(block).join();
}

// 结果
Benchmark              Mode  Cnt   Score   Error  Units
benchmarkBlockImport  thrpt   10  120.5 ± 5.3    ops/s
```

---

## 28.4 调试技巧

```java
// 1. 启用详细日志
-Dlog4j.configurationFile=log4j2-debug.xml

// 2. JVM 诊断
-XX:+UnlockDiagnosticVMOptions
-XX:+LogCompilation

// 3. 远程调试
-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005
```

---

## 28.5 故障模拟

```java
@Test
void shouldHandleNetworkPartition() {
  // 模拟网络分区
  networkSimulator.partitionNetwork();
  
  // 验证恢复
  await().atMost(Duration.ofMinutes(5))
    .until(() -> node.isSynced());
}
```

---

## 28.6 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| 单元测试 | Go test | JUnit |
| Mock 框架 | gomock | Mockito |
| 基准测试 | Go benchmark | JMH |
| 调试工具 | Delve | IntelliJ |

---

**最后更新**: 2026-01-13
