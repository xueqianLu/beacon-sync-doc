# 第 8 章: Status 协议

> 目标：说明 Nimbus 的 status 握手与一致性检查逻辑，以及 v1/v2 的分歧点。

## 关键实现

- Status 消息结构（v1/v2）与本地 status 生成：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_protocol.nim
- Status 校验（fork digest / finalized / head / wall clock）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_protocol.nim

### 1) Status 消息结构（v1 / v2）

来源：`beacon_chain/networking/peer_protocol.nim`

```nim
type
  StatusMsg* = object
    forkDigest*: ForkDigest
    finalizedRoot*: Eth2Digest
    finalizedEpoch*: Epoch
    headRoot*: Eth2Digest
    headSlot*: Slot

  # https://github.com/ethereum/consensus-specs/blob/v1.6.0-alpha.2/specs/fulu/p2p-interface.md#status-v2
  StatusMsgV2* = object
    forkDigest*: ForkDigest
    finalizedRoot*: Eth2Digest
    finalizedEpoch*: Epoch
    headRoot*: Eth2Digest
    headSlot*: Slot
    earliestAvailableSlot*: Slot
```

### 2) 本地 status 生成（getCurrentStatusV1 / getCurrentStatusV2）

来源：`beacon_chain/networking/peer_protocol.nim`

```nim
proc getCurrentStatusV1(state: PeerSyncNetworkState): StatusMsg =
  let
    dag = state.dag
    wallEpoch = state.getWallEpoch

  if dag != nil:
    StatusMsg(
      forkDigest: state.forkDigestAtEpoch(wallEpoch),
      finalizedRoot:
        (if dag.finalizedHead.slot.epoch != GENESIS_EPOCH:
           dag.finalizedHead.blck.root
         else:
           ZERO_HASH),
      finalizedEpoch: dag.finalizedHead.slot.epoch,
      headRoot: dag.head.root,
      headSlot: dag.head.slot)
  else:
    StatusMsg(
      forkDigest: state.forkDigestAtEpoch(wallEpoch),
      finalizedRoot: ZERO_HASH,
      finalizedEpoch: GENESIS_EPOCH,
      headRoot: state.genesisBlockRoot,
      headSlot: GENESIS_SLOT)

proc getCurrentStatusV2(state: PeerSyncNetworkState): StatusMsgV2 =
  let
    dag = state.dag
    wallEpoch = state.getWallEpoch

  if dag != nil:
    StatusMsgV2(
      forkDigest: state.forkDigestAtEpoch(wallEpoch),
      finalizedRoot:
        (if dag.finalizedHead.slot.epoch != GENESIS_EPOCH:
           dag.finalizedHead.blck.root
         else:
           ZERO_HASH),
      finalizedEpoch: dag.finalizedHead.slot.epoch,
      headRoot: dag.head.root,
      headSlot: dag.head.slot,
      earliestAvailableSlot: dag.earliestAvailableSlot())
  else:
    StatusMsgV2(
      forkDigest: state.forkDigestAtEpoch(wallEpoch),
      finalizedRoot: ZERO_HASH,
      finalizedEpoch: GENESIS_EPOCH,
      headRoot: state.genesisBlockRoot,
      headSlot: GENESIS_SLOT,
      earliestAvailableSlot: GENESIS_SLOT)
```

### 3) Status 一致性检查（checkStatusMsg）

该检查负责将“明显不可能/不兼容”的 peer 识别为 irrelevant，并触发断连（见后续 `handleStatusV1/handleStatusV2`）。

来源：`beacon_chain/networking/peer_protocol.nim`

```nim
proc checkStatusMsg(state: PeerSyncNetworkState, status: StatusMsg | StatusMsgV2):
    Result[void, cstring] =
  let
    dag = state.dag
    wallSlot = (
      state.getBeaconTime() + MAXIMUM_GOSSIP_CLOCK_DISPARITY
    ).slotOrZero(state.cfg.timeParams)

  if status.finalizedEpoch > status.headSlot.epoch:
    return err("finalized epoch newer than head")

  if status.headSlot > wallSlot:
    return err("head more recent than wall clock")

  if state.forkDigestAtEpoch(wallSlot.epoch) != status.forkDigest:
    return err("fork digests differ")

  if dag != nil:
    if status.finalizedEpoch <= dag.finalizedHead.slot.epoch:
      let blockId = dag.getBlockIdAtSlot(status.finalizedEpoch.start_slot())
      if blockId.isSome and
          (not status.finalizedRoot.isZero) and
          status.finalizedRoot != blockId.get().bid.root:
        return err("peer following different finality")
  else:
    if status.finalizedEpoch == GENESIS_EPOCH:
      if not (status.finalizedRoot in [state.genesisBlockRoot, ZERO_HASH]):
        return err("peer following different finality")
  ok()
```

### 4) 握手流程：连接后主动发起 status（onPeerConnected）

Nimbus 在连接建立后主动发起一次 status req/resp（并基于 `FULU_FORK_EPOCH` 选择 v1/v2），如果对方没有在 `RESP_TIMEOUT_DUR` 内响应，会以 `FaultOrError` 断连。

来源：`beacon_chain/networking/peer_protocol.nim`

```nim
onPeerConnected do (peer: Peer, incoming: bool) {.async: (raises: [CancelledError]).}:
  debug "Peer connected", peer, peerId = shortLog(peer.peerId), incoming

  let wallEpoch = peer.networkState.getWallEpoch
  if wallEpoch >= peer.networkState.cfg.FULU_FORK_EPOCH:
    let
      ourStatus = peer.networkState.getCurrentStatusV2()
      theirStatus = await peer.statusV2(ourStatus, timeout = RESP_TIMEOUT_DUR)
    if theirStatus.isOk:
      discard await peer.handleStatusV2(peer.networkState, theirStatus.get())
      peer.updateAgent()
    else:
      peer.state(PeerSync).setStatusV2Msg(Opt.none(StatusMsgV2))
      debug "Status response not received in time", peer, errorKind = theirStatus.error.kind
      await peer.disconnect(FaultOrError)
  else:
    let
      ourStatus = peer.networkState.getCurrentStatusV1()
      theirStatus = await peer.statusV1(ourStatus, timeout = RESP_TIMEOUT_DUR)
    if theirStatus.isOk:
      discard await peer.handleStatusV1(peer.networkState, theirStatus.get())
      peer.updateAgent()
    else:
      debug "Status response not received in time", peer, errorKind = theirStatus.error.kind
      await peer.disconnect(FaultOrError)
```

### 5) 处理对方 status：通过校验则进入 PeerPool，否则断连

来源：`beacon_chain/networking/peer_protocol.nim`

```nim
proc handleStatusV1(peer: Peer, state: PeerSyncNetworkState, theirStatus: StatusMsg):
    Future[bool] {.async: (raises: [CancelledError]).} =
  let res = checkStatusMsg(state, theirStatus)

  return if res.isErr():
    debug "Irrelevant peer", peer, theirStatus, err = res.error()
    await peer.disconnect(IrrelevantNetwork)
    false
  else:
    peer.setStatusMsg(theirStatus)

    if peer.connectionState == Connecting:
      await peer.handlePeer()
    true

proc handleStatusV2(peer: Peer, state: PeerSyncNetworkState, theirStatus: StatusMsgV2):
    Future[bool] {.async: (raises: [CancelledError]).} =
  let res = checkStatusMsg(state, theirStatus)

  return if res.isErr():
    debug "Irrelevant peer", peer, theirStatus, err = res.error()
    await peer.disconnect(IrrelevantNetwork)
    false
  else:
    peer.setStatusV2Msg(Opt.some(theirStatus))

    if peer.connectionState == Connecting:
      await peer.handlePeer()
    true
```

### 6) 主动刷新 status（updateStatus）与读取辅助方法

来源：`beacon_chain/networking/peer_protocol.nim`

```nim
proc updateStatus*(peer: Peer): Future[bool] {.async: (raises: [CancelledError]).} =
  let nstate = peer.networkState(PeerSync)
  if nstate.getWallEpoch >= nstate.cfg.FULU_FORK_EPOCH:
    let
      ourStatus = getCurrentStatusV2(nstate)
      theirStatus = (await peer.statusV2(ourStatus, timeout = RESP_TIMEOUT_DUR))
    if theirStatus.isOk():
      await peer.handleStatusV2(nstate, theirStatus.get())
    else:
      peer.setStatusV2Msg(Opt.none(StatusMsgV2))
      return false
  else:
    let
      ourStatus = getCurrentStatusV1(nstate)
      theirStatus = (await peer.statusV1(ourStatus, timeout = RESP_TIMEOUT_DUR)).valueOr:
        return false
    await peer.handleStatusV1(nstate, theirStatus)

proc getHeadSlot*(peer: Peer): Slot =
  let pstate = peer.state(PeerSync)
  if pstate.statusMsgV2.isSome():
    pstate.statusMsgV2.get.headSlot
  else:
    pstate.statusMsg.headSlot
```

## 与同步的关联

- 同步侧会依赖 peer 的 status 新鲜度与分数（PeerScore）进行选择与驱逐：
  - Peer 分数常量：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_scores.nim

> 实践含义：Status 在 Nimbus 中不仅是“协议层握手”，还直接决定 peer 是否进入 PeerPool，以及后续请求（Range/Root、Gossip）的候选集合与驱逐策略。
