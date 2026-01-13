# 仓库重构迁移指南

## 变更日期
2026-01-13

## 变更原因
将单一客户端（Prysm）文档仓库重构为**多客户端 Beacon 同步机制文档中心**，以支持 Teku、Lighthouse 等其他客户端的文档。

---

## 目录结构变更

### 旧结构
```
beacon-sync-doc/
├── README.md
├── chapter_01_*.md
├── chapter_02_*.md
├── ...
├── chapter_28_*.md
├── code_references.md
└── beacon_sync_outline.md
```

### 新结构
```
beacon-sync-doc/
├── README.md                      # 多客户端总入口
├── docs/
│   ├── prysm/                     # Prysm 文档（原根目录章节）
│   │   ├── README.md
│   │   ├── chapter_01_*.md
│   │   ├── ...
│   │   ├── code_references.md
│   │   └── outline.md
│   └── teku/                      # Teku 文档（新增）
│       └── README.md
├── comparison/                    # 客户端对比分析（新增）
│   ├── README.md
│   ├── sync_strategies.md
│   └── implementation_diff.md
└── shared/                        # 共享通用内容（新增）
    ├── README.md
    └── glossary.md
```

---

## 文件迁移清单

### 移动到 `docs/prysm/`
- ✅ 所有 `chapter_*.md` 文件（41 个）
- ✅ `code_references.md`
- ✅ `beacon_sync_outline.md` → `outline.md`
- ✅ `Prysm_Beacon.md`
- ✅ `beacon_node_sync_documentation.md`

### 新建文件
- ✅ `docs/prysm/README.md` - Prysm 文档入口
- ✅ `docs/teku/README.md` - Teku 文档入口
- ✅ `comparison/README.md` - 对比分析入口
- ✅ `comparison/sync_strategies.md` - 同步策略对比
- ✅ `comparison/implementation_diff.md` - 实现差异
- ✅ `shared/README.md` - 共享资源入口
- ✅ `shared/glossary.md` - 统一术语表

### 更新文件
- ✅ `README.md` - 改为多客户端总入口
- ✅ `index.md` - 更新 GitHub Pages 首页
- ✅ `_config.yml` - 更新导航和配置

---

## 链接更新指南

### 对于 Prysm 文档内部链接

**旧链接**:
```markdown
[第 1 章](./chapter_01_pos_overview.md)
[代码参考](./code_references.md)
```

**新链接**（仍然有效，因为都在同一目录）:
```markdown
[第 1 章](./chapter_01_pos_overview.md)
[代码参考](./code_references.md)
```

### 从根目录指向 Prysm 文档

**新链接**:
```markdown
[Prysm 文档](./docs/prysm/README.md)
[Prysm 第 1 章](./docs/prysm/chapter_01_pos_overview.md)
```

### 跨客户端引用

```markdown
[与 Teku 对比](../../comparison/sync_strategies.md)
[返回总览](../../README.md)
```

---

## GitHub Pages 更新

### 配置变更
- `_config.yml` 标题更新为"多客户端实现"
- 导航菜单新增：Prysm、Teku、客户端对比、共享资源
- 排除文件列表更新

### URL 映射

| 旧 URL | 新 URL |
|--------|--------|
| `/chapter_01_pos_overview.html` | `/docs/prysm/chapter_01_pos_overview.html` |
| `/code_references.html` | `/docs/prysm/code_references.html` |
| `/beacon_sync_outline.html` | `/docs/prysm/outline.html` |

**注意**: 需要配置重定向或保持旧链接兼容性。

---

## 兼容性处理

### 方案 1: GitHub Pages 重定向（推荐）
在根目录保留旧文件作为重定向页面：

```markdown
---
redirect_to: /docs/prysm/chapter_01_pos_overview.html
---
```

### 方案 2: 符号链接（本地开发）
```bash
ln -s docs/prysm/chapter_01_pos_overview.md chapter_01_pos_overview.md
```

### 方案 3: 更新所有外部链接
通知用户更新书签和外部引用。

---

## Git 历史处理

### 保持历史记录
```bash
git mv chapter_01_*.md docs/prysm/
# Git 会自动追踪文件移动历史
```

### 验证历史
```bash
git log --follow docs/prysm/chapter_01_pos_overview.md
```

---

## 后续步骤

### Phase 2: Teku 文档编写
1. 研究 Teku 代码库结构
2. 提取关键实现路径
3. 按 Prysm 章节结构编写对应内容
4. 完成 `docs/teku/code_references.md`

### Phase 3: 对比分析完善
1. 扩展 `comparison/` 目录内容
2. 添加性能基准测试数据
3. 创建架构对比图表
4. 编写协议实现对比

### Phase 4: 其他客户端
1. Lighthouse (Rust)
2. Nimbus (Nim)
3. Lodestar (TypeScript)

---

## 验证清单

- ✅ 目录结构创建完成
- ✅ Prysm 文档迁移完成（41 个文件）
- ✅ Teku 框架搭建完成
- ✅ 对比分析文件创建（3 个）
- ✅ 共享资源创建（2 个）
- ✅ README.md 更新完成
- ✅ index.md 更新完成
- ✅ _config.yml 更新完成
- ⏳ Jekyll 本地预览测试（待执行）
- ⏳ GitHub Pages 部署测试（待执行）
- ⏳ 所有内部链接验证（待执行）

---

## 回滚方案

如果需要回滚到单一客户端结构：

```bash
# 恢复 Prysm 文档到根目录
git checkout <commit-before-migration>
```

或手动移动：
```bash
mv docs/prysm/* .
rm -rf docs/ comparison/ shared/
```

---

**变更负责人**: AI Assistant  
**审核人**: luxq  
**完成日期**: 2026-01-13
