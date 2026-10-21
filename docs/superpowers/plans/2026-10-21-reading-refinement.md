# 微阅 1.0.11 Implementation Plan

> For agentic workers: use subagent-driven-development for the isolated native preview task and review, with the primary agent owning UI integration. Do not modify the same files concurrently.

**Goal:** 修复用户六张截图中的阅读、预览和设置问题，安装可用新版。

**Architecture:** 保留 Swift/WKWebView 与现有原生保存接口。前端用独立的阅读表现模块和设置导航模块承载新布局，主 app.js 只接入过滤、渲染和生命周期。原生网页适配保持无应用消息桥和独立临时会话。

**Tech Stack:** Swift/AppKit/WebKit/Quick Look；原生 JavaScript、CSS 容器查询；Node 测试与离线 macOS 窗口夹具。

## 1. 右侧网页适配（独立实现任务）
- [ ] 修改 Sources/ContentPreview.swift，在页面加载和布局变化时应用可阅读的容器适配；不调整原生文档预览的隔离规则。
- [ ] 在 tests/ContentPreviewTests.swift / 新增响应式原生夹具验证固定宽度正文、320/480/880px、窗口变化、导航与清理。
- [ ] 本地 HTTP 提供桌面侧栏 + 文章正文和正常响应式页面；断言内容可见、正文不溢出、字体 >=14px、图片不超宽。
- [ ] 实现后按规格审查，再检查质量和异步生命周期。

## 2. 当前群关注阅读与连续布局
- [ ] app.js 移除跨群 activeView=followed 入口，增加当前群 readerFollowedOnly 条件；过滤调用 archive.query 后按 ReaderPersonalization.isFollowed 检查。
- [ ] index.html 在中间工具区增加两个 aria-pressed 按钮，删除左侧关注导航；保留人员管理入口。
- [ ] 修复 reader-discovery.css 对 continuation 的覆盖：连续行隐藏姓名栏，行动栏不额外占整行；首行仍显示姓名和徽标。
- [ ] 五档 consecutiveGap 改为 [0,16,40,80,144]，设置页同步提供视觉预览；断言数值、归组姓名和筛选阅读位置。

## 3. 长图和表情
- [ ] 原生 AttachmentPreview.swift 增加长图判定和自动适应宽度；点开后纵向滚动阅读，聊天列表缩略图不改；测试长图打开和窗口缩放阅读位置。
- [ ] 新阅读表现模块提供安全表情分段/DOM 渲染；用明确映射测试 [二哈]、邻接表情、未知标记与 Unicode emoji。
- [ ] 正文只用文本节点和可信本地 img 组合，复制、检索、资料保存继续使用原消息文本。
- [ ] 审核随包资源来源和许可/归属说明，网络失败时保留可读文本。

## 4. 搜索条和设置分栏
- [ ] 将 message-type-filters 移入搜索条主行；容器查询控制搜索宽度、按钮间距和辅助筛选换行。
- [ ] 新增 settings-navigation.js/css，左分类右内容；保留所有现有控件 ID 和保存函数。
- [ ] 阅读、关注、偏好、存储页面纳入统一导航外观，关闭/返回回到设置分类；切换分类不重置 AI 表单草稿。
- [ ] 实测宽窄窗口、键盘切换、表单保存、嵌套清理返回和对话框并发保护。

## 5. 集成、验证与交付
- [ ] 更新有意改变的旧测试预期，保留保存/清理/附件/后台功能回归；Node 测试后运行必要的原生与 GUI 测试。
- [ ] 新 UI 夹具覆盖三条连续关注消息、全群与只看关注、超长图、多图、表情、搜索布局和五个设置分类；截图逐项目检。
- [ ] 版本设为 1.0.11 build 17；更新使用说明和验收范围，通用编译并签名。
- [ ] 提交本地修改，生成 DMG/ZIP/源码；核对哈希、源码清单、两种架构与签名。
- [ ] 正常退出并备份旧应用，安装至 /Applications/微阅.app；确认实际启动新版。
