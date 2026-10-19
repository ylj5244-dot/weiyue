# 微博群聊接入：证据、实现与边界

核对日期：2026-10-18。研究期间仅访问公开网页和源码；未登录用户账号，未发送消息，未安装或执行第三方项目。本文区分官方网页实现、第三方代码事实、作者声称与仍待本机实测的行为。

## 官方入口与已确认路径

官方入口为 [https://api.weibo.com/chat](https://api.weibo.com/chat)，页面标题为“微博聊天网页版”。该页本次直接引用的前端脚本是 [app.48f8ddda.js](https://h5.sinaimg.cn/m/pcweibochat/js/app.48f8ddda.js)。以下路径和调用参数由该公开脚本核实；它们是网页的实际实现，不能视为公开 SDK 的稳定承诺。

| 用途 | 官方脚本中的形状 |
| --- | --- |
| 当前登录身份 | `GET /webim/query_primary_info.json`；成功取 `profile.id`、`profile.screen_name`、`profile.profileImageUrl`；`error_code=21301` 时转回登录 |
| 会话列表 | `GET /webim/2/direct_messages/contacts.json?special_source=3`；响应含 `contacts[]`，条目包含 `user`、`message`、`unread_count` |
| 群消息当前页及历史 | `GET /webim/groupchat/query_messages.json?convert_emoji=1&query_sender=1`；调用参数为 `count:20`、`id:<群会话ID>`、`max_mid:<历史游标>` |
| 清除群未读 | 独立 `POST /webim/groupchat/clear_unread.json`；参数含 `id`，部分场景含 `is_clear_significant:1` |
| 单聊历史 | 另有 `/webim/2/direct_messages/conversation.json`，本应用桥接不观察该路径 |

官方前端为相关请求添加 `source=209678993`。本应用不构造这些请求，只观察官方页面已发起的请求响应。

## 身份、历史与原文

研究参考仓库：[alloevil/weibo-chat-auto](https://github.com/alloevil/weibo-chat-auto)，核对提交为 `e7f8f2346d851fcdaff37d5efbafd5102a0e1647`。

- [群列表解析](https://github.com/alloevil/weibo-chat-auto/blob/e7f8f2346d851fcdaff37d5efbafd5102a0e1647/lib/group-sessions.js)使用 `contacts[].user.type === 2` 判定群，`user.id` 为群会话 ID。单聊同样放在 `user` 下；不能因为出现 `user` 就认定为群。该项目按名称去重，本应用按 ID 去重，保留同名群。
- [消息标准化](https://github.com/alloevil/weibo-chat-auto/blob/e7f8f2346d851fcdaff37d5efbafd5102a0e1647/lib/normalize-message.js)兼容 `id / mid / message_id`，发送者来自 `from_uid` 或 `from_user` 的 ID 字段；群接口的 `time` 为秒。所有 ID 必须保存为字符串。JSON 数字应在解析前保护，不能先经 JavaScript Number 四舍五入再转字符串。
- 官方历史逻辑将下一游标设为 `messages[0].id - 1`；[第三方分页实现](https://github.com/alloevil/weibo-chat-auto/blob/e7f8f2346d851fcdaff37d5efbafd5102a0e1647/lib/paginate.js)直接使用最老 ID 并去重，默认每页 20 条、500 页上限。这一差异尚未在用户账号实测。本应用首版不主动分页，以已捕获数据为覆盖范围。
- 第三方项目会压平正文中的换行及连续空白，本应用完整保存已取得的正文，不作此变换。消息来源链接目前只指向官方聊天页，不伪造未验证的消息深链。
- 查询出现 `error_code`、结构异常或精度不明时必须报告未归档，不能把失败转为空数组“成功”。缺失时间不能用当前时间冒充消息时间。

## 已读行为与 WebKit

官方脚本不仅在打开群时调用清未读，也在窗口聚焦后的部分群新消息处理分支调用。保留完整官方页面会同时保留这些官方行为。本应用承诺“观察器不增加请求、不主动清未读”，不承诺“官方 WebView 永远不改变已读”。[参考项目说明](https://github.com/alloevil/weibo-chat-auto#live-sync--sending-messages)也承认额外群查询是否推进已读，无法从外部充分排除；其默认关闭实时轮询仅是作者的风险控制选择。

[第三方原生登录实现](https://github.com/alloevil/weibo-chat-auto/blob/e7f8f2346d851fcdaff37d5efbafd5102a0e1647/src-tauri/src/lib.rs#L68)直接在 WebView 打开官方聊天地址，提供 WKWebView 扫码方式的实现佐证。其注释记录过期 Cookie 时页面地址仍留在 `/chat`；页面地址、标题、有 Cookie 或有容器 DOM 均不足以证明登录成功。本文没有独立验证该项目的本机运行效果。

本应用桥接应在 `.atDocumentStart`、页面执行环境 `.page` 注入。Apple 的 [WKContentWorld 文档](https://developer.apple.com/documentation/webkit/wkcontentworld)说明隔离执行环境拥有独立的 JavaScript 变量；替换隔离环境的 fetch 不会替换官方页面环境中的 fetch。原生接收端仍必须独立校验消息来源 frame 的域和协议，并在原生边界处理账号隔离、群选择与本地写入权限。

## 当前原创桥接实现

`Resources/bridge/weibo.js` 是独立编写的 classic IIFE，没有复制参考项目实质代码。它只观察上表的身份、会话列表、群消息三个 GET 路径。

- 仅在 `https://api.weibo.com` frame 内自动安装，重复注入不重复包装；无主动请求、Cookie 读取、Keychain、本地文件或本地状态读取能力。
- fetch 返回原 Promise 和原 Response，观察副本；XHR 保留原 open/send 返回值、参数、原页面事件及响应。观察器或原生桥失败不改变网页请求结果。
- 输出 `profile / groups / messages / status` 事件。群默认 `selected:false`，选中状态、账号归属、是否持久化均由原生和本地模型决定。
- 原始 JSON 大整数在解析前转为精确字符串；小数及指数数字保留原数字文本，标识字段拒绝非十进制整数形状。已被 XHR 解析的 JSON 若存在不安全整数 ID，则拒绝该批，不能恢复已丢失的精度。
- 无发送者 ID 或明确为 0 的消息使用 `unknown:<消息ID>` 非用户标识，缺失显示名称时写“发送者待确认”。它不代表任何已确认成员或系统账号，也不把不同未知发送者合并；正常消息与这类通知同页时可以一并归档。账号和群 ID 仍严格校验。
- 保留安全的图片、链接、视频 URL；不主动请求媒体，不将脚本或本地文件协议送入附件。
- `window.__weiboReaderBridgeDiagnostics` 仅提供只读版本、响应数、档案数、群数、消息数及错误数，不包含正文、账号、URL 或 Cookie。
- 首版没有 DOM 抽取、WebSocket 观察或后台实时轮询。只捕获历史查询不能宣称实时消息无遗漏。后续应根据真实官方流量增加已验证的通道。

`tests/bridge.test.cjs` 使用合成内容和实际 Response 对象验证精度、保留原文、群隔离、错误处理、fetch/XHR 语义、来源限制、自动安装与附件协议。测试不会访问微博或发送消息。

## 尚待真实验证

应用内扫码、登录持久化、切换账号、历史边界、动态新增消息、撤回/引用、图片和文件选择、弹窗与其他官方菜单，需要逐项在本机验证。阅读视图应说明只覆盖已经加载并被捕获的消息，完整性未知时不能显示“全群历史已同步”。本地阅读标记与进度独立保存，不反写官方未读。

微博开放平台旧 Wiki 页面本次未返回可读正文。[现行官方 CLI 手册](https://open.weibo.com/cli/quickstart)说明开发者认证及服务开通前提；本次没有找到个人群聊完整读取属于公开开放能力的充分证据，不能将其当作可直接替代网页接入的已验证方案。

## 许可证

参考仓库实际 [LICENSE](https://github.com/alloevil/weibo-chat-auto/blob/e7f8f2346d851fcdaff37d5efbafd5102a0e1647/LICENSE) 为 MIT，版权声明为 Copyright (c) 2026 alloevil。复制其实质代码时需保留版权和许可文本；本应用桥接没有复制该项目实质代码。该许可证不代表微博对接口访问的授权。
