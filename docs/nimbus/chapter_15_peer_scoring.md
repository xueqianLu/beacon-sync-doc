# 第 15 章: Peer Scoring

> 目标：总结 Nimbus 的 peer 分数模型（上限/下限/常见扣分项）以及它如何影响 peer pool 与断连策略。

## 关键代码定位

- 分数常量：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_scores.nim
- PeerPool（按 score/throughput 排序、acquire/release）：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/peer_pool.nim
- score 低于阈值触发断连：https://github.com/status-im/nimbus-eth2/blob/v25.12.0/beacon_chain/networking/eth2_network.nim

## 分数常量（v25.12.0）

来源：`beacon_chain/networking/peer_scores.nim`

```nim
const
	NewPeerScore* = 300
		## Score which will be assigned to newly connected peer
	PeerScoreLowLimit* = 0
		## Score after which peer will be kicked
	PeerScoreHighLimit* = 1000
		## Max value of peer's score

	PeerScorePoorRequest* = -50
		## This peer is not responding on time or behaving improperly otherwise
	PeerScoreInvalidRequest* = -500
		## This peer is sending malformed or nonsensical data

	PeerScoreNoStatus* = -100
		## Peer did not answer `status` request.
	PeerScoreStaleStatus* = -50
		## Peer's `status` answer did not progress in time.
	PeerScoreUseless* = -10
		## Peer's latest head is lower then ours.
	PeerScoreGoodStatus* = 50
		## Peer's `status` answer is fine.

	PeerScoreBadResponse* = -1000
		## Peer's response is not in requested range.
	PeerScoreUnviableFork* = -200
		## Peer responded with data from an unviable fork - are they on a different chain?
```

## 分数更新与上限夹紧（cap）

来源：`beacon_chain/networking/eth2_network.nim`

```nim
func updateScore*(peer: Peer, score: int) {.inline.} =
	## Update peer's ``peer`` score with value ``score``.
	peer.score = peer.score + score
	if peer.score > PeerScoreHighLimit:
		peer.score = PeerScoreHighLimit
```

## 低分断连（releasePeer）

Nimbus 在释放 peer 回到池子时，会检查当前分数是否低于 `PeerScoreLowLimit`，如低于则异步断连。

来源：`beacon_chain/networking/eth2_network.nim`

```nim
proc releasePeer(peer: Peer) =
	## Checks for peer's score and disconnects peer if score is less than
	## `PeerScoreLowLimit`.
	if peer.connectionState notin {ConnectionState.Disconnecting, ConnectionState.Disconnected}:
		if peer.score < PeerScoreLowLimit:
			debug "Peer was disconnected due to low score", peer = peer,
						peer_score = peer.score,
						score_low_limit = PeerScoreLowLimit,
						score_high_limit = PeerScoreHighLimit
			asyncSpawn(peer.disconnect(PeerScoreLow))
```

> 这也解释了为什么第 18 章里 `getOrUpdatePeerStatus` / `syncStep` 会频繁调用 `peer.updateScore(...)`：分数不仅是统计指标，还是“是否继续占用连接资源”的硬门槛。
