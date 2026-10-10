# 闲鱼一键发帖 v1.0.0

本地填表 → 一键发布到闲鱼网页版。附带 **AI 文案生成**（本地模板，离线可用，针对墙面翻新/刷漆接单优化）。

## 功能
- 📝 发帖表单：标题 / 价格 / 新旧程度 / 描述 / 图片（相册多选，最多9张）
- ✨ AI 文案：输入服务类型、价格、服务区域、联系方式 → 本地模板生成标题+描述 → 可编辑 → 一键填入表单
- 🐟 闲鱼 Tab：内嵌 goofish.com，首次手动登录（扫码/短信），登录态持久化保存
- 🚀 一键发布：自动打开发布页，JS 注入填表、上传图片、点击发布

## 发布页 DOM（goofish.com/publish，2026-10 验证）
- 标题：`[contenteditable="true"]` 第一个（排除描述编辑器）
- 价格：`input[placeholder="0.00"]`
- 新旧程度：`input[type="radio"]` 按索引（0=全新…6=6成新及以下）
- 描述：`[data-placeholder*="描述一下"]` 富文本编辑器
- 图片：`input[type="file"]`，base64 → File → DataTransfer 注入
- 发布按钮：`button` 文本含"发布"

## 构建
GitHub Actions 自动构建无签名 IPA（同 bijia-ios 流程）。
