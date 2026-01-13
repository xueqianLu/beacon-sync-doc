# 附录：业务 5 – Aggregate & Proof 聚合投票

本页展示 Aggregate & Proof 从单票、聚合者选举、本地聚合与构造 SignedAggregateAndProof，到在 `beacon_aggregate_and_proof` 主题上传播并被其他节点验证的完整流程。

---

## 业务 5：Aggregate & Proof 聚合投票

### 主流程

![业务 5：Aggregate & Proof 主线](img/business5_aggregate_overall.png)

子流程跳转：

- [聚合者职责与选举](#b5-aggregate-duties)
- [本地聚合与构造 AggregateAndProof](#b5-aggregate-build-message)
- [Aggregate & Proof 广播](#b5-aggregate-broadcast)
- [Aggregate & Proof 接收与验证](#b5-aggregate-receive-validate)

### B5 Aggregate Duties & Selection（聚合者职责与选举） {#b5-aggregate-duties}

![B5 Aggregate Duties and Selection](img/business5_agg_selection.png)

### B5 Aggregate Build Message（本地聚合与构造消息） {#b5-aggregate-build-message}

![B5 Aggregate Build Message](img/business5_agg_build.png)

### B5 Aggregate Broadcast（广播） {#b5-aggregate-broadcast}

![B5 Aggregate Broadcast](img/business5_agg_broadcast.png)

### B5 Aggregate Receive & Validate（接收与验证） {#b5-aggregate-receive-validate}

![B5 Aggregate Receive and Validate](img/business5_agg_receive_validate.png)
