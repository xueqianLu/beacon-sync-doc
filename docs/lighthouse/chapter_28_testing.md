# 第 28 章: Lighthouse Testing v8.0.1

本章以“如何在 Lighthouse 源码里找到与同步相关的测试”为主，帮助读者把文档与可运行的测试证据链对齐。

---

## 28.0 附录导航（流程图）

- 同步流程图索引（business1-7）：[chapter_sync_flow_diagrams.md](chapter_sync_flow_diagrams.md)

---

## 28.0.1 建议的验证路径（从文档到测试）

如果你希望把本仓库的章节内容与 Lighthouse 的测试做“证据链对齐”，推荐这样走：

1. **先选一个主题**（例如 range sync、block lookup、gossip validation）
2. **在本仓库章节中定位到代码入口链接**（v8.0.1 的 GitHub blob）
3. **沿着模块目录找 tests**（优先找同目录或相邻目录的 `tests/`、`tests.rs`）
4. **用测试名/断言理解边界条件**（例如重试次数、超时、事件安全）

## 28.1 network/sync 的单元测试

sync 模块自带测试目录：

- `beacon_node/network/src/sync/tests/`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/sync/tests

（在 GitHub 上浏览目录即可看到覆盖：range sync、block lookup、network_context 请求状态等。）

写作建议：当你要验证第 17-23 章的结论（initial sync、full sync、missing parent、regular sync），这组 tests 通常是最直接的入口。

---

## 28.2 NetworkBeaconProcessor 测试

`NetworkBeaconProcessor` 的测试在：

- `beacon_node/network/src/network_beacon_processor/tests.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/network/src/network_beacon_processor/tests.rs

这类测试通常验证：

- gossip/rpc 导入路径是否正确上报 ValidationResult
- duplicate cache/处理队列的行为边界

写作建议：当你要验证第 11-16 章（gossipsub、validation、scoring、性能优化）在 Beacon Node 侧的“闭环行为”，processor tests 往往能给出最贴近真实运行路径的断言。

---

## 28.3 Checkpoint / Weak Subjectivity 相关测试

弱主观性（checkpoint sync）在 beacon_chain tests 里有专门测试：

- `weak_subjectivity_sync_*`（store_tests）
  - https://github.com/sigp/lighthouse/blob/v8.0.1/beacon_node/beacon_chain/tests/store_tests.rs

---

## 28.4 fork_choice crate 测试

fork choice 的测试在：

- `consensus/fork_choice/tests/tests.rs`
  - https://github.com/sigp/lighthouse/blob/v8.0.1/consensus/fork_choice/tests/tests.rs

---

## 28.5 与 Prysm/Teku 的对比

- 三者都会在“同步/导入/分叉选择”这几个关键路径上写大量测试。
- Lighthouse 的结构特点是：network/sync/processor/fork_choice 分别在不同 crate/模块，测试也分布在对应目录里，定位时按模块边界找最快。

---

## 28.6 本仓库章节与测试入口的快速映射（建议）

- 第 11/14 章（gossip decode/validation 闭环）→ processor tests + network 事件路径
- 第 17/18 章（initial/range sync）→ `network/src/sync/tests/` + `range_sync/chain.rs`
- 第 23 章（missing parent / lookup）→ `network/src/sync/tests/` + `block_lookups/*`
- 第 24 章（forkchoice sync）→ `consensus/fork_choice/tests/tests.rs`

这不是一一对应的“唯一答案”，但足够作为快速定位入口。
