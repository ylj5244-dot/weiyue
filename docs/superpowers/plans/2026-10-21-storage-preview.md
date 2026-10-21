# 微阅 1.0.10 实施计划

> For agentic workers: use subagent-driven-development for focused implementation and staged review. Keep independent file ownership explicit.

Goal: 完成用户的五项修改并交付可运行、经过验证的 Mac 应用。

Architecture: 保留 AppKit + WKWebView、原有状态格式与账号隔离。新增后台存储统计与保留策略模块；原生侧栏预览独立于本地 JS 桥接；消息操作维持失败回滚但先反馈。

Tech Stack: Swift / AppKit / WebKit / Quartz，原生 JavaScript / CSS，Node test 与 Swift 合成测试。

## Task 1：复现和修复大量消息的标记延迟

- [ ] `Sources/Store.swift`、`Resources/ui/message-actions.js`：先以 6000 和 10000 条消息运行现状基准，再优化持久化重复解析和按钮 pending 状态；保留严格备份/损坏/同版本/旧版本检查。
- [ ] `tests/StoreTests.swift`、`tests/StoreConcurrencyTests.swift`、`tests/message-actions.test.cjs` 增加即时反馈和失败回滚测试，原测试不削弱。
- [ ] 运行 `node --test tests/message-actions.test.cjs` 和 Swift 存储测试，记录改前改后耗时；复核规范后再做质量审查。

## Task 2：存储与自动清理

- [ ] `Sources/StorageUsage.swift` 提供只读分类占用统计，不跟随符号链接；新增 `tests/StorageUsageTests.swift`。
- [ ] `Resources/ui/cleanup.js` 扩展时间范围与保护；`Resources/ui/storage-management.js` 处理设置、计时、最近清理结果；`Sources/CacheCleaner.swift` 添加缓存安全删除事务。
- [ ] `Resources/ui/index.html`、`app.js` 与新 CSS 加入二级页面、统计、手动清理、默认关闭开关和 1–4 天选项；`Sources/App.swift` 接入统计和自动清理 RPC，保持账号/版本/任务互斥。
- [ ] 增加边界/共享引用/关闭与重开/同步不回填/失败重试的 Node 与 Swift 测试，用合成目录验证实际释放字节。

## Task 3：紧凑附件、右侧浏览与图片布局

- [ ] `Sources/ContentPreview.swift` 创建隔离的内嵌 WKWebView / QLPreviewView，并管理 URL、导航状态与外部打开。
- [ ] `Sources/App.swift` 接入预览 RPC、布局同步、账号切换与退出清理；`Resources/ui/content-preview.js` 管理右侧面板与保留 AI 工作区。
- [ ] 修改 `app.js` 的附件标题/重复正文处理并新增 `attachment-layout.css`，缩小文档链接条目，图片完整比例且居中。
- [ ] 以合成链接、PDF、Word、宽图、窄图和多图验证点击、导航、外部按钮、弹窗覆盖、关闭后讨论状态、宽窄和日夜布局。

## Task 4：整体验证与交付

- [ ] 运行 `bash scripts/test.sh` 和新增原生 UI 测试，必要时修复相关旧 UI 测试的预期外观。
- [ ] 更新版本为 1.0.10（16），调整构建/打包清单、使用指南及验收记录；保持 MIT 与无星号简洁产品文案。
- [ ] 生成通用 DMG、ZIP、源码、安装说明、校验清单至工作区 outputs；验证两个架构、签名、源码清单与最终截图。
- [ ] 在保存后正常退出旧版再安装；不清理真实账号数据。交付时区分合成验证、真实运行和仍需用户确认的实际操作。
