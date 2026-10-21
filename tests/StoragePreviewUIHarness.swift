import AppKit
import WebKit

// Synthetic account, 6,000+ messages and in-memory persistence/RPC only.
// All remote subresources, fetches and navigations are blocked. Images are
// generated locally and served only through the test's weiyue-media scheme.
@main final class StoragePreviewUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!
    var state: [String: Any] = [:], calls: [[String: Any]] = [], images: [String: Data] = [:]
    var heldSaves: [(Any, [String: Any])] = [], saveMode = "success", autoMode = "success"
    var preview: [String: Any] = [:], finished = false
    var appearances: ReadingAppearanceStore!, phase = 0, phaseResult = ""
    let account = "synthetic-v110", timestamp = "2026-10-21T01:00:00Z"
    static func main() {
        let app = NSApplication.shared, delegate = StoragePreviewUIHarness()
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { print("FAIL: v110 UI process watchdog"); fflush(stdout); exit(1) }
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-v110-ui-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            appearances = try ReadingAppearanceStore(directory: temp.appendingPathComponent("synthetic-appearance"))
            state = fixture()
            images["wide"] = makeImage(960, 320, "WIDE 3:1", .systemTeal)
            images["tall"] = makeImage(240, 720, "TALL 1:3", .systemOrange)
            images["multi-a"] = makeImage(640, 400, "MULTI 8:5", .systemBlue)
            images["multi-b"] = makeImage(300, 600, "MULTI 1:2", .systemPurple)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name: "app")
            configuration.setURLSchemeHandler(self, forURLScheme: "weiyue-media")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('Network disabled in v110 UI tests'));window.XMLHttpRequest=function(){throw Error('Network disabled in v110 UI tests');};window.WebSocket=function(){throw Error('Network disabled in v110 UI tests');};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "weiyue-v110-offline-" + UUID().uuidString, encodedContentRuleList: rules) { list, error in
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 150) { self.finish(false, "v110 UI timeout") }
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
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "1.0.10 合成验收 · 6006 条", "selected": true],["accountId":account,"id":"g2","name":"第二合成群 · 跨群关注","selected":true]], "messages": messages, "bookmarks": [], "collections": [], "discussions": [discussion], "progress": ["g": ["auto": anchor]], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic-model", "readMode": "text", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "existing", "followedMembers":[["senderId":"follow-A","name":"林晓"],["senderId":"follow-B","name":"另一关注成员"]]]]
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
            preview = ["kind": attachment["type"] ?? "link", "title": attachment["name"] ?? "合成预览", "url": attachment["url"] ?? "", "canGoBack": true, "canGoForward": true, "loading": false, "error": ""]
            calls.append(["action": action, "payload": payload]); publish(); reply(id, preview)
        case "contentPreviewAction": calls.append(["action": action, "payload": payload]); publish(); reply(id, preview)
        case "closeContentPreview", "previewLayout": calls.append(["action": action, "payload": payload]); publish(); reply(id)
        case "qaModes": saveMode = payload["save"] as? String ?? saveMode; autoMode = payload["auto"] as? String ?? autoMode; reply(id)
        case "qaReleaseSave":
            let pending = heldSaves; heldSaves = []; saveMode = "success"; publish()
            for (request, candidate) in pending { if payload["fail"] as? Bool == true { reject(request, "SYNTHETIC_SAVE_FAILURE") } else { commit(request, candidate) } }; reply(id)
        case "qaInspect":
            reply(id, ["messageCount": (state["messages"] as? [Any])?.count ?? 0, "settings": state["settings"] ?? [:], "bookmarks": state["bookmarks"] ?? [], "progress": state["progress"] ?? [:], "discussions": state["discussions"] ?? [], "readingAppearance": appearances.snapshot()])
        case "qaResize":
            window.setContentSize(NSSize(width: payload["width"] as? Double ?? 1488, height: payload["height"] as? Double ?? 1000)); web.setFrameSize(window.contentView!.bounds.size); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); reply(id)
        case "qaRefreshFollowed":
            var refreshed = (state["messages"] as! [[String: Any]]).first { $0["id"] as? String == "m5981" }!
            refreshed["text"] = (refreshed["text"] as? String ?? "") + "〔合成刷新〕"
            web.evaluateJavaScript("window.onNativeEvent(" + json(["type":"messages","accountId":account,"groupId":"g2","messages":[refreshed],"messageSource":"live"]) + ")", completionHandler: nil); reply(id)
        case "qaSnapshot": snapshot(payload["name"] as? String ?? "") { success in if success { self.reply(id) } }
        case "ai", "titleDiscussion", "aiDiscussionTitle", "webSearch", "testAI", "saveKey", "authorizeAI", "openExternal", "openAttachment", "listModels", "importDocument", "downloadAttachment", "revealAttachment": finish(false, "unexpected external action: " + action)
        default: reply(id)
        }
    }
    func snapshot(_ name: String, _ completion: @escaping (Bool) -> Void) {
        guard name.hasPrefix("v110-"), !name.contains("/") else { finish(false, "invalid screenshot name"); return }
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
                self.snapshot("v110-failure") { _ in
                    self.web.evaluateJavaScript("JSON.stringify({observations:window.__observations,errors:window.__errors,calls:window.__calls,body:document.body.innerText.slice(-2000)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
                }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) {
        guard !finished else { return }; finished = true
        if let output { try? Data(result.utf8).write(to: output.appendingPathComponent(success ? "v110-ui-results.json" : "v110-ui-failure.txt")) }
        print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout)
        if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1)
    }
    enum ReaderHarnessError: Error { case missingImage }
    static let tests = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms));
window.__observations={assertions:0,toggles:[],images:[],documents:[],screenshots:[]};
const assert=(value,label)=>{__observations.assertions++;if(!value)throw Error(label);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let seq=0;const pending=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=pending.get(response.id);if(resolve){pending.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='v110-qa-'+(++seq);pending.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const calls=action=>__calls.filter(c=>c.action===action),latestLayout=()=>calls('previewLayout').at(-1)?.payload;
const rect=el=>{const r=el.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};};
const shown=el=>!!el&&!el.hidden&&getComputedStyle(el).display!=='none'&&getComputedStyle(el).visibility!=='hidden'&&rect(el).width>0&&rect(el).height>0;
const overlaps=(a,b)=>Math.min(a.right,b.right)-Math.max(a.left,b.left)>.7&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>.7;
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]');
const attach=(id,index=0)=>card(id)?.querySelector('.attachment-card[data-attachment-index="'+index+'"]');
const flush=async()=>{await window.flushBeforeQuit();await sleep(50);};
const jump=async id=>{window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId:'g',messageId:id}}));await wait(()=>card(id),'mount '+id);card(id).scrollIntoView({block:'center'});await sleep(160);await flush();};
const shot=async name=>{await qa('qaSnapshot',{name:'v110-'+name});__observations.screenshots.push('v110-'+name+'.png');};
const openStorage=async()=>{$('settings-button').click();await wait(()=>$('settings-dialog').open,'settings opened');assert(!$('storage-dialog').open,'storage is a second-level destination');$('open-storage-management').click();await wait(()=>$('storage-dialog').open&&$('storage-total').textContent==='7.0 MB','storage loaded');assert(!$('settings-dialog').open,'settings closes when storage opens');};
const closeStorage=async()=>{document.querySelector('#storage-dialog [data-close-dialog="storage-dialog"]').click();await wait(()=>!$('storage-dialog').open,'storage closed');await sleep(80);};
const tick=()=>window.onNativeEvent({type:'retentionTick'});
await wait(()=>card('action-target')&&window.ReaderStorage&&window.__calls,'synthetic fixture');await flush();
assert((await qa('qaInspect')).messageCount===6006,'fixture contains 6006 messages');
assert(document.querySelectorAll('.message-card').length<200,'6006-message archive remains virtualized');
assert($('conversation-messages').textContent.includes('OLD_DISCUSSION_QUESTION'),'existing discussion restored');
await jump('action-target');
for(const [kind,selector] of [['bookmark','.message-bookmark-action'],['manual','.manual-progress-action']]){
  const button=card('action-target').querySelector(selector);assert(button.getAttribute('aria-pressed')==='false',kind+' initially unpressed');
  await qa('qaModes',{save:'hold'});const started=performance.now();button.click();
  const elapsed=performance.now()-started;
  assert(button.getAttribute('aria-pressed')==='true',kind+' immediately shows requested pressed state');
  assert(button.getAttribute('aria-busy')==='true'&&button.disabled,kind+' immediately exposes pending state');
  await wait(()=>__heldSaves===1,kind+' save held');await sleep(180);
  assert(button.getAttribute('aria-busy')==='true'&&button.getAttribute('aria-pressed')==='true',kind+' remains pending while persistence is delayed');
  await shot(kind+'-pending');await qa('qaReleaseSave',{fail:true});
  await wait(()=>button.getAttribute('aria-busy')==='false'&&button.classList.contains('save-failed'),kind+' failure exposed');
  assert(button.getAttribute('aria-pressed')==='false'&&!button.disabled,kind+' failure restores previous state and permits retry');
  await flush();let saved=await qa('qaInspect');
  assert(kind==='bookmark'?!saved.bookmarks.some(b=>b.messageId==='action-target'&&!b.deletedAt):!saved.progress.g.manual,kind+' rollback is durably persisted');
  await shot(kind+'-failure');button.click();await wait(()=>button.getAttribute('aria-busy')==='false'&&!button.classList.contains('save-failed'),kind+' retry saved');
  assert(button.getAttribute('aria-pressed')==='true',kind+' retry reaches requested state');await flush();
  saved=await qa('qaInspect');assert(kind==='bookmark'?saved.bookmarks.some(b=>b.messageId==='action-target'&&!b.deletedAt):saved.progress.g.manual.messageId==='action-target',kind+' retry persists exact target');
  __observations.toggles.push({kind,immediateFeedbackMs:elapsed,pendingObserved:true,failureRolledBack:true,retrySaved:true});
}
for(const width of [1488,1120]){
  await qa('qaResize',{width});ReaderLayout.reset();await sleep(180);
  for(const appearance of ['light','dark']){
    ReaderAppearance.restore(appearance);await sleep(60);
    for(const id of ['wide','tall','multi']){
      await jump(id);await wait(()=>[...card(id).querySelectorAll('img')].every(i=>i.dataset.loaded==='true'),id+' images loaded');await sleep(80);
      const list=card(id).querySelector('.message-attachments'),listRect=rect(list),items=[...card(id).querySelectorAll('.image-attachment')];
      const boxes=items.map(c=>{const img=c.querySelector('img'),r=rect(img),f=rect(c.querySelector('.image-frame')),b=rect(c);assert(img.naturalWidth>0&&img.naturalHeight>0,'native synthetic image decoded');assert(Math.abs(r.width/r.height-img.naturalWidth/img.naturalHeight)<.015,id+' preserves original aspect ratio');assert(Math.abs((r.left+r.right)-(f.left+f.right))<1.5,id+' image centered in frame');assert(b.left>=listRect.left-1&&b.right<=listRect.right+1,id+' card stays inside reading column');assert(c.scrollWidth<=c.clientWidth+1,id+' has no horizontal overflow');return {image:r,card:b,naturalWidth:img.naturalWidth,naturalHeight:img.naturalHeight};});
      const min=Math.min(...boxes.map(v=>v.card.left)),max=Math.max(...boxes.map(v=>v.card.right));
      assert(Math.abs((min+max)-(listRect.left+listRect.right))<2,id+' image group centered in message');
      if(boxes.length>1)assert(!overlaps(boxes[0].image,boxes[1].image),'multiple images never overlap');
      __observations.images.push({width,appearance,id,list:listRect,boxes});
      if(appearance==='light')await shot((width===1488?'wide':'narrow')+'-'+id);
    }
    await jump('doc');const documentCard=attach('doc'),open=documentCard.querySelector('.attachment-open'),rail=documentCard.querySelector('.attachment-floating-actions'),title=documentCard.querySelector('.file-detail');
    const d=rect(documentCard),o=rect(open),r=rect(rail),t=rect(title);__observations.documents.push({width,appearance,card:d,open:o,rail:r,title:t});
    assert(d.height<=80,'document row remains compact');assert(!overlaps(o,r),'document title/open target does not overlap toolbar');assert(t.right<=r.left+1&&t.left>=d.left-1,'document title stays in allocated column');assert(documentCard.scrollWidth<=documentCard.clientWidth+1&&d.right<=rect($('reader-scroll')).right+1,'document row has no overflow');
    const oldConversation=$('conversation-messages').textContent,oldContext=$('context-list').textContent,previewBefore=calls('previewContent').length;
    open.click();await wait(()=>calls('previewContent').length===previewBefore+1&&shown($('content-preview-panel')),'document preview RPC');await wait(()=>latestLayout()?.visible===true,'native preview layout visible');
    const request=calls('previewContent').at(-1).payload;
    assert(request.accountId==='synthetic-v110'&&request.groupId==='g'&&request.messageId==='doc'&&request.attachmentIndex===0,'document preview routes exact attachment');assert($('inspector').classList.contains('previewing')&&$('content-preview-title').textContent.includes('合成文档'),'right preview panel shows document title');assert($('content-preview-external').textContent.includes('默认应用'),'document external action label');
    const panel=rect($('content-preview-panel')),inspector=rect($('inspector'));assert(panel.left>=inspector.left-1&&panel.right<=inspector.right+1&&panel.width>200,'preview stays inside right column');
    for(const operation of ['back','forward','reload','external']){const count=calls('contentPreviewAction').length;$('content-preview-'+operation).click();await wait(()=>calls('contentPreviewAction').length===count+1,'preview action '+operation);assert(calls('contentPreviewAction').at(-1).payload.operation===operation,'correct preview operation '+operation);}
    await shot((width===1488?'wide':'narrow')+'-document-'+appearance);
    $('settings-button').click();await wait(()=>$('settings-dialog').open&&latestLayout()?.visible===false,'modal hides native preview');assert(shown($('content-preview-panel')),'modal preserves preview state');document.querySelector('#settings-dialog [data-close-dialog="settings-dialog"]').click();await wait(()=>!$('settings-dialog').open&&latestLayout()?.visible===true,'closing modal restores native preview');
    $('content-preview-close').click();await wait(()=>!shown($('content-preview-panel'))&&latestLayout()?.visible===false,'preview closed');assert(!$('inspector').classList.contains('previewing'),'discussion panel restored');assert($('conversation-messages').textContent===oldConversation&&$('context-list').textContent===oldContext,'closing preview preserves original discussion and context');
  }
}
ReaderAppearance.restore('light');await jump('link');let before=calls('previewContent').length;attach('link').querySelector('.attachment-open').click();await wait(()=>calls('previewContent').length===before+1,'link preview RPC');assert(calls('previewContent').at(-1).payload.messageId==='link','link routes exact message');assert($('content-preview-external').textContent.includes('默认浏览器'),'link external action label');assert($('content-preview-address').textContent==='https://synthetic.invalid/article','link address shown');await shot('narrow-link-preview');
await openStorage();assert(!$('auto-cleanup-enabled').checked,'automatic cleanup defaults off');assert([...$('auto-cleanup-days').options].map(o=>o.value).join(',')==='1,2,3,4','retention choices are exactly 1–4 days');assert($('auto-cleanup-days').value==='3','default retention is three days');assert($('storage-categories').children.length===3,'all storage categories displayed');assert($('storage-categories').textContent.includes('4.0 MB')&&$('storage-categories').textContent.includes('2.0 MB'),'storage category byte formatting');assert($('storage-message-count').textContent.includes('6,006'),'storage message count displayed');
assert(latestLayout()?.visible===false,'storage modal hides native preview');tick();await sleep(120);assert(calls('autoCleanup').length===0,'default-off cleanup does not run on tick');await shot('storage-default-off');
$('auto-cleanup-days').value='4';$('save-auto-cleanup').click();await wait(()=>!$('save-auto-cleanup').disabled,'disabled cleanup settings saved');await flush();assert(calls('autoCleanup').length===0,'saving disabled preference does not clean');
await qa('qaModes',{save:'hold'});$('auto-cleanup-enabled').checked=true;$('auto-cleanup-days').value='2';$('save-auto-cleanup').click();await wait(()=>__heldSaves===1,'enabled cleanup preference held');assert(calls('autoCleanup').length===0,'cleanup waits for durable opt-in');await qa('qaReleaseSave');await wait(()=>calls('autoCleanup').length===1&&!$('save-auto-cleanup').disabled,'opt-in triggers cleanup');
assert(!card('link').querySelector('.message-bookmark-action').disabled,'cleanup completion re-enables message bookmark actions');assert(!attach('doc').querySelector('.attachment-read').disabled,'cleanup completion re-enables attachment AI actions');assert(!$('ai-question').disabled&&!$('new-discussion').disabled,'cleanup completion re-enables discussion input and controls');
const cleanup=calls('autoCleanup')[0].payload;assert(cleanup.accountId==='synthetic-v110','cleanup account is explicit');assert(cleanup.protectedMessages.some(m=>m.id==='m5999'),'current discussion context protected');assert(cleanup.protectedMessages.some(m=>m.id==='link'),'current preview source protected');let saved=await qa('qaInspect');assert(saved.settings.autoCleanup.enabled&&saved.settings.autoCleanup.retentionDays===2,'opt-in and selected retention persisted');
tick();await sleep(120);assert(calls('autoCleanup').length===1,'successful cleanup is not repeated before schedule');await shot('storage-enabled');
$('auto-cleanup-enabled').checked=false;$('save-auto-cleanup').click();await wait(()=>!$('save-auto-cleanup').disabled,'stop saved');await flush();const stopped=calls('autoCleanup').length;tick();await sleep(120);assert(calls('autoCleanup').length===stopped,'stopped cleanup does not run on tick');
// A failed automatic run must also remain stopped after the user disables it.
await qa('qaModes',{auto:'fail-next'});$('auto-cleanup-enabled').checked=true;$('save-auto-cleanup').click();await wait(()=>calls('autoCleanup').length===stopped+1&&!$('save-auto-cleanup').disabled,'synthetic cleanup failure');assert($('auto-cleanup-status').textContent.includes('SYNTHETIC_AUTO_CLEANUP_FAILURE'),'cleanup failure is visible');
$('auto-cleanup-enabled').checked=false;$('save-auto-cleanup').click();await wait(()=>!$('save-auto-cleanup').disabled,'stop after failure saved');await flush();await sleep(150);assert(calls('autoCleanup').length===stopped+1,'stopping after a failure must not immediately retry cleanup');
const realNow=Date.now;Date.now=()=>realNow()+360000;tick();await sleep(150);Date.now=realNow;assert(calls('autoCleanup').length===stopped+1,'stopped failed cleanup does not retry after retry interval');await shot('storage-stopped-after-failure');
await closeStorage();$('content-preview-close').click();await flush();saved=await qa('qaInspect');assert(saved.discussions.some(d=>d.id==='existing'&&d.messages[0].content==='OLD_DISCUSSION_QUESTION'),'all original discussion data remains');assert(__errors.length===0,'no JavaScript runtime errors: '+JSON.stringify(__errors));
// Discovery is exercised through the visible controls, on the same large archive.
const mountedIds=()=>[...$('messages').querySelectorAll('.message-card')].map(c=>c.dataset.messageId).sort();
const expectIds=(ids,label)=>assert(JSON.stringify(mountedIds())===JSON.stringify(ids.slice().sort()),label+': '+JSON.stringify(mountedIds()));
const type=async value=>{document.querySelector('[data-message-type="'+value+'"]').click();await sleep(140);assert(document.querySelector('[data-message-type="'+value+'"]').getAttribute('aria-pressed')==='true','selected message type '+value);};
const query=async value=>{$('message-search').value=value;$('message-search').dispatchEvent(new Event('input',{bubbles:true}));await sleep(220);};
const member=async id=>{$('member-filter-button').click();await wait(()=>!$('member-popover').hidden,'member menu');const option=[...$('member-list').querySelectorAll('.member-option')].find(el=>el.querySelector('small')?.textContent==='ID '+id);assert(!!option,'member option '+id);option.click();await sleep(140);};
assert([...document.querySelectorAll('[data-message-type]')].map(b=>b.dataset.messageType).join(',')==='all,link,image,document,video','five message-type chips are present');
for(const [value,ids] of [['link',['m5994','link']],['image',['wide','tall','multi']],['document',['m5991','m5992','m5993','doc']],['video',['m5990']]]){await type(value);expectIds(ids,'type '+value+' returns exact messages');}
await type('all');assert($('result-count').textContent.startsWith('6002 '),'all type restores current group archive');
await type('document');await query('FILTER_Report_');expectIds(['m5991','m5992','m5993'],'filename search includes document names');
await query('report-needle');expectIds(['m5991','m5992','m5993'],'URL search includes attachment URLs');await member('filter-member');expectIds(['m5991','m5992'],'member filter combines with document type and URL');
$('date-filter-button').click();$('date-from').value='2026-10-20';$('date-to').value='2026-10-20';$('date-from').dispatchEvent(new Event('change',{bubbles:true}));await sleep(140);expectIds(['m5991'],'date range combines with type, URL and member');await shot('type-search-combined');
$('clear-filters').click();await sleep(140);assert($('result-count').textContent.startsWith('6002 ')&&$('date-from').value===''&&$('message-search').value==='','clear restores all combined filters');
await type('link');await query('plain-link-needle');expectIds(['m5994'],'body-only URL is discoverable as link');$('clear-filters').click();await sleep(100);await flush();
const progressBeforeFeed=JSON.stringify((await qa('qaInspect')).progress);
$('nav-followed').click();await wait(()=>$('chat-view').classList.contains('followed-feed'),'dedicated followed feed');await sleep(120);expectIds(['m5980','m5981','m5983','m5984'],'followed feed joins groups by stable IDs');assert($('nav-followed').classList.contains('active')&&$('followed-count').textContent==='4','followed navigation and count are independent');assert(card('m5981').textContent.includes('新昵称'),'same stable ID remains followed after nickname changes');assert(!card('m5982')&&!card('m5985'),'same-name non-followed senders stay excluded');assert([...$('messages').querySelectorAll('.message-card')].every(c=>shown(c.querySelector('.reader-followed-badge'))&&c.querySelector('.followed-message-source')),'each followed row has an accent and source action');
assert([...$('followed-scope').options].map(o=>o.value).join(',')===',g,g2','followed group choices include all groups');await shot('followed-feed');
// Keep a source-group anchor visible while changing layout in a short viewport.
await qa('qaResize',{width:1120,height:460});await sleep(180);card('m5981').scrollIntoView({block:'start'});await sleep(160);$('reader-scroll').scrollTop+=rect(card('m5981')).top-rect($('reader-scroll')).top+24;await sleep(160);
const feedAnchor=()=>{const top=rect($('reader-scroll')).top,c=[...$('messages').querySelectorAll('.message-card')].find(c=>rect(c).bottom>top+3);return {id:c?.dataset.messageId,group:c?.dataset.groupId,offset:c?rect(c).top-top:0};};
const feedBefore=feedAnchor();__observations.followedAnchors={before:feedBefore};__observations.followedSetup={anchor:feedBefore,scrollTop:$('reader-scroll').scrollTop,clientHeight:$('reader-scroll').clientHeight,scrollHeight:$('reader-scroll').scrollHeight};assert(feedBefore.id==='m5981'&&feedBefore.group==='g2','followed anchor comes from another source group: '+JSON.stringify(__observations.followedSetup));
$('font-button').value='18';$('font-button').dispatchEvent(new Event('change',{bubbles:true}));await sleep(200);const fontAnchor=feedAnchor();__observations.followedAnchors.afterFont=fontAnchor;assert(fontAnchor.id===feedBefore.id&&fontAnchor.group===feedBefore.group&&Math.abs(fontAnchor.offset-feedBefore.offset)<2,'font change preserves cross-group followed anchor: '+JSON.stringify(__observations.followedAnchors));
$('settings-button').click();await wait(()=>$('settings-dialog').open,'settings for followed spacing');$('open-reading-appearance').click();await wait(()=>$('reading-appearance-dialog').open,'followed spacing dialog');document.querySelector('[data-consecutive-spacing="5"]').click();await wait(()=>!$('reading-font').disabled&&document.documentElement.dataset.readingConsecutiveSpacing==='5','followed spacing saved');$('done-reading-appearance').click();await sleep(200);const spacingAnchor=feedAnchor();__observations.followedAnchors.afterSpacing=spacingAnchor;assert(spacingAnchor.id===feedBefore.id&&spacingAnchor.group===feedBefore.group&&Math.abs(spacingAnchor.offset-feedBefore.offset)<2,'spacing change preserves cross-group followed anchor: '+JSON.stringify(__observations.followedAnchors));
await qa('qaRefreshFollowed');await wait(()=>card('m5981')?.textContent.includes('合成刷新'),'followed refresh received');await sleep(200);const refreshAnchor=feedAnchor();__observations.followedAnchors.afterRefresh=refreshAnchor;assert(refreshAnchor.id===feedBefore.id&&refreshAnchor.group===feedBefore.group&&Math.abs(refreshAnchor.offset-feedBefore.offset)<2,'message refresh preserves cross-group followed anchor: '+JSON.stringify(__observations.followedAnchors));await flush();assert(JSON.stringify((await qa('qaInspect')).progress)===progressBeforeFeed,'followed font, spacing and refresh never write group progress');
__observations.followedAnchors={before:feedBefore,afterFont:fontAnchor,afterSpacing:spacingAnchor,afterRefresh:refreshAnchor};
$('font-button').value='14';$('font-button').dispatchEvent(new Event('change',{bubbles:true}));await qa('qaResize',{width:1120,height:1000});await sleep(180);
$('followed-scope').value='g2';$('followed-scope').dispatchEvent(new Event('change',{bubbles:true}));await sleep(140);expectIds(['m5981','m5983'],'followed group scope filters exact group');await member('follow-A');expectIds(['m5981'],'followed group and member filters combine');
$('reader-scroll').dispatchEvent(new WheelEvent('wheel',{deltaY:240,bubbles:true}));$('reader-scroll').scrollTop=400;$('reader-scroll').dispatchEvent(new Event('scroll'));await sleep(650);await flush();assert(JSON.stringify((await qa('qaInspect')).progress)===progressBeforeFeed,'reading followed feed never overwrites group reading positions');
card('m5981').querySelector('.followed-message-source button').click();await wait(()=>!$('chat-view').classList.contains('followed-feed')&&card('m5981'),'return to source group');await flush();assert($('nav-chats').classList.contains('active')&&(await qa('qaInspect')).settings.activeGroupId==='g2','return action selects source group');assert(!card('m5981').querySelector('.followed-message-source'),'source-group row returns to ordinary reading view');
await jump('m5995');const own=card('m5995'),lookalike=card('m5996');assert(own.classList.contains('is-own-message')&&shown(own.querySelector('.own-message-label')),'own stable sender ID has own-message treatment');assert(!lookalike.classList.contains('is-own-message')&&!lookalike.querySelector('.own-message-label'),'same display name is not treated as self');const ownRect=rect(own),otherRect=rect(lookalike);assert(ownRect.left>otherRect.left+20&&Math.abs(ownRect.right-otherRect.right)<2,'own message is narrower and aligned to right edge');assert(getComputedStyle(own.querySelector('.message-heading')).justifyContent==='flex-end','own header aligns right');
const ownName=own.querySelector('.message-name'),ownTime=own.querySelector('.message-time'),nameRect=rect(ownName),timeRect=rect(ownTime),headingRect=rect(own.querySelector('.message-heading'));
assert(shown(ownName)&&nameRect.width>=56&&ownName.textContent==='同名用户','own name remains readable at narrow width');
for(const [label,r] of [['name',nameRect],['time',timeRect]])assert(r.left>=ownRect.left&&r.right<=ownRect.right&&r.top>=ownRect.top&&r.bottom<=ownRect.bottom,'own '+label+' stays fully inside card');
assert(nameRect.left>(ownRect.left+ownRect.right)/2&&timeRect.left>nameRect.left&&headingRect.right>=ownRect.right-25,'own name and time occupy right side of full-width heading');await shot('own-message-alignment');
await jump('m5998');$('settings-button').click();await wait(()=>$('settings-dialog').open,'settings for spacing');$('open-reading-appearance').click();await wait(()=>$('reading-appearance-dialog').open,'reading spacing dialog');
__observations.spacing=[];
for(const level of [1,2,3,4,5]){
  document.querySelector('[data-consecutive-spacing="'+level+'"]').click();await wait(()=>!$('reading-font').disabled&&document.documentElement.dataset.readingConsecutiveSpacing===String(level),'spacing level '+level);await sleep(120);
  const extra=Number(getComputedStyle(document.documentElement).getPropertyValue('--reading-consecutive-gap').replace('px','')),gap=rect(card('m5999').querySelector('.message-body')).top-rect(card('m5998').querySelector('.message-body')).bottom;
  assert(extra===[0,8,20,38,64][level-1],'spacing level has specified extra pixels');assert(Math.abs(gap-[24,32,44,62,88][level-1])<1,'actual consecutive message gap level '+level+': '+gap);assert((await qa('qaInspect')).readingAppearance.preferences.consecutiveSpacing===level,'spacing saved to temporary native preference store');__observations.spacing.push({level,extra,gap});
}
assert(__observations.spacing.at(-1).gap-__observations.spacing[0].gap>=63,'five spacing levels visibly span at least 64 pixels');await shot('spacing-range');$('done-reading-appearance').click();await jump('m5998');await shot('spacing-maximum');await flush();
__observations.discovery={types:['all','link','image','document','video'],filenameAndURL:true,memberAndDateCombined:true,followedAcrossGroups:true,stableIdsOnly:true,feedPreservesProgress:true,ownMessageStableID:true,ownRect,otherRect};
assert(__errors.length===0,'no JavaScript runtime errors after discovery: '+JSON.stringify(__errors));
return JSON.stringify({...__observations,messageCount:saved.messageCount,autoCleanupCalls:calls('autoCleanup').length,protectedMessages:cleanup.protectedMessages.map(m=>m.id),previewCalls:calls('previewContent').length,previewOperations:calls('contentPreviewAction').map(c=>c.payload.operation),network:'blocked; all RPC responses and images synthetic'});
"""#
    static let reloadTests = #"""
let assertions=0;const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{assertions++;if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let seq=0;const pending=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=pending.get(response.id);if(resolve){pending.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='v110-reload-'+(++seq);pending.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]');
await wait(()=>document.documentElement.dataset.readingConsecutiveSpacing==='5'&&card('action-target'),'native preferences restored after reload');
assert(getComputedStyle(document.documentElement).getPropertyValue('--reading-consecutive-gap').trim()==='64px','saved 64px spacing restored');
window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId:'g',messageId:'m5998'}}));await wait(()=>card('m5998')&&card('m5999'),'spacing pair after reload');card('m5998').scrollIntoView({block:'center'});await sleep(180);
const gap=card('m5999').querySelector('.message-body').getBoundingClientRect().top-card('m5998').querySelector('.message-body').getBoundingClientRect().bottom;assert(Math.abs(gap-88)<1,'actual 88px gap survives page reload');assert((await qa('qaInspect')).readingAppearance.preferences.consecutiveSpacing===5,'native file still contains level five');
await qa('qaSnapshot',{name:'v110-spacing-reloaded'});assert(__errors.length===0,'reload has no runtime errors');return JSON.stringify({assertions,spacingLevel:5,extraPixels:64,actualGap:gap,reloaded:true,screenshot:'v110-spacing-reloaded.png'});
"""#
}
