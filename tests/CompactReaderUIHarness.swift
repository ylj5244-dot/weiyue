import AppKit
import WebKit

// Synthetic account, 6,000+ messages and in-memory persistence/RPC only.
// All remote subresources, fetches and navigations are blocked. Images are
// generated locally and served only through the test's weiyue-media scheme.
@main final class CompactReaderUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!
    var state: [String: Any] = [:], calls: [[String: Any]] = [], images: [String: Data] = [:]
    var heldSaves: [(Any, [String: Any])] = [], saveMode = "success", autoMode = "success"
    var preview: [String: Any] = [:], finished = false
    var appearances: ReadingAppearanceStore!
    let account = "synthetic-v112", timestamp = "2026-10-21T01:00:00Z"
    static func main() {
        let app = NSApplication.shared, delegate = CompactReaderUIHarness()
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { print("FAIL: v112 UI process watchdog"); fflush(stdout); exit(1) }
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-v112-ui-" + UUID().uuidString)
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
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('Network disabled in v112 UI tests'));window.XMLHttpRequest=function(){throw Error('Network disabled in v112 UI tests');};window.WebSocket=function(){throw Error('Network disabled in v112 UI tests');};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "weiyue-v112-offline-" + UUID().uuidString, encodedContentRuleList: rules) { list, error in
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 150) { self.finish(false, "v112 UI timeout") }
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
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "阅读布局验收一群", "selected": true],["accountId":account,"id":"g2","name":"第二合成群 · 跨群关注","selected":true]], "messages": messages, "bookmarks": [], "collections": [], "discussions": [discussion], "progress": ["g": ["auto": anchor]], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic-model", "readMode": "text", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "existing", "followedMembers":[["senderId":"follow-A","name":"林晓"],["senderId":"follow-B","name":"另一关注成员"],["senderId":"follow-C","name":"重点连续成员"]]]]
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
        case "syncNow", "loadHistory", "openOfficial", "layout": calls.append(["action": action, "payload": payload]); publish(); reply(id)
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
        guard name.hasPrefix("v112-"), !name.contains("/") else { finish(false, "invalid screenshot name"); return }
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
        web.callAsyncJavaScript(CommandLine.arguments.contains("--baseline") ? Self.baseline : Self.tests, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): self.finish(true, String(describing: value))
            case .failure(let error):
                self.snapshot("v112-failure") { _ in
                    self.web.evaluateJavaScript("JSON.stringify({observations:window.__observations,errors:window.__errors,calls:window.__calls,body:document.body.innerText.slice(-2000)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
                }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) {
        guard !finished else { return }; finished = true
        if let output { try? Data(result.utf8).write(to: output.appendingPathComponent(success ? "v112-compact-reader-ui-results.json" : "v112-compact-reader-ui-failure.txt")) }
        print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout)
        if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1)
    }
    enum ReaderHarnessError: Error { case missingImage }
    static let baseline = #"""

const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms));
window.__observations={assertions:0,section:'startup',screenshots:[],layouts:[],spacing:[],bubbleWidths:[],attachments:[],performance:{fontChanges:[],nativeMessages:[]}};
const originalNativeEvent=window.onNativeEvent;window.onNativeEvent=function(event){const started=performance.now();try{return originalNativeEvent(event);}finally{if(event?.type==='messages')__observations.performance.nativeMessages.push({duration:performance.now()-started,messages:event.messages?.length||0});}};
const assert=(value,label)=>{__observations.assertions++;if(!value)throw Error(label);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let sequence=0;const pending=new Map(),receive=window.nativeReceive;
window.nativeReceive=response=>{const resolve=pending.get(response.id);if(resolve){pending.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='v112-qa-'+(++sequence);pending.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
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
const shot=async name=>{await wait(()=>$('toast').hidden,'toast settled '+name);const file='v112-'+name;await qa('qaSnapshot',{name:file});__observations.screenshots.push(file+'.png');};
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



await fitReader(1024);await shot('before-1024');
__observations.header={header:rect(document.querySelector('#chat-view>.content-header')),tools:rect(document.querySelector('.reader-tools')),scroll:rect($('reader-scroll')),main:rect($('main'))};
return JSON.stringify(__observations);
"""#
    static let tests = #"""

const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms));
window.__observations={assertions:0,section:'startup',screenshots:[],layouts:[],spacing:[],bubbleWidths:[],attachments:[],performance:{fontChanges:[],nativeMessages:[]}};
const originalNativeEvent=window.onNativeEvent;window.onNativeEvent=function(event){const started=performance.now();try{return originalNativeEvent(event);}finally{if(event?.type==='messages')__observations.performance.nativeMessages.push({duration:performance.now()-started,messages:event.messages?.length||0});}};
const assert=(value,label)=>{__observations.assertions++;if(!value)throw Error(label);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let sequence=0;const pending=new Map(),receive=window.nativeReceive;
window.nativeReceive=response=>{const resolve=pending.get(response.id);if(resolve){pending.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='v112-qa-'+(++sequence);pending.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
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
const shot=async name=>{await wait(()=>$('toast').hidden,'toast settled '+name);const file='v112-'+name;await qa('qaSnapshot',{name:file});__observations.screenshots.push(file+'.png');};
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




const syncButton=$('sync-status-button'),filterButton=$('reader-filter-button'),syncMenu=$('sync-popover'),filterMenu=$('reader-filter-popover'),nav=$('reader-navigation');
const escape=()=>document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
const openSync=async()=>{if(!shown(syncMenu))syncButton.click();await wait(()=>shown(syncMenu),'sync popover visible');await sleep(80);};
const openFilters=async()=>{if(!shown(filterMenu))filterButton.click();await wait(()=>shown(filterMenu),'filter popover visible');await sleep(80);};
const closeMenus=async()=>{escape();await sleep(60);};
const sync=(state,more={})=>window.onNativeEvent({type:'sync',accountId:'synthetic-v112',groupId:'g',state,...more});
const appendLive=id=>window.onNativeEvent({type:'messages',accountId:'synthetic-v112',groupId:'g',messageSource:'live',messages:[{accountId:'synthetic-v112',groupId:'g',id,senderId:'new-sync-member',senderName:'合成同步成员',sentAt:'2026-10-21T09:30:00Z',text:'SYNTHETIC_OFFICIAL_SYNC 仅用于官方模式增量消息计数验收',attachments:[]}]});
const coverageCount=()=>Number($('coverage-text').textContent.match(/本地 (\d+) 条/)?.[1]);
const bounds=()=>({left:0,right:innerWidth,top:0,bottom:innerHeight});
const assertMenu=(menu,label)=>{assert(shown(menu),label+' is visible');assert(inside(rect(menu),bounds(),1),label+' stays in viewport');const r=rect(menu);assert(menu.contains(document.elementFromPoint(r.left+12,r.top+12)),label+' is not clipped by reader');};
const assertControls=label=>{
 const controls=[...document.querySelectorAll('.reader-audience button,#message-search,[data-message-type],#reader-filter-button,#open-range-summary,#font-button')];
 for(const c of controls){assert(shown(c),label+' visible '+(c.id||c.textContent));assert(inside(rect(c),rect(document.querySelector('.reader-tools')),1),label+' within tool row '+(c.id||c.textContent));}
 for(let i=0;i<controls.length;i++)for(let j=i+1;j<controls.length;j++)assert(!overlaps(rect(controls[i]),rect(controls[j])),label+' controls do not overlap '+i+'/'+j);
};
__observations.section='compact geometry';
assert(syncButton&&filterButton&&syncMenu&&filterMenu&&nav,'all compact controls are present');
sync('idle',{text:'实时同步已开启',hasMore:true});await sleep(80);
for(const width of [1024,820,650,430]){
 await fitReader(width);await reset();await closeMenus();
 const header=rect(document.querySelector('#chat-view>.content-header')),tools=rect(document.querySelector('.reader-tools')),scroll=rect($('reader-scroll'));
 assertControls(width+'px');
 assert(header.height<=68,'group header remains compact at '+width+': '+header.height);
 assert(tools.height<=(width>=820?64:100),'toolbar uses at most two compact rows at '+width+': '+tools.height);
 assert(scroll.top-header.top<=(width>=820?132:178),'unfiltered chrome height at '+width+': '+(scroll.top-header.top));
 assert(!shown($('reader-summary')),'no persistent result row when unfiltered at '+width);
 for(const element of [$('main'),$('reader-area'),document.querySelector('.reader-tools')])assert(element.scrollWidth<=element.clientWidth+1,'no horizontal overflow '+element.id+' at '+width);
 assert(shown($('coverage-action'))&&inside(rect(nav),rect($('reader-area'))),'latest navigation inside reader at '+width);
 await openSync();assert(Math.abs(rect($('main')).top-header.top)<1,'sync opening does not scroll whole app at '+width);assertMenu(syncMenu,'sync '+width);await shot('sync-'+width);await closeMenus();
 await openFilters();assert(Math.abs(rect($('main')).top-header.top)<1,'filter opening does not scroll whole app at '+width);assertMenu(filterMenu,'filters '+width);await shot('filters-'+width);await closeMenus();
 __observations.layouts.push({width,header,tools,scroll,nav:rect(nav),main:rect($('main'))});await shot('compact-'+width);
}
await fitReader(1024);
__observations.section='menu focus and sync actions';
syncButton.focus();await openSync();assert(syncButton.getAttribute('aria-expanded')==='true','sync toggle announces expanded');
assert(syncMenu.contains(document.activeElement),'sync popover receives focus');await closeMenus();assert(!shown(syncMenu)&&document.activeElement===syncButton,'Escape closes sync and restores toggle focus');
await openSync();$('message-search').click();assert(!shown(syncMenu),'outside click closes sync');
await openSync();await openFilters();assert(!shown(syncMenu)&&shown(filterMenu),'only one compact popover opens');
assert(filterMenu.contains(document.activeElement),'filter popover receives focus');await closeMenus();assert(document.activeElement===filterButton,'Escape restores filter focus');
await openSync();assert($('coverage-text').textContent.includes('条')&&$('coverage-text').textContent.includes('非完整历史'),'coverage count and range remain accessible');assert(shown($('sync-now'))&&shown($('load-history')),'sync actions are reachable');
$('sync-now').click();await wait(()=>calls('syncNow').length>0,'sync now RPC');assert($('sync-now').disabled,'sync button disabled during request');assert(/同步|加载/.test($('sync-status-short').textContent),'busy status remains visible');
sync('idle',{text:'实时同步已开启',hasMore:true});await sleep(80);await openSync();$('load-history').click();await wait(()=>calls('loadHistory').length>0,'history RPC');assert(calls('loadHistory').at(-1).payload.count===500,'history keeps batch size 500');
sync('error',{text:'合成同步错误'});await sleep(70);assert(/异常|错误|失败|重试|问题/.test($('sync-status-short').textContent),'sync error visible while collapsed');await openSync();assert($('sync-status').textContent==='合成同步错误','full sync error retained');
sync('idle',{text:'已保存合成消息',hasMore:false});await sleep(70);assert($('load-history').disabled,'exhausted history is disabled');assert($('load-history').textContent.includes('没有更早'),'history exhaustion explained');
sync('idle',{text:'实时同步已开启',hasMore:true});await closeMenus();
__observations.section='filter behavior';
await query('report-needle');await type('document');expectIds(['m5991','m5992','m5993'],'query combines with message type');assert(shown($('reader-summary'))&&$('active-filter-summary').textContent.includes('report-needle'),'active query is visible outside popover');
await openFilters();if(!shown($('member-popover')))$('member-filter-button').click();await wait(()=>shown($('member-popover')),'member picker');input('member-search','filter-member');await sleep(80);
const member=[...$('member-list').querySelectorAll('button')].find(b=>b.textContent.includes('检索成员 filter-member'));assert(member&&shown(member),'target member is reachable');member.click();await sleep(150);expectIds(['m5991','m5992'],'member applies to existing query/type');
await openFilters();if(!shown($('date-filter')))$('date-filter-button').click();assert(shown($('date-from'))&&shown($('date-to')),'date controls reachable inside menu');
for(const id of ['date-from','date-to']){$(id).value='2026-10-20';$(id).dispatchEvent(new Event('change',{bubbles:true}));}await sleep(160);await closeMenus();expectIds(['m5991'],'date range combines with query/type/member');
assert($('active-filter-summary').textContent.includes('2026-10-20')&&$('active-filter-summary').textContent.includes('检索成员'),'active date/member are visible');assert(shown($('clear-filters')),'clear filters is reachable');
$('clear-filters').click();await sleep(140);assert(!$('message-search').value&&!$('date-from').value&&!$('date-to').value,'clear resets search and dates');assert(!shown($('reader-summary')),'clear hides conditional summary');assert(document.querySelector('[data-message-type="all"]').getAttribute('aria-pressed')==='true','clear resets message type');
await audience('followed');expectIds(['m5970','m5971','m5972','m5980','m5984'],'followed still shows current group only');await reset();
await openFilters();$('manage-followed-feed').click();await wait(()=>$('settings-dialog').open,'manage followed opens settings');assert(!shown(filterMenu),'opening settings closes filters');assert(document.querySelector('[data-settings-category="followed"]').getAttribute('aria-selected')==='true','follow management selects correct category');await doneSettings();
await fitReader(430);await query('文件检索');await type('document');assert(shown($('reader-summary')),'narrow active filters visible');assert(Math.abs(rect($('main')).top-48)<1,'active filters do not scroll whole app');assert($('reader-summary').scrollWidth<=$('reader-summary').clientWidth+1,'narrow active filters do not overflow');await shot('active-filters-430');await reset();
await openFilters();if(!shown($('date-filter')))$('date-filter-button').click();await qa('qaResize',{width:innerWidth,height:460});await sleep(120);assertMenu(filterMenu,'short window filter');assert(filterMenu.scrollHeight>=filterMenu.clientHeight,'short window filter has constrained scroll');await closeMenus();await fitReader(1024);
__observations.section='font and summary controls';
await jump('m5960');await font(18);assert(getComputedStyle(card('m5960').querySelector('.message-body')).fontSize==='18px','compact font selector changes real message size');await font(14);assert(getComputedStyle(card('m5960').querySelector('.message-body')).fontSize==='14px','font selector restores14');
$('open-range-summary').click();await wait(()=>$('range-summary-dialog').open,'range summary opens from toolbar');assert(shown($('range-summary-start'))&&shown($('range-summary-end')),'range summary time fields are reachable');$('range-summary-close').click();await wait(()=>!$('range-summary-dialog').open,'range summary closes');
__observations.section='reading navigation and selection clearance';
await jump('m5960');const beforeManual=(await qa('qaInspect')).progress.g?.manual;
card('m5960').querySelector('.manual-progress-action').click();await flush();await sleep(120);
assert(shown($('manual-position')),'manual continuation available after setting');const fixed=(await qa('qaInspect')).progress.g.manual;assert(fixed.messageId==='m5960','manual continuation records selected message');
await jump('m5980');await sleep(260);const visibleBefore=(()=>{const top=rect($('reader-scroll')).top;const c=[...$('messages').querySelectorAll('.message-card')].find(c=>rect(c).bottom>top+15);return {id:c.dataset.messageId,offset:rect(c).top-top};})();
$('coverage-action').click();await wait(()=>card('link'),'latest message mounted');await sleep(350);assert(shown($('return-position')),'latest creates return control');
const afterLatest=await qa('qaInspect');assert(afterLatest.progress.g.manual.messageId===fixed.messageId,'latest preserves independent manual point');assert(afterLatest.progress.g.returnPoint.messageId===visibleBefore.id,'latest captures pre-jump message');
const last=card('link');assert(!overlaps(rect(last),rect(nav)),'floating navigation does not cover final message');
$('return-position').click();await wait(()=>card(visibleBefore.id),'return target mounted');await sleep(320);const restored=rect(card(visibleBefore.id)).top-rect($('reader-scroll')).top;assert(Math.abs(restored-visibleBefore.offset)<3,'return restores original pixel position');
$('manual-position').click();await wait(()=>card('m5960'),'manual target mounted');await sleep(160);assert((await qa('qaInspect')).progress.g.manual.messageId==='m5960','manual control does not overwrite fixed anchor');
await jump('action-target');card('action-target').querySelector('.message-select').click();await wait(()=>shown($('selection-bar')),'selection bar visible');await sleep(100);assert(!overlaps(rect(nav),rect($('selection-bar'))),'floating navigation clears selection bar');await shot('selection-clearance');$('clear-selection').click();await sleep(80);
await fitReader(430);assert(nav.scrollWidth<=nav.clientWidth+1,'all three navigation actions fit narrow pane');assert(inside(rect(nav),rect($('reader-area'))),'manual and return navigation remain in narrow pane');await shot('navigation-430');await fitReader(1024);
__observations.section='view transitions';
await openFilters();await jump('m5981','g2');assert(!shown(filterMenu),'source jump across groups closes filters');assert(!$('message-search').value,'cross-group jump has no stale query');await jump('m5960','g');
await openSync();$('mode-official').click();await sleep(120);assert(!shown(syncMenu)&&!shown($('reader-area'))&&shown($('official-area')),'official switch closes menu and selects host');
await wait(()=>calls('layout').at(-1)?.payload.visible===true,'official native host visible');
const countBeforeLive=Number.parseInt($('result-count').textContent,10),coverageBeforeLive=coverageCount();
appendLive('official-sync-1');await wait(()=>coverageCount()===coverageBeforeLive+1,'official live message updates archive coverage');
await openSync();assertMenu(syncMenu,'official sync');await wait(()=>calls('layout').at(-1)?.payload.visible===false,'popover hides native overlay');
assert(Number.parseInt($('result-count').textContent,10)===countBeforeLive+1,'official live message refreshes visible reading count in sync menu');
assert(!shown($('reader-area'))&&shown($('official-area')),'updating sync count retains official mode');
await closeMenus();await wait(()=>calls('layout').at(-1)?.payload.visible===true,'closing menu restores native host');$('mode-reader').click();await wait(()=>shown($('reader-area')),'reader restored');
await query('SYNTHETIC_OFFICIAL_SYNC');expectIds(['official-sync-1'],'new official message is searchable');
$('mode-official').click();await sleep(120);const filteredCoverageBefore=coverageCount();appendLive('official-sync-2');await wait(()=>coverageCount()===filteredCoverageBefore+1,'filtered official live message updates coverage');await openSync();
assert(Number.parseInt($('result-count').textContent,10)===2&&$('result-count').textContent.includes('匹配'),'official live message refreshes filtered result count');
await closeMenus();$('mode-reader').click();await wait(()=>shown($('reader-area')),'filtered reader restored');expectIds(['official-sync-1','official-sync-2'],'returning to reader matches current sync menu count');await reset();
await openFilters();$('enter-standby').click();await sleep(150);assert(!shown(filterMenu),'standby closes filter');assert($('reader-area').classList.contains('is-standby'),'standby entered');assert(!shown(nav),'standby hides message navigation');assert($('mode-official').disabled,'standby cannot open stale official group');
const groupButton=[...document.querySelectorAll('.group-pick')].find(b=>b.textContent.includes('阅读布局验收一群'));assert(groupButton,'group is present in sidebar');groupButton.click();await sleep(180);assert(!$('reader-area').classList.contains('is-standby'),'group resumes from standby');
__observations.section='theme and final state';
await fitReader(1024);await reset();sync('idle',{text:'实时同步已开启',hasMore:true});
const scheme=$('appearance-select')||document.querySelector('[aria-label="外观"]');
if(scheme){scheme.value='dark';scheme.dispatchEvent(new Event('change',{bubbles:true}));}else{window.onNativeEvent({type:'appearance',appearance:'dark'});}
await sleep(120);assert(document.documentElement.dataset.colorScheme==='dark','dark theme applied');await shot('dark-1024');await openFilters();assertMenu(filterMenu,'dark filter');await shot('dark-filter');await closeMenus();
if(scheme){scheme.value='light';scheme.dispatchEvent(new Event('change',{bubbles:true}));}else{window.onNativeEvent({type:'appearance',appearance:'light'});}
await sleep(120);await jump('m5960');await shot('final-light-1024');
card('m5960').querySelector('.manual-progress-action').click();await flush();
await qa('qaResize',{width:innerWidth,height:384});await sleep(160);await jump('m5970');$('reader-scroll').scrollTop+=rect(card('m5970')).top-rect($('reader-scroll')).top;await sleep(100);window.scrollTo(0,0);document.documentElement.scrollTop=0;document.body.scrollTop=0;await sleep(80);assert(Math.abs(rect($('main')).top-48)<1,'comparison viewport starts at app toolbar');
__observations.comparison={main:rect($('main')),viewport:{width:innerWidth,height:innerHeight},header:rect(document.querySelector('#chat-view>.content-header')),tools:rect(document.querySelector('.reader-tools')),scroll:rect($('reader-scroll'))};
await shot('reference-comparison-1024');
assert(window.__errors.length===0,'no runtime or promise errors: '+window.__errors.join(' | '));await flush();
return JSON.stringify(__observations);

"""#
}
