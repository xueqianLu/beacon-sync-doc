# 第 27 章: 监控与指标

本章介绍 Teku 同步模块的监控体系。

---

## 27.1 Prometheus 指标

```java
// 同步状态
Gauge syncStatus = Gauge.build()
  .name("teku_sync_status")
  .help("Sync status (0=syncing, 1=in_sync)")
  .register();

// Head lag
Gauge headLag = Gauge.build()
  .name("teku_head_lag_slots")
  .help("Head lag in slots")
  .register();

// 同步速度
Counter blocksProcessed = Counter.build()
  .name("teku_blocks_processed_total")
  .help("Total blocks processed")
  .register();

// 导入延迟
Histogram importDuration = Histogram.build()
  .name("teku_block_import_duration_seconds")
  .help("Block import duration")
  .buckets(0.01, 0.05, 0.1, 0.5, 1.0)
  .register();
```

---

## 27.2 Grafana 仪表盘

```json
{
  "dashboard": {
    "title": "Teku Sync Monitoring",
    "panels": [
      {
        "title": "Sync Status",
        "expr": "teku_sync_status"
      },
      {
        "title": "Sync Speed",
        "expr": "rate(teku_blocks_processed_total[5m])"
      },
      {
        "title": "Head Lag",
        "expr": "teku_head_lag_slots"
      }
    ]
  }
}
```

---

## 27.3 告警规则

```yaml
groups:
  - name: sync_alerts
    rules:
      - alert: NodeBehind
        expr: teku_head_lag_slots > 100
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Node is behind"
          
      - alert: SyncStalled
        expr: rate(teku_blocks_processed_total[5m]) == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Sync stalled"
```

---

## 27.4 日志分析

```java
// 结构化日志
LOG.info("Sync progress",
  kv("currentSlot", currentSlot),
  kv("headSlot", headSlot),
  kv("speed", blocksPerSecond),
  kv("eta", estimatedTimeToComplete)
);
```

---

## 27.5 与 Prysm 对比

| 维度 | Prysm | Teku |
|------|-------|------|
| 指标格式 | Prometheus | Prometheus |
| 仪表盘 | Grafana | Grafana |
| 日志 | logrus | log4j |
| 结构化 | ✅ | ✅ |

---

**最后更新**: 2026-01-13
