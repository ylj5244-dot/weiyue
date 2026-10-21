# 开源许可与参考来源

微阅使用根目录的 [MIT License](../LICENSE)，版权署名为 Copyright (c) 2026 ylj5244-dot。该授权适用于本仓库的项目代码与随附文档，以及 GitHub Release 提供的微阅应用与源码；当前发行版为 v1.0.12（构建 18）。使用、修改或再分发时请保留版权和许可声明。内置微博表情等第三方素材的来源及授权边界另见 [资源来源说明](weibo-emoticons.md)。

本项目使用 macOS 系统框架，不随源码分发 Apple SDK、系统框架或微博网页代码；项目没有 npm 或 Swift Package 外部包依赖。应用图标由 `scripts/make-icon.swift` 绘制，界面图标定义在 `Resources/ui/index.html`。

微博接入研究参考了 [alloevil/weibo-chat-auto](https://github.com/alloevil/weibo-chat-auto)（核对提交 `e7f8f2346d851fcdaff37d5efbafd5102a0e1647`），以及微博公开网页的请求结构。原始研究记录和出处见 [接入研究](access-research.md)。该文档保留首版研究阶段的说明，当前同步行为以 [完整使用指南](user-guide.md) 为准。

微阅的 MIT 授权不授予对第三方平台、服务、商标或用户资料的额外权利。微博与 AI 服务适用各自的条款；本项目不代表这些服务的官方产品。

正式发行包不包含个人聊天记录、登录会话或 API Key。使用者自行登录并配置自己的服务；数据保存与请求范围见 [完整使用指南](user-guide.md)。
