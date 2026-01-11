# 第 19 章 Checkpoint Sync 与 Backfill

## 19.1 Checkpoint Sync 原理

### 19.0 Checkpoint Sync 主流程图

下图概览展示了 Checkpoint Sync 的完整生命周期：从获取可信检查点 state、初始化本地区块链数据库，到向前同步到最新 Head 并通过 Backfill 回填历史数据。更细节的分步骤流程图可在附录中查看：

- 附录：同步相关流程图总览（业务 4：Checkpoint Sync 与 Backfill）

![业务 4：Checkpoint Sync 主线](img/business4_checkpoint_sync_flow.png)

### 19.1.1 弱主观性检查点

从受信任的近期 finalized checkpoint 启动，无需同步全部历史：

```
传统Full Sync:
Genesis ──> ... ──> Checkpoint ──> ... ──> Head
[=========================================>]
          数天同步时间

Checkpoint Sync:
                     Checkpoint ──> Head
                     [===============>]
                          数小时
```

### 19.1.2 获取 Checkpoint State

```go
// 从API获取checkpoint state
func (s *Service) loadCheckpointState(url string) (state.BeaconState, error) {
    // 1. 获取finalized checkpoint
    checkpoint, err := s.fetchCheckpoint(url)
    if err != nil {
        return nil, err
    }

    // 2. 获取state
    st, err := s.fetchState(url, checkpoint.Root)
    if err != nil {
        return nil, err
    }

    // 3. 验证state root
    stateRoot, err := st.HashTreeRoot(s.ctx)
    if err != nil {
        return nil, err
    }

    if stateRoot != checkpoint.Root {
        return nil, errors.New("state root mismatch")
    }

    return st, nil
}
```

### 19.1.3 启动流程

```go
func (s *Service) startFromCheckpoint() error {
    // 1. 加载checkpoint state
    st, err := s.loadCheckpointState(s.cfg.CheckpointSyncURL)
    if err != nil {
        return err
    }

    // 2. 初始化数据库
    if err := s.initFromState(st); err != nil {
        return err
    }

    // 3. 从checkpoint继续同步到head
    checkpointSlot := st.Slot()
    return s.syncFromSlot(checkpointSlot + 1)
}
```

---

## 19.2 Backfill 同步

### 19.2.1 Backfill 概念

Checkpoint sync 后，历史数据缺失，需要向后回填：

```
Timeline:
Genesis          Checkpoint              Head
  │                  │                    │
  [====历史缺失====][==已同步==][=实时=]
                     ↑
                Checkpoint Start
                     ↓
                [<==Backfill]
```

### 19.2.2 Backfill 实现

```go
// 来自prysm/beacon-chain/sync/backfill/service.go
func (s *Service) backfill() error {
    // 从checkpoint向前回填
    startSlot := s.getCheckpointSlot()

    for currentSlot := startSlot; currentSlot > 0; {
        batchEnd := currentSlot
        batchStart := currentSlot - primitives.Slot(s.batchSize)
        if batchStart < 0 {
            batchStart = 0
        }

        // 请求历史blocks
        blocks, err := s.requestBackfillBatch(batchStart, batchEnd)
        if err != nil {
            return err
        }

        // 保存到数据库
        if err := s.saveBlocks(blocks); err != nil {
            return err
        }

        currentSlot = batchStart
    }

    return nil
}
```

---

## 19.3 配置与使用

```bash
# Prysm checkpoint sync配置
./prysm.sh beacon-chain \
  --checkpoint-sync-url=https://beaconstate.ethstaker.cc \
  --genesis-beacon-api-url=https://beaconstate.ethstaker.cc

# 启用backfill
./prysm.sh beacon-chain \
  --checkpoint-sync-url=https://beaconstate.ethstaker.cc \
  --enable-experimental-backfill
```

**下一章**: 第 20 章 Optimistic Sync 详解
