# 第 24 章: Forkchoice Sync

本章解释 Nimbus（nimbus-eth2 v25.12.0）里 forkchoice 与“同步/导入流水线”的交互点：forkchoice 选头、head 落地到 DAG、reorg 清理，以及与执行层 `forkchoiceUpdated` 的对齐闭环。
