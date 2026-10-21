import AppKit
import WebKit
import Quartz
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var localView: WKWebView!
    var officialView: WKWebView!
    var store: StateStore!
    var readingAppearance: ReadingAppearanceStore!
    var currentState: [String: Any] = StateStore.empty(accountId: "")
    var accountId = ""
    var accountName = ""
    var liveIdentityConfirmed = false
    var knownAccounts = Set<String>()
    var uiReady = false
    var events: [[String: Any]] = []
    var pendingRemote: [[String: Any]] = []
    var lastMessages: [String: [String: Any]] = [:]
    var popupWindows: [NSWindow] = []
    var attachmentPreviews: [UUID: AttachmentPreviewController] = [:]
    let contentPreview = ContentPreviewController()
    var contentPreviewGeneration = 0
    var retentionTimer: Timer?
    let ai = AIClient()
    var discussionTitles = DiscussionTitleCoordinator()
    let webSearch = WebSearchClient()
    var localIndex: URL!
    var terminationRequested = false
    var media: MediaStore!
    var syncConfigurationTask: DispatchWorkItem?
    var dataDirectory: URL!
    var attachmentDirectory: URL!
    var refreshingAttachments = Set<String>()
    var freezeInboundForQuit = false
    let fileOperations = DispatchGroup()
    let storageQueue = DispatchQueue(label: "local.weiyue.storage", qos: .userInitiated)
    var cacheCleaner: CacheCleaner!
    var cleanupInProgress = false
    var pendingCleanupRemote: [[String: Any]] = []
    var syncConfigurationGeneration = 0
    let contentQueue = DispatchQueue(label: "local.weiyue.content", qos: .userInitiated)
    var contentOperation: UUID?
    var contentGeneration = 0
    let credentialQueue = DispatchQueue(label: "local.weiyue.credentials", qos: .userInitiated)
    var aiGeneration = 0
    var aiBridgeOperation: UUID?
    var aiBridgeGeneration = -1
    var aiProgressTask: DispatchWorkItem?
    var pendingAIProgress: [String: Any]?
    var rangeRequest: (id: String, accountId: String, groupId: String, operation: UUID, cancelled: Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WeiboReader", isDirectory: true)
            store = try StateStore(directory: base)
            readingAppearance = try ReadingAppearanceStore(directory: base.appendingPathComponent("阅读与皮肤", isDirectory: true))
            dataDirectory = base
            attachmentDirectory = base.appendingPathComponent("附件",isDirectory:true)
            media = try MediaStore(directory:attachmentDirectory)
            cacheCleaner = CacheCleaner(directory: attachmentDirectory, recoveryDirectory: base.appendingPathComponent("清理记录", isDirectory: true))
            accountId = UserDefaults.standard.string(forKey: "lastAccountId") ?? ""
            accountName = UserDefaults.standard.string(forKey: "lastAccountName") ?? ""
            if !accountId.isEmpty {
                knownAccounts.insert(accountId)
                let loaded = try store.load(accountId: accountId)
                currentState = loaded.state
                if let warning = loaded.warning { events.append(["type": "status", "text": warning]) }
            }
        } catch {
            // Retain the damaged files and stop instead of creating an empty overwrite.
            showError(error.localizedDescription)
            NSApp.terminate(nil); return
        }
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1460, height: 920),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        // Keep both WebViews and their ongoing work alive when the window closes.
        window.isReleasedWhenClosed = false
        window.title = "微阅 · 微博群聊工作台"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1120, height: 700)
        window.backgroundColor = NSColor.windowBackgroundColor
        applyAppearance(WorkspacePolicy.savedAppearance())
        window.setFrameAutosaveName("WeiboReaderMain")
        window.center()
        let localConfig = WKWebViewConfiguration()
        localConfig.setURLSchemeHandler(media, forURLScheme:"weiyue-media")
        localConfig.websiteDataStore = .nonPersistent()
        localConfig.userContentController.add(self, name: "app")
        localView = WKWebView(frame: window.contentView!.bounds, configuration: localConfig)
        localView.autoresizingMask = [.width, .height]
        localView.navigationDelegate = self
        localView.uiDelegate = self
        localView.setValue(false, forKey: "drawsBackground")
        window.contentView!.addSubview(localView)
        let officialConfig = WKWebViewConfiguration()
        officialConfig.websiteDataStore = .default()
        officialConfig.preferences.javaScriptCanOpenWindowsAutomatically = true
        officialConfig.userContentController.add(self, contentWorld: .page, name: "weibo")
        if let path = Bundle.main.url(forResource: "weibo", withExtension: "js", subdirectory: "bridge"),
           let source = try? String(contentsOf: path, encoding: .utf8) {
            officialConfig.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                                            forMainFrameOnly: true, in: .page))
        }
        officialView = WKWebView(frame: .zero, configuration: officialConfig)
        officialView.navigationDelegate = self; officialView.uiDelegate = self
        officialView.isHidden = true
        officialView.allowsBackForwardNavigationGestures = true
        window.contentView!.addSubview(officialView)
        window.contentView!.addSubview(contentPreview.view)
        contentPreview.onChange = { [weak self] value in self?.event(value) }
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.retentionTick() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(retentionTick), name: NSWorkspace.didWakeNotification, object: nil)
        localIndex = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ui")!
        localView.loadFileURL(localIndex, allowingReadAccessTo: localIndex.deletingLastPathComponent())
        officialView.load(URLRequest(url: URL(string: "https://api.weibo.com/chat")!))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func retentionTick() {
        guard uiReady, !terminationRequested, !cleanupInProgress else { return }
        event(["type": "retentionTick"])
    }
    func applyAppearance(_ preference: String) {
        switch preference {
        case "light": window?.appearance = NSAppearance(named: .aqua)
        case "dark": window?.appearance = NSAppearance(named: .darkAqua)
        default: window?.appearance = nil
        }
    }

    func closeAttachmentPreviews() {
        contentPreviewGeneration += 1; contentPreview.close()
        let previews = Array(attachmentPreviews.values)
        attachmentPreviews.removeAll()
        previews.forEach { $0.close() }
    }

    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于微阅", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏微阅", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出微阅", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "编辑"; menu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let windowItem = NSMenuItem(); windowItem.title = "窗口"; menu.addItem(windowItem)
        let windows = NSMenu(title: "窗口"); windowItem.submenu = windows
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
    @objc func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.8"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "微阅", .applicationVersion: version,
            .credits: NSAttributedString(string: "微博群聊 · 书签收藏 · 行内翻译 · 重点关注\n三栏比例可调，外观跟随系统。资料保存在本机。")])
    }
    func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = "微阅"; alert.informativeText = text
        alert.alertStyle = .warning; alert.addButton(withTitle: "好"); alert.runModal()
    }
    func jsJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
    func hasAPIKey(baseURL: String? = nil) -> Bool {
        let base = baseURL ?? (currentState["settings"] as? [String: Any])?["baseURL"] as? String ?? ""
        if let known = SecretStore.knownPresence(accountId: accountId, baseURL: base) { return known }
        // Preserve the existing configured endpoint as a presence hint without
        // touching credentials at launch. Actual use requires explicit consent.
        let configured = (currentState["settings"] as? [String: Any])?["baseURL"] as? String ?? ""
        return !accountId.isEmpty && !base.isEmpty && (try? AIClient.endpoint(base)) == (try? AIClient.endpoint(configured))
    }
    func requireCurrentAccount(_ payload: [String: Any]) throws {
        guard !accountId.isEmpty, payload["accountId"] as? String == accountId else {
            throw ReaderError.message("账号已切换，请在当前账号重新打开 AI 设置或发起讨论。")
        }
    }
    func withAIKey(baseURL: String, id: Any, onFailure: ((Error) -> Void)? = nil, operation: @escaping () throws -> Void) {
        let account = accountId, generation = aiGeneration
        credentialQueue.async { [weak self] in
            let result = Result { () -> Void in
                guard try SecretStore.read(accountId: account, baseURL: baseURL, allowInteraction: false) != nil else {
                    throw ReaderError.message("此账号与 API 地址尚未保存 Key，请在设置中填写。")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard account == self.accountId, generation == self.aiGeneration, !self.terminationRequested else {
                    let error = ReaderError.message("本次请求已取消，资料和提问仍保留。")
                    if let onFailure { onFailure(error) } else { self.reply(id, error: error.localizedDescription) }; return
                }
                do { try result.get(); try operation() } catch {
                    if let onFailure { onFailure(error) } else { self.reply(id, error: error.localizedDescription) }
                }
            }
        }
    }
    func scheduleSyncConfiguration() {
        syncConfigurationTask?.cancel()
        guard !terminationRequested, !cleanupInProgress else { return }
        let work = DispatchWorkItem { [weak self] in self?.configureSync() }
        syncConfigurationTask = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func configureSync(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard !terminationRequested, !cleanupInProgress, liveIdentityConfirmed, !accountId.isEmpty else {
            completion?(.failure(ReaderError.message("同步暂未就绪，请先确认微博登录，或等待当前清理完成。")))
            return
        }
        let state = currentState, expectedAccount = accountId, revision = currentState["revision"] as? Int ?? 0
        syncConfigurationGeneration += 1
        let generation = syncConfigurationGeneration
        storageQueue.async { [weak self] in
            let configuration = SyncConfigurationPolicy.configuration(state: state)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.accountId == expectedAccount, !self.terminationRequested,
                      !self.cleanupInProgress, self.liveIdentityConfirmed else {
                    completion?(.failure(ReaderError.message("账号或同步状态已改变，本次操作未开始。"))); return
                }
                // Automatic reconfiguration may supersede another automatic task.
                // An explicit action keeps its callback and waits for the latest state.
                guard completion != nil || self.syncConfigurationGeneration == generation else { return }
                guard self.currentState["revision"] as? Int == revision else {
                    if let completion { self.configureSync(completion: completion) }
                    else { self.scheduleSyncConfiguration() }
                    return
                }
                let groups = configuration["groups"] as? [[String: Any]] ?? []
                self.officialView.evaluateJavaScript("(() => { const sync = window.__weiboReaderSync; if (!sync || typeof sync.configure !== 'function') throw new Error('微博同步接口尚未加载，请刷新官方页面。'); return sync.configure(\(self.jsJSON(configuration))); })()") { [weak self] value, error in
                    guard let self else { return }
                    guard self.accountId == expectedAccount, self.liveIdentityConfirmed, !self.terminationRequested, !self.cleanupInProgress else {
                        completion?(.failure(ReaderError.message("账号或同步状态已改变，本次操作未开始。"))); return
                    }
                    if let error {
                        if let completion { completion(.failure(error)) }
                        else { self.event(["type":"status","text":"同步暂未启动：" + self.syncErrorText(error)]) }
                    } else if (value as? [String: Any])?["ok"] as? Bool == true {
                        self.refreshLegacyAttachments(groups:groups)
                        completion?(.success(()))
                    } else {
                        let error = ReaderError.message("微博同步接口未确认配置成功，请刷新官方页面后重试。")
                        if let completion { completion(.failure(error)) }
                        else { self.event(["type":"status", "text": error.localizedDescription]) }
                    }
                }
            }
        }
    }
    func rangeHistoryRequest(_ action: String, id: Any, payload: [String: Any]) throws {
        guard liveIdentityConfirmed, let requestedAccount = payload["accountId"] as? String,
              requestedAccount == accountId, !requestedAccount.isEmpty,
              let requestId = payload["requestId"] as? String, !requestId.isEmpty,
              requestId.utf16.count <= 160, requestId.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ReaderError.message("请先确认当前微博账号，再重新选择时间段。")
        }
        if action == "cancelRange" {
            guard let active = rangeRequest, active.id == requestId, active.accountId == requestedAccount else {
                reply(id, result: ["ok":true,"cancelled":false]); return
            }
            rangeRequest?.cancelled = true
            let script = "const sync = window.__weiboReaderSync; return sync && typeof sync.cancelRange === 'function' ? sync.cancelRange(request) : {ok:true,cancelled:false};"
            officialView.callAsyncJavaScript(script, arguments: ["request":["accountId":requestedAccount,"requestId":requestId]], in:nil, in:.page) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value): self.reply(id, result: value as? [String: Any] ?? ["ok":true,"cancelled":true])
                case .failure(let error): self.reply(id, error: self.syncErrorText(error))
                }
            }
            return
        }
        guard rangeRequest == nil else { throw ReaderError.message("已有时间段正在读取，请先完成或取消。") }
        guard let group = payload["groupId"] as? String,
              (currentState["groups"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == group && $0["selected"] as? Bool == true }),
              let from = payload["from"] as? String, let to = payload["to"] as? String,
              from.utf16.count <= 40, to.utf16.count <= 40 else {
            throw ReaderError.message("请选择已启用同步的群聊及有效的起止时间。")
        }
        let formatter = ISO8601DateFormatter()
        func parse(_ value: String) -> Date? {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        guard let start = parse(from), let end = parse(to), start <= end, end <= Date() else {
            throw ReaderError.message("请选择有效的起止日期和时间，结束时间不能晚于现在。")
        }
        let operation = UUID()
        rangeRequest = (requestId,requestedAccount,group,operation,false)
        let request: [String: Any] = ["accountId":requestedAccount,"groupId":group,"requestId":requestId,"from":from,"to":to]
        configureSync { [weak self] configured in
            guard let self else { return }
            func fail(_ text: String) {
                if self.rangeRequest?.operation == operation { self.rangeRequest = nil }
                self.reply(id, error: text)
            }
            guard self.accountId == requestedAccount, self.liveIdentityConfirmed,
                  self.rangeRequest?.operation == operation else { fail("账号或登录状态已改变，本次时间段读取已停止。"); return }
            guard self.rangeRequest?.cancelled != true else { fail("时间段读取已取消。"); return }
            if case .failure(let error) = configured { fail(self.syncErrorText(error)); return }
            guard (self.currentState["groups"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == group && $0["selected"] as? Bool == true }) else {
                fail("这个群已停止同步，本次时间段读取未开始。"); return
            }
            let script = "const sync = window.__weiboReaderSync; if (!sync || typeof sync.loadRange !== 'function') throw new Error('微博时间段读取接口尚未加载，请刷新官方页面。'); return await sync.loadRange(request);"
            self.officialView.callAsyncJavaScript(script, arguments:["request":request], in:nil, in:.page) { [weak self] result in
                guard let self else { return }
                defer { if self.rangeRequest?.operation == operation { self.rangeRequest = nil } }
                guard self.accountId == requestedAccount, self.liveIdentityConfirmed else {
                    self.reply(id,error:"账号或登录状态已改变，已丢弃其他账号的时间段结果。"); return
                }
                switch result {
                case .success(let value):
                    guard let value = value as? [String: Any],
                          let messages = value["messages"] as? [[String: Any]], messages.count <= 4000,
                          messages.allSatisfy({ $0["groupId"] as? String == group && $0["accountId"] as? String == requestedAccount }),
                          let coverage = value["coverage"] as? [String: Any], coverage["complete"] is Bool else {
                        self.reply(id,error:"微博时间段结果无法核实，请稍后重试。"); return
                    }
                    self.reply(id,result:value)
                case .failure(let error): self.reply(id,error:self.syncErrorText(error))
                }
            }
        }
    }
    func syncErrorText(_ error: Error) -> String {
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }
    func refreshLegacyAttachments(groups:[[String:Any]]) {
        guard !terminationRequested, !cleanupInProgress else { return }
        let expectedAccount=accountId
        for group in groups {
            guard let groupId=group["id"] as? String,let loaded=group["loadedCount"] as? Int,loaded > 0 else{continue}
            let key="attachmentMigrationV2." + MediaPolicy.cacheKey(accountId:accountId,url:groupId)
            guard !UserDefaults.standard.bool(forKey:key),!refreshingAttachments.contains(key) else{continue}
            refreshingAttachments.insert(key)
            officialView.callAsyncJavaScript("return await window.__weiboReaderSync.replayRecent(groupId,count)",arguments:["groupId":groupId,"count":min(loaded,500)],in:nil,in:.page) { [weak self] result in
                guard let self else{return}
                guard case .success(let value)=result,let value=value as? [String:Any],value["cancelled"] as? Bool == false,self.accountId == expectedAccount else {self.refreshingAttachments.remove(key);return}
                // All message events have been enqueued on the local WebView before
                // this barrier. Persist their revisions before acknowledging migration.
                self.localView.callAsyncJavaScript("await window.flushBeforeQuit(); return true",arguments:[:],in:nil,in:.page) { [weak self] saved in
                    guard let self else{return};self.refreshingAttachments.remove(key)
                    if case .success = saved,self.accountId == expectedAccount { UserDefaults.standard.set(true,forKey:key) }
                }
            }
        }
    }
    func finishCleanup() {
        cleanupInProgress = false
        let pending = pendingCleanupRemote
        pendingCleanupRemote.removeAll()
        guard !terminationRequested else { return }
        officialView.evaluateJavaScript("window.__weiboReaderSync?.resume()", completionHandler: nil)
        pending.forEach(receiveWeibo)
        scheduleSyncConfiguration()
    }
    func automaticCleanupRequest(id: Any, payload: [String: Any]) throws {
        try requireCurrentAccount(payload)
        guard !terminationRequested, !cleanupInProgress, contentOperation == nil, attachmentPreviews.isEmpty,
              aiBridgeOperation == nil || aiBridgeGeneration != aiGeneration,
              rangeRequest == nil || rangeRequest?.cancelled == true,
              let revision = payload["revision"] as? Int, currentState["revision"] as? Int == revision else {
            throw ReaderError.message("资料正在使用，自动清理将稍后重试。")
        }
        let account = accountId, protected = payload["protectedMessages"] as? [[String: Any]] ?? []
        _ = try RetentionPolicy.settings(currentState)
        cleanupInProgress = true; discussionTitles.cancel()
        syncConfigurationTask?.cancel(); syncConfigurationGeneration += 1; fileOperations.enter()
        media.reset { [weak self] in
            guard let self else { return }
            self.officialView.evaluateJavaScript("window.__weiboReaderSync?.pause()") { [weak self] _, _ in
                guard let self else { return }
                self.storageQueue.async {
                    let result = Result { try AutomaticCleanup.run(store: self.store, cleaner: self.cacheCleaner, accountId: account,
                        revision: revision, protectedMessages: protected) }
                    DispatchQueue.main.async {
                        defer { self.fileOperations.leave(); self.finishCleanup() }
                        guard self.accountId == account else { self.reply(id, error: "账号已切换，清理结果保存在原账号中。"); return }
                        switch result {
                        case .success(let value):
                            if let state = value["state"] as? [String: Any] { self.currentState = state; self.lastMessages.removeAll() }
                            self.reply(id, result: value)
                        case .failure(let error): self.reply(id, error: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }
    func previewContentRequest(id: Any, payload: [String: Any]) throws {
        try requireCurrentAccount(payload)
        let item = try attachment(payload), account = accountId
        contentPreviewGeneration += 1; let generation = contentPreviewGeneration
        contentPreview.close()
        if item["type"] as? String == "link", let raw = item["url"] as? String {
            try contentPreview.open(url: ContentPreviewPolicy.webURL(raw), name: item["name"] as? String ?? raw)
            reply(id, result: contentPreview.snapshot); return
        }
        guard item["type"] as? String == "document" else { throw ReaderError.message("右侧预览支持链接和文档。") }
        media.fetch(accountId: account, attachment: item, using: officialView) { [weak self] result in
            guard let self else { return }
            guard account == self.accountId, generation == self.contentPreviewGeneration, !self.terminationRequested else {
                self.reply(id, error: "预览已关闭或切换。"); return
            }
            do {
                let asset = try result.get()
                try self.contentPreview.open(file: asset.file, name: asset.name, allowedDirectory: self.attachmentDirectory)
                self.reply(id, result: self.contentPreview.snapshot)
            } catch { self.reply(id, error: error.localizedDescription) }
        }
    }
    func cleanupRequest(_ action: String, id: Any, payload: [String: Any]) throws {
        try requireCurrentAccount(payload)
        let account = accountId
        if action == "cleanupStatus" {
            fileOperations.enter()
            storageQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.cacheCleaner.latestRecovery(accountId: account) }
                DispatchQueue.main.async {
                    defer { self.fileOperations.leave() }
                    guard self.accountId == account else { self.reply(id, error: "账号已切换，请重新打开本地清理。"); return }
                    switch result {
                    case .success(let receipt): self.reply(id, result: ["receipt": receipt as Any? ?? NSNull()])
                    case .failure(let error): self.reply(id, error: error.localizedDescription)
                    }
                }
            }
            return
        }
        guard !cleanupInProgress, !terminationRequested else { throw ReaderError.message("另一个清理或保存操作正在完成，请稍后重试。") }
        guard let revision = payload["revision"] as? Int, currentState["revision"] as? Int == revision else {
            throw ReaderError.message("本地资料已更新，请重新预览清理范围。")
        }
        if action == "cleanupPreview" {
            guard let refs = payload["refs"] as? [[String: Any]] else { throw ReaderError.message("缺少清理文件范围。") }
            fileOperations.enter()
            storageQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.cacheCleaner.preview(accountId: account, refs: refs).json }
                DispatchQueue.main.async {
                    defer { self.fileOperations.leave() }
                    guard self.accountId == account, self.currentState["revision"] as? Int == revision else {
                        self.reply(id, error: "本地资料已更新，请重新预览清理范围。"); return
                    }
                    switch result {
                    case .success(var value): value["revision"] = revision; self.reply(id, result: value)
                    case .failure(let error): self.reply(id, error: error.localizedDescription)
                    }
                }
            }
            return
        }
        guard contentOperation == nil, aiBridgeOperation == nil || aiBridgeGeneration != aiGeneration else {
            throw ReaderError.message("资料或 AI 仍在处理，请结束或取消后再清理。")
        }
        let nextState = payload["state"] as? [String: Any]
        let refs = payload["refs"] as? [[String: Any]] ?? []
        if action == "cleanupApply" {
            guard let nextState, nextState["accountId"] as? String == account,
                  nextState["revision"] as? Int == revision + 1 else {
                throw ReaderError.message("清理后的资料版本无效，尚未修改本地文件。")
            }
        }
        cleanupInProgress = true
        syncConfigurationTask?.cancel()
        syncConfigurationGeneration += 1
        fileOperations.enter()
        media.reset { [weak self] in
            guard let self else { return }
            self.officialView.evaluateJavaScript("window.__weiboReaderSync?.pause()") { [weak self] _, _ in
            guard let self else { return }
            self.storageQueue.async {
                let result: Result<[String: Any], Error> = Result {
                    let before = try self.store.load(accountId: account).state
                    guard before["revision"] as? Int == revision else { throw ReaderError.message("本地资料已更新，请重新预览清理范围。") }
                    if action == "cleanupApply", let nextState {
                        try self.store.validate(state: nextState, accountId: account)
                        let plan = try self.cacheCleaner.preview(accountId: account, refs: refs)
                        let receipt = try self.cacheCleaner.trash(plan: plan, beforeState: before)
                        do { try self.store.save(state: nextState, accountId: account) }
                        catch {
                            do { _ = try self.cacheCleaner.restore(id: receipt.id, accountId: account) }
                            catch { throw ReaderError.message("清理后的文字保存未成功，部分文件需从系统废纸篓恢复；清理快照已保留。") }
                            throw error
                        }
                        return ["state": nextState, "receipt": receipt.json]
                    }
                    let receiptId: String?
                    if let requested = payload["id"] as? String { receiptId = requested }
                    else { receiptId = try self.cacheCleaner.latestRecovery(accountId: account)?["id"] as? String }
                    guard let receiptId else { throw ReaderError.message("当前账号没有可以撤销的清理记录。") }
                    let restored = try self.cacheCleaner.restore(id: receiptId, accountId: account, markRestored: false)
                    return ["beforeState": restored.beforeState, "warnings": restored.warnings, "id": receiptId]
                }
                DispatchQueue.main.async {
                    defer { self.fileOperations.leave(); self.finishCleanup() }
                    guard self.accountId == account else { self.reply(id, error: "账号已切换，本次操作已保存在原账号中。"); return }
                    switch result {
                    case .success(let value):
                        if let saved = value["state"] as? [String: Any] { self.currentState = saved; self.lastMessages.removeAll() }
                        self.reply(id, result: value)
                    case .failure(let error): self.reply(id, error: error.localizedDescription)
                    }
                }
            }
            }
        }
    }
    func attachment(_ payload:[String:Any]) throws -> [String:Any] {
        guard let group=payload["groupId"] as? String,let mid=payload["messageId"] as? String,
              let index=(payload["attachmentIndex"] ?? payload["index"]) as? Int,
              let message=(currentState["messages"] as? [[String:Any]])?.first(where:{$0["groupId"] as? String == group && $0["id"] as? String == mid}),
              message["accountId"] as? String == accountId,
              let attachments=message["attachments"] as? [[String:Any]],attachments.indices.contains(index)
        else {throw ReaderError.message("这条消息的附件尚未保存，请先同步群聊。")}
        return attachments[index]
    }
    func beginContent() throws -> UUID {
        guard contentOperation == nil else { throw ReaderError.message("上一份资料仍在本机读取，请稍候再试。") }
        let token = UUID(); contentOperation = token; return token
    }
    func finishContent(_ result: Result<[String: Any], Error>, id: Any, token: UUID, account: String, generation: Int) {
        if contentOperation == token { contentOperation = nil }
        guard account == accountId, generation == contentGeneration, !terminationRequested else {
            reply(id, error: "资料读取已取消，或账号已切换。内容没有发送给 AI。"); return
        }
        switch result {
        case .success(let value): reply(id, result: value)
        case .failure(let error): reply(id, error: error.localizedDescription)
        }
    }
    func readContent(file: URL, name: String, id: Any, token: UUID, account: String, generation: Int,
                     importing: Bool = false, readMode: String = "auto", capabilities: [String: Any] = [:], sourceIdentity: [String: Any] = [:]) {
        let base = attachmentDirectory!
        fileOperations.enter()
        contentQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<[String: Any], Error> = Result {
                var source = file, identity = sourceIdentity
                if importing {
                    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard info.isRegularFile == true, let size = info.fileSize, size <= DirectInput.maxFileBytes else {
                        throw ReaderError.message("请选择不超过 25 MB 的文档或图片。")
                    }
                    let folder = try WorkspacePolicy.importDirectory(base: base, accountId: account)
                        .appendingPathComponent(token.uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let safeName = MediaPolicy.filename(name, mime: "application/octet-stream")
                    source = folder.appendingPathComponent(safeName)
                    try FileManager.default.copyItem(at: file, to: source)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
                    identity = ["id": "import-" + token.uuidString, "localPath": source.path, "name": name]
                }
                var value: [String: Any]
                var fallbackReason: String?
                if readMode != "local" {
                    do {
                        var direct = try DirectInput.prepare(file: source, name: name, capabilities: capabilities)
                        direct["source"] = identity
                        value = direct; value["direct"] = true; value["modelFile"] = direct
                        value["kind"] = direct["mimeType"] as? String == "application/pdf" ? "document" : "image"
                        if importing { value["id"] = "import-" + token.uuidString; value["localPath"] = source.path }
                        return value
                    } catch {
                        if readMode == "model" { throw error }
                        fallbackReason = error.localizedDescription
                    }
                }
                value = try ContentExtractor.extract(file: source, name: name).json
                value["direct"] = false
                if let fallbackReason {
                    value["warnings"] = ["自动模式本次改为本地读取文字：" + fallbackReason] + (value["warnings"] as? [String] ?? [])
                }
                if importing { value["id"] = "import-" + token.uuidString; value["localPath"] = source.path }
                return value
            }
            DispatchQueue.main.async {
                defer { self.fileOperations.leave() }
                self.finishContent(result, id: id, token: token, account: account, generation: generation)
            }
        }
    }
    func aiCapabilities(_ payload: [String: Any]) throws -> [String: Any] {
        let settings = currentState["settings"] as? [String: Any] ?? [:]
        let base = payload["baseURL"] as? String ?? settings["baseURL"] as? String ?? ""
        let model = payload["model"] as? String ?? settings["model"] as? String ?? ""
        guard !base.isEmpty, !model.isEmpty else { return ["provider": "compatible", "images": false, "pdf": false, "thinking": false, "canDisableThinking": false] }
        var capabilities = try AIClient.capabilities(baseURL: base, model: model)
        if capabilities["provider"] as? String == "compatible" {
            capabilities["images"] = payload["allowImages"] as? Bool ?? settings["allowImages"] as? Bool ?? false
            capabilities["pdf"] = payload["allowPDF"] as? Bool ?? settings["allowPDF"] as? Bool ?? false
        }
        return capabilities
    }
    func contentReadOptions(_ payload: [String: Any]) throws -> (String, [String: Any]) {
        let mode = payload["readMode"] as? String ?? "auto"
        guard ["auto", "model", "local"].contains(mode) else { throw ReaderError.message("资料读取方式无效。") }
        if mode == "local" { return (mode, [:]) }
        if mode == "auto" { return (mode, (try? aiCapabilities(payload)) ?? [:]) }
        return (mode, try aiCapabilities(payload))
    }
    func queueAIProgress(_ update: [String: Any], requestId: String, operation: UUID, account: String, generation: Int) {
        guard aiBridgeOperation == operation, account == accountId, generation == aiGeneration, !terminationRequested else { return }
        var pending = pendingAIProgress ?? ["type": "aiProgress", "requestId": requestId, "accountId": account]
        for (key, value) in update {
            if ["contentDelta", "reasoningDelta"].contains(key), let delta = value as? String {
                pending[key] = (pending[key] as? String ?? "") + delta
            } else { pending[key] = value }
        }
        pendingAIProgress = pending
        if aiProgressTask == nil {
            let work = DispatchWorkItem { [weak self] in self?.flushAIProgress(operation: operation, account: account, generation: generation) }
            aiProgressTask = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }
    func flushAIProgress(operation: UUID, account: String, generation: Int) {
        guard aiBridgeOperation == operation else { return }
        aiProgressTask?.cancel(); aiProgressTask = nil
        let pending = pendingAIProgress; pendingAIProgress = nil
        guard account == accountId, generation == aiGeneration, !terminationRequested, let pending else { return }
        event(pending)
    }
    func startAIRequest(id: Any, payload: [String: Any], messages: [[String: Any]]) throws {
        // A foreground discussion always gets priority, including while a title
        // is still waiting for noninteractive credential access.
        discussionTitles.cancel()
        guard let base = payload["baseURL"] as? String, let model = payload["model"] as? String else { throw ReaderError.message("请填写 API 地址与模型。") }
        if aiBridgeGeneration != aiGeneration { aiBridgeOperation = nil; aiProgressTask?.cancel(); aiProgressTask = nil; pendingAIProgress = nil }
        guard aiBridgeOperation == nil else { throw ReaderError.message("已有资料正在准备或讨论正在生成，请等待或先取消。") }
        guard !messages.isEmpty, messages.count <= 200, messages.allSatisfy({ $0["content"] is String && ["system", "user", "assistant"].contains($0["role"] as? String ?? "") }) else {
            throw ReaderError.message("讨论内容格式无效，请重新选择材料。")
        }
        let sources = payload["sources"] as? [[String: Any]] ?? []
        guard sources.count <= 20 else { throw ReaderError.message("一次最多直接读取 20 份资料，请分批发送。") }
        let webSearchEnabled = try WebSearchPolicy.enabled(payload["webSearchEnabled"])
        var webQuery: String?
        if webSearchEnabled {
            _ = try WebSearchPolicy.endpoint(baseURL:base)
            if let query = payload["webSearchQuery"], !(query is String) { throw ReaderError.message("联网搜索词格式无效，请重新输入问题。") }
            webQuery = try WebSearchPolicy.query(payload["webSearchQuery"] as? String,messages:messages)
        }
        let capabilities = try aiCapabilities(payload), operation = UUID(), account = accountId, generation = aiGeneration
        let requestId = String((payload["requestId"] as? String ?? String(describing: id)).prefix(200))
        aiBridgeOperation = operation; aiBridgeGeneration = generation
        let thinking = payload["thinking"] as? String ?? "auto"
        let allowImages = capabilities["provider"] as? String == "compatible" && capabilities["images"] as? Bool == true
        let allowPDF = capabilities["provider"] as? String == "compatible" && capabilities["pdf"] as? Bool == true
        let started = Date()
        var webSearchMetadata: [String: Any]?
        let finish: (Result<String, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            let stillCurrent = self.aiBridgeOperation == operation && account == self.accountId && generation == self.aiGeneration && !self.terminationRequested
            if stillCurrent {
                var update: [String: Any] = ["phase": "completed", "elapsed": Date().timeIntervalSince(started)]
                if case .failure(let error) = result { update["phase"] = (error as NSError).code == NSURLErrorCancelled ? "cancelled" : "error"; update["error"] = error.localizedDescription }
                self.queueAIProgress(update, requestId: requestId, operation: operation, account: account, generation: generation)
                self.flushAIProgress(operation: operation, account: account, generation: generation)
                self.aiBridgeOperation = nil
            }
            guard stillCurrent else { self.reply(id, error: "已取消。本次问题与材料仍保留。"); return }
            switch result {
            case .success(let text):
                var value: [String:Any] = ["text":text]
                if let webSearchMetadata { value["webSearch"] = webSearchMetadata }
                self.reply(id, result:value)
            case .failure(let error): self.reply(id, error: (error as NSError).code == NSURLErrorCancelled ? "已取消。本次问题与材料仍保留。" : error.localizedDescription)
            }
        }
        let progress: ([String: Any]) -> Void = { [weak self] update in
            var value = update; value["elapsed"] = Date().timeIntervalSince(started)
            self?.queueAIProgress(value, requestId: requestId, operation: operation, account: account, generation: generation)
        }
        progress(["phase": "preparing", "fileCount": sources.count])
        flushAIProgress(operation: operation, account: account, generation: generation)
        resolveAISources(sources, account: account, generation: generation, operation: operation) { [weak self] resolved in
            guard let self else { return }
            do {
                let files = try resolved.get()
                guard account == self.accountId, generation == self.aiGeneration, self.aiBridgeOperation == operation, !self.terminationRequested else { throw URLError(.cancelled) }
                self.fileOperations.enter()
                self.contentQueue.async { [weak self] in
                    guard let self else { return }
                    let prepared: Result<[[String: Any]], Error> = Result {
                        var parts: [[String: Any]] = [], totalEncodedBytes = 0
                        for file in files {
                            let added = try DirectInput.parts(file: file.0, name: file.1, capabilities: capabilities)
                            for part in added {
                                totalEncodedBytes += (part["text"] as? String)?.utf8.count ?? 0
                                totalEncodedBytes += ((part["image_url"] as? [String: Any])?["url"] as? String)?.utf8.count ?? 0
                                totalEncodedBytes += ((part["file"] as? [String: Any])?["file_data"] as? String)?.utf8.count ?? 0
                            }
                            guard totalEncodedBytes <= DirectInput.maxEncodedBytes else { throw ReaderError.message("选中的图片和文档合计过大，请分批发送。") }
                            parts.append(contentsOf: added)
                        }
                        return try AIInputPolicy.messages(messages, appending: parts)
                    }
                    DispatchQueue.main.async { [self] in
                        defer { self.fileOperations.leave() }
                        guard account == self.accountId, generation == self.aiGeneration, self.aiBridgeOperation == operation, !self.terminationRequested else { finish(.failure(URLError(.cancelled))); return }
                        do {
                            let outgoing = try prepared.get()
                            let dispatchChat: ([[String:Any]]) -> Void = { [weak self] requestMessages in
                                guard let self, account == self.accountId, generation == self.aiGeneration,
                                      self.aiBridgeOperation == operation, !self.terminationRequested else { finish(.failure(URLError(.cancelled))); return }
                                progress(["phase":"credentials"])
                                self.withAIKey(baseURL:base,id:id,onFailure:{finish(.failure($0))}) {
                                    guard account == self.accountId, generation == self.aiGeneration, self.aiBridgeOperation == operation, !self.terminationRequested else { throw URLError(.cancelled) }
                                    try self.ai.send(accountId:account,baseURL:base,model:model,messages:requestMessages,
                                        thinking:thinking,allowImages:allowImages,allowPDF:allowPDF,onProgress:progress,completion:finish)
                                }
                            }
                            if let query = webQuery {
                                progress(["phase":"searching","detail":"正在搜索公开网页 · " + query])
                                self.flushAIProgress(operation:operation,account:account,generation:generation)
                                try self.webSearch.search(accountId:account,baseURL:base,query:query) { [weak self] result in
                                    guard let self, account == self.accountId, generation == self.aiGeneration,
                                          self.aiBridgeOperation == operation, !self.terminationRequested else { finish(.failure(URLError(.cancelled))); return }
                                    do {
                                        let search = try result.get(); webSearchMetadata = search.metadata
                                        var update: [String:Any] = ["phase":"reading","webSearch":search.metadata,
                                            "detail":search.status == "success" ? "已取得 \(search.evidence.count) 个网页来源，正在阅读并核对。" : "未取得可核实的网页资料，将明确说明搜索结果。"]
                                        if let warning = search.warning { update["warning"] = warning }
                                        progress(update);self.flushAIProgress(operation:operation,account:account,generation:generation)
                                        dispatchChat(try WebSearchPolicy.messages(outgoing,result:search))
                                    } catch { finish(.failure(error)) }
                                }
                            } else { dispatchChat(outgoing) }
                        } catch { finish(.failure(error)) }
                    }
                }
            } catch { finish(.failure(error)) }
        }
    }
    func startDiscussionTitle(id: Any, payload: [String: Any]) throws {
        try requireCurrentAccount(payload)
        guard !terminationRequested, !cleanupInProgress else { throw ReaderError.message("当前操作尚未结束，暂未生成讨论标题。") }
        guard (aiBridgeOperation == nil || aiBridgeGeneration != aiGeneration), contentOperation == nil,
              rangeRequest == nil || rangeRequest?.cancelled == true else {
            throw ReaderError.message("正在处理讨论或资料，稍后再生成标题。")
        }
        let request = try DiscussionTitlePolicy.request(state: currentState, activeAccountId: accountId, payload: payload)
        let account = accountId, generation = aiGeneration
        try discussionTitles.start(request, authorize: { [weak self] complete in
            guard let self else { complete(.failure(URLError(.cancelled))); return }
            self.withAIKey(baseURL: request.baseURL, id: id, onFailure: { complete(.failure($0)) }) {
                complete(.success(()))
            }
        }, isCurrent: { [weak self] in
            guard let self, account == self.accountId, generation == self.aiGeneration, !self.terminationRequested else { return false }
            return DiscussionTitlePolicy.isCurrent(request, state: self.currentState, activeAccountId: self.accountId)
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let title): self.reply(id, result: ["title": title])
            case .failure(let error):
                self.reply(id, error: (error as NSError).code == NSURLErrorCancelled ? "本次标题生成已取消。" : error.localizedDescription)
            }
        })
    }
    // Resolve source references against native account-scoped state. Neither JS
    // paths outside the import directory nor remote URLs can become file reads.
    func resolveAISources(_ sources: [[String: Any]], account: String, generation: Int, operation: UUID,
                          collected: [(URL, String)] = [], completion: @escaping (Result<[(URL, String)], Error>) -> Void) {
        guard account == accountId, generation == aiGeneration, aiBridgeOperation == operation, !terminationRequested else { completion(.failure(URLError(.cancelled))); return }
        guard let source = sources.first else { completion(.success(collected)); return }
        do {
            if let path = source["localPath"] as? String {
                let file = try WorkspacePolicy.importedFile(path: path, base: attachmentDirectory, accountId: account)
                resolveAISources(Array(sources.dropFirst()), account: account, generation: generation, operation: operation,
                    collected: collected + [(file, source["name"] as? String ?? file.lastPathComponent)], completion: completion)
            } else {
                let item = try AIInputPolicy.sourceAttachment(source, state: currentState, accountId: account)
                media.fetch(accountId: account, attachment: item, using: officialView) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let asset): self.resolveAISources(Array(sources.dropFirst()), account: account, generation: generation, operation: operation,
                        collected: collected + [(asset.file, asset.name)], completion: completion)
                    case .failure(let error): completion(.failure(error))
                    }
                }
            }
        } catch { completion(.failure(error)) }
    }
    func reply(_ id: Any, result: Any = [:], error: String? = nil) {
        var payload: [String: Any] = ["id": id, "ok": error == nil, "result": result]
        if let error { payload["error"] = error }
        localView.evaluateJavaScript("window.nativeReceive(\(jsJSON(payload)))", completionHandler: nil)
    }
    func event(_ payload: [String: Any]) {
        guard uiReady else { events.append(payload); return }
        localView.evaluateJavaScript("window.onNativeEvent(\(jsJSON(payload)))", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "weibo" {
            guard message.webView === officialView, message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.host == "api.weibo.com",
                  message.frameInfo.securityOrigin.protocol == "https" else { return }
            receiveWeibo(body); return
        }
        guard message.name == "app", message.webView === localView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == localIndex.standardizedFileURL,
              let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do {
            if terminationRequested && ["ai", "titleDiscussion", "extractAttachment", "importDocument", "testAI", "listModels", "authorizeAI", "cleanupPreview", "cleanupApply", "cleanupUndo", "autoCleanup", "previewContent", "loadRange"].contains(action) {
                throw ReaderError.message("应用正在保存并退出，已停止发起新的读取和 AI 请求。")
            }
            if cleanupInProgress && ["save", "ai", "titleDiscussion", "testAI", "extractAttachment", "importDocument", "prepareImported", "attachmentPreview", "openAttachment", "downloadAttachment", "revealAttachment", "previewContent", "loadHistory", "syncNow", "loadRange"].contains(action) {
                throw ReaderError.message("本地清理正在完成，请稍后继续操作。")
            }
            switch action {
            case "ready":
                uiReady = true
                reply(id, result: ["state": currentState, "hasAPIKey": hasAPIKey(), "accountName": accountName,
                    "layoutPreferences": UserDefaults.standard.dictionary(forKey: WorkspacePolicy.defaultsKey) ?? [:],
                    "appearance": WorkspacePolicy.savedAppearance(), "readingAppearance": readingAppearance.snapshot()])
                let waiting = events; events.removeAll()
                DispatchQueue.main.async { waiting.forEach(self.event) }
            case "save":
                guard let state = payload["state"] as? [String: Any],
                      let savingAccount = state["accountId"] as? String,
                      knownAccounts.contains(savingAccount) else { throw ReaderError.message("保存账号尚未验证，资料没有写入其他账号。") }
                let undoId = (state["cleanup"] as? [String: Any])?["lastUndoReceiptId"] as? String
                let previousUndoId = (currentState["cleanup"] as? [String: Any])?["lastUndoReceiptId"] as? String
                fileOperations.enter()
                // An old account's queued save may finish in its own file. No
                // serialization, validation or disk verification runs on main.
                storageQueue.async { [weak self] in
                    guard let self else { return }
                    let result = Result {
                        try self.store.save(state: state, accountId: savingAccount)
                        if let undoId, undoId != previousUndoId {
                            // A failed receipt update leaves another safe undo
                            // available; the successfully saved state stays valid.
                            try? self.cacheCleaner.completeRestore(id: undoId, accountId: savingAccount)
                        }
                    }
                    DispatchQueue.main.async {
                        defer { self.fileOperations.leave() }
                        switch result {
                        case .success:
                            if savingAccount == self.accountId, (state["revision"] as? Int ?? 0) >= (self.currentState["revision"] as? Int ?? 0) {
                                let refresh = SyncConfigurationPolicy.inputsChanged(from: self.currentState, to: state)
                                self.currentState = state
                                self.discussionTitles.cancelIfInvalidated()
                                if refresh { self.scheduleSyncConfiguration() }
                            }
                            self.reply(id, result: ["revision": state["revision"] ?? 0])
                        case .failure(let error): self.reply(id, error: error.localizedDescription)
                        }
                    }
                }
            case "autoCleanup":
                try automaticCleanupRequest(id: id, payload: payload)
            case "previewContent":
                try previewContentRequest(id: id, payload: payload)
            case "closeContentPreview":
                contentPreviewGeneration += 1; contentPreview.close(); reply(id)
            case "contentPreviewAction":
                try contentPreview.navigate(payload["operation"] as? String ?? ""); reply(id, result: contentPreview.snapshot)
            case "previewLayout":
                if let x = payload["x"] as? Double, let y = payload["y"] as? Double,
                   let width = payload["width"] as? Double, let height = payload["height"] as? Double,
                   [x, y, width, height].allSatisfy({ $0.isFinite }) {
                    let rect = NSRect(x: x, y: localView.bounds.height - y - height, width: max(0, width), height: max(0, height)).intersection(localView.bounds)
                    contentPreview.layout(rect, visible: payload["visible"] as? Bool == true)
                }
                reply(id)
            case "cleanupPreview", "cleanupApply", "cleanupUndo", "cleanupStatus":
                try cleanupRequest(action, id: id, payload: payload)
            case "loadRange", "cancelRange":
                try rangeHistoryRequest(action, id: id, payload: payload)
            case "loadHistory", "syncNow":
                guard liveIdentityConfirmed, let group = payload["groupId"] as? String,
                      (currentState["groups"] as? [[String:Any]] ?? []).contains(where:{$0["id"] as? String == group && $0["selected"] as? Bool == true}) else {
                    throw ReaderError.message("请先登录并勾选要同步的群聊。")
                }
                let expectedAccount = accountId
                let count=max(1,min(5000,payload["count"] as? Int ?? 500))
                configureSync { [weak self] configured in
                    guard let self else { return }
                    guard self.accountId == expectedAccount else { self.reply(id, error: "账号已切换，请在当前账号重新同步。"); return }
                    if case .failure(let error) = configured { self.reply(id, error: self.syncErrorText(error)); return }
                    guard (self.currentState["groups"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == group && $0["selected"] as? Bool == true }) else {
                        self.reply(id, error: "这个群已停止同步，本次操作未开始。"); return
                    }
                    let script = "const sync = window.__weiboReaderSync; if (!sync || typeof sync[operation] !== 'function') throw new Error('微博同步接口尚未加载，请刷新官方页面。'); return await (operation === 'loadHistory' ? sync.loadHistory(groupId, count) : sync.syncNow(groupId));"
                    self.officialView.callAsyncJavaScript(script, arguments: ["operation": action, "groupId": group, "count": count], in: nil, in: .page) { [weak self] result in
                        guard let self else { return }
                        guard self.accountId == expectedAccount else { self.reply(id, error: "账号已切换，本次同步已停止。"); return }
                        switch result {
                        case .success(let value):
                            guard let value = value as? [String: Any] else { self.reply(id, error: "微博未返回同步结果，请稍后重试。"); return }
                            if value["cancelled"] as? Bool == true { self.reply(id, error: "同步已暂停或取消，已经读取的消息仍保留。"); return }
                            self.reply(id, result: value)
                        case .failure(let error): self.reply(id, error: self.syncErrorText(error))
                        }
                    }
                }
            case "layout":
                if let x = payload["x"] as? Double, let y = payload["y"] as? Double,
                   let width = payload["width"] as? Double, let height = payload["height"] as? Double,
                   [x, y, width, height].allSatisfy({ $0.isFinite }) {
                    let bounds = localView.bounds
                    let rect = NSRect(x: x, y: bounds.height - y - height, width: max(0,width), height: max(0,height)).intersection(bounds)
                    officialView.frame = rect
                    officialView.isHidden = payload["visible"] as? Bool != true || rect.width < 100 || rect.height < 100
                }
                reply(id)
            case "saveAppearance":
                let preference = try WorkspacePolicy.appearance(payload["appearance"])
                UserDefaults.standard.set(preference, forKey: WorkspacePolicy.appearanceDefaultsKey)
                applyAppearance(preference)
                reply(id, result: ["appearance": preference])
            case "saveReadingAppearance":
                guard !terminationRequested, let preferences = payload["preferences"] as? [String: Any] else { throw ReaderError.message("阅读设置不可用，请稍后重试。") }
                reply(id, result: try readingAppearance.save(preferences))
            case "importReadingSkin", "importReadingFont":
                guard !terminationRequested else { throw ReaderError.message("应用正在退出。") }
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.allowedContentTypes = action == "importReadingSkin" ? [.json] : ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
                panel.title = action == "importReadingSkin" ? "导入微阅皮肤" : "导入 TTF／OTF 字体"
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    guard response == .OK, let file = panel.url else { self.reply(id, result: ["cancelled": true]); return }
                    guard !self.terminationRequested else { self.reply(id, error: "应用正在退出，本次导入未开始。"); return }
                    do { self.reply(id, result: try action == "importReadingSkin" ? self.readingAppearance.importSkin(file) : self.readingAppearance.importFont(file)) }
                    catch { self.reply(id, error: error.localizedDescription) }
                }
            case "exportReadingSkinSample":
                guard let source = Bundle.main.url(forResource: "skin-example.weiyue-skin", withExtension: "json", subdirectory: "ui") else { throw ReaderError.message("皮肤样例未找到。") }
                let panel = NSSavePanel(); panel.nameFieldStringValue = "纸页青绿.weiyue-skin.json"; panel.allowedContentTypes = [.json]
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    guard response == .OK, let file = panel.url else { self.reply(id, result: ["cancelled": true]); return }
                    do { try Data(contentsOf: source).write(to: file, options: .atomic); self.reply(id) }
                    catch { self.reply(id, error: error.localizedDescription) }
                }
            case "saveLayout":
                guard let value = payload["preferences"] as? [String: Any] else { throw ReaderError.message("缺少区域显示设置。") }
                let preferences = try WorkspacePolicy.layout(value)
                UserDefaults.standard.set(preferences, forKey: WorkspacePolicy.defaultsKey)
                reply(id, result: ["preferences": preferences])
            case "openOfficial":
                let groupId = payload["groupId"] as? String
                if let groupId, !groupId.isEmpty {
                    // User-selected contact only; this triggers the official page's own normal navigation.
                    let script = "(() => { const id = \(jsJSON(groupId)); const node = [...document.querySelectorAll('.name .hidden')].find(n => n.textContent.trim() === id); if (node) { node.parentElement.click(); return true; } return false; })()"
                    officialView.evaluateJavaScript(script) { [weak self] result, _ in
                        guard let self else { return }
                        if result as? Bool != true { self.event(["type":"status", "text":"请在官方聊天列表中选择这个群。资料标记已保留。"] ) }
                        if var cached = self.lastMessages[groupId] {
                            cached["messageSource"] = "replay"
                            self.event(cached)
                        }
                    }
                    if let mid = payload["messageId"] as? String {
                        officialView.evaluateJavaScript("document.getElementById(\(jsJSON(mid)))?.scrollIntoView({block:'center'})", completionHandler: nil)
                    }
                }
                reply(id)
            case "reloadOfficial":
                officialView.reload(); reply(id)
            case "saveKey":
                try requireCurrentAccount(payload)
                guard let base = payload["baseURL"] as? String, let key = payload["key"] as? String else {
                    throw ReaderError.message("请选择 API 服务地址并填写密钥。")
                }
                let expectedAccount = accountId
                credentialQueue.async { [weak self] in
                    let result = Result { try SecretStore.save(key, accountId: expectedAccount, baseURL: base) }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard expectedAccount == self.accountId else { self.reply(id, error: "账号已切换，请重新确认。"); return }
                        switch result {
                        case .success: self.reply(id, result: ["hasAPIKey": self.hasAPIKey(baseURL: base)])
                        case .failure(let error): self.reply(id, error: error.localizedDescription)
                        }
                    }
                }
            case "keyStatus":
                try requireCurrentAccount(payload)
                guard let base = payload["baseURL"] as? String else { throw ReaderError.message("请填写 API 服务地址。") }
                _ = try AIClient.endpoint(base)
                reply(id, result: ["hasAPIKey": hasAPIKey(baseURL: base)])
            case "authorizeAI":
                try requireCurrentAccount(payload)
                guard let base = payload["baseURL"] as? String else { throw ReaderError.message("请填写 API 服务地址。") }
                _ = try AIClient.endpoint(base)
                let expectedAccount = accountId
                credentialQueue.async { [weak self] in
                    let result = Result { try SecretStore.read(accountId: expectedAccount, baseURL: base, allowInteraction: true) != nil }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard expectedAccount == self.accountId else { self.reply(id, error: "账号已切换，请重新确认。"); return }
                        switch result {
                        case .success(let present): self.reply(id, result: ["hasAPIKey": present])
                        case .failure(let error): self.reply(id, error: error.localizedDescription)
                        }
                    }
                }
            case "listModels":
                try requireCurrentAccount(payload)
                guard let base=payload["baseURL"] as? String else {throw ReaderError.message("请填写 API 地址。")}
                withAIKey(baseURL: base, id: id) { [self] in try ai.listModels(accountId:accountId,baseURL:base) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let models):
                        var value: [String: Any] = ["models": models, "refreshedAt": ISO8601DateFormatter().string(from: Date())]
                        value["capabilities"] = try? self.aiCapabilities(payload)
                        value["provider"] = (try? AIClient.endpoint(base)).map { AIModelPolicy.provider($0) } ?? "compatible"
                        self.reply(id, result: value)
                    case .failure(let error): self.reply(id, error: error.localizedDescription)
                    }
                } }
            case "testAI":
                try requireCurrentAccount(payload)
                var testPayload = payload; testPayload["sources"] = [[String: Any]]()
                try startAIRequest(id: id, payload: testPayload, messages: [["role": "user", "content": "只回复OK"]])
            case "aiCapabilities":
                try requireCurrentAccount(payload)
                reply(id, result: try aiCapabilities(payload))
            case "storageUsage":
                fileOperations.enter()
                storageQueue.async { [weak self] in
                    guard let self else { return }
                    let result = Result { try StorageUsage.scan(directory: self.dataDirectory) }
                    DispatchQueue.main.async {
                        defer { self.fileOperations.leave() }
                        switch result {
                        case .success(let value): self.reply(id, result: value)
                        case .failure(let error): self.reply(id, error: error.localizedDescription)
                        }
                    }
                }
            case "storageLocations":
                reply(id,result:["dataPath":dataDirectory.path,"attachmentsPath":attachmentDirectory.path])
            case "revealStorage":
                let folder=payload["kind"] as? String == "attachments" ? attachmentDirectory! : dataDirectory!
                NSWorkspace.shared.open(folder);reply(id)
            case "extractAttachment":
                try requireCurrentAccount(payload)
                let item = try attachment(payload)
                guard let expected = payload["expectedAttachment"] as? [String: Any],
                      ["url", "type", "name"].allSatisfy({ (expected[$0] as? String ?? "") == (item[$0] as? String ?? "") }) else {
                    throw ReaderError.message("附件已更新，请从原消息重新选择并读取，避免使用旧文件内容。")
                }
                guard ["image", "document"].contains(item["type"] as? String ?? "") else {
                    throw ReaderError.message("暂时支持读取图片和文档。视频或网页链接请在官方聊天中打开。")
                }
                let (readMode, capabilities) = try contentReadOptions(payload)
                let identity = payload.filter { ["groupId", "messageId", "attachmentIndex", "expectedAttachment"].contains($0.key) }
                let token = try beginContent(), account = accountId, generation = contentGeneration
                media.fetch(accountId: account, attachment: item, using: officialView) { [weak self] result in
                    guard let self else { return }
                    guard account == self.accountId, generation == self.contentGeneration else {
                        self.finishContent(.failure(URLError(.cancelled)), id: id, token: token, account: account, generation: generation); return
                    }
                    switch result {
                    case .success(let asset): self.readContent(file: asset.file, name: asset.name, id: id, token: token, account: account, generation: generation,
                        readMode: readMode, capabilities: capabilities, sourceIdentity: identity)
                    case .failure(let error): self.finishContent(.failure(error), id: id, token: token, account: account, generation: generation)
                    }
                }
            case "importDocument":
                try requireCurrentAccount(payload)
                let (readMode, capabilities) = try contentReadOptions(payload)
                let token = try beginContent(), account = accountId, generation = contentGeneration
                let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.title = "选择要交给 AI 的文档或图片"; panel.prompt = "读取资料"
                panel.message = "文件先保存在本机；点击发送、翻译或解读后，按所选模式将原文件／页面图片或提取的正文提交给 AI。支持 PDF、Word、文本和图片，单个文件不超过 25 MB。"
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    guard response == .OK, let file = panel.url else {
                        self.finishContent(.success(["cancelled": true]), id: id, token: token, account: account, generation: generation); return
                    }
                    guard account == self.accountId, generation == self.contentGeneration else {
                        self.finishContent(.failure(URLError(.cancelled)), id: id, token: token, account: account, generation: generation); return
                    }
                    self.readContent(file: file, name: file.lastPathComponent, id: id, token: token, account: account, generation: generation, importing: true, readMode: readMode, capabilities: capabilities)
                }
            case "prepareImported":
                try requireCurrentAccount(payload)
                guard let path = payload["localPath"] as? String else { throw ReaderError.message("缺少本地资料路径。") }
                let file = try WorkspacePolicy.importedFile(path: path, base: attachmentDirectory, accountId: accountId)
                let (readMode, capabilities) = try contentReadOptions(payload)
                let token = try beginContent(), account = accountId, generation = contentGeneration
                var identity: [String: Any] = ["localPath": file.path, "name": file.lastPathComponent]
                if let sourceId = payload["id"] as? String { identity["id"] = sourceId }
                readContent(file: file, name: file.lastPathComponent, id: id, token: token, account: account, generation: generation,
                    readMode: readMode, capabilities: capabilities, sourceIdentity: identity)
            case "revealImported":
                try requireCurrentAccount(payload)
                guard let path = payload["localPath"] as? String else { throw ReaderError.message("缺少本地文档路径。") }
                let file = try WorkspacePolicy.importedFile(path: path, base: attachmentDirectory, accountId: accountId)
                NSWorkspace.shared.activateFileViewerSelecting([file]); reply(id)
            case "cancelContent":
                contentGeneration += 1; reply(id, result: ["cancelled": true])
            case "attachmentPreview", "openAttachment", "downloadAttachment", "revealAttachment":
                let item=try attachment(payload), expectedAccount=accountId
                if item["type"] as? String == "link", action != "attachmentPreview", let raw=item["url"] as? String,let url=URL(string:raw),["https","http"].contains(url.scheme ?? "") {
                    NSWorkspace.shared.open(url);reply(id);return
                }
                let savedKey="savedAttachment." + MediaPolicy.cacheKey(accountId:accountId,url:item["url"] as? String ?? "")
                if action == "revealAttachment",let saved=UserDefaults.standard.string(forKey:savedKey),FileManager.default.fileExists(atPath:saved) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:saved)]);reply(id);return
                }
                media.fetch(accountId:accountId,attachment:item,using:officialView) { [weak self] result in
                    guard let self else{return}
                    guard expectedAccount == self.accountId, !self.terminationRequested else{self.reply(id,error:"账号已切换或应用正在退出，附件读取已取消。");return}
                    do {
                        let asset=try result.get()
                        if action == "attachmentPreview" { self.reply(id,result:["url":try self.media.preview(asset),"name":asset.name]) }
                        else if action == "revealAttachment" {
                            NSWorkspace.shared.activateFileViewerSelecting([asset.file]);self.reply(id,result:["path":asset.file.path])
                        } else if action == "openAttachment" {
                            if let kind = AttachmentPreviewKind(rawValue: item["type"] as? String ?? "") {
                                let preview = try AttachmentPreviewController(file: asset.file, name: asset.name, kind: kind), previewId = UUID()
                                preview.onClose = { [weak self] in self?.attachmentPreviews.removeValue(forKey: previewId) }
                                self.attachmentPreviews[previewId] = preview
                                preview.present(relativeTo: self.window)
                            } else {
                                let panel=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                                panel.title=asset.name
                                if let preview=QLPreviewView(frame:panel.contentView!.bounds,style:.normal) {
                                    preview.autoresizingMask=[.width,.height];preview.previewItem=asset.file as NSURL;panel.contentView=preview
                                }
                                panel.isReleasedWhenClosed=false;self.popupWindows.append(panel);panel.center();panel.makeKeyAndOrderFront(nil)
                            }
                            self.reply(id)
                        } else {
                            let panel=NSSavePanel();panel.nameFieldStringValue=asset.name
                            panel.beginSheetModal(for:self.window) { response in
                                guard response == .OK,let destination=panel.url else{self.reply(id,result:["cancelled":true]);return}
                                self.fileOperations.enter()
                                DispatchQueue.global(qos:.userInitiated).async {
                                    do {
                                        let staging=destination.deletingLastPathComponent().appendingPathComponent(".weiyue-"+UUID().uuidString)
                                        defer { try? FileManager.default.removeItem(at:staging) }
                                        try FileManager.default.copyItem(at:asset.file,to:staging)
                                        if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:staging) }
                                        else { try FileManager.default.moveItem(at:staging,to:destination) }
                                        DispatchQueue.main.async { defer {self.fileOperations.leave()};UserDefaults.standard.set(destination.path,forKey:savedKey);self.reply(id,result:["path":destination.path]) }
                                    } catch { DispatchQueue.main.async { defer {self.fileOperations.leave()};self.reply(id,error:"保存附件失败：\(error.localizedDescription)") } }
                                }
                            }
                        }
                    } catch {self.reply(id,error:error.localizedDescription)}
                }
            case "ai":
                try requireCurrentAccount(payload)
                guard let messages = payload["messages"] as? [[String: Any]] else { throw ReaderError.message("AI 配置或材料不完整。") }
                try startAIRequest(id: id, payload: payload, messages: messages)
            case "titleDiscussion":
                try startDiscussionTitle(id: id, payload: payload)
            case "cancelDiscussionTitle":
                try requireCurrentAccount(payload)
                discussionTitles.cancel()
                reply(id)
            case "cancelAI":
                if let operation = aiBridgeOperation { flushAIProgress(operation: operation, account: accountId, generation: aiGeneration) }
                aiGeneration += 1; discussionTitles.cancel(); ai.cancel(); webSearch.cancel(); aiBridgeOperation = nil; aiProgressTask?.cancel(); aiProgressTask = nil; pendingAIProgress = nil; reply(id)
            case "copy":
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(payload["text"] as? String ?? "", forType: .string)
                reply(id)
            case "export":
                let panel = NSSavePanel(); panel.nameFieldStringValue = payload["name"] as? String ?? "微阅资料.md"
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    guard response == .OK, let url = panel.url else { self.reply(id, result: ["cancelled": true]); return }
                    do { try (payload["text"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8); NSWorkspace.shared.activateFileViewerSelecting([url]); self.reply(id,result:["path":url.path]) }
                    catch { self.reply(id, error: "导出失败：\(error.localizedDescription)") }
                }
            default: throw ReaderError.message("不支持的操作。")
            }
        } catch { reply(id, error: error.localizedDescription) }
    }

    func receiveWeibo(_ body: [String: Any]) {
        // Once the official producer is paused, close its passive observation gate
        // too. Unseen remote messages are recovered from saved cursors next launch.
        guard !freezeInboundForQuit else{return}
        if cleanupInProgress {
            if pendingCleanupRemote.count < 200 { pendingCleanupRemote.append(body) }
            return
        }
        guard let type = body["type"] as? String else { return }
        if type == "profile", let nextId = body["accountId"] as? String, !nextId.isEmpty {
            do {
                let changed = nextId != accountId
                accountName = body["name"] as? String ?? "微博账号"
                if changed {
                    let loaded = try store.load(accountId: nextId)
                    discussionTitles.cancel(); ai.cancel(); webSearch.cancel()
                    aiGeneration += 1
                    SecretStore.clearSession()
                    contentGeneration += 1
                    media.reset()
                    closeAttachmentPreviews()
                    accountId = nextId; currentState = loaded.state; lastMessages.removeAll()
                    event(["type":"account", "state":currentState, "hasAPIKey":hasAPIKey(), "accountName":accountName])
                    if let warning = loaded.warning { event(["type":"status", "text":warning]) }
                }
                liveIdentityConfirmed = true
                knownAccounts.insert(nextId)
                UserDefaults.standard.set(nextId, forKey: "lastAccountId")
                UserDefaults.standard.set(accountName, forKey: "lastAccountName")
                event(["type":"status", "text":"已连接微博 · \(accountName)。选择群聊后，已加载消息会保存在本机。"])
                let waiting = pendingRemote; pendingRemote.removeAll()
                waiting.forEach(receiveWeibo)
                scheduleSyncConfiguration()
            } catch { event(["type":"status", "text":error.localizedDescription]) }
            return
        }
        if type == "status" {
            event(["type":"status", "text":body["text"] as? String ?? "微博接入状态已更新。"])
            return
        }
        if type == "rangeProgress" {
            guard liveIdentityConfirmed, let active = rangeRequest,
                  active.accountId == accountId, body["accountId"] as? String == accountId,
                  body["requestId"] as? String == active.id, body["groupId"] as? String == active.groupId else { return }
            event(body); return
        }
        guard type == "groups" || type == "messages" || type == "sync" else { return }
        guard liveIdentityConfirmed else {
            if pendingRemote.count < 30 { pendingRemote.append(body) }
            return
        }
        guard body["accountId"] as? String == accountId else {
            event(["type":"status", "text":"账号身份尚未匹配，此批消息未归档。请刷新官方页面重新确认登录。"])
            return
        }
        let payload = body
        if type == "messages", let group = body["groupId"] as? String {
            // Keep every page already observed in this login session, so enabling
            // local saving after scrolling history does not import only its last page.
            var cached = lastMessages[group]?["messages"] as? [[String: Any]] ?? []
            var positions: [String: Int] = [:]
            for (index, item) in cached.enumerated() {
                if let id = item["id"] as? String { positions[id] = index }
            }
            for item in body["messages"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                if let index = positions[id] { cached[index] = item }
                else { positions[id] = cached.count; cached.append(item) }
            }
            var merged = payload; merged["messages"] = cached
            lastMessages[group] = merged
        }
        event(payload)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if webView === localView {
            if url.isFileURL && url.standardizedFileURL == localIndex.standardizedFileURL { decisionHandler(.allow) }
            else if navigationAction.navigationType == .linkActivated && ["https","http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
            else { decisionHandler(.cancel) }
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if ["https", "http", "about", "blob"].contains(url.scheme ?? "") { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === officialView {
            event(["type":"status", "text":liveIdentityConfirmed ? "官方聊天已就绪。阅读资料以已加载消息为准。" : "请在官方页面扫码登录。登录仅由微博处理。"])
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === officialView {
            liveIdentityConfirmed = false
            syncConfigurationTask?.cancel()
            pendingRemote.removeAll()
            lastMessages.removeAll()
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { event(["type":"status", "text":"页面暂未加载成功，可点击刷新。\(error.localizedDescription)"]) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        event(["type":"status", "text":"网页进程已退出，已保存的标记仍在本机。请刷新恢复页面。"])
        if webView === localView { uiReady = false; localView.reload() }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView !== localView else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self; popup.uiDelegate = self
        let panel = NSWindow(contentRect: NSRect(x:0,y:0,width:1000,height:760), styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title = "微博"; panel.contentView = popup; panel.center(); panel.makeKeyAndOrderFront(nil)
        panel.isReleasedWhenClosed = false; popupWindows.append(panel)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: webView.window ?? window) { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = webView === localView ? "微阅" : "微博网页提示"; alert.informativeText = message
        alert.addButton(withTitle:"好"); alert.beginSheetModal(for:webView.window ?? window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = "确认操作"; alert.informativeText = message
        alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:webView.window ?? window) { result in completionHandler(result == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt
        let input = NSTextField(string: defaultText ?? ""); input.frame = NSRect(x:0,y:0,width:320,height:26)
        alert.accessoryView = input; alert.addButton(withTitle:"确定"); alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:webView.window ?? window) { result in completionHandler(result == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath:suggestedFilename).lastPathComponent
        panel.beginSheetModal(for:window) { result in completionHandler(result == .OK ? panel.url : nil) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        event(["type":"status", "text":"下载未完成：\(error.localizedDescription)"])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !terminationRequested, let window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationRequested { return .terminateLater }
        terminationRequested = true
        closeAttachmentPreviews()
        contentGeneration += 1
        aiGeneration += 1
        discussionTitles.cancel(); ai.cancel(); webSearch.cancel()
        guard uiReady else {
            fileOperations.notify(queue:.main) { NSApp.reply(toApplicationShouldTerminate:true) }
            return .terminateLater
        }
        syncConfigurationTask?.cancel()
        officialView.evaluateJavaScript("window.__weiboReaderSync?.pause()") { [weak self] _, _ in self?.freezeInboundForQuit=true;self?.flushAndTerminate() }
        return .terminateLater
    }
    func flushAndTerminate() {
        localView.callAsyncJavaScript("if (!window.flushBeforeQuit) throw new Error('保存尚未就绪'); await window.flushBeforeQuit({quitting:true});", arguments:[:], in:nil, in:.page) { [weak self] result in
            guard let self else { NSApp.reply(toApplicationShouldTerminate:true); return }
            if case .failure = result {
                let alert = NSAlert(); alert.messageText = "最近的修改尚未确认保存"
                alert.informativeText = "留在应用中可以重试保存，已保存的阅读标记仍保留。"
                alert.addButton(withTitle:"留在应用"); alert.addButton(withTitle:"仍然退出")
                let quit = alert.runModal() == .alertSecondButtonReturn
                self.terminationRequested = quit
                if !quit {
                    self.freezeInboundForQuit=false
                    self.localView.evaluateJavaScript("window.resumeAfterCancelledQuit?.()",completionHandler:nil)
                    self.officialView.evaluateJavaScript("window.__weiboReaderSync?.resume()",completionHandler:nil);self.scheduleSyncConfiguration()
                }
                if quit { self.fileOperations.notify(queue:.main) { NSApp.reply(toApplicationShouldTerminate:true) } }
                else { NSApp.reply(toApplicationShouldTerminate:false) }
            } else { self.fileOperations.notify(queue:.main) { NSApp.reply(toApplicationShouldTerminate:true) } }
        }
    }
}

@main struct Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
