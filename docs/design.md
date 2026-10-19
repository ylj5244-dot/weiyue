# 微阅：Mac 微博群聊工作台

2026-10-18。用户已明确授权按混合方案开始开发，先验证真实微博群聊接入，保持阅读位置和官方功能。先个人自用、单机、账号隔离；不发布到外部。

## 产品要求

- 苹果式桌面视觉：系统字体、轻盈侧栏、低饱和蓝色、留白、细分隔线、明确层级，深浅模式适配，中文可读性优先。
- 官方聊天以完整 WKWebView 保留，原网页菜单、输入、媒体、文件选择和弹窗可用；专注阅读提供独立本地视图。以真实网页逐项验收，不声称手机专属能力已支持。
- 用户可选群；只归档所选择群的消息。v0.2 经用户授权，在官方会话中用只读 GET 补齐历史并后台同步。历史覆盖范围明确可见，不读取未选群或全部私信。
- 阅读标记没有产品数量上限。每条含唯一 id、账号 id、群 id、消息 id、创建时间 ISO、消息时间、备注和文本快照。显示完整年月日时分秒。新增不覆盖。可恢复删除。自动进度、本轮起点、临时跳转返回点与手动标记分别保存。
- 标记绑定消息，不只记像素。加载历史、追加消息、搜索、查看最新、调整字号、切群、应用重启不改变标记。原文缺失时显示快照和缺口，不谎称定位成功。
- 按姓名筛选候选成员，并按稳定用户 id 选择；按选定成员、关键词、时间过滤本地已加载记录。用户可勾选任意多条，保存为资料集，也可直接加入 AI 上下文。不能将仅本地搜索标成全群历史搜索。
- 收藏资料集保存消息快照和出处，与右侧 AI 上下文联动；选中的条目可移除，切换群不自动更换已选 AI 材料。讨论绑定所选资料和明确的会话 id；从收藏可继续讨论。
- AI 使用用户自己的 HTTPS API 地址、Key、模型。Key 放 macOS Keychain，只由原生进程访问。页面不获得 Key。支持 OpenAI-compatible chat/completions，明确错误和取消，无后台自动上传，无群聊发送工具。任何内容发回群均由用户在官方页面手动完成。
- 原生持久化对每次保存原子写入并保留已验证备份；保存失败不得显示成功。重启、损坏恢复均测试。演示数据只在显式演示模式存在，与真实账号完全分开。

## 架构

Swift AppKit 原生 .app + WKWebView；本地 UI 与微博远程页使用不同桥接权限。所有资源随 app 打包，无 npm 或服务启动需求。Swift 编译用当前 CLT，不依赖 SwiftUI 宏。

官方页在 https://api.weibo.com/chat 。远程页桥接观察允许路径返回的账号、群列表和消息响应；经明确配置后，还为已选群发起同源只读 GET 历史及轮询请求，并记录规范化元数据。不窃取或复制 cookies，不发写请求，不主动清未读。只有选定群消息写入本地模型。UI 的保存、AI、导出桥接仅限本地资源主框架；远程网页不能调用。

本地模型位于 Resources/ui/model.js，同时可被 Node 测试和浏览器使用。HTML/CSS/JS 实现三栏，官方视图作为原生子视图叠放在 UI 指定的中部区域。官方视图保留实例，切换阅读只隐藏，尽量不丢草稿。

## 跨模块契约

所有 id 必须为字符串，保留 64 位精度。Message = {id, groupId, senderId, senderName, text, sentAt, attachments:[], sourceURL?}；Group = {id,name,selected,accountId?}。

State = {version:1, revision:0, accountId:'', groups:[], messages:[], bookmarks:[], collections:[], progress:{}, discussions:[], settings:{baseURL:'',model:''}}。各数据实体含 accountId；默认空状态不种入假消息。

model.js 挂载 window.ReaderModel 并导出 CommonJS，提供 createState, normalizeState, upsertGroups, selectGroup, ingestMessages, addBookmark, removeBookmark, restoreBookmark, setProgress, findMembers, searchMessages, createCollection, buildContext。变更函数直接修改 state，仅数据实际变化时递增 revision；相同响应不重复改写，失败 throw Error；日期默认当前 ISO。searchMessages(state,{groupId,senderId,query,from,to}) 返回 Message[]；findMembers(state,groupId,query) 返回 {id,name,count}[]；buildContext(state,messageIds) 返回 {messages:[快照],text}。messageIds 采用 groupId 与 messageId 的复合 key，提供 messageKey(message)。

原生 bridge：window.webkit.messageHandlers.app.postMessage({id,action,payload})；UI 定义 window.nativeReceive({id,ok,result,error}) Promise RPC。actions: ready(返回 state 与 hasAPIKey)、save({state})、layout({x,y,width,height,visible})、openOfficial({groupId?})、reloadOfficial、ai({baseURL,model,messages})、cancelAI、saveKey({key})、export({text,name})、copy({text})。原生主动调用 window.onNativeEvent({type:'groups',accountId,groups})、{type:'messages',accountId,groupId,messages}、{type:'status',text}。

## 验收

1000 个标记存取和恢复，无覆盖；不同群相同消息 id 和同名成员不混淆；重启恢复；损坏主文件回退备份且告警；选择 3 条仅保存/发送这 3 条；选中素材切群仍不变；新消息/历史补载不改变手动标记和阅读进度；官方视图无拦截发送、无自动测试消息；真实账号群聊加载/历史/菜单逐项记录实测状态。

## 当前证据与边界

v0.2 已在原生应用验证两个群共 2038 条消息归档、图片原图及缓存定位、可用 AI 模型连接和系统浅深主题跟随。最新构建已安装并通过严格签名检查；退出后进程消失，重开恢复模式与两群阅读锚点，2038 条消息、两个书签、一个摘录和一个讨论保留。标记日期、原文定位与返回阅读处，以及官方编辑器草稿清空、表情／文件选择／消息菜单／群公告／成员面板已实测。附件复制与退出协调修复已完成，但复制进行中退出尚未端到端验证。未进行真实发送、转发、撤回或上传；自然新消息到达及文档附件尚未完成端到端验收。既有第三方项目仅作公开研究参考，不执行其代码。详见 [verification.md](verification.md)。


## v0.2 同步与附件补充

- `window.__weiboReaderSync` 提供 `configure`、`loadHistory`、`syncNow`、`pause`、`resume`、`replayRecent`。仅已确认账号的已选群可读取。初次历史按本地已有数量补足目标，后续可继续加载；默认每 4 秒轮询，跨页追补至已知最新消息。身份变化、取消、限流和超时都不能把迟到响应归到其他账号。
- 消息 ID 和附件 ID 保留字符串精度。附件形状为 `{type,url,name,thumbnailURL?,size?,mimeType?}`，只接受 HTTP(S) 地址。旧消息回读用于补全附件，不改变正常历史与实时同步游标。
- 阅读界面使用原生附件预览／打开／下载／定位能力；远程网页没有本地文件或 Keychain 读取权限。消息追加、历史插入和图片显示需保持消息锚点，切换模式及重启恢复也按锚点验证。
- 同步状态独立于归档数据；内容未变化时不重复保存。退出前停止后台读取并确认本地保存，附件复制与最终退出需协调；相关最新修复的真实重启结果以验收记录为准。
