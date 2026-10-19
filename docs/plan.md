# 微阅 Implementation Plan

> **For agentic workers:** use coordinated independent implementation and a final review. User explicitly requested execution in this chat.

**Goal:** 可安装的 Mac 混合微博群聊阅读应用，先验证真实接入，保护无限阅读标记与资料。
**Architecture:** AppKit + isolated local/remote WKWebView, pure JS domain model, native atomic state store and Keychain AI.
**Tech Stack:** system Swift/AppKit/WebKit/Foundation/Security; plain JS/CSS; Node built-in tests.
**Spec:** docs/design.md

## Global Constraints

- 不修改父目录已有项目；当前独立目录和 codex/weibo-reader 分支。
- 不发送测试群消息，不复制浏览器 cookies，不自动向 AI 上传私密消息。
- 无限标记、完整时间、按稳定身份检索、选择保存与 AI 联动。
- 真实未验证能力不得显示为已验证；UI 显示本地覆盖范围。

## Review Focus

- 重启/保存失败/文件损坏，不能覆盖唯一有效快照。
- 64 位消息 id、同名成员、同群跨账号不混淆。
- 新消息、加载历史、切群和搜索不偷改阅读锚点。
- 远程网页不能访问本地数据、Keychain、文件和 AI 权限。
- AI 失败与取消不丢提问或污染其他讨论。

## Tasks

- [x] 1. 真实官方网页只读验证与接入观察协议：核实群列表、消息 DOM、历史与菜单。记录来源和实测。
- [x] 2. model.js + tests/model.test.cjs：先失败测试，覆盖 1000 标记、复合身份、进度稳定、选择收藏/AI。
- [x] 3. Sources/Store.swift + 原生存储测试：原子保存、单调 revision、备份恢复、错误不吞。
- [x] 4. 本地三栏 UI index.html/app.css/app.js：官方/阅读切换、空状态、标记、成员搜索、资料集、AI 会话和设置。
- [x] 5. App.swift/AIClient.swift + bridge/weibo.js：原生隔离桥接、官方网页保留、只读消息接入、Keychain API、文件下载/弹窗。
- [x] 6. scripts/build.sh 构建 .app；真实应用启动、检查 UI、重启恢复；最终审查与修复；docs/verification.md 如实记录未验证项目。

## Execution ruling

用户的“现在可以继续开始做，就按你建议的混合方案”已授权实施；文档把已批准方案和补充要求具体化，不再次要求批准同一事项。使用独立目录避免干扰父仓库的其他未提交工作。当前 SwiftUI 宏历史故障为参考，选择无需宏的 AppKit 并以当前编译结果验证。


## v0.2 增量与收尾（2026-10-18）

- [x] 已选群只读 GET 同步：初始历史覆盖、继续加载、4 秒轮询、跨页追补、限流与账号隔离。
- [x] 旧消息附件补全、图片预览与原图、原生缓存和 Finder 定位。
- [x] 模型列表与连接测试；可用模型配置已在原生应用保存。
- [x] 真实两群共 2038 条、两个书签、一个摘录和一个讨论重启保留；浅深主题跟随验证。
- [x] JavaScript 68 项、Store 8 项及 AI、Media 检查通过；正式构建成功。
- [x] 最新构建安装及严格签名校验；Cmd-Q 后进程退出，再启动恢复官方／阅读模式、两群消息锚点与偏移。
- [x] 标记完整日期、定位原文高亮、返回阅读处；官方草稿清空、表情面板、取消文件选择、消息菜单和群公告／成员面板实测。

任务 6 已完成最新构建的最终安装和重启检查。附件复制与退出协调代码已完成，但复制进行中退出的真实中断场景未验证。自然新消息到达、文档附件及真实发送／转发／撤回／上传未纳入已通过项；用户明确暂不主动查找文档。验收事实统一记录在 [verification.md](verification.md)。
