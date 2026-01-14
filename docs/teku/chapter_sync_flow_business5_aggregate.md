# 附录：业务 5 – Aggregate & Proof 聚合投票

本页展示 Teku 中 Aggregate Attestation 的完整流程，包括聚合器选举、聚合过程和广播。

---

## 业务 5：Aggregate & Proof 聚合投票

### 主流程

![业务 5：Aggregate 主线](../../img/teku/business5_aggregate_flow.png)

**关键步骤**：
1. Aggregator 选举
2. 收集相同 AttestationData 的 attestations
3. 聚合 aggregation bits 和签名
4. 创建 AggregateAndProof
5. 广播到 beacon_aggregate_and_proof 主题

**Teku 特点**：
```java
public class AggregateAttestationService {
  public SafeFuture<Optional<SignedAggregateAndProof>> produceAggregate(
      UInt64 slot,
      Bytes32 attestationDataRoot) {
    
    return attestationAggregator.createAggregate(slot, attestationDataRoot)
      .thenCompose(aggregateOpt -> {
        if (aggregateOpt.isEmpty()) {
          return SafeFuture.completedFuture(Optional.empty());
        }
        
        Attestation aggregate = aggregateOpt.get();
        
        // 创建 AggregateAndProof
        AggregateAndProof aggregateAndProof = new AggregateAndProof(
          aggregatorIndex,
          aggregate,
          selectionProof
        );
        
        // 签名
        return signatureService.sign(aggregateAndProof)
          .thenApply(signature -> 
            Optional.of(new SignedAggregateAndProof(
              aggregateAndProof, signature
            ))
          );
      });
  }
}
```

---

**最后更新**: 2026-01-14
