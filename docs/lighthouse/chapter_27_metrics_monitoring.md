# 第 27 章: Lighthouse Metrics & Monitoring v8.0.1

Lighthouse 为网络与同步提供了较丰富的 metrics：既覆盖 libp2p（连接数、RPC 错误、gossipsub publish/validation），也覆盖 beacon processor/sync 的导入与错误分布。

本章建议的阅读方式是：先把指标按“层”分开（网络栈 vs 处理器/导入），再把它们关联到具体故障模式（gossip 不传播、rpc 超时、导入慢、peer 频繁断开）。

---

## 27.0 附录导航（流程图）

- Regular Sync（gossip 验证闭环 + 兜底）：[chapter_sync_flow_business7_regular.md](chapter_sync_flow_business7_regular.md)
- Initial Sync（batch 导入 + 模式切换）：[chapter_sync_flow_business6_initial.md](chapter_sync_flow_business6_initial.md)

---

## 27.1 网络栈（lighthouse_network）指标

入口：

- `beacon_node/lighthouse_network/src/metrics.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/lighthouse_network/src/metrics.rs

建议在文档中重点列举这类指标：

- 连接数：`libp2p_peers` / `libp2p_peers_multi`
- RPC：`libp2p_rpc_requests_total`、`libp2p_rpc_errors_per_client`
- Gossip：`gossipsub_failed_publishes_*`、`gossipsub_unaccepted_messages_per_client`
- Peer 评分分布：`peer_score_distribution`、`peer_score_per_client`

---

## 27.2 Beacon Node network 指标

入口：

- `beacon_node/network/src/metrics.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/metrics.rs

这一层更贴近“处理器与导入”：

- gossip block verified/imported
- import errors per type
- missing components
- forkchoice / availability 相关统计

---

## 27.2.1 两层 metrics 如何对齐读？（一个实用套路）

当出现“同步/导入异常”时，推荐按下面顺序排查，尽量避免在错误层次上做无效分析：

1. **先看网络栈层**：连接数是否下降？RPC 错误是否上升？gossip publish/validation 是否异常？
2. **再看处理器/导入层**：block/attestation 的 verified/imported 是否下降？import errors 是否集中在某类错误？

如果网络栈层正常但导入层异常，优先怀疑：

- 验证瓶颈（CPU/签名验证）
- 状态转换瓶颈（state transition）
- 执行层交互瓶颈（payload 验证/可用性）

如果网络栈层异常但导入层看起来“没数据”，优先怀疑：

- peer 不健康（被惩罚/断连/无法完成 status 握手）
- topics 未订阅或订阅不足（未接近 head）

---

## 27.3 用 metrics 辅助定位常见问题

写作建议（可作为 Troubleshooting 的固定模板）：

1. “为什么 gossip 不传播？”
   - 看 `gossipsub_unaccepted_messages_per_client`（Reject/Ignore/Accept 比例）
2. “为什么块导入很慢？”
   - 看 `beacon_processor_*_imported_total` 与 import errors
3. “为什么 peer 频繁断开？”
   - 看 `libp2p_peer_actions_per_client` 与 peer_score 分布

---

## 27.3.1 把指标固化成告警/看板的建议

如果你要把 Lighthouse 的网络与同步指标固化成告警/看板，可以先按“红黄绿”分三组：

- 红（直接影响可用性）：`libp2p_peers`、`libp2p_rpc_errors_*`、`gossipsub_unaccepted_messages_*`
- 黄（性能退化）：导入吞吐下降、验证队列积压（看 `beacon_processor_*` 的速率/延迟类指标）
- 绿（健康度分布）：peer score 分布、client 分布（用于长期观察网络质量）

---

## 27.4 与 Prysm/Teku 的对比

- 三者都有：连接数/RPC/gossip/同步吞吐等核心指标。
- Lighthouse 在 network 与 lighthouse_network 两层各有 metrics，读指标时要区分“网络栈（libp2p）”与“处理器/导入（beacon processor）”。
