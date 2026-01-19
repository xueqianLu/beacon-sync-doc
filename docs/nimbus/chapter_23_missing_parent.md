# 第 23 章: Missing Parent

本章解释 Nimbus（nimbus-eth2 v25.12.0）中“缺父块/缺依赖（Missing Parent）”的完整闭环：

- **检测**：在尝试把块加入 `ChainDAGRef` 前做 parent 查找；找不到就返回 `VerifierError.MissingParent`。
- **隔离**：`BlockProcessor` 把该块记为 orphan，加入 quarantine，并登记其 `parent_root` 为“待拉取”的 missing root。
- **拉取**：`RequestManager` 周期性从 quarantine 的 missing 列表取出 root，走 `BeaconBlocksByRoot` 去网络请求。
- **解锁**：当 parent 块被成功写入 DAG/DB 后，`BlockProcessor.enqueueQuarantine` 会把以该 parent 为依赖的 orphans 重新入队处理。

这套设计把“块到达顺序不拓扑/分叉分支不在内存 DAG 中”这类常见现象，稳定地转化为“隔离 + 拉取 + 重试”的可控流程。

---

## 23.1 MissingParent 的来源：`checkHeadBlock` 找不到 parent

当一个非 backfill 块准备走 `addHeadBlockWithParent` 进入 DAG 时，Nimbus 会先做前置检查 `checkHeadBlock`。其中 parent 查找失败时，会返回 `VerifierError.MissingParent`（“parent unknown or finalized already”）。

来源：`/tmp/nimbus-eth2/beacon_chain/consensus_object_pools/block_clearance.nim`

```nim
proc checkHeadBlock*(
    dag: ChainDAGRef, signedBlock: ForkySignedBeaconBlock):
    Result[BlockRef, VerifierError] =
  ...

  let parent = dag.getBlockRef(blck.parent_root).valueOr:
    let parentId = dag.getBlockId(blck.parent_root)
    if parentId.isSome() and parentId.get.slot < dag.finalizedHead.slot:
      debug "Block unviable due to pre-finalized-checkpoint parent",
        parentId = parentId.get()
      return err(VerifierError.UnviableFork)

    debug "Block parent unknown or finalized already", parentId
    return err(VerifierError.MissingParent)
```

要点：

- `getBlockRef(parent_root)` 失败并不总是“完全没见过 parent”，可能是 parent 已在 DB 里但不在当前内存 DAG 的 `BlockRef` 结构里（例如重启后只导入 canonical branch）。
- Nimbus 这里把无法区分的情况统一归为 `MissingParent`，交给后续的 quarantine/request-manager 闭环处理。

---

## 23.2 Quarantine 数据结构：orphans + missing roots

quarantine 的职责是暂存“目前无法接到 DAG 的块”，并维护一个“应该去网络拉取的 root 列表”（`missing`）。

来源：`/tmp/nimbus-eth2/beacon_chain/consensus_object_pools/block_quarantine.nim`

```nim
type
  Quarantine* = object
    ## ...
    orphans*: OrphanLru
    sidecarless*: SidecarlessLru
    unviable*: UnviableLru

    missing*: Table[Eth2Digest, MissingBlock]
      ## Roots of blocks that we would like to have (either parent_root of
      ## unresolved blocks or block roots of attestations)
```

### 23.2.1 `addOrphan`：把块变成 orphan，并登记 missing parent

当某块缺父时（`VerifierError.MissingParent`），Nimbus 会把它加入 `orphans`，并把 `parent_root` 加入 `missing` 调度列表。

来源：`/tmp/nimbus-eth2/beacon_chain/consensus_object_pools/block_quarantine.nim`

```nim
proc addOrphan*(
    quarantine: var Quarantine,
    finalizedSlot: Slot,
    signedBlock: ForkySignedBeaconBlock
): Result[void, UnviableKind] =
  ## Adds block to quarantine's `orphans` and `missing` lists
  ## assuming the parent isn't unviable
  quarantine.cleanupOrphans(finalizedSlot)

  let parent_root = signedBlock.message.parent_root
  quarantine.unviable.get(parent_root).isErrOr:
    # Inherit unviable kind from parent
    return err(quarantine.addUnviable(signedBlock.root, value))

  ...

  # Even if the quarantine is full, we need to schedule its parent for
  # downloading or we'll never get to the bottom of things
  discard quarantine.addMissing(parent_root)

  for (evicted, key, _) in quarantine.orphans.putWithEvicted(
    (signedBlock.root, signedBlock.signature), ForkedSignedBeaconBlock.init(signedBlock)
  ):
    if evicted:
      quarantine.sidecarless.del key[0]

  ok()
```

### 23.2.2 `addMissing` + `checkMissing`：missing roots 的去重与指数退避

missing roots 并非每次都立即拉取；`checkMissing` 会做一个简单的指数退避（`tries` 的 bit 计数），避免在网络不佳时疯狂重试。

来源：`/tmp/nimbus-eth2/beacon_chain/consensus_object_pools/block_quarantine.nim`

```nim
func checkMissing*(quarantine: var Quarantine, max: int): seq[FetchRecord] =
  ## Return a list of blocks that we should try to resolve from other client
  ## - to be called periodically but not too often (once per slot?)
  ...
  for k, v in quarantine.missing.mpairs:
    v.tries += 1
    if countOnes(v.tries.uint64) == 1:
      result.add(FetchRecord(root: k))
      if result.len >= max:
        break

proc addMissing*(quarantine: var Quarantine, root: Eth2Digest): Result[void, UnviableKind] =
  ## Schedule the download a given block or its ancestor, if we're keeping
  ## track of it as an orphan
  ...
  # It's not really missing if we're keeping it in the quarantine.
  # In that case, add the next missing parent root instead
  ...
```

---

## 23.3 `BlockProcessor`：MissingParent → quarantine，并尝试从 DB 解锁

`BlockProcessor.addBlock/storeBlock` 是“所有不可信来源的块”进入系统的统一入口。对于 `MissingParent`，它会：

1. `quarantine.addOrphan(...)` 把块隔离。
2. **尝试从本地 DB 恢复 non-canonical branch**：调用 `enqueueFromDb(parent_root)`，如果 parent（以及可能的 sidecars）已在 DB 中，就直接入队处理，避免纯网络拉取。

来源：`/tmp/nimbus-eth2/beacon_chain/gossip_processing/block_processor.nim`

```nim
  if res.isOk():
    # Once a block is successfully stored, enqueue the direct descendants
    self.enqueueQuarantine(res[])
    res.mapConvert(void)
  else:
    case res.error()
    of VerifierError.MissingParent:
      quarantine[].addOrphan(dag.finalizedHead.slot, blck).isOkOr:
        debug "Could not add orphan", ...
        return err(error.toVerifierError())

      # This indicates that no `BlockRef` is available for the `parent_root`.
      # However, the block may still be available in local storage.
      self.enqueueFromDb(blck.message.parent_root)

      ...
      debug "Block quarantined", ...
      err(res.error())
```

### 23.3.1 `enqueueFromDb`：用 DB 加速“缺父块”分支的恢复

`enqueueFromDb` 会尝试从数据库加载 `root` 对应块（`dag.getForkedBlock(root)`），并在 sidecars 完整时把它丢回 `enqueueBlock` 走正常验证/落库链路。

来源：`/tmp/nimbus-eth2/beacon_chain/gossip_processing/block_processor.nim`

```nim
proc enqueueFromDb(self: ref BlockProcessor, root: Eth2Digest) =
  let
    dag = self.consensusManager.dag
    blck = dag.getForkedBlock(root).valueOr:
      return

  withBlck(blck):
    var sidecarsOk = true

    let sidecarsOpt =
      when consensusFork >= ConsensusFork.Fulu:
        ...
      elif consensusFork in [ConsensusFork.Deneb, ConsensusFork.Electra]:
        ...
      else:
        noSidecars

    if sidecarsOk:
      debug "Loaded block from storage", root
      self.enqueueBlock(MsgSource.gossip, forkyBlck.asSigned(), sidecarsOpt)
```

---

## 23.4 `RequestManager`：把 missing roots 转成 BlocksByRoot 请求

### 23.4.1 block loop：从 quarantine 取 missing roots 并并行请求

`RequestManager` 有一个轮询 loop（`requestManagerBlockLoop`），定期调用 `quarantine.checkMissing(...)` 取得本轮要尝试拉取的 root 列表，然后用多个 worker 并行执行 `requestBlocksByRoot`。

来源：`/tmp/nimbus-eth2/beacon_chain/sync/request_manager.nim`

```nim
proc requestManagerBlockLoop(
    rman: RequestManager) {.async: (raises: [CancelledError]).} =
  while true:
    # TODO This polling could be replaced with an AsyncEvent that is fired
    #      from the quarantine when there's work to do
    await sleepAsync(POLL_INTERVAL)

    if rman.inhibit():
      continue

    let missingBlockRoots =
      rman.quarantine[].checkMissing(SYNC_MAX_REQUESTED_BLOCKS).mapIt(it.root)
    if missingBlockRoots.len == 0:
      continue

    ...

    for i in 0 ..< PARALLEL_REQUESTS:
      workers[i] = rman.requestBlocksByRoot(blockRoots)

    await allFutures(workers)
```

### 23.4.2 `requestBlocksByRoot`：接收 blocks 并交给 `blockVerifier`

网络请求返回 blocks 后，Nimbus 会对每个 block 调用 `blockVerifier`（最终会走到 `BlockProcessor.addBlock/storeBlock`）。
其中 `VerifierError.MissingParent` 在这里会被显式忽略：因为响应中 blocks 的拓扑顺序未必符合“立即可应用”的顺序。

来源：`/tmp/nimbus-eth2/beacon_chain/sync/request_manager.nim`

```nim
proc requestBlocksByRoot(rman: RequestManager, items: seq[Eth2Digest]) {.async: (raises: [CancelledError]).} =
  ...
  let blocks = (await beaconBlocksByRoot_v2(peer, BlockRootsList items))
  if blocks.isOk:
    let ublocks = blocks.get()
    if checkResponse(items, ublocks.asSeq()):
      for b in ublocks:
        let ver = await rman.blockVerifier(b[], false)
        if ver.isErr():
          case ver.error()
          of VerifierError.MissingParent:
            # Ignoring because the order of the blocks that we requested may be different
            # from the order in which we need these blocks to apply.
            discard
          ...
```

---

## 23.5 解锁与重入队：parent 写入后 `enqueueQuarantine` 处理 orphans

当某个块成功写入 DAG 后（`storeBlock` 返回 `ok(BlockRef)`），`BlockProcessor` 会调用 `enqueueQuarantine(parent)`：

- 从 quarantine 中 `pop(parent.root)` 取出“以 parent 为父”的所有 orphan。
- 处理 sidecar 相关分支：若仍缺 sidecar，则转入 `sidecarless`；否则正常 `enqueueBlock` 重新进入处理队列。

来源：`/tmp/nimbus-eth2/beacon_chain/gossip_processing/block_processor.nim`

```nim
proc enqueueQuarantine(self: ref BlockProcessor, parent: BlockRef) =
  let
    dag = self.consensusManager[].dag
    quarantine = self.consensusManager[].quarantine

  for quarantined in quarantine[].pop(parent.root):
    debug "Block from quarantine", parent, quarantined = shortLog(quarantined.root)
    withBlck(quarantined):
      ...
      when consensusFork in ConsensusFork.Deneb .. ConsensusFork.Fulu:
        if not sidecarsOpt.isSome():
          dag.verifyBlockProposer(...).isOkOr:
            warn "Failed to verify signature of unorphaned blobless block", ...
            continue

          discard quarantine[].addSidecarless(dag.finalizedHead.slot, forkyBlck)
          continue

      self.enqueueBlock(MsgSource.gossip, forkyBlck, sidecarsOpt)
```

---

## 23.6 小结：Missing Parent 的“稳定化”机制

- **产生点**：`checkHeadBlock` 发现 parent 不在 `BlockRef` DAG（未知或已被 finalized 清理）。
- **隔离点**：`BlockProcessor` 把块放入 quarantine（orphans），并登记 `parent_root` 到 missing roots。
- **拉取点**：`RequestManager` 基于 `checkMissing` 的指数退避策略，周期性发起 `BlocksByRoot`。
- **解锁点**：parent 被写入 DAG 后，`enqueueQuarantine` 重新入队后继，最终恢复拓扑顺序。
- **加速点**：`enqueueFromDb` 尝试从 DB 直接恢复 non-canonical branch，减少纯网络依赖。
