# 第19章 Checkpoint Sync与Backfill

## 19.1 Checkpoint Sync原理

### 19.1.1 弱主观性检查点

从受信任的近期finalized checkpoint启动，无需同步全部历史：

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

### 19.1.2 获取Checkpoint State

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

## 19.2 Backfill同步

### 19.2.1 Backfill概念

Checkpoint sync后，历史数据缺失，需要向后回填：

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

### 19.2.2 Backfill实现

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

**下一章**: 第20章 Optimistic Sync详解
