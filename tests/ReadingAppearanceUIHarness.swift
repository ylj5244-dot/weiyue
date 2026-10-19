import AppKit
import WebKit

@main final class ReadingAppearanceUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!, stateURL: URL!
    var state: [String: Any] = [:], phase = 0
    var pendingAI: Any?
    var previousApp: NSRunningApplication?, pendingNativeSelection: (id: Any, size: String)?, nativeSelectionSerial = 0
    var nativeFontsOnly: Bool { CommandLine.arguments.contains("--native-fonts") }
    let account = "synthetic-reading-appearance", timestamp = "2026-10-18T01:00:00Z"
    static func main() { let app = NSApplication.shared; let delegate = ReadingAppearanceUIHarness(); app.delegate = delegate; app.setActivationPolicy(delegate.nativeFontsOnly ? .accessory : .prohibited); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            previousApp = NSWorkspace.shared.frontmostApplication
            NotificationCenter.default.addObserver(self, selector: #selector(nativeMenuStarted(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-reading-appearance-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            stateURL = temp.appendingPathComponent("synthetic-state.json"); state = fixture(); try writeState()
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self, name: "app")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('Network is disabled in synthetic UI tests'));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1488, height: 1000), configuration: configuration); web.navigationDelegate = self
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.appearance = NSAppearance(named: .aqua); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.finish(false, "reading appearance UI timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture() -> [String: Any] {
        let names = ["沈远", "沈远", "沈远", "林初", "周宁", "周宁", "沈远", "林初"]
        let texts = ["阅读时先把已经确认的事实和自己的判断分开。", "这条消息加了阅读标记，标记应当常驻显示。", "同一个人的连续消息仍然属于一个发言块。", "这里是手动续读点，滚动不会覆盖这个位置。", "讨论可以继续，上一段读到哪里也不会丢失。", "每条消息保留单独选择、添加标记和引用的能力。", "重新发言时，发言块按三种颜色自然轮转。", "页面只使用合成内容进行界面验收。"]
        let formatter = ISO8601DateFormatter()
        let messages: [[String: Any]] = (0..<names.count).map { n -> [String: Any] in
            let date = formatter.string(from: Date(timeIntervalSince1970: 1_792_281_600 + Double(n * 60)))
            return ["accountId": account, "groupId": "g", "id": String(n), "senderId": "u" + names[n], "senderName": names[n], "sentAt": date, "text": texts[n], "attachments": []]
        }
        let longToken = String(repeating: "LongReference", count: 12)
        let answer = "先区分事实、判断和待验证问题，再整理共识与分歧。\n\n这是用于检查字号和换行的合成回答。扩大字号后，中文段落和长链接都应在右侧面板内自然折行。\n\nhttps://synthetic.invalid/" + longToken + "\n\n下一步：返回原文，核对依据与讨论发生的完整时间。 [网页1]"
        let search: [String: Any] = ["status": "success", "query": "合成测试", "searchedAt": timestamp, "sources": [["id": "网页1", "title": "合成参考来源 " + longToken, "url": "https://synthetic.invalid/reference", "siteName": "本地测试", "publishedAt": NSNull(), "excerpt": "只用于验证参考来源字体和换行，不访问外部网络。"]]]
        let discussion: [String: Any] = ["accountId": account, "id": "appearance", "title": "如何把讨论整理得更清楚", "createdAt": timestamp, "contextSnapshots": [], "messages": [["role": "user", "content": "请整理这段讨论的核心观点。", "createdAt": timestamp], ["role": "assistant", "content": answer, "reasoning": "先核对原文中的事实，再把观点与推断分开。" + longToken, "webSearch": search, "createdAt": timestamp]]]
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "阅读体验 · 合成验收", "selected": true]], "messages": messages, "bookmarks": [], "collections": [], "discussions": [discussion], "progress": [:], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "appearance"]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)! }
    func writeState() throws { try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic) }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func publish() { web.evaluateJavaScript("window.__saved=" + json(state), completionHandler: nil) }
    @objc func nativeMenuStarted(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, let pending = pendingNativeSelection else { return }
        pendingNativeSelection = nil
        let titles = menu.items.map { $0.title }, index = menu.items.firstIndex { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == pending.size }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let index { menu.performActionForItem(at: index) }; menu.cancelTracking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reply(pending.id, ["opened": true, "choices": titles, "selected": index != nil]) }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do { switch action {
        case "ready": state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]; publish(); reply(id, ["state": state, "hasAPIKey": true, "accountName": "合成验收", "appearance": "light"])
        case "save": state = payload["state"] as? [String: Any] ?? state; try writeState(); publish(); reply(id, ["revision": state["revision"] ?? 1])
        case "appearanceInspect": state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]; publish(); reply(id)
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "appearanceSnapshot":
            let name = payload["name"] as? String ?? ""
            guard ["v103-reading-day", "v103-reading-night", "v103-reading-narrow", "v103-reading-reloaded"].contains(name) else { finish(false, "invalid screenshot name"); return }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failed"); return }
                do { try data.write(to: self.output.appendingPathComponent(name + ".png")); self.web.evaluateJavaScript("window.__appearanceShot=" + self.json(name), completionHandler: nil); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "aiCapabilities": reply(id, ["thinking": true, "canDisableThinking": true])
        case "appearanceNativeFont":
            nativeSelectionSerial += 1; let serial = nativeSelectionSerial
            pendingNativeSelection = (id, payload["size"] as? String ?? "")
            NSApplication.shared.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(web)
            let x = payload["x"] as? Double ?? 1, y = payload["y"] as? Double ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let point = NSPoint(x: x, y: self.web.isFlipped ? y : self.web.bounds.height - y), target = self.web.hitTest(NSPoint(x: x, y: self.web.isFlipped ? y : self.web.bounds.height - y))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: self.web.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: serial, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                        if type == .leftMouseDown { target?.mouseDown(with: event) } else { target?.mouseUp(with: event) }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if serial == self.nativeSelectionSerial, self.pendingNativeSelection != nil { self.pendingNativeSelection = nil; self.reply(id, ["opened": false]) } }
        case "ai":
            // This host is a local stub: no provider, network or real credential is used.
            pendingAI = id
            web.evaluateJavaScript("window.onNativeEvent(" + json(["type": "aiProgress", "accountId": account, "requestId": payload["requestId"] ?? "", "phase": "answering", "contentDelta": "本地合成流式回答，用于检验实时文字缩放。", "reasoningDelta": "本地合成思考内容，用于检验实时文字缩放。"]) + ")", completionHandler: nil)
        case "appearanceCompleteAI": if let pendingAI { self.pendingAI = nil; reply(pendingAI, ["text": "本地合成流式回答，用于检验实时文字缩放。", "cancelled": false]) }; reply(id)
        case "webSearch", "openExternal", "openOfficial": finish(false, "appearance tests must not request external services: " + action)
        default: reply(id)
        } } catch { finish(false, error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let tests = nativeFontsOnly ? (phase == 0 ? Self.nativeFontTests : Self.nativeFontReloadTests) : (phase == 0 ? Self.tests : Self.reloadTests)
        web.callAsyncJavaScript(Self.helpers + tests, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                print("PASS phase \(self.phase): \(value)"); fflush(stdout)
                if self.phase == 0 { self.phase = 1; self.web.reload() } else { self.finish(true, self.nativeFontsOnly ? "native menu clicks and choices; four-corner hit regions; independent fonts; native-selected AI preference reload" : "persistent bookmark/resume markers; independent 14–22px AI text; temporary-disk reload; narrow panel; light/dark snapshots") }
            case .failure(let error): self.web.evaluateJavaScript("JSON.stringify({errors:window.__errors,settings:window.__saved?.settings,body:document.body.innerText.slice(-1800)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout); if nativeFontsOnly { previousApp?.activate(options: []) }; if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<160;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]'),post=(action,payload={})=>window.webkit.messageHandlers.app.postMessage({id:'appearance-'+Math.random(),action,payload});
const size=el=>parseFloat(getComputedStyle(el).fontSize),answer=()=>document.querySelector('.conversation-message.assistant');
const shot=async name=>{await wait(()=>$('toast').hidden,'notification settled');window.__appearanceShot='';post('appearanceSnapshot',{name});await wait(()=>window.__appearanceShot===name,'screenshot '+name);};
const visible=(el,label)=>{assert(el,label+' exists');let p=el;while(p&&p!==document.body){const s=getComputedStyle(p);assert(!p.hidden&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)>0,label+' visible through ancestors');p=p.parentElement;}const r=el.getBoundingClientRect();assert(r.width>0&&r.height>0,label+' has visible bounds');};
const absent=(id,kind)=>{const el=card(id)?.querySelector('.'+kind+'-indicator');return !el||(getComputedStyle(el).display==='none'&&el.getClientRects().length===0);};
const marker=(id,kind)=>{const c=card(id);assert(c&&!c.matches(':hover'),kind+' is inspected without hover');const el=c.querySelector('.message-reading-markers .'+kind+'-indicator');visible(el,kind+' marker');assert(el.textContent.trim().length>0,kind+' has a text label');assert(!el.closest('.message-actions'),kind+' is independent of hover actions');return el;};
const setSize=async n=>{$('ai-font-size').value=String(n);$('ai-font-size').dispatchEvent(new Event('change',{bubbles:true}));await wait(()=>size(answer())===n&&window.__saved?.settings.aiFontSize===n,'AI font size '+n+' persisted');};
const fontControls=()=>{const reader=$('font-button'),ai=$('ai-font-size');assert(reader.tagName==='SELECT'&&ai.tagName==='SELECT','both font controls use native dropdowns');assert([...reader.options].map(o=>o.value).join(',')==='14,16,18','reader keeps its original three choices');const styleKeys=['width','height','borderRadius','borderColor','backgroundColor','fontSize'];const a=getComputedStyle(reader.parentElement),b=getComputedStyle(ai.parentElement);for(const key of styleKeys)assert(a[key]===b[key],'matching font control '+key);for(const select of [reader,ai]){const outer=select.parentElement.getBoundingClientRect(),inner=select.getBoundingClientRect();assert(outer.width===64&&outer.height===28,'compact 64 by 28 font control');assert(inner.width>=outer.width-2&&inner.height>=outer.height-2,'native select fills the control');for(const fraction of [.15,.5,.85])assert(document.elementFromPoint(inner.left+inner.width*fraction,inner.top+inner.height/2)===select,'Aa, number and arrow all target the native select');select.focus();assert(document.activeElement===select,'font dropdown accepts keyboard focus');}ai.blur();};
const bookmark=async(id,note)=>{const before=new Set(window.__saved.bookmarks.map(b=>b.id));card(id).querySelector('.message-bookmark-action').click();assert(!$('bookmark-dialog').open,'direct bookmark opens no dialog');await wait(()=>window.__saved.bookmarks.some(b=>!before.has(b.id))&&!card(id).querySelector('.message-bookmark-action').disabled,'direct bookmark saved');const saved=window.__saved.bookmarks.find(b=>!before.has(b.id));$('nav-bookmarks').click();const entry=document.querySelector('.bookmark-card[data-bookmark-id="'+saved.id+'"]');assert(entry,'direct bookmark appears on bookmark page');entry.querySelector('.bookmark-edit-action').click();await wait(()=>$('bookmark-dialog').open,'bookmark note editor');$('bookmark-note').value=note;$('bookmark-form').requestSubmit();await wait(()=>!$('bookmark-dialog').open,'bookmark note saved');$('nav-chats').click();await wait(()=>card(id),'reader restored after note edit');};
const manual=async id=>{const action=card(id).querySelector('.manual-progress-action');if(action.closest('details'))action.closest('details').open=true;action.click();await wait(()=>window.__saved?.progress.g?.manual?.messageId===id,'manual point saved');};
const row=note=>[...$('bookmarks-list').querySelectorAll('.bookmark-card')].find(el=>el.querySelector('.bookmark-note')?.textContent===note);
const remove=async note=>{$('nav-bookmarks').click();$('bookmarks-active').click();const r=row(note);assert(r,'bookmark '+note+' exists');[...r.querySelectorAll('button')].find(b=>b.textContent==='删除').click();await wait(()=>!row(note),'bookmark deleted');$('nav-chats').click();await wait(()=>card('1'),'reader restored');};
const restore=async note=>{$('nav-bookmarks').click();$('bookmarks-deleted').click();const r=row(note);assert(r,'deleted bookmark '+note+' exists');[...r.querySelectorAll('button')].find(b=>b.textContent==='恢复书签').click();await wait(()=>!row(note),'bookmark restored');$('nav-chats').click();await wait(()=>card('1'),'reader restored');};
const noOverflow=()=>{for(const el of [$('inspector'),$('conversation'),$('conversation-messages'),...document.querySelectorAll('.conversation-message,.stream-reasoning pre,.web-sources')])assert(el.scrollWidth<=el.clientWidth+1,'no horizontal overflow '+el.id+' '+el.className+' '+el.scrollWidth+'/'+el.clientWidth);const r=$('ai-font-size').getBoundingClientRect(),p=$('inspector').getBoundingClientRect();assert(r.left>=p.left&&r.right<=p.right,'font control fits narrow panel');};
await wait(()=>card('5')&&answer()&&$('ai-font-size'),'reader and restored discussion');await sleep(200);
"""#
    static let tests = #"""
assert(!document.querySelector('#messages .message-avatar'),'focus reader contains no avatars');
assert($('ai-font-size').value==='14'&&size(answer())===14,'default AI reading font is 14px');assert([...$('ai-font-size').options].map(o=>o.value).join(',')==='14,16,18,20,22','explicit 14–22px choices');
fontControls();
const originalReaderSize=size(card('0').querySelector('.message-body'));
await bookmark('1','重点阅读');await manual('1');await sleep(2350);marker('1','bookmark');marker('1','manual-resume');assert(card('1').classList.contains('is-bookmarked')&&card('1').classList.contains('is-manual-resume'),'bookmark and resume can coexist on continuation');
await manual('3');await sleep(2350);assert(!card('1').classList.contains('is-manual-resume')&&absent('1','manual-resume'),'moving resume removes old marker');marker('1','bookmark');marker('3','manual-resume');assert(!card('3').classList.contains('target-message'),'persistent resume does not depend on transient target highlight');
const originalBookmark=window.__saved.bookmarks.find(b=>b.messageId==='1'&&!b.deletedAt);card('1').querySelector('.message-bookmark-action').click();await wait(()=>window.__saved.bookmarks.find(b=>b.id===originalBookmark.id)?.deletedAt&&!card('1').querySelector('.message-bookmark-action').disabled,'second click cancels bookmark');assert(!card('1').classList.contains('is-bookmarked')&&absent('1','bookmark'),'cancel removes durable marker');card('1').querySelector('.message-bookmark-action').click();await wait(()=>!window.__saved.bookmarks.find(b=>b.id===originalBookmark.id)?.deletedAt&&!card('1').querySelector('.message-bookmark-action').disabled,'third click restores original bookmark');assert(window.__saved.bookmarks.find(b=>b.id===originalBookmark.id).note==='重点阅读','restore retains original note');marker('1','bookmark');await remove('重点阅读');assert(!card('1').classList.contains('is-bookmarked')&&absent('1','bookmark'),'deleting last bookmark leaves no stale indicator');await restore('重点阅读');marker('1','bookmark');marker('3','manual-resume');
for(const n of [16,18,20,22,14,18]){await setSize(n);assert(size(card('0').querySelector('.message-body'))===originalReaderSize,'AI font does not change reader font');assert(size(document.querySelector('.conversation-message.user'))===n,'user messages follow AI size');assert(size(answer().querySelector('.stream-reasoning pre'))===n-1,'saved thinking follows AI size with one-pixel hierarchy');}
$('conversation').scrollTop=0;ReaderAppearance.restore('light');await sleep(100);const day=getComputedStyle(marker('1','bookmark')).backgroundColor;await shot('v103-reading-day');ReaderAppearance.restore('dark');await sleep(100);const night=getComputedStyle(marker('1','bookmark')).backgroundColor;assert(day!==night,'marker palette adapts for night');await shot('v103-reading-night');
await setSize(22);for(const n of [16,18,14,16]){$('font-button').value=String(n);$('font-button').dispatchEvent(new Event('change',{bubbles:true}));await sleep(80);assert(size(card('0').querySelector('.message-body'))===n&&size(answer())===22,'reader font dropdown leaves AI size unchanged');}
ReaderLayout.restore({...ReaderLayout.getState().preferences,inspectorWidth:280});await sleep(150);assert(Math.abs($('inspector').getBoundingClientRect().width-ReaderLayout.getState().inspectorMin)<1,'minimum inspector width exercised');fontControls();document.querySelectorAll('.stream-reasoning,.web-sources').forEach(el=>el.open=true);$('conversation').scrollTop=0;noOverflow();await shot('v103-reading-narrow');
await wait(()=>!$('ai-send').disabled,'local mock AI controls ready');$('ai-question').value='本地合成流式验收';$('ai-form').requestSubmit();await wait(()=>$('ai-stream-answer')?.textContent.includes('本地合成流式回答'),'local mock stream');
for(const n of [20,22]){await setSize(n);assert(size($('ai-stream-answer'))===n&&size($('ai-stream-thought'))===n-1,'live answer and thinking follow AI size');noOverflow();}post('appearanceCompleteAI');await wait(()=>!$('ai-cancel').hidden===false,'local mock stream completed');
await window.flushBeforeQuit();assert(window.__saved.settings.aiFontSize===22,'AI preference saved before page reload');assert(window.__errors.length===0,'no UI script errors '+JSON.stringify(window.__errors));
return JSON.stringify({noAvatars:true,markerWithoutHover:true,continuationMarker:true,combinedMarkers:true,manualMoveClearsOld:true,bookmarkToggleRestore:true,deleteRestore:true,fontChoices:[14,16,18,20,22],independentSizes:true,liveStreamScaling:true,narrowWidth:ReaderLayout.getState().inspectorMin,noOverflow:true,day,night});
"""#
    static let reloadTests = #"""
assert($('ai-font-size').value==='22'&&size(answer())===22&&window.__saved.settings.aiFontSize===22,'22px preference restored from temporary disk after reload');marker('1','bookmark');marker('3','manual-resume');assert(absent('1','manual-resume'),'old manual point stays cleared after reload');assert(window.__saved.bookmarks.filter(b=>!b.deletedAt).length===1,'only restored bookmark remains active');
ReaderLayout.restore({...ReaderLayout.getState().preferences,inspectorWidth:280});await sleep(100);document.querySelectorAll('.stream-reasoning,.web-sources').forEach(el=>el.open=true);noOverflow();$('conversation').scrollTop=0;await shot('v103-reading-reloaded');assert(window.__errors.length===0,'no reload script errors');return JSON.stringify({diskReload:true,font22:true,persistentMarkers:true,narrowLayout:true});
"""#
    static let nativeFontTests = #"""
const nativeCall=(action,payload)=>new Promise(resolve=>{const id='native-font-'+Math.random(),receive=window.nativeReceive;window.nativeReceive=value=>{if(value.id===id){window.nativeReceive=receive;resolve(value.result);}else receive(value);};window.webkit.messageHandlers.app.postMessage({id,action,payload});});
const nativePick=async(id,n)=>{const select=$(id),r=select.getBoundingClientRect();for(const [x,y] of [[r.left+2,r.top+2],[r.right-2,r.top+2],[r.left+2,r.bottom-2],[r.right-2,r.bottom-2]])assert(document.elementFromPoint(x,y)===select,'four corners target native dropdown '+id);const result=await nativeCall('appearanceNativeFont',{x:r.left+r.width/2,y:r.top+r.height/2,size:String(n)});assert(result.opened&&result.selected,'real native menu opened and selected '+id+' '+JSON.stringify(result));await wait(()=>select.value===String(n),'native menu commits '+id);return result.choices;};
const reader=await nativePick('font-button',18);assert(size(card('0').querySelector('.message-body'))===18&&size(answer())===14,'native reader choice only changes reader');
const ai=await nativePick('ai-font-size',22);await wait(()=>window.__saved.settings.aiFontSize===22,'native AI selection saved');assert(size(answer())===22&&size(card('0').querySelector('.message-body'))===18,'native AI choice only changes AI');await window.flushBeforeQuit();return JSON.stringify({nativeReaderChoices:reader,nativeAIChoices:ai,nativeSelection:true,fourCorners:true,independentSizes:true});
"""#
    static let nativeFontReloadTests = #"""
assert($('ai-font-size').value==='22'&&size(answer())===22&&window.__saved.settings.aiFontSize===22,'native-selected AI 22 restored after reload');assert($('font-button').value==='14'&&size(card('0').querySelector('.message-body'))===14,'reader retains existing session-only setting behavior');return JSON.stringify({nativeSelectedAIRestored:true,readerSessionOnly:true});
"""#
}
