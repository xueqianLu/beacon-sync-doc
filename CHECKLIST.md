# GitHub 发布清单

在将文档发布到 GitHub 并启用 GitHub Pages 之前，请按照此清单检查。

## 文件检查

### 必需文件

- [x] `README.md` - 项目主页
- [x] `LICENSE` - MIT 许可证
- [x] `_config.yml` - Jekyll 配置
- [x] `.gitignore` - Git 忽略文件
- [x] `index.md` - GitHub Pages 首页
- [x] `Gemfile` - Ruby 依赖
- [x] `.github/workflows/pages.yml` - GitHub Actions

### 文档文件

- [x] `CONTRIBUTING.md` - 贡献指南
- [x] `DEPLOY.md` - 部署说明
- [x] `PROGRESS.md` - 进度报告
- [x] `COMPLETION_SUMMARY.md` - 完成总结
- [x] `CONTRIBUTORS.md` - 贡献者名单

### 内容文件

- [x] 13 个已完成章节的 Markdown 文件
- [x] `beacon_sync_outline.md` - 完整大纲
- [x] `code_references.md` - 代码参考

## 配置检查

### \_config.yml

- [ ] 修改 `title` 为你的标题
- [ ] 修改 `description` 为你的描述
- [ ] 修改 `author` 为你的名字
- [ ] 修改 `email` 为你的邮箱
- [ ] 修改 `repository` 为你的仓库名（格式：username/repo）

### README.md

- [ ] 将所有 `xueqianLu` 替换为你的 GitHub 用户名
- [ ] 将所有 `beacon-sync-doc` 替换为你的仓库名
- [ ] 修改邮箱地址
- [ ] 检查所有链接是否正确

### index.md

- [ ] 同样修改用户名和仓库名
- [ ] 修改邮箱地址
- [ ] 检查所有链接

### CONTRIBUTING.md

- [ ] 修改邮箱地址
- [ ] 修改仓库链接

## 内容检查

### 格式检查

- [ ] 所有 Markdown 文件格式正确
- [ ] 代码块有正确的语言标识符
- [ ] 图表 ASCII 格式正确显示
- [ ] 中英文排版规范

### 链接检查

- [ ] 章节间链接正确
- [ ] 外部链接有效
- [ ] 相对路径正确
- [ ] 锚点链接正常

### 内容检查

- [ ] 没有敏感信息（密钥、密码等）
- [ ] 代码示例正确
- [ ] 技术内容准确
- [ ] 没有错别字

## Git 检查

### Git 配置

```bash
# 检查当前配置
git config user.name
git config user.email

# 如需修改
git config user.name "Your Name"
git config user.email "your-email@example.com"
```

### 初始化仓库

```bash
# 如果还没有初始化
cd /path/to/beacon-sync-doc
git init

# 添加所有文件
git add .

# 检查状态
git status

# 提交
git commit -m "Initial commit: Beacon Node sync documentation"
```

### 检查.gitignore

- [ ] 排除了 `_site/` 目录
- [ ] 排除了 `.jekyll-cache/`
- [ ] 排除了 `.DS_Store`
- [ ] 排除了编辑器文件

## GitHub 设置

### 创建仓库

1. 登录 GitHub
2. 点击右上角 `+` → `New repository`
3. 填写信息：
   - Repository name: `beacon-sync-doc`（或你的名字）
   - Description: "深入解析以太坊 Beacon 节点同步机制"
   - Public 或 Private
   - **不要**选择 "Initialize with README"（我们已有）
4. 点击 `Create repository`

### 推送代码

```bash
# 添加远程仓库
git remote add origin https://github.com/YOUR_USERNAME/beacon-sync-doc.git

# 推送到main分支
git branch -M main
git push -u origin main
```

### 启用 GitHub Pages

1. 进入仓库设置
   - 点击 `Settings`
2. 找到 `Pages` 设置
   - 左侧菜单选择 `Pages`
3. 配置 Source
   - Source: `GitHub Actions`
4. 等待构建

   - GitHub Actions 会自动运行
   - 查看 `Actions` 标签页监控进度
   - 通常需要 1-2 分钟

5. 访问网站
   - URL: `https://YOUR_USERNAME.github.io/beacon-sync-doc/`
   - 在 Pages 设置页面会显示部署状态和 URL

## 本地测试

### 安装 Jekyll

```bash
# macOS
brew install ruby
gem install bundler jekyll

# Ubuntu
sudo apt install ruby-full build-essential
gem install bundler jekyll
```

### 测试运行

```bash
cd beacon-sync-doc
bundle install
bundle exec jekyll serve --livereload

# 访问 http://localhost:4000/beacon-sync-doc/
```

### 测试内容

- [ ] 首页正常显示
- [ ] 导航链接正常
- [ ] 章节页面正常
- [ ] 代码高亮正常
- [ ] 样式显示正确
- [ ] 移动端显示正常

## 部署后检查

### 网站访问

- [ ] 首页加载正常
- [ ] 所有链接可点击
- [ ] 图片/图表显示
- [ ] 代码块格式正确
- [ ] 在不同浏览器测试
- [ ] 在移动设备测试

### SEO 检查

- [ ] 页面标题正确
- [ ] Meta 描述完整
- [ ] Sitemap 生成（/sitemap.xml）
- [ ] robots.txt 存在

### 性能检查

- [ ] 页面加载速度
- [ ] 图片优化
- [ ] 文件大小合理

## 后续优化

### 可选配置

#### 自定义域名

1. 创建 `CNAME` 文件
2. 配置 DNS
3. 在 GitHub 设置中启用

#### Google Analytics

```yaml
# _config.yml
google_analytics: UA-XXXXXXXXX-X
```

#### 社交分享

添加 Open Graph 标签和 Twitter Cards

#### 搜索功能

集成 Algolia 或其他搜索服务

### 维护计划

- [ ] 定期更新内容
- [ ] 修复问题
- [ ] 回复 Issues
- [ ] 合并 PR
- [ ] 更新依赖

## 常见问题

### Q: 404 错误

**A**: 检查 `_config.yml` 中的 `baseurl` 是否与仓库名一致

### Q: 样式丢失

**A**: 确保使用 `relative_url` filter：

```liquid
{{ '/assets/css/style.css' | relative_url }}
```

### Q: 构建失败

**A**: 查看 Actions 日志，通常是 Jekyll 版本或插件问题

### Q: 链接失效

**A**: 使用相对路径，启用 `jekyll-relative-links` 插件

## 完成检查

当所有检查项通过后，即可发布到 GitHub Pages。

## 支持资源

- 查看 [DEPLOY.md](./DEPLOY.md) 详细说明
- GitHub Pages 文档: https://docs.github.com/pages
- Jekyll 文档: https://jekyllrb.com/docs/

---
