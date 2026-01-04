# GitHub Pages 部署指南

本文档说明如何将文档部署到 GitHub Pages。

## 🚀 快速部署

### 方法1: 自动部署（推荐）

#### 1. 推送到 GitHub

```bash
# 初始化仓库（如果还没有）
git init
git add .
git commit -m "Initial commit: Beacon Node sync documentation"

# 添加远程仓库
git remote add origin https://github.com/YOUR_USERNAME/beaconsync.git

# 推送到主分支
git push -u origin main
```

#### 2. 启用 GitHub Pages

1. 访问仓库设置: `Settings` → `Pages`
2. 在 "Source" 下选择:
   - Branch: `main`
   - Folder: `/ (root)`
3. 点击 `Save`

#### 3. 等待部署

- GitHub Actions 会自动构建和部署
- 通常需要 1-2 分钟
- 访问: `https://YOUR_USERNAME.github.io/beaconsync/`

### 方法2: 使用 GitHub Actions

创建 `.github/workflows/deploy.yml`:

```yaml
name: Deploy to GitHub Pages

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: "pages"
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        
      - name: Setup Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.1'
          bundler-cache: true
          cache-version: 0
          
      - name: Setup Pages
        id: pages
        uses: actions/configure-pages@v4
        
      - name: Build with Jekyll
        run: bundle exec jekyll build --baseurl "${{ steps.pages.outputs.base_path }}"
        env:
          JEKYLL_ENV: production
          
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3

  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

## 📝 配置说明

### _config.yml

关键配置项:

```yaml
# 基础URL（GitHub Pages自动设置）
baseurl: "/beaconsync"  # 仓库名

# 网站URL
url: "https://YOUR_USERNAME.github.io"

# 主题
theme: jekyll-theme-cayman

# 必需的插件
plugins:
  - jekyll-feed
  - jekyll-seo-tag
  - jekyll-sitemap
  - jekyll-relative-links
```

### Gemfile (可选)

如果需要本地测试，创建 `Gemfile`:

```ruby
source "https://rubygems.org"

gem "github-pages", group: :jekyll_plugins
gem "jekyll-include-cache", group: :jekyll_plugins

group :jekyll_plugins do
  gem "jekyll-feed"
  gem "jekyll-seo-tag"
  gem "jekyll-sitemap"
  gem "jekyll-relative-links"
end
```

## 🖥️ 本地预览

### 安装依赖

```bash
# 安装 Ruby（如果没有）
# macOS
brew install ruby

# Ubuntu
sudo apt install ruby-full

# 安装 Jekyll 和 Bundler
gem install jekyll bundler

# 安装项目依赖
bundle install
```

### 启动本地服务器

```bash
# 启动 Jekyll 服务器
bundle exec jekyll serve

# 或者使用实时重载
bundle exec jekyll serve --livereload

# 访问 http://localhost:4000/beaconsync/
```

### 构建静态文件

```bash
# 构建到 _site 目录
bundle exec jekyll build

# 测试构建的站点
cd _site
python3 -m http.server 8000
```

## 🎨 主题自定义

### 使用自定义主题

1. 选择主题（例如 minimal-mistakes）:

```yaml
# _config.yml
remote_theme: mmistakes/minimal-mistakes
```

2. 创建自定义布局:

```html
<!-- _layouts/default.html -->
<!DOCTYPE html>
<html lang="{{ site.lang | default: 'zh-CN' }}">
<head>
  <meta charset="UTF-8">
  <title>{{ page.title }} - {{ site.title }}</title>
  <link rel="stylesheet" href="{{ '/assets/css/style.css' | relative_url }}">
</head>
<body>
  <header>
    <h1>{{ site.title }}</h1>
  </header>
  
  <main>
    {{ content }}
  </main>
  
  <footer>
    <p>&copy; 2026 {{ site.author }}</p>
  </footer>
</body>
</html>
```

### 自定义样式

创建 `assets/css/style.scss`:

```scss
---
---

@import "{{ site.theme }}";

// 自定义样式
body {
  font-family: "PingFang SC", "Microsoft YaHei", sans-serif;
}

code {
  background-color: #f4f4f4;
  padding: 2px 4px;
  border-radius: 3px;
}

// 中文优化
h1, h2, h3, h4, h5, h6 {
  font-weight: 600;
  margin-top: 1.5em;
  margin-bottom: 0.5em;
}
```

## 🔧 故障排查

### 常见问题

#### 1. 404 错误

**问题**: 访问 GitHub Pages 显示 404

**解决**:
```yaml
# 检查 _config.yml 中的 baseurl
baseurl: "/beaconsync"  # 必须与仓库名一致
```

#### 2. 相对链接失效

**问题**: 页面间链接无法跳转

**解决**:
```yaml
# _config.yml
plugins:
  - jekyll-relative-links

relative_links:
  enabled: true
  collections: true
```

#### 3. 构建失败

**问题**: GitHub Actions 构建失败

**解决**:
```bash
# 本地测试构建
bundle exec jekyll build --verbose

# 检查错误日志
cat _site/jekyll-build.log
```

#### 4. 样式不显示

**问题**: GitHub Pages 样式丢失

**解决**:
```html
<!-- 使用 relative_url filter -->
<link rel="stylesheet" href="{{ '/assets/css/style.css' | relative_url }}">
```

### 调试技巧

#### 启用详细日志

```bash
bundle exec jekyll serve --verbose --trace
```

#### 检查构建输出

```bash
# 查看生成的 HTML
cat _site/index.html

# 检查文件结构
tree _site
```

## 📊 SEO 优化

### 添加元数据

```yaml
# _config.yml
title: "Beacon Node 同步模块详解"
description: "深入解析以太坊Beacon节点同步机制"
author: "luxq"
lang: zh-CN

# 社交媒体
twitter:
  username: your_twitter
  card: summary_large_image

# Open Graph
og_image: /assets/images/og-image.png
```

### 添加 Sitemap

```yaml
# _config.yml
plugins:
  - jekyll-sitemap

# sitemap 会自动生成在 _site/sitemap.xml
```

### robots.txt

创建 `robots.txt`:

```
User-agent: *
Disallow:

Sitemap: https://YOUR_USERNAME.github.io/beaconsync/sitemap.xml
```

## 📱 响应式设计

确保在移动设备上正常显示:

```html
<!-- _layouts/default.html -->
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <!-- ... -->
</head>
```

## 🔗 自定义域名（可选）

### 设置步骤

1. 创建 `CNAME` 文件:
```
docs.your-domain.com
```

2. 配置 DNS:
```
Type: CNAME
Name: docs
Value: YOUR_USERNAME.github.io
```

3. 在 GitHub 设置中启用自定义域名

## 📈 监控访问

### Google Analytics

```yaml
# _config.yml
google_analytics: UA-XXXXXXXXX-X
```

### GitHub Insights

访问: `Insights` → `Traffic` 查看访问统计

## ✅ 部署检查清单

部署前确认:

- [ ] 所有 Markdown 文件格式正确
- [ ] 链接都可以正常访问
- [ ] 图片路径正确
- [ ] _config.yml 配置正确
- [ ] .gitignore 包含必要的忽略项
- [ ] 本地测试通过
- [ ] Git 提交信息清晰
- [ ] README.md 内容完整

---

## 🎉 部署成功！

部署成功后，你的文档将在以下地址可访问:

```
https://YOUR_USERNAME.github.io/beaconsync/
```

享受你的在线文档吧！
