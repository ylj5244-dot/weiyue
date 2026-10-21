import AppKit
import WebKit

// Synthetic account, 6,000+ messages and in-memory persistence/RPC only.
// All remote subresources, fetches and navigations are blocked. Images are
// generated locally and served only through the test's weiyue-media scheme.
@main final class ReadingRefinementUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!
    var state: [String: Any] = [:], calls: [[String: Any]] = [], images: [String: Data] = [:]
    var heldSaves: [(Any, [String: Any])] = [], saveMode = "success", autoMode = "success"
    var preview: [String: Any] = [:], finished = false
    var appearances: ReadingAppearanceStore!, phase = 0, phaseResult = ""
    let account = "synthetic-v111", timestamp = "2026-10-21T01:00:00Z"
    static func main() {
        let app = NSApplication.shared, delegate = ReadingRefinementUIHarness()
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { print("FAIL: v111 UI process watchdog"); fflush(stdout); exit(1) }
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-v111-ui-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            appearances = try ReadingAppearanceStore(directory: temp.appendingPathComponent("synthetic-appearance"))
            state = fixture()
            images["wide"] = makeImage(960, 320, "WIDE 3:1", .systemTeal)
            images["long-scroll"] = makeImage(300, 3600, "LONG 1:12", .systemIndigo)
            images["tall"] = makeImage(240, 720, "TALL 1:3", .systemOrange)
            images["multi-a"] = makeImage(640, 400, "MULTI 8:5", .systemBlue)
            images["multi-b"] = makeImage(300, 600, "MULTI 1:2", .systemPurple)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name: "app")
            configuration.setURLSchemeHandler(self, forURLScheme: "weiyue-media")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('Network disabled in v111 UI tests'));window.XMLHttpRequest=function(){throw Error('Network disabled in v111 UI tests');};window.WebSocket=function(){throw Error('Network disabled in v111 UI tests');};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "weiyue-v111-offline-" + UUID().uuidString, encodedContentRuleList: rules) { list, error in
                guard let list else { self.finish(false, error?.localizedDescription ?? "offline resource rule failed"); return }
                configuration.userContentController.add(list)
                self.web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1488, height: 1000), configuration: configuration)
                self.web.navigationDelegate = self
                self.window = NSWindow(contentRect: self.web.frame, styleMask: [.titled], backing: .buffered, defer: false)
                self.window.contentView = self.web; self.window.ignoresMouseEvents = true
                self.window.appearance = NSAppearance(named: .aqua)
                self.window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); self.window.orderBack(nil)
                self.web.loadFileURL(self.temp.appendingPathComponent("index.html"), allowingReadAccessTo: self.temp)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 150) { self.finish(false, "v111 UI timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func makeImage(_ width: Int, _ height: Int, _ title: String, _ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus(); color.withAlphaComponent(0.23).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        color.setStroke(); let line = NSBezierPath(rect: NSRect(x: 10, y: 10, width: width - 20, height: height - 20)); line.lineWidth = 5; line.stroke()
        (title as NSString).draw(at: NSPoint(x: 18, y: height / 2), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    func fixture() -> [String: Any] {
        func message(_ id: String, _ text: String, _ attachments: [[String: Any]] = [], _ index: Int) -> [String: Any] {
            ["accountId": account, "groupId": "g", "id": id, "senderId": "member-\(index % 3)", "senderName": "合成验收成员 \(index % 3 + 1)", "sentAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_792_300_000 + Double(index * 60))), "text": text, "attachments": attachments]
        }
        func attachment(_ type: String, _ name: String, _ file: String) -> [String: Any] { ["type": type, "name": name, "url": "https://synthetic.invalid/" + file] }
        var messages = (0..<6000).map { message("m\($0)", "合成历史消息 \($0) · 用于六千条本地记录的交互验收。", [], $0) }
        for (index, sender, name, group) in [(5980,"follow-A","林晓","g"),(5981,"follow-A","林晓（新昵称）","g2"),(5982,"same-name-unfollowed","林晓","g2"),(5983,"follow-B","另一关注成员","g2"),(5984,"follow-A","林晓","g"),(5985,"unfollowed-B","另一关注成员","g2")] {
            messages[index]["senderId"] = sender; messages[index]["senderName"] = name; messages[index]["groupId"] = group
            messages[index]["text"] = "关注视图合成记录 \(index)：稳定成员 ID \(sender)"
        }
        for (index, sender, name, text) in [
            (5960,"width-short","短句成员","短句。"),
            (5961,"width-long","长段成员",String(repeating: "长段文字用于验证背景宽度跟随内容，并在阅读栏边界自然换行，不出现横向溢出。", count: 7)),
            (5962,"width-group","连续宽度成员","简短回复。"),
            (5963,"width-group","连续宽度成员","中间这一条稍长，用来检查连续发言的边缘。"),
            (5964,"width-group","连续宽度成员","同一个人连续发言的三条消息应该沿用一组宽度，由最长的一条决定，并随字号与阅读栏宽度调整。"),
            (5965,"width-medium","中等成员","中等长度的一段文字，用来确认字体变化时背景宽度能够跟着改变。"),
            (5970,"follow-C","重点连续成员","关注连续发言第一条。"),
            (5971,"follow-C","重点连续成员","关注连续发言第二条。"),
            (5972,"follow-C","重点连续成员","关注连续发言第三条。"),
            (5974,"withdrawal-notice","普通账号","张三撤回了一条消息"),
            (5975,"withdrawal-notice","普通账号","你撤回了一条消息。"),
            (5976,"withdrawal-discussion","讨论成员","昨天他撤回了一条消息，我想了解原因。"),
            (5977,"withdrawal-question","提问成员","撤回功能怎么使用？"),
            (5978,"emoji-member","表情成员","表情验证：[二哈] [哈哈] [/ee9092.png] [未知表情V111] [项目A] 原始标记保留。")
        ] { messages[index]["senderId"] = sender; messages[index]["senderName"] = name; messages[index]["text"] = text }
        messages[5966] = message("m5966", "长图缩略图验收", [attachment("image", "long-scroll", "long-scroll.png")], 5966)
        messages[5990] = message("m5990", "合成视频检索", [attachment("video", "FILTER_Research_2026.mp4", "movie-needle.mp4")], 5990)
        for (index, name, sender, sentAt) in [(5991,"FILTER_Report_Alpha.pdf","filter-member","2026-10-20T03:00:00Z"),(5992,"FILTER_Report_Old.pdf","filter-member","2026-10-18T03:00:00Z"),(5993,"FILTER_Report_Other.pdf","other-filter-member","2026-10-20T04:00:00Z")] {
            messages[index] = message("m\(index)", "文件检索合成记录", [attachment("document", name, "report-needle-\(index).pdf")], index)
            messages[index]["senderId"] = sender; messages[index]["senderName"] = "检索成员 " + sender; messages[index]["sentAt"] = sentAt
        }
        messages[5994]["text"] = "仅正文中的链接 https://synthetic.invalid/plain-link-needle"
        messages[5995]["senderId"] = account; messages[5995]["senderName"] = "同名用户"; messages[5995]["text"] = "自己发言：按稳定 ID 靠右显示。"
        messages[5996]["senderId"] = "lookalike-not-me"; messages[5996]["senderName"] = "同名用户"; messages[5996]["text"] = "同名的其他人：仍靠左显示。"
        for index in 5997...5999 { messages[index]["senderId"] = "spacing-person"; messages[index]["senderName"] = "连续发言验收"; messages[index]["text"] = "连续发言 \(index - 5996) · 五档实际间距验收。" }
        messages += [
            message("action-target", "书签与从这里阅读：此消息仅用于保存延迟和失败恢复验收。", [], 6000),
            message("wide", "横图 · 原始比例 3:1", [attachment("image", "wide", "wide.png")], 6001),
            message("tall", "竖图 · 原始比例 1:3", [attachment("image", "tall", "tall.png")], 6002),
            message("multi", "多图 · 两张不同原始比例", [attachment("image", "multi-a", "multi-a.png"), attachment("image", "multi-b", "multi-b.png")], 6003),
            message("doc", "合成文档_长文件名称用于核验右栏预览和紧凑文件行不会水平溢出或互相遮挡.pdf", [attachment("document", "合成文档_长文件名称用于核验右栏预览和紧凑文件行不会水平溢出或互相遮挡.pdf", "report.pdf")], 6004),
            message("link", "合成网页 · 右侧独立浏览器验收", [attachment("link", "合成网页 · 右侧独立浏览器验收", "article")], 6005)
        ]
        let anchor: [String: Any] = ["accountId": account, "groupId": "g", "messageId": "action-target", "messageSentAt": messages[6000]["sentAt"]!, "updatedAt": timestamp, "offset": 0]
        let discussion: [String: Any] = ["accountId": account, "id": "existing", "title": "原有讨论必须保留", "createdAt": timestamp, "instructions": "保留原讨论", "contextSnapshots": [messages[5999]], "messages": [["role": "user", "content": "OLD_DISCUSSION_QUESTION", "createdAt": timestamp], ["role": "assistant", "content": "OLD_DISCUSSION_ANSWER", "createdAt": timestamp]]]
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "1.0.11 合成验收 · 6006 条", "selected": true],["accountId":account,"id":"g2","name":"第二合成群 · 跨群关注","selected":true]], "messages": messages, "bookmarks": [], "collections": [], "discussions": [discussion], "progress": ["g": ["auto": anchor]], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic-model", "readMode": "text", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "existing", "followedMembers":[["senderId":"follow-A","name":"林晓"],["senderId":"follow-B","name":"另一关注成员"],["senderId":"follow-C","name":"重点连续成员"]]]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func reject(_ id: Any, _ message: String) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": false, "error": message]) + ")", completionHandler: nil) }
    func publish() { web.evaluateJavaScript("window.__calls=" + json(calls) + ";window.__heldSaves=\(heldSaves.count);", completionHandler: nil) }
    func commit(_ id: Any, _ candidate: [String: Any]) { state = candidate; reply(id, ["revision": candidate["revision"] ?? 0]) }
    func attachment(_ payload: [String: Any]) -> [String: Any] {
        let messages = state["messages"] as? [[String: Any]] ?? []
        guard let message = messages.first(where: { $0["id"] as? String == payload["messageId"] as? String && $0["groupId"] as? String == payload["groupId"] as? String }),
              let attachments = message["attachments"] as? [[String: Any]], let index = payload["attachmentIndex"] as? Int, attachments.indices.contains(index) else { return [:] }
        return attachments[index]
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        switch action {
        case "ready": publish(); reply(id, ["state": state, "hasAPIKey": true, "accountName": "离线合成验收", "appearance": "light", "readingAppearance": appearances.snapshot()])
        case "save":
            guard let candidate = payload["state"] as? [String: Any], candidate["accountId"] as? String == account else { finish(false, "unexpected non-synthetic save"); return }
            calls.append(["action": action, "revision": candidate["revision"] ?? 0, "autoCleanup": (candidate["settings"] as? [String: Any])?["autoCleanup"] ?? NSNull()])
            if saveMode == "hold" { heldSaves.append((id, candidate)); publish() }
            else if saveMode == "fail-next" { saveMode = "success"; publish(); reject(id, "SYNTHETIC_SAVE_FAILURE") }
            else { publish(); commit(id, candidate) }
        case "aiCapabilities": reply(id, ["thinking": false, "canDisableThinking": false])
        case "keyStatus": reply(id, ["hasAPIKey": true])
        case "saveReadingAppearance":
            do { reply(id, try appearances.save(payload["preferences"] as! [String: Any])) } catch { reject(id, error.localizedDescription) }
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.appendingPathComponent("synthetic-attachments").path])
        case "storageUsage":
            calls.append(["action": action]); publish()
            reply(id, ["totalBytes": 7 * 1_048_576, "fileCount": 42, "categories": [["id": "records", "name": "聊天记录与设置", "bytes": 1_048_576], ["id": "attachments", "name": "图片与文档缓存", "bytes": 4 * 1_048_576], ["id": "recovery", "name": "备份与恢复副本", "bytes": 2 * 1_048_576]]])
        case "autoCleanup":
            calls.append(["action": action, "payload": payload]); publish()
            if autoMode == "fail-next" { autoMode = "success"; reject(id, "SYNTHETIC_AUTO_CLEANUP_FAILURE"); return }
            var settings = state["settings"] as! [String: Any], preference = settings["autoCleanup"] as! [String: Any]
            preference["lastRunAt"] = ISO8601DateFormatter().string(from: Date()); preference["lastRemovedCount"] = 0; preference["lastFreedBytes"] = 0; preference["lastError"] = ""
            settings["autoCleanup"] = preference; state["settings"] = settings; state["revision"] = (state["revision"] as? Int ?? 0) + 1
            reply(id, ["state": state, "removedCount": 0, "freedBytes": 0])
        case "attachmentPreview":
            let expected = attachment(payload), name = expected["name"] as? String ?? ""
            guard images[name] != nil else { finish(false, "unknown synthetic image: " + name); return }
            reply(id, ["url": "weiyue-media://synthetic/" + name])
        case "previewContent":
            let attachment = attachment(payload)
            preview = ["kind": attachment["type"] ?? "link", "title": attachment["name"] ?? "合成预览", "url": attachment["url"] ?? "", "canGoBack": true, "canGoForward": true, "loading": false, "error": "", "readingEnabled": true, "readingAdapted": true, "canToggleReading": attachment["type"] as? String == "link"]
            calls.append(["action": action, "payload": payload]); publish(); reply(id, preview)
        case "contentPreviewAction":
            if let operation = payload["operation"] as? String, ["reading", "original"].contains(operation) { preview["readingEnabled"] = operation == "reading"; preview["readingAdapted"] = operation == "reading" }
            calls.append(["action": action, "payload": payload]); publish(); reply(id, preview)
        case "copy": calls.append(["action": action, "payload": payload]); publish(); reply(id)
        case "closeContentPreview", "previewLayout": calls.append(["action": action, "payload": payload]); publish(); reply(id)
        case "qaModes": saveMode = payload["save"] as? String ?? saveMode; autoMode = payload["auto"] as? String ?? autoMode; reply(id)
        case "qaReleaseSave":
            let pending = heldSaves; heldSaves = []; saveMode = "success"; publish()
            for (request, candidate) in pending { if payload["fail"] as? Bool == true { reject(request, "SYNTHETIC_SAVE_FAILURE") } else { commit(request, candidate) } }; reply(id)
        case "qaInspect":
            reply(id, ["messageCount": (state["messages"] as? [Any])?.count ?? 0, "settings": state["settings"] ?? [:], "bookmarks": state["bookmarks"] ?? [], "progress": state["progress"] ?? [:], "discussions": state["discussions"] ?? [], "readingAppearance": appearances.snapshot(), "includeWidths": !CommandLine.arguments.contains("--core-only")])
        case "qaResize":
            window.setContentSize(NSSize(width: payload["width"] as? Double ?? 1488, height: payload["height"] as? Double ?? 1000)); web.setFrameSize(window.contentView!.bounds.size); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); reply(id)
        case "qaRefreshGroup":
            var refreshed = (state["messages"] as! [[String: Any]]).first { $0["id"] as? String == "m5971" }!
            refreshed["text"] = (refreshed["text"] as? String ?? "") + "〔合成刷新〕"
            web.evaluateJavaScript("window.onNativeEvent(" + json(["type":"messages","accountId":account,"groupId":"g","messages":[refreshed],"messageSource":"live"]) + ")", completionHandler: nil); reply(id)
        case "qaSnapshot": snapshot(payload["name"] as? String ?? "") { success in if success { self.reply(id) } }
        case "ai", "titleDiscussion", "aiDiscussionTitle", "webSearch", "testAI", "saveKey", "authorizeAI", "openExternal", "openAttachment", "listModels", "importDocument", "downloadAttachment", "revealAttachment": finish(false, "unexpected external action: " + action)
        default: reply(id)
        }
    }
    func snapshot(_ name: String, _ completion: @escaping (Bool) -> Void) {
        guard name.hasPrefix("v111-"), !name.contains("/") else { finish(false, "invalid screenshot name"); return }
        web.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { self.finish(false, error?.localizedDescription ?? "snapshot conversion failed"); return }
            do { try data.write(to: self.output.appendingPathComponent(name + ".png")); completion(true) }
            catch { self.finish(false, error.localizedDescription) }
        }
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!, name = url.lastPathComponent
        guard let data = images[name] else { urlSchemeTask.didFailWithError(ReaderHarnessError.missingImage); return }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.callAsyncJavaScript(self.phase == 0 ? Self.tests : Self.reloadTests, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                if self.phase == 0 { self.phaseResult = String(describing: value); self.phase = 1; self.web.reload() }
                else {
                    var combined = (try? JSONSerialization.jsonObject(with: Data(self.phaseResult.utf8))) as? [String: Any] ?? [:]
                    let reload = (try? JSONSerialization.jsonObject(with: Data(String(describing: value).utf8))) as? [String: Any] ?? [:]
                    combined["reload"] = reload
                    combined["mainAssertions"] = combined["assertions"]
                    combined["assertions"] = (combined["assertions"] as? Int ?? 0) + (reload["assertions"] as? Int ?? 0)
                    self.finish(true, self.json(combined))
                }
            case .failure(let error):
                self.snapshot("v111-failure") { _ in
                    self.web.evaluateJavaScript("JSON.stringify({observations:window.__observations,errors:window.__errors,calls:window.__calls,body:document.body.innerText.slice(-2000)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
                }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) {
        guard !finished else { return }; finished = true
        if let output { try? Data(result.utf8).write(to: output.appendingPathComponent(success ? "v111-refinement-ui-results.json" : "v111-refinement-ui-failure.txt")) }
        print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout)
        if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1)
    }
    enum ReaderHarnessError: Error { case missingImage }
    static let tests = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms));
window.__observations={assertions:0,section:'startup',screenshots:[],layouts:[],spacing:[],bubbleWidths:[],attachments:[],performance:{fontChanges:[],nativeMessages:[]}};
const originalNativeEvent=window.onNativeEvent;window.onNativeEvent=function(event){const started=performance.now();try{return originalNativeEvent(event);}finally{if(event?.type==='messages')__observations.performance.nativeMessages.push({duration:performance.now()-started,messages:event.messages?.length||0});}};
const assert=(value,label)=>{__observations.assertions++;if(!value)throw Error(label);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let sequence=0;const pending=new Map(),receive=window.nativeReceive;
window.nativeReceive=response=>{const resolve=pending.get(response.id);if(resolve){pending.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='v111-qa-'+(++sequence);pending.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const calls=action=>(window.__calls||[]).filter(c=>c.action===action);
const rect=el=>{const r=el.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};};
const shown=el=>!!el&&!el.hidden&&getComputedStyle(el).display!=='none'&&getComputedStyle(el).visibility!=='hidden'&&rect(el).width>0&&rect(el).height>0;
const inside=(a,b,t=1)=>a.left>=b.left-t&&a.right<=b.right+t&&a.top>=b.top-t&&a.bottom<=b.bottom+t;
const overlaps=(a,b)=>Math.min(a.right,b.right)-Math.max(a.left,b.left)>.7&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>.7;
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]');
const mountedIds=()=>[...$('messages').querySelectorAll('.message-card')].map(c=>c.dataset.messageId).sort();
const expectIds=(ids,label)=>assert(JSON.stringify(mountedIds())===JSON.stringify(ids.slice().sort()),label+': '+JSON.stringify(mountedIds()));
const expectAllIds=async(ids,label)=>{const seen=new Set(),scroll=$('reader-scroll');for(const fraction of [0,.5,1]){scroll.scrollTop=(scroll.scrollHeight-scroll.clientHeight)*fraction;await sleep(140);mountedIds().forEach(id=>seen.add(id));}assert(Number.parseInt($('result-count').textContent,10)===ids.length,label+' result count');assert(JSON.stringify([...seen].sort())===JSON.stringify(ids.slice().sort()),label+': '+JSON.stringify([...seen]));};
const flush=async()=>{await window.flushBeforeQuit();await sleep(50);};
const shot=async name=>{const file='v111-'+name;await qa('qaSnapshot',{name:file});__observations.screenshots.push(file+'.png');};
const input=(id,value)=>{$(id).value=value;$(id).dispatchEvent(new Event('input',{bubbles:true}));};
const query=async value=>{input('message-search',value);await sleep(220);};
const type=async value=>{document.querySelector('[data-message-type="'+value+'"]').click();await sleep(150);};
const audience=async value=>{document.querySelector('[data-reader-audience="'+value+'"]').click();await sleep(150);};
const reset=async()=>{if(!$('clear-filters').hidden)$('clear-filters').click();await sleep(100);};
const jump=async(id,groupId='g')=>{window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId,messageId:id}}));await wait(()=>card(id),'mount '+id);card(id).scrollIntoView({block:'center'});await sleep(180);};
const font=async size=>{$('font-button').value=String(size);const started=performance.now();$('font-button').dispatchEvent(new Event('change',{bubbles:true}));__observations.performance.fontChanges.push({size,synchronousDuration:performance.now()-started});await sleep(200);};
const fitReader=async width=>{await qa('qaResize',{width:1488,height:1000});ReaderLayout.reset();await sleep(180);for(let n=0;n<3;n++){const difference=width-rect($('reader-area')).width;if(Math.abs(difference)<1)break;await qa('qaResize',{width:window.innerWidth+difference,height:1000});await sleep(180);}assert(Math.abs(rect($('reader-area')).width-width)<2,'reading pane reaches '+width+'px: '+JSON.stringify(ReaderLayout.getState()));};
const tabs=()=>[...document.querySelectorAll('[data-settings-category]')];
const panelIds={reading:'reading-appearance-dialog',followed:'reader-personalization-dialog',preferences:'preferences-dialog',ai:'settings-form',storage:'storage-dialog'};
const category=async key=>{document.querySelector('[data-settings-category="'+key+'"]').click();await wait(()=>document.querySelector('[data-settings-category="'+key+'"]').getAttribute('aria-selected')==='true'&&shown($(panelIds[key])),'settings category '+key);await sleep(80);};
const openSettings=async key=>{$('settings-button').click();await wait(()=>$('settings-dialog').open,'settings opens');if(key)await category(key);};
const doneSettings=async()=>{await category('reading');$('done-reading-appearance').click();await wait(()=>!$('settings-dialog').open,'complete closes settings');await sleep(100);assert(document.querySelectorAll('dialog[open]').length===0,'complete closes every embedded dialog');};
await wait(()=>card('action-target')&&window.ReaderLayout&&window.__calls,'synthetic fixture');await flush();
const initial=await qa('qaInspect');assert(initial.messageCount===6006,'archive contains 6006 synthetic messages');assert(document.querySelectorAll('.message-card').length<200,'large archive remains virtualized');assert(!$('nav-followed')&&!$('followed-scope'),'global followed navigation and cross-group selector are absent');
assert($('conversation-messages').textContent.includes('OLD_DISCUSSION_QUESTION'),'original discussion restored');
__observations.scope=initial.includeWidths?'complete':'core-only';

__observations.section='compact search and message types';
assert([...document.querySelectorAll('[data-message-type]')].map(b=>b.dataset.messageType).join(',')==='all,link,image,document,video','five message type controls present');
for(const width of [926,560,430]){
  await fitReader(width);const pane=rect($('reader-area')),row=document.querySelector('.reader-search-row')||document.querySelector('.reader-tools'),search=rect(document.querySelector('.message-search')),buttons=[...document.querySelectorAll('[data-message-type]')].map(rect);
  assert(search.width>=80&&search.width<=281,'compact search has useful bounded width at '+width);
  for(const b of buttons)assert(Math.abs((b.top+b.bottom-search.top-search.bottom)/2)<2,'search and every type share one row at '+width);
  assert(row.scrollWidth<=row.clientWidth+1,'search row has no horizontal overflow at '+width);
  assert(search.left>=pane.left&&buttons.at(-1).right<=pane.right,'all search controls stay in pane at '+width);
  assert(document.documentElement.scrollWidth<=window.innerWidth+1,'window has no horizontal overflow at '+width);
  __observations.layouts.push({width:rect($('reader-area')).width,search,buttons,layout:ReaderLayout.getState()});await shot('search-row-'+width);
}
await fitReader(560);
for(const [value,ids] of [['link',['m5994','link']],['image',['m5966','wide','tall','multi']],['document',['m5991','m5992','m5993','doc']],['video',['m5990']]]){await type(value);await expectAllIds(ids,'type '+value+' finds exact local messages');}
await type('document');await query('report-needle');expectIds(['m5991','m5992','m5993'],'URL query combines with type');await reset();

__observations.section='current group followed and continuation';
const progressBefore=JSON.stringify((await qa('qaInspect')).progress);await audience('followed');expectIds(['m5970','m5971','m5972','m5980','m5984'],'followed filter includes only current group');
assert([...$('messages').querySelectorAll('.message-card')].every(c=>c.dataset.groupId==='g'),'no other group appears in current-group followed mode');
const first=card('m5970'),followCards=['m5970','m5971','m5972'].map(card);
assert(shown(first.querySelector('.message-heading'))&&shown(first.querySelector('.message-name'))&&shown(first.querySelector('.reader-followed-badge')),'first followed message shows name and badge');
for(const c of followCards.slice(1)){assert(c.classList.contains('continuation'),'same followed sender forms continuation');assert(!shown(c.querySelector('.message-heading'))&&!shown(c.querySelector('.message-name'))&&!shown(c.querySelector('.reader-followed-badge')),'continuation hides all repeated heading content');assert(shown(c.querySelector('.message-body')),'continuation body stays visible');}
assert(followCards.every(c=>c.classList.contains('reader-followed')),'every continuation row carries followed emphasis');
const followColors=followCards.map(c=>getComputedStyle(c).backgroundColor);assert(new Set(followColors).size===1,'followed background is consistent across its whole group');
assert(followCards.every(c=>getComputedStyle(c).boxShadow!=='none'),'whole followed group retains accent');await shot('followed-continuation');
await query('关注连续');expectIds(['m5970','m5971','m5972'],'followed audience combines with search');await query('');
await qa('qaResize',{width:1122,height:460});await sleep(180);card('m5971').scrollIntoView({block:'start'});await sleep(120);$('reader-scroll').scrollTop+=rect(card('m5971')).top-rect($('reader-scroll')).top+12;await sleep(160);
const anchor=()=>{const top=rect($('reader-scroll')).top,c=[...$('messages').querySelectorAll('.message-card')].find(c=>rect(c).bottom>top+15);return{id:c?.dataset.messageId,group:c?.dataset.groupId,offset:c?rect(c).top-top:0};};
const before=anchor();assert(before.id==='m5971','followed continuation is the visible anchor');await font(18);const afterFont=anchor();assert(afterFont.id===before.id&&afterFont.group===before.group&&Math.abs(afterFont.offset-before.offset)<2,'font change preserves followed continuation anchor');
await qa('qaRefreshGroup');await wait(()=>card('m5971')?.textContent.includes('合成刷新'),'synthetic message refreshed');await sleep(180);const afterRefresh=anchor();assert(afterRefresh.id===before.id&&afterRefresh.group===before.group&&Math.abs(afterRefresh.offset-before.offset)<2,'message refresh preserves followed continuation anchor');await flush();assert(JSON.stringify((await qa('qaInspect')).progress)===progressBefore,'filtered reading never replaces ordinary group progress');__observations.followed={firstHeading:true,continuationsHidden:true,groupBackground:followColors[0],before,afterFont,afterRefresh};
await font(14);await fitReader(560);await audience('all');await jump('m5981','g2');await audience('followed');expectIds(['m5981','m5983'],'second group followed mode stays inside second group');assert(card('m5981').textContent.includes('新昵称'),'stable followed identity survives nickname changes');await audience('all');await jump('m5976');

__observations.section='withdrawal and local emoticons';
await query('撤回');expectIds(['m5976','m5977'],'complete withdrawal notices hidden while discussion of withdrawal remains');assert(!$('messages').textContent.includes('张三撤回了一条消息'),'withdrawal notification text absent from reading area');await shot('withdrawal-discussion-preserved');await reset();
await query('表情验证');expectIds(['m5978'],'emoticon fixture found');const body=card('m5978').querySelector('.message-body');await wait(()=>body.querySelectorAll('img.reader-emoticon').length===2&&[...body.querySelectorAll('img')].every(img=>img.complete&&img.naturalWidth>0),'local emoticons decoded');
const icons=[...body.querySelectorAll('img.reader-emoticon')];assert(icons.some(img=>img.alt==='[二哈]'&&img.src.endsWith('2018new_erha_org.png')),'[二哈] uses its actual local image');assert(icons.every(img=>new URL(img.src).protocol==='file:'),'emoticons load from bundled files');assert(body.textContent.includes('[未知表情V111]')&&body.textContent.includes('[项目A]'),'unknown bracket strings remain unchanged');
assert(body.querySelector('.reader-legacy-emoticon')?.textContent==='😂'&&body.querySelector('.reader-legacy-emoticon')?.getAttribute('aria-label')==='[/ee9092.png]','legacy encoded emoticon maps to its Unicode face');
card('m5978').querySelector('.message-copy-action').click();await wait(()=>calls('copy').length===1,'copy intercepted');assert(calls('copy')[0].payload.text==='表情验证：[二哈] [哈哈] [/ee9092.png] [未知表情V111] [项目A] 原始标记保留。','copy retains every original bracket marker');__observations.emoticons=icons.map(img=>({alt:img.alt,naturalWidth:img.naturalWidth,naturalHeight:img.naturalHeight,box:rect(img)}));await shot('local-emoticons');await reset();

__observations.section='settings navigation and drafts';
await openSettings('reading');assert(tabs().map(b=>b.dataset.settingsCategory).join(',')==='reading,followed,preferences,ai,storage','five settings categories in specified order');
const nav=document.querySelector('.settings-navigation'),host=$('settings-panels');assert(rect(nav).right<=rect(host).left+1,'navigation stays left of settings content');
for(const key of Object.keys(panelIds)){
  await category(key);const p=$(panelIds[key]);assert(p.parentElement===host,'panel '+key+' embedded inside shared dialog');assert($('settings-dialog').contains(p),'panel '+key+' belongs to settings');assert(Object.keys(panelIds).filter(other=>shown($(panelIds[other]))).join(',')===key,'only selected settings panel is visible: '+key);assert(inside(rect(p),rect(host)),'panel '+key+' remains inside right content area');assert(document.querySelectorAll('dialog:modal').length===1&&$('settings-dialog').matches(':modal'),'only outer settings is modal: '+key);await shot('settings-'+key);
}
const cleanupRoundTrip=async()=>{await category('storage');$('open-cleanup').click();await wait(()=>$('cleanup-dialog').open&&$('settings-dialog').open,'cleanup opens above the retained settings session');assert($('cleanup-dialog').matches(':modal')&&$('settings-dialog').matches(':modal'),'cleanup is modal above existing settings');assert(shown($('cleanup-back')),'cleanup offers return to storage');$('cleanup-back').click();await wait(()=>$('settings-dialog').open&&shown($('storage-dialog'))&&!$('cleanup-dialog').open,'cleanup returns to embedded storage');assert(document.querySelector('[data-settings-category="storage"]').getAttribute('aria-selected')==='true','cleanup return selects storage category');};
await cleanupRoundTrip();
await category('ai');input('api-base-url','https://draft-v111.invalid/v1');input('api-model','draft-v111-model');assert($('api-key').value==='','no credential supplied');
await category('followed');input('reader-follow-id','follow-draft-v111');input('reader-follow-name','草稿关注验收');$('reader-follow-add').click();assert(!!document.querySelector('#reader-followed-list [data-sender-id="follow-draft-v111"]'),'followed unsaved draft added');
await category('preferences');$('preference-add').click();input('preference-title','跨分类草稿');input('preference-content','仅用于离线验收：请保留完整段落。');
await category('storage');await wait(()=>$('storage-total').textContent==='7.0 MB','embedded storage usage');await cleanupRoundTrip();
await category('ai');assert($('api-base-url').value==='https://draft-v111.invalid/v1'&&$('api-model').value==='draft-v111-model','AI draft survives switching panels and manual cleanup return');
await category('followed');assert(!!document.querySelector('#reader-followed-list [data-sender-id="follow-draft-v111"]'),'unsaved followed draft survives manual cleanup return');
await category('preferences');assert($('preference-title').value==='跨分类草稿'&&$('preference-content').value==='仅用于离线验收：请保留完整段落。','unsaved preference draft survives manual cleanup return');
await category('followed');assert(!!document.querySelector('#reader-followed-list [data-sender-id="follow-draft-v111"]'),'followed draft survives category changes');$('reader-follow-save').click();await wait(()=>!$('reader-follow-save').disabled||$('reader-follow-status').textContent==='已保存','followed save completes');await flush();assert((await qa('qaInspect')).settings.followedMembers.some(m=>m.senderId==='follow-draft-v111'),'followed draft persisted');assert($('settings-dialog').open&&shown($('reader-personalization-dialog')),'followed save stays in current panel');
await category('preferences');assert($('preference-title').value==='跨分类草稿'&&$('preference-content').value==='仅用于离线验收：请保留完整段落。','preference draft survives category changes');$('preferences-save').click();await wait(()=>!$('preferences-save').disabled,'preference save completes');await flush();assert((await qa('qaInspect')).settings.aiPreferences.entries.some(item=>item.title==='跨分类草稿'),'preference draft persisted');assert($('settings-dialog').open&&shown($('preferences-dialog')),'preference save stays in current panel');
await category('ai');assert($('api-base-url').value==='https://draft-v111.invalid/v1'&&$('api-model').value==='draft-v111-model','saving other panels does not replace AI draft');await shot('settings-ai-draft-retained');await doneSettings();
await openSettings('followed');assert(!document.querySelector('#reader-followed-list [data-sender-id="follow-draft-v111"] button').disabled,'saved followed member can be edited after reopening');input('reader-follow-id','follow-reopened-v111');input('reader-follow-name','重开再编辑');$('reader-follow-add').click();$('reader-follow-save').click();await wait(()=>$('reader-follow-status').textContent==='已保存','second followed save');
await category('preferences');const prefButton=[...$('preferences-items').querySelectorAll('button')].find(b=>b.textContent.includes('跨分类草稿'));assert(!!prefButton,'saved preference visible on reopening');prefButton.click();input('preference-title','重开后再编辑');$('preferences-save').click();await wait(()=>!$('preferences-save').disabled,'second preference save');await flush();assert((await qa('qaInspect')).settings.aiPreferences.entries.some(item=>item.title==='重开后再编辑'),'preference remains editable after reopening');await doneSettings();
__observations.settings={fiveEmbeddedPanels:true,aiDraftRetained:true,followedDraftRetained:true,preferenceDraftRetained:true,allDraftsSurviveManualCleanup:true,savesStayOpen:true,reopenEditable:true};

__observations.section='consecutive spacing and own name';
await jump('m5998');await openSettings('reading');
for(const level of [1,2,3,4,5]){
  document.querySelector('[data-consecutive-spacing="'+level+'"]').click();await wait(()=>!$('reading-font').disabled&&document.documentElement.dataset.readingConsecutiveSpacing===String(level),'spacing '+level+' saved');await sleep(120);
  const extra=Number(getComputedStyle(document.documentElement).getPropertyValue('--reading-consecutive-gap').replace('px','')),gap=rect(card('m5999').querySelector('.message-body')).top-rect(card('m5998').querySelector('.message-body')).bottom;
  assert(extra===[0,16,40,80,144][level-1],'five widely separated extra spacing values');assert(Math.abs(gap-[24,40,64,104,168][level-1])<1,'actual consecutive body gap at level '+level+': '+gap);assert((await qa('qaInspect')).readingAppearance.preferences.consecutiveSpacing===level,'spacing level persisted natively');__observations.spacing.push({level,extra,gap});
}
await shot('spacing-five-levels');await doneSettings();await jump('m5998');await shot('spacing-maximum');await jump('m5995');
const own=card('m5995'),other=card('m5996'),ownName=own.querySelector('.message-name'),ownTime=own.querySelector('.message-time');assert(own.classList.contains('is-own-message')&&!other.classList.contains('is-own-message'),'self uses stable identity rather than nickname');assert(shown(ownName)&&ownName.textContent==='同名用户'&&rect(ownName).width>=56,'own name is fully readable');assert(inside(rect(ownName),rect(own))&&inside(rect(ownTime),rect(own))&&!overlaps(rect(ownName),rect(ownTime)),'own name and time remain separate inside card');assert(getComputedStyle(own.querySelector('.message-heading')).justifyContent==='flex-end','own heading remains right aligned');assert(Math.abs(rect(own).right-(rect(own.parentElement).right-parseFloat(getComputedStyle(own).marginRight)))<2,'own message sits against reading content right edge');await shot('own-name-visible');

__observations.section='preview reading button and split sizing';
await fitReader(926);await jump('link');card('link').querySelector('.attachment-open').click();await wait(()=>shown($('content-preview-panel'))&&calls('previewContent').length>0,'link preview');
assert(shown($('content-preview-reading'))&&!$('content-preview-reading').disabled,'reading mode control available for web preview');assert($('content-preview-reading').getAttribute('aria-pressed')==='true','web preview begins in reading mode');
$('content-preview-reading').click();await wait(()=>calls('contentPreviewAction').at(-1)?.payload.operation==='original','restore original page mode');assert($('content-preview-reading').getAttribute('aria-pressed')==='false','original page mode reflected in toolbar');$('content-preview-reading').click();await wait(()=>calls('contentPreviewAction').at(-1)?.payload.operation==='reading','resume reading mode');assert($('content-preview-reading').getAttribute('aria-pressed')==='true','reading mode restored');
await sleep(120);const beforePreview=rect($('content-preview-host')),beforeReader=rect($('reader-area'));
for(let n=0;n<4;n++)$('inspector-divider').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}));await sleep(220);
const afterPreview=rect($('content-preview-host')),afterReader=rect($('reader-area')),lastLayout=calls('previewLayout').at(-1)?.payload;
__observations.previewGeometry={beforePreview,beforeReader,afterPreview,afterReader,lastLayout};
assert(afterPreview.width>=beforePreview.width+60&&afterReader.width<beforeReader.width,'split resize changes preview width and reading pane');assert(lastLayout.visible&&Math.abs(lastLayout.width-afterPreview.width)<1&&Math.abs(lastLayout.x-afterPreview.left)<1,'native preview receives current split geometry');assert($('content-preview-reading').getAttribute('aria-pressed')==='true','split resizing retains reading mode');await shot('preview-reading-resized');
await openSettings('storage');await wait(()=>calls('previewLayout').at(-1)?.payload.visible===false,'modal settings hide native preview');await doneSettings();await wait(()=>calls('previewLayout').at(-1)?.payload.visible===true,'closing settings restores native preview');$('content-preview-close').click();assert($('conversation-messages').textContent.includes('OLD_DISCUSSION_QUESTION'),'closing preview restores original discussion');await fitReader(560);
await jump('doc');card('doc').querySelector('.attachment-open').click();await wait(()=>shown($('content-preview-panel')),'document preview');assert(!$('content-preview-reading')||!shown($('content-preview-reading'))||$('content-preview-reading').disabled,'web reading toggle unavailable for local documents');$('content-preview-close').click();
__observations.preview={readingAndOriginal:true,splitBefore:beforePreview,splitAfter:afterPreview,modalVisibility:true};

if(initial.includeWidths){
  __observations.section='content-sized message backgrounds';
  await fitReader(926);await font(14);await jump('m5960');
  const size=()=>({short:rect(card('m5960')),long:rect(card('m5961')),medium:rect(card('m5965')),group:['m5962','m5963','m5964'].map(id=>({id,...rect(card(id))}))});
  const wide14=size();assert(wide14.short.width<rect($('reader-area')).width*.75,'short message background does not span wide reading pane');assert(wide14.long.width>wide14.short.width+100,'long message background is meaningfully wider than short message');assert(wide14.group.every(r=>Math.abs(r.width-wide14.group[0].width)<1&&Math.abs(r.left-wide14.group[0].left)<1),'one consecutive speaker group has a single aligned width');await shot('bubble-width-wide-14');
  const assertWideNames=fontSize=>{for(const id of ['m5960','m5959']){const name=card(id).querySelector('.message-name');assert(shown(name)&&name.scrollWidth<=name.clientWidth+1,'ordinary name remains complete in content-sized wide bubble at font '+fontSize+': '+id+' '+name.textContent+' '+name.clientWidth+'/'+name.scrollWidth);}};assertWideNames(14);
  await font(18);const wide18=size();assert(wide18.medium.width>wide14.medium.width+25,'medium message background grows with text font size');assert(wide18.group.every(r=>Math.abs(r.width-wide18.group[0].width)<1),'consecutive group remains equal width at larger font');assertWideNames(18);await shot('bubble-width-wide-18');__observations.bubbleWidths.push({reader:926,font:14,...wide14},{reader:926,font:18,...wide18});
  for(const width of [560,430]){
    await font(14);await fitReader(width);await jump('m5960');const sizes=size(),bounds=rect($('reader-scroll'));
    for(const [id,r] of [['short',sizes.short],['long',sizes.long],['medium',sizes.medium],...sizes.group.map(r=>[r.id,r])])assert(r.left>=bounds.left-1&&r.right<=bounds.right+1,'message '+id+' background fits reading pane '+width);
    assert(sizes.long.width<wide14.long.width-80,'long bubble contracts with reading pane '+width);assert(sizes.group.every(r=>Math.abs(r.width-sizes.group[0].width)<1),'consecutive group width stays unified at '+width);
    for(const id of ['m5960','m5961','m5962','m5963','m5964','m5965']){
      const c=card(id),b=rect(c),actions=c.querySelector('.message-actions');assert(c.scrollWidth<=c.clientWidth+1,'bubble does not overflow horizontally: '+id+' at '+width);assert(inside(rect(actions),b),'action toolbar fits '+id+' at '+width);
      for(const control of actions.querySelectorAll('button'))assert(inside(rect(control),b),'each action fits '+id+' at '+width);
      if(width===430&&!c.classList.contains('continuation')){const name=c.querySelector('.message-name'),heading=c.querySelector('.message-heading');assert(shown(name)&&name.scrollWidth<=name.clientWidth+1,'ordinary name remains readable in narrow pane: '+id);assert(!overlaps(rect(actions),rect(heading)),'narrow message heading and actions use separate rows: '+id);}
    }
    __observations.bubbleWidths.push({reader:width,font:14,...sizes});await shot('bubble-width-'+width);
  }
  for(const width of [560,430]){await fitReader(width);await jump('m5995');const ownCard=card('m5995'),rightBounds=rect(ownCard.parentElement),name=ownCard.querySelector('.message-name');assert(Math.abs(rect(ownCard).right-(rightBounds.right-parseFloat(getComputedStyle(ownCard).marginRight)))<2,'content-sized self message remains on right at '+width);assert(shown(name)&&name.scrollWidth<=name.clientWidth+1,'own name remains complete after width recomputation at '+width);}
}else __observations.bubbleWidthsStatus='not run: explicit core-only diagnostic mode';

__observations.section='layout completion and explicit navigation race';
await fitReader(560);await reset();await jump('m5960');const beforeNavigationRace=anchor();
window.dispatchEvent(new Event('weiyue:layout-start'));window.dispatchEvent(new Event('weiyue:layout-end'));window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId:'g',messageId:'m5995'}}));
await wait(()=>card('m5995'),'explicit destination mounts during layout completion');await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));await sleep(180);
const raceDestination=card('m5995'),raceViewport=rect($('reader-scroll')),afterNavigationRace=anchor();assert(!!raceDestination&&rect(raceDestination).bottom>raceViewport.top&&rect(raceDestination).top<raceViewport.bottom,'late layout restoration cannot replace explicit same-group message navigation');assert(afterNavigationRace.id!==beforeNavigationRace.id,'explicit navigation retains its new reading anchor');__observations.layoutNavigationRace={before:beforeNavigationRace,after:afterNavigationRace,destination:'m5995'};

__observations.section='attachment bounds and long thumbnail';
for(const width of [926,560,430]){
  await fitReader(width);
  for(const id of ['wide','tall','multi','m5966','doc']){
    await jump(id);const c=card(id),bounds=rect(c);const images=[...c.querySelectorAll('.image-attachment img')];
    if(images.length){await wait(()=>images.every(img=>img.complete&&img.naturalWidth>0),'attachment images '+id);for(const img of images){const box=rect(img);assert(inside(box,rect(c)),'image stays inside message bubble '+id+' at '+width);assert(Math.abs(box.width/box.height-img.naturalWidth/img.naturalHeight)<.02,'image retains natural aspect ratio '+id);assert(box.height<=461,'thumbnail retains existing maximum height '+id);}}
    const attachment=c.querySelector('.attachment-card'),actions=c.querySelector('.message-actions'),content=c.querySelector('.message-content');
    __observations.attachments.push({id,readerWidth:width,card:bounds,content:rect(content),actions:rect(actions),attachment:attachment?rect(attachment):null,scrollWidth:c.scrollWidth,clientWidth:c.clientWidth,columns:getComputedStyle(content).gridTemplateColumns});
    if(id==='doc'){await sleep(120);c.scrollIntoView({block:'center'});c.querySelector('.attachment-open').focus({preventScroll:true});await sleep(180);await shot('document-bounds-'+width);}
    assert(!attachment||rect(attachment).left>=bounds.left-1&&rect(attachment).right<=bounds.right+1,'attachment stays within message horizontal bounds '+id+' at '+width+': '+JSON.stringify(__observations.attachments.at(-1)));
    assert(c.scrollWidth<=c.clientWidth+1,'attachment message has no horizontal overflow '+id+' at '+width);
    if(id==='doc'){const open=c.querySelector('.attachment-open'),rail=c.querySelector('.attachment-floating-actions');assert(!overlaps(rect(open),rect(rail)),'document title and action rail do not overlap');assert(inside(rect(actions),rect(c)),'all six document message actions fit inside bubble at '+width);for(const button of actions.querySelectorAll('button'))assert(inside(rect(button),rect(c)),'document action '+button.textContent.trim()+' fits at '+width);assert(inside(rect(rail),rect(attachment)),'document attachment tools remain inside file row at '+width);}
    if(id==='m5966')await shot('long-thumbnail-'+width);
  }
}
await fitReader(560);await jump('m5998');await flush();
const saved=await qa('qaInspect');assert(saved.discussions.some(d=>d.id==='existing'&&d.messages[0].content==='OLD_DISCUSSION_QUESTION'),'original discussion data unchanged');assert(__errors.length===0,'no JavaScript runtime errors: '+JSON.stringify(__errors));
return JSON.stringify({...__observations,messageCount:saved.messageCount,network:'blocked; synthetic bridge, local emoticons and image fixtures only'});

"""#
    static let reloadTests = #"""
let assertions=0;const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{assertions++;if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let seq=0;const pending=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=pending.get(response.id);if(resolve){pending.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='v111-reload-'+(++seq);pending.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]');
await wait(()=>document.documentElement.dataset.readingConsecutiveSpacing==='5'&&card('action-target'),'native preferences restored after reload');
assert(getComputedStyle(document.documentElement).getPropertyValue('--reading-consecutive-gap').trim()==='144px','saved maximum spacing restored');
window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId:'g',messageId:'m5998'}}));await wait(()=>card('m5998')&&card('m5999'),'spacing pair after reload');card('m5998').scrollIntoView({block:'center'});await sleep(180);
const gap=card('m5999').querySelector('.message-body').getBoundingClientRect().top-card('m5998').querySelector('.message-body').getBoundingClientRect().bottom;assert(Math.abs(gap-168)<1,'actual 168px gap survives page reload');
const saved=await qa('qaInspect');assert(saved.readingAppearance.preferences.consecutiveSpacing===5,'native file contains maximum spacing');assert(saved.settings.followedMembers.some(m=>m.senderId==='follow-reopened-v111'),'followed edit survives reload');assert(saved.settings.aiPreferences.entries.some(p=>p.title==='重开后再编辑'),'preference edit survives reload');
assert(!$('nav-followed'),'reloaded sidebar has no followed navigation');await qa('qaSnapshot',{name:'v111-spacing-reloaded'});assert(__errors.length===0,'reload has no runtime errors');return JSON.stringify({assertions,spacingLevel:5,extraPixels:144,actualGap:gap,reloaded:true,screenshot:'v111-spacing-reloaded.png'});

"""#
}
