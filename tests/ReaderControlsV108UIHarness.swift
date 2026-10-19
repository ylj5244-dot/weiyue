import AppKit
import WebKit

@main final class ReaderControlsV108UIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!, source: URL!, appearances: ReadingAppearanceStore!
    var state: [String: Any] = [:], phase = 0, pendingAI: Any?, pendingContent: Any?
    var previousApp: NSRunningApplication?
    var requestCount = 0, cancelCount = 0, contentCancelCount = 0, nextImport = "normal"
    let account = "v108-synthetic", timestamp = "2026-10-18T08:00:00Z"
    static func main() { let app = NSApplication.shared; let delegate = ReaderControlsV108UIHarness(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            previousApp = NSWorkspace.shared.frontmostApplication
            source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-v108-ui-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            appearances = try ReadingAppearanceStore(directory: temp.appendingPathComponent("appearance-data"))
            state = fixture(); try saveState()
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController.add(self, name: "app")
            config.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.__testReplies={};window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('External network disabled in fixture'));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1488, height: 1000), configuration: config); web.navigationDelegate = self; web.autoresizingMask = [.width, .height]
            window = NSWindow(contentRect: web.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false); window.contentView = web; window.appearance = NSAppearance(named: .aqua); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.finish(false, "v108 UI timed out") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture() -> [String: Any] {
        var messages: [[String: Any]] = []
        for n in 0..<240 {
            let text = n == 3 ? "Original English paragraph.\nAnother line with 123 numbers." : n == 0 ? "旧讨论资料，仅供历史使用。" : "这是第 \(n) 条合成消息，文字行距与消息间距一起调整。\n第二行保留原有段落，阅读位置不应跳到开头。"
            let attachments: [[String: Any]] = n == 7 ? [["type": "document", "name": "合成文档.pdf", "url": "https://synthetic.invalid/document.pdf"]] : []
            messages.append(["accountId": account, "groupId": "g", "id": String(n), "senderId": n < 5 ? "u0" : "u\(n / 3)", "senderName": n < 5 ? "沈远" : "读者\(n / 3)", "sentAt": timestamp, "text": text, "attachments": attachments])
        }
        let bookmark: [String: Any] = ["accountId": account, "id": "b1", "groupId": "g", "messageId": "1", "note": "内蒙？", "messageSentAt": timestamp, "createdAt": timestamp, "snapshot": messages[1]]
        let manual: [String: Any] = ["accountId": account, "groupId": "g", "messageId": "1", "offset": 0, "updatedAt": timestamp, "messageSentAt": timestamp]
        let discussion: [String: Any] = ["accountId": account, "id": "old", "title": "旧讨论", "createdAt": timestamp, "contextSnapshots": [messages[0]], "messages": [["role": "user", "content": "旧提问", "createdAt": timestamp], ["role": "assistant", "content": "这是旧讨论的回答。", "createdAt": timestamp]]]
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "阅读与皮肤 · 合成验收", "selected": true]], "messages": messages, "bookmarks": [bookmark], "collections": [], "discussions": [discussion], "progress": ["g": ["manual": manual]], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "old"]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)! }
    func saveState() throws { try JSONSerialization.data(withJSONObject: state).write(to: temp.appendingPathComponent("state.json"), options: .atomic) }
    func publish() { web.evaluateJavaScript("window.__saved=" + json(state) + ";window.__counts=" + json(["requests": requestCount, "cancel": cancelCount, "cancelContent": contentCancelCount]), completionHandler: nil) }
    func reply(_ id: Any, _ result: Any = [:], error: String? = nil) {
        var payload: [String: Any] = ["id": id, "ok": error == nil, "result": result]; if let error { payload["error"] = error }
        let test = (id as? String)?.hasPrefix("test-") == true ? "window.__testReplies[\(json(id))]=\(json(payload));" : ""
        web.evaluateJavaScript(test + "window.nativeReceive(" + json(payload) + ")", completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do { switch action {
        case "ready":
            state = try JSONSerialization.jsonObject(with: Data(contentsOf: temp.appendingPathComponent("state.json"))) as! [String: Any]; publish()
            reply(id, ["state": state, "hasAPIKey": true, "accountName": "本地合成验收", "appearance": "light", "readingAppearance": appearances.snapshot()])
        case "save": state = payload["state"] as? [String: Any] ?? state; try saveState(); publish(); reply(id)
        case "aiCapabilities": reply(id, ["thinking": true, "canDisableThinking": true])
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "saveReadingAppearance": reply(id, try appearances.save(payload["preferences"] as! [String: Any]))
        case "importReadingSkin", "importReadingFont":
            if nextImport == "cancel" { nextImport = "normal"; reply(id, ["cancelled": true]); return }
            if nextImport == "invalid" { nextImport = "normal"; reply(id, error: "合成无效文件：原设置已保留。"); return }
            let mode = nextImport; nextImport = "normal"
            var result = try action == "importReadingSkin" ? appearances.importSkin(source.appendingPathComponent("skin-example.weiyue-skin.json")) : appearances.importFont(URL(fileURLWithPath: mode == "otf" ? "/System/Library/Fonts/Supplemental/STIXGeneralBol.otf" : "/System/Library/Fonts/Supplemental/Arial.ttf"))
            if mode == "decode-error", var data = result["fontData"] as? [String: String] { data["base64"] = "AAAA"; result["fontData"] = data }
            reply(id, result)
        case "exportReadingSkinSample":
            let content = try Data(contentsOf: source.appendingPathComponent("skin-example.weiyue-skin.json")); _ = try ReadingAppearanceStore.skin(JSONSerialization.jsonObject(with: content)); try content.write(to: temp.appendingPathComponent("exported-skin.json")); reply(id)
        case "copy":
            let pasteboard = NSPasteboard.withUniqueName(); pasteboard.setString(payload["text"] as? String ?? "", forType: .string)
            web.evaluateJavaScript("window.__copied=" + json(pasteboard.string(forType: .string) ?? ""), completionHandler: nil); pasteboard.releaseGlobally(); reply(id)
        case "ai":
            requestCount += 1; pendingAI = id; publish(); web.evaluateJavaScript("window.__lastRequest=" + json(payload), completionHandler: nil)
            let event: [String: Any] = ["type": "aiProgress", "accountId": account, "requestId": payload["requestId"] ?? "", "phase": "answering", "contentDelta": "已收到的部分回答。"]
            web.evaluateJavaScript("window.onNativeEvent(" + json(event) + ")", completionHandler: nil)
        case "cancelAI":
            cancelCount += 1; let old = pendingAI; pendingAI = nil; publish()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.reply(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { if let old { self.reply(old, ["text": "LATE_RESULT_MUST_NOT_APPEAR"]) } }
        case "extractAttachment": pendingContent = id
        case "cancelContent":
            contentCancelCount += 1; let old = pendingContent; pendingContent = nil; publish()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.reply(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { if let old { self.reply(old, ["kind": "document", "name": "合成文档.pdf", "text": "LATE_DOCUMENT", "method": "fixture", "pageCount": 1, "processedPages": 1, "warnings": []]) } }
        case "testInspect": publish(); reply(id, appearances.snapshot())
        case "testImportMode": nextImport = payload["mode"] as? String ?? "normal"; reply(id)
        case "testFocus": NSApp.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(web); reply(id)
        case "testResize": window.setContentSize(NSSize(width: payload["width"] as? Double ?? 1488, height: payload["height"] as? Double ?? 1000)); reply(id)
        case "testSnapshot":
            let name = payload["name"] as? String ?? ""
            guard name.hasPrefix("v108-"), !name.contains("/") else { throw ReaderError.message("invalid snapshot name") }
            web.takeSnapshot(with: nil) { image, error in
                do { guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw ReaderError.message(error?.localizedDescription ?? "snapshot failed") }; try data.write(to: self.output.appendingPathComponent(name + ".png")); self.reply(id) } catch { self.reply(id, error: error.localizedDescription) }
            }
        case "openOfficial": reply(id) // local routing only; no WebView or network is opened
        case "webSearch", "openExternal", "loadRange": finish(false, "unexpected external operation: " + action)
        default: reply(id)
        } } catch { reply(id, error: error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSApp.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(web)
        web.callAsyncJavaScript(Self.helpers + (phase == 0 ? Self.tests : Self.reloadTests), arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                print("PASS phase \(self.phase): \(value)"); fflush(stdout)
                if self.phase == 0 { self.phase = 1; self.web.reload() } else { self.finish(true, "v108 source isolation, cancellation, copying, density/skin/font persistence and geometry") }
            case .failure(let error): print("Native focus: active=\(NSApp.isActive) key=\(self.window.isKeyWindow) firstResponder=\(String(describing:self.window.firstResponder))"); self.web.evaluateJavaScript("JSON.stringify({errors:window.__errors,body:document.body.innerText.slice(-2500)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout); previousApp?.activate(options: []); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
const request=async(action,payload={})=>{const id='test-'+Math.random();window.webkit.messageHandlers.app.postMessage({id,action,payload});await wait(()=>window.__testReplies[id],action);const reply=window.__testReplies[id];delete window.__testReplies[id];if(!reply.ok)throw Error(reply.error);return reply.result;};
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]'),rect=el=>el.getBoundingClientRect(),style=el=>getComputedStyle(el);
const hit=el=>{const r=rect(el);return el.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2));};
const inside=(a,b)=>{a=rect(a);b=rect(b);return a.left>=b.left-1&&a.right<=b.right+1&&a.top>=b.top-1&&a.bottom<=b.bottom+1;};
const openAppearance=async()=>{$('settings-button').click();await wait(()=>$('settings-dialog').open,'settings');$('open-reading-appearance').click();await wait(()=>$('reading-appearance-dialog').open,'reading appearance');};
const saved=async()=>{const result=await request('testInspect');await wait(()=>!$('reading-font').disabled,'appearance idle');return result;};
const select=async(id,value)=>{$(id).value=value;$(id).dispatchEvent(new Event('change',{bubbles:true}));await wait(()=>!$(id).disabled,'select saved');await sleep(80);};
const shot=async(name,focusId)=>{await wait(()=>$('toast').hidden,'toast settled');if(focusId){await request('testFocus');const target=card(focusId).querySelector('.message-copy-action');target.focus();try{await wait(()=>document.activeElement===target&&Number(style(target.parentElement).opacity)===1,'action rail visible');}catch(error){throw Error(name+' '+error.message+' '+JSON.stringify({hasFocus:document.hasFocus(),targetConnected:target.isConnected,active:document.activeElement?.outerHTML?.slice(0,600),opacity:target.parentElement?style(target.parentElement).opacity:null,currentTarget:card(focusId)?.querySelector('.message-copy-action')===target,focusWithin:target.parentElement?.matches(':focus-within')}));}}await request('testSnapshot',{name});};
const noOverflow=()=>{for(const el of [$('main'),$('inspector'),$('reader-scroll'),$('reading-appearance-dialog')].filter(el=>el.getClientRects().length))assert(el.scrollWidth<=el.clientWidth+1,'horizontal overflow '+el.id+' '+el.scrollWidth+'/'+el.clientWidth);};
await wait(()=>card('3')&&window.__saved&&!$('ai-send').disabled,'ready');await sleep(120);
"""#
    static let tests = #"""
assert($('context-count').textContent==='已选 1 条','old sources restored');const old=JSON.stringify(window.__saved.discussions[0]);
$('new-discussion').click();await wait(()=>$('context-count').textContent==='已选 0 条','new sources clear');assert($('context-list').children.length===0,'new source list empty');assert(JSON.stringify(window.__saved.discussions[0])===old,'history source and answer unchanged');
card('3').querySelector('.message-copy-action').click();await wait(()=>window.__copied,'copied');assert(window.__copied===window.__saved.messages.find(m=>m.id==='3').text,'copy retains exact original');assert(card('3').querySelector('.message-actions').firstElementChild.classList.contains('message-copy-action'),'copy is first');
assert($('enter-standby').querySelector('.standby-cap svg'),'power cap survives render');assert(Math.abs(rect($('enter-standby').querySelector('.standby-cap')).width-35)<1,'round standby cap');
const row=document.querySelector('.recent-bookmark-row'),edit=row.querySelector('.recent-bookmark-edit'),date=row.querySelector('time');assert(inside(edit,row)&&rect(row).right-rect(edit).right>=7,'note safely inset');assert(rect(date).right-parseFloat(style(date).paddingRight)<=rect(edit).left+1,'date and note do not overlap');assert(hit(edit),'note hit target');edit.click();await wait(()=>$('bookmark-dialog').open,'note opens edit');$('bookmark-dialog').close();
card('1').querySelector('.message-copy-action').focus();for(const button of card('1').querySelectorAll('.message-actions button[aria-pressed="true"]')){assert(style(button).boxShadow==='none','selected fill has no outside shadow');assert(inside(button,button.parentElement),'selected button fits rail');}await shot('v108-controls-wide','1');
$('ai-question').value='新的空白讨论';$('ai-form').requestSubmit();await wait(()=>window.__counts.requests===1&&$('ai-stream-answer')?.textContent.includes('已收到'),'streaming');assert(!$('ai-cancel').hidden&&hit($('ai-cancel')),'stop visible and clickable');assert($('ai-send').hidden,'stop occupies send position');assert(window.__lastRequest.sources.length===0&&!JSON.stringify(window.__lastRequest.messages).includes('旧讨论资料'),'new request has no old sources');await shot('v108-stop');
$('ai-cancel').click();assert($('ai-cancel').disabled&&$('ai-stop-label').textContent.includes('正在停止'),'stop locks through cancellation');$('ai-cancel').click();await wait(()=>!$('ai-send').disabled,'cancel acknowledged');await sleep(350);assert(window.__counts.cancel===1,'single cancellation');assert(!document.body.textContent.includes('LATE_RESULT_MUST_NOT_APPEAR'),'late answer ignored');assert(window.__saved.discussions.some(d=>d.messages.some(m=>m.status==='interrupted'&&m.content==='已收到的部分回答。')),'partial answer preserved');
$('new-discussion').click();card('3').querySelector('.message-translate-action').click();await wait(()=>window.__counts.requests===2&&!$('ai-cancel').hidden,'inline stop available');$('ai-cancel').click();await wait(()=>!$('ai-send').disabled,'inline cancellation');await sleep(350);assert(window.__counts.cancel===2,'inline uses native cancellation');
card('7').scrollIntoView({block:'center'});await sleep(80);const menu=card('7').querySelector('.attachment-more-menu');menu.value='add';menu.dispatchEvent(new Event('change',{bubbles:true}));await wait(()=>!$('ai-cancel').hidden,'content stop available');$('ai-cancel').click();await wait(()=>!$('ai-send').disabled,'content cancellation');await sleep(260);assert(window.__counts.cancelContent===1&&$('context-count').textContent==='已选 0 条','late extraction cannot append sources');
$('reader-scroll').scrollTop=0;await sleep(100);await openAppearance();const metrics=[];
for(const level of [1,2,3,4,5]){document.querySelector('[data-reading-density="'+level+'"]').click();await wait(()=>!$('reading-font').disabled,'density save');await sleep(60);const r=await saved();assert(r.preferences.density===level,'density persisted');metrics.push({level,line:parseFloat(style(card('2').querySelector('.message-body')).lineHeight),padding:parseFloat(style(card('2')).paddingBottom)});}
for(let i=1;i<metrics.length;i++)assert(metrics[i].line>metrics[i-1].line&&metrics[i].padding>metrics[i-1].padding,'both density measures increase');assert(parseFloat(style(card('2').querySelector('.message-body')).fontSize)===14,'density leaves size unchanged');
$('import-reading-skin').click();await wait(()=>!$('reading-skin').disabled,'skin import');let current=await saved();assert(current.skins.length===1&&document.documentElement.classList.contains('custom-reading-skin'),'skin imported');assert(style(document.documentElement).getPropertyValue('--panel').trim()==='#fffdf6','day palette applied');await shot('v108-reading-skin-day');ReaderAppearance.restore('dark');await sleep(100);assert(style(document.documentElement).getPropertyValue('--panel').trim()==='#222f28','night palette applied');await shot('v108-reading-skin-night');ReaderAppearance.restore('light');
const skinBefore=current.preferences.skinId;await request('testImportMode',{mode:'invalid'});$('import-reading-skin').click();await wait(()=>!$('reading-skin').disabled,'invalid skin returned');assert((await saved()).preferences.skinId===skinBefore&&$('reading-appearance-status').classList.contains('error'),'invalid import preserves skin and explains error');
await request('testImportMode',{mode:'cancel'});$('import-reading-font').click();await wait(()=>!$('reading-font').disabled,'cancelled font import');assert((await saved()).fonts.length===0,'cancel does not add font');
await select('reading-font','family:Arial');assert(style(document.documentElement).fontFamily.startsWith('Arial'),'installed font applied');
$('import-reading-font').click();await wait(()=>!$('reading-font').disabled,'font import');current=await saved();assert(current.fonts.length===1&&current.preferences.fontChoice.startsWith('import:'),'font file imported');assert([...document.fonts].some(font=>font.family.startsWith('WeiyueImported_')&&font.status==='loaded'),'imported bytes actually decoded by WebKit');assert(style(document.documentElement).fontFamily.includes('WeiyueImported_'),'imported font applied');
const ttfChoice=current.preferences.fontChoice;await request('testImportMode',{mode:'decode-error'});$('import-reading-font').click();await wait(()=>!$('reading-font').disabled,'decode error returned');assert($('reading-appearance-status').textContent.includes('字体显示暂用系统默认')&&$('reading-appearance-status').classList.contains('error'),'font decode failure stays visible, not replaced by success');await select('reading-font',ttfChoice);assert([...document.fonts].some(font=>font.status==='loaded'),'valid font can recover after decode error');
await request('testImportMode',{mode:'otf'});$('import-reading-font').click();await wait(()=>!$('reading-font').disabled,'OTF import');current=await saved();assert(current.fonts.length===2&&current.fonts.some(font=>font.extension==='otf'),'OTF file accepted');assert([...document.fonts].some(font=>font.status==='loaded'),'OTF decoded by WebKit');await select('reading-font',ttfChoice);
$('export-reading-sample').click();await wait(()=>!$('reading-font').disabled,'sample exported');noOverflow();await shot('v108-reading-font');$('done-reading-appearance').click();
await request('testResize',{width:1120});await sleep(140);$('reader-scroll').scrollTop=0;await sleep(100);card('1').querySelector('.message-copy-action').focus();noOverflow();for(const c of [card('0'),card('1'),card('3')]){const rail=c.querySelector('.message-actions');assert(inside(rail,c),'floating actions fit narrow card');assert(rect(rail).bottom<=rect(c.querySelector('.message-body-row')).top+1,'actions do not obscure text');for(const button of rail.children)assert(inside(button,rail),'every button fits rail');}await shot('v108-controls-narrow','1');
await request('testResize',{width:1120,height:700});await sleep(100);await openAppearance();noOverflow();assert(inside($('done-reading-appearance'),$('reading-appearance-dialog'))&&hit($('done-reading-appearance')),'footer reachable at minimum height');await shot('v108-settings-minimum');$('done-reading-appearance').click();await request('testResize',{width:1120,height:1000});await sleep(100);
// Near the end, compacting content may put the desired top below the legal
// scroll maximum. Verify the browser clamps at the end while keeping it visible.
window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId:'g',messageId:'230'}}));await wait(()=>card('230'),'near-end destination');await sleep(300);
await openAppearance();document.querySelector('[data-reading-density="1"]').click();await wait(()=>!$('reading-font').disabled,'near-end density change');await sleep(300);
const endScroll=$('reader-scroll');assert(Math.abs(endScroll.scrollTop-(endScroll.scrollHeight-endScroll.clientHeight))<2,'near-end compaction clamps at legal scroll end');assert(rect(card('230')).bottom>rect(endScroll).top&&rect(card('230')).top<rect(endScroll).bottom,'near-end reading target stays visible');
document.querySelector('[data-reading-density="5"]').click();await wait(()=>!$('reading-font').disabled,'restore before middle test');$('done-reading-appearance').click();
// A deep position with sufficient following content must preserve exact offset.
window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId:'g',messageId:'210'}}));await wait(()=>card('210'),'deep reader destination');await sleep(300);
const readingAnchor=()=>{const top=rect($('reader-scroll')).top,c=[...document.querySelectorAll('.message-card')].find(c=>rect(c).bottom>top+1);return {id:c.dataset.messageId,offset:top-rect(c).top};};const beforeDensity=readingAnchor();assert(beforeDensity.id==='210','newer navigation to 210 survives pending appearance reflow '+JSON.stringify(beforeDensity));await openAppearance();document.querySelector('[data-reading-density="1"]').click();await wait(()=>!$('reading-font').disabled,'deep density change');await sleep(300);let kept=readingAnchor();assert(kept.id===beforeDensity.id&&Math.abs(kept.offset-beforeDensity.offset)<2,'density preserves deep reading anchor '+JSON.stringify({beforeDensity,kept}));await select('reading-font','system');await sleep(300);kept=readingAnchor();assert(kept.id===beforeDensity.id&&Math.abs(kept.offset-beforeDensity.offset)<2,'font change preserves deep reading anchor');document.querySelector('[data-reading-density="5"]').click();await wait(()=>!$('reading-font').disabled,'restore wide density');await select('reading-font',ttfChoice);$('done-reading-appearance').click();$('reader-scroll').scrollTop=0;await wait(()=>card('3'),'return to top');await sleep(100);
$('enter-standby').click();await wait(()=>window.__saved.settings.readerStandby===true,'standby saved');assert($('standby-label').textContent==='已待机'&&$('enter-standby').querySelector('.standby-cap svg'),'standby button state retains cap');document.querySelector('.group-pick').click();await wait(()=>card('3'),'return to group');
await window.flushBeforeQuit();assert(window.__errors.length===0,'no script errors '+JSON.stringify(window.__errors));return JSON.stringify({newSourcesEmpty:true,historyPreserved:true,copyExact:true,stopPaths:3,lateResultsIgnored:true,metrics,skinModes:2,invalidImportPreserved:true,fontLoaded:true,narrowGeometry:true,deepAnchorPreserved:true,nearEndClampVerified:true,standby:true});
"""#
    static let reloadTests = #"""
assert(document.documentElement.dataset.readingDensity==='5','density restored');assert(document.documentElement.classList.contains('custom-reading-skin'),'skin restored');assert([...document.fonts].some(font=>font.family.startsWith('WeiyueImported_')&&font.status==='loaded'),'font restored after reload');
await openAppearance();const before=await saved();assert(before.preferences.density===5&&before.fonts.length===2&&before.skins.length===1,'assets and preferences persisted');await shot('v108-reading-reloaded');$('reset-reading-appearance').click();await wait(()=>!$('reading-font').disabled,'reset');const after=await saved();assert(after.preferences.density===3&&after.preferences.skinId==='default'&&after.preferences.fontChoice==='system','defaults restored');assert(after.fonts.length===2&&after.skins.length===1,'reset keeps imports available');assert(!document.documentElement.classList.contains('custom-reading-skin')&&!style(document.documentElement).fontFamily.includes('WeiyueImported_'),'default appearance visible');assert([...document.fonts].filter(font=>font.family.startsWith('WeiyueImported_')).length===0,'unused font face released');$('done-reading-appearance').click();noOverflow();assert(window.__errors.length===0,'no reload script errors');return JSON.stringify({reload:true,fontLoaded:true,restoreDefault:true,importsKept:true});
"""#
}
