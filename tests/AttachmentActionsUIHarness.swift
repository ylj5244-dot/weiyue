import AppKit
import WebKit

// Synthetic accounts, image bytes, extraction results and AI replies only.
// No application installation, real user state, network or external file action.
@main final class AttachmentActionsUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
    var previousApp: NSRunningApplication?
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!
    var states: [String: [String: Any]] = [:]
    var account = "synthetic-attachments-a"
    var calls: [[String: Any]] = [], extractions: [[String: Any]] = [], routes: [[String: Any]] = []
    var pendingExtractions: [(Any, [String: Any])] = [], pendingAI: [(Any, Int)] = []
    var extractionMode = "success", aiMode = "success", mouseEventNumber = 0
    let timestamp = "2026-10-19T01:00:00Z"
    var imageData = Data()
    var pendingNativeSelection: (id: Any, title: String)?, nativeSelectionSerial = 0
    static func main() { let app = NSApplication.shared; let delegate = AttachmentActionsUIHarness(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            previousApp = NSWorkspace.shared.frontmostApplication
            NotificationCenter.default.addObserver(self, selector: #selector(nativeMenuStarted(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-attachment-ui-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            states[account] = fixture(account)
            let image = NSImage(size: NSSize(width: 300, height: 160))
            image.lockFocus(); NSColor(calibratedRed: 0.85, green: 0.92, blue: 0.99, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 300, height: 160)).fill()
            ("SYNTHETIC IMAGE 0" as NSString).draw(at: NSPoint(x: 25, y: 92), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.61, alpha: 1)])
            ("Selected attachment only" as NSString).draw(at: NSPoint(x: 25, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray]); image.unlockFocus()
            imageData = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self, name: "app"); configuration.setURLSchemeHandler(self, forURLScheme: "weiyue-media")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('Network disabled in attachment UI tests'));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1488, height: 1000), configuration: configuration); web.navigationDelegate = self
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.ignoresMouseEvents = true; window.acceptsMouseMovedEvents = true; window.appearance = NSAppearance(named: .aqua); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 110) { self.finish(false, "attachment UI timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture(_ account: String) -> [String: Any] {
        let attachments: [[String: Any]] = [
            ["type": "image", "name": "SELECTED_IMAGE_0.png", "url": "https://synthetic.invalid/image-0.png"],
            ["type": "document", "name": "SELECTED_REPORT_1_用于核验窄栏换行与悬浮操作不遮挡文件标题的长名称.pdf", "url": "https://synthetic.invalid/report-1.pdf", "size": 123456],
            ["type": "image", "name": "UNSELECTED_IMAGE_2.png", "url": "https://synthetic.invalid/image-2.png"],
            ["type": "video", "name": "合成视频_用于核验完整文件名与打开按钮宽度.mp4", "url": "https://synthetic.invalid/video-3.mp4"],
            ["type": "link", "name": "合成链接_用于核验独立窗口打开与文字完整显示", "url": "https://synthetic.invalid/link-4"]
        ]
        let message: [String: Any] = ["accountId": account, "groupId": "g", "id": "m0", "senderId": "member", "senderName": "附件操作合成验收", "sentAt": timestamp, "text": "UNSELECTED_MESSAGE_BODY_MUST_NOT_ENTER_AI", "attachments": attachments]
        let old: [String: Any] = ["accountId": account, "groupId": "g", "id": "m1", "senderId": "old-member", "senderName": "旧资料", "sentAt": "2026-10-19T00:59:00Z", "text": "OLD_CONTEXT_MUST_NOT_ENTER_AI", "attachments": []]
        let discussion: [String: Any] = ["accountId": account, "id": "existing", "title": "旧讨论必须保留", "createdAt": timestamp, "instructions": "OLD_INSTRUCTIONS_MUST_NOT_ENTER_AI", "contextSnapshots": [old], "messages": [["role": "user", "content": "OLD_HISTORY_QUESTION", "createdAt": timestamp], ["role": "assistant", "content": "OLD_HISTORY_ANSWER", "createdAt": timestamp]]]
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "附件操作 · 合成验收", "selected": true]], "messages": [old, message], "bookmarks": [], "collections": [], "discussions": [discussion], "progress": [:], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic-attachment-model", "readMode": "text", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "existing", "aiDraftInstructions": "OLD_DRAFT_MUST_NOT_ENTER_AI"]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func error(_ id: Any, _ message: String) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": false, "error": message]) + ")", completionHandler: nil) }
    func publish() { web.evaluateJavaScript("window.__saved=" + json(states[account] ?? [:]) + ";window.__calls=" + json(calls) + ";window.__extractions=" + json(extractions) + ";window.__routes=" + json(routes) + ";window.__pendingExtractions=\(pendingExtractions.count);window.__pendingAI=\(pendingAI.count);", completionHandler: nil) }
    func extracted(_ payload: [String: Any]) -> [String: Any] {
        let index = payload["attachmentIndex"] as? Int ?? 0, expected = payload["expectedAttachment"] as? [String: Any] ?? [:]
        return ["kind": index == 1 ? "document" : "image", "name": expected["name"] as? String ?? "synthetic", "text": "SELECTED_ATTACHMENT_\(index)_CONTENT\nRevenue 120. Original source paragraph.", "method": "synthetic-local-extraction", "pageCount": 2, "processedPages": 2, "truncated": false, "warnings": []]
    }
    @objc func nativeMenuStarted(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, let pending = pendingNativeSelection else { return }
        pendingNativeSelection = nil
        let titles = menu.items.map { $0.title }, index = menu.items.firstIndex { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == pending.title }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let index { menu.performActionForItem(at: index) }; menu.cancelTracking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reply(pending.id, ["opened": true, "choices": titles, "selected": index != nil]) }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        switch action {
        case "ready": publish(); reply(id, ["state": states[account]!, "hasAPIKey": true, "accountName": "附件操作合成验收", "appearance": "light"])
        case "save":
            guard let candidate = payload["state"] as? [String: Any], let candidateAccount = candidate["accountId"] as? String, candidateAccount.hasPrefix("synthetic-attachments-") else { finish(false, "unexpected account save"); return }
            states[candidateAccount] = candidate; publish(); reply(id, ["revision": candidate["revision"] ?? 1])
        case "aiCapabilities": reply(id, ["thinking": false, "canDisableThinking": false])
        case "keyStatus": reply(id, ["hasAPIKey": true])
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "attachmentPreview": reply(id, ["url": "weiyue-media://synthetic/preview-\(payload["attachmentIndex"] as? Int ?? 0).png"])
        case "extractAttachment":
            extractions.append(payload)
            if extractionMode == "hold" { pendingExtractions.append((id, payload)); publish() }
            else if extractionMode == "fail-next" { extractionMode = "success"; publish(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.error(id, "SYNTHETIC_EXTRACTION_FAILURE：文件暂不可读，请重试") } }
            else { publish(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.reply(id, self.extracted(payload)) } }
        case "ai":
            calls.append(payload); let number = calls.count
            if aiMode == "hold" { pendingAI.append((id, number)); publish() }
            else { publish(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.reply(id, ["text": "SYNTHETIC_REPLY_\(number)", "cancelled": false]) } }
        case "previewContent": routes.append(["action": action, "payload": payload]); publish(); reply(id, ["kind": (payload["attachmentIndex"] as? Int == 1 ? "document" : "link"), "title": "Synthetic content preview", "url": "https://synthetic.invalid/preview"] )
        case "openAttachment", "downloadAttachment", "revealAttachment", "openOfficial": routes.append(["action": action, "payload": payload]); publish(); reply(id, ["cancelled": false])
        case "qaModes": extractionMode = payload["extraction"] as? String ?? extractionMode; aiMode = payload["ai"] as? String ?? aiMode; reply(id)
        case "qaReleaseExtraction":
            let pending = pendingExtractions; pendingExtractions = []; extractionMode = "success"; publish()
            for (request, reference) in pending { reply(request, extracted(reference)) }; reply(id)
        case "qaReleaseAI":
            let pending = pendingAI; pendingAI = []; aiMode = "success"; publish()
            for (request, number) in pending { reply(request, ["text": "SYNTHETIC_REPLY_\(number)", "cancelled": false]) }; reply(id)
        case "qaInspect": reply(id, states[account] ?? [:])
        case "qaSwitchAccount":
            account = "synthetic-attachments-b"; states[account] = fixture(account); publish()
            web.evaluateJavaScript("window.onNativeEvent(" + json(["type": "account", "state": states[account]!, "hasAPIKey": true, "accountName": "切换后合成账号"]) + ")", completionHandler: nil); reply(id)
        case "qaResize": window.setContentSize(NSSize(width: payload["width"] as? Double ?? 1488, height: 1000)); web.setFrameSize(window.contentView!.bounds.size); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); reply(id)
        case "qaFocus":
            NSApplication.shared.activate(ignoringOtherApps: true); window.makeKey(); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.makeFirstResponder(web)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reply(id, ["key": self.window.isKeyWindow, "active": NSApplication.shared.isActive]) }
        case "qaPointer":
            let x = payload["x"] as? Double ?? 3, y = payload["y"] as? Double ?? 3
            let point = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), location = web.convert(point, to: nil), target = web.hitTest(point)
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].enumerated() {
                mouseEventNumber += 1; let at = NSPoint(x: location.x + (index == 0 ? 0 : 1), y: location.y)
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.001, windowNumber: window.windowNumber, context: nil, eventNumber: mouseEventNumber, clickCount: 1, pressure: index == 2 ? 0 : 1) { if index == 0 { target?.mouseDown(with: event) } else if index == 1 { target?.mouseDragged(with: event) } else { target?.mouseUp(with: event) } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.reply(id) }
        case "qaNativeMenu":
            nativeSelectionSerial += 1; let serial = nativeSelectionSerial
            pendingNativeSelection = (id, payload["title"] as? String ?? "")
            NSApplication.shared.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(web)
            let x = payload["x"] as? Double ?? 1, y = payload["y"] as? Double ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let point = NSPoint(x: x, y: self.web.isFlipped ? y : self.web.bounds.height - y), target = self.web.hitTest(NSPoint(x: x, y: self.web.isFlipped ? y : self.web.bounds.height - y))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: self.web.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: serial, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { if type == .leftMouseDown { target?.mouseDown(with: event) } else { target?.mouseUp(with: event) } }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if serial == self.nativeSelectionSerial, self.pendingNativeSelection != nil { self.pendingNativeSelection = nil; self.reply(id, ["opened": false]) } }
        case "qaSnapshot":
            let name = payload["name"] as? String ?? ""
            guard name.hasPrefix("v107-attachments-") && !name.contains("/") else { finish(false, "invalid screenshot name"); return }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failed"); return }
                do { try data.write(to: self.output.appendingPathComponent(name + ".png")); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "webSearch", "testAI", "saveKey", "authorizeAI", "openExternal", "listModels", "importDocument", "prepareImported": finish(false, "unexpected external action " + action)
        default: reply(id)
        }
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) { let url = urlSchemeTask.request.url!; urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: imageData.count, textEncodingName: nil)); urlSchemeTask.didReceive(imageData); urlSchemeTask.didFinish() }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.callAsyncJavaScript(Self.tests, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): self.finish(true, String(describing: value))
            case .failure(let error): self.web.evaluateJavaScript("JSON.stringify({observations:window.__observations,errors:window.__errors,requests:window.__calls?.length,extractions:window.__extractions,routes:window.__routes,body:document.body.innerText.slice(-1600)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout); previousApp?.activate(options: []); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let tests = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(value,label)=>{if(!value)throw Error(label);};
const wait=async(fn,label)=>{for(let n=0;n<180;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let seq=0;const pending=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=pending.get(response.id);if(resolve){pending.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='attachment-qa-'+(++seq);pending.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const card=index=>document.querySelector('.message-card[data-message-id="m0"] .attachment-card[data-attachment-index="'+index+'"]');
const rect=el=>{const r=el.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};};
const overlaps=(a,b)=>Math.min(a.right,b.right)-Math.max(a.left,b.left)>.5&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>.5;
const shown=el=>{if(!el||el.hidden)return false;const r=rect(el),s=getComputedStyle(el);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)>0;};
const status=index=>card(index).querySelector('.attachment-status'),tools=index=>card(index).querySelector('.attachment-floating-actions');
const menu=(index,value)=>{const select=card(index).querySelector('.attachment-more-menu');select.value=value;select.dispatchEvent(new Event('change',{bubbles:true}));};
const read=async()=>{await window.flushBeforeQuit();return qa('qaInspect');};
const settled=async()=>{await wait(()=>!card(0).querySelector('.attachment-read').disabled&&!card(1).querySelector('.attachment-read').disabled,'attachment tasks settled');await sleep(100);};
const clickTask=(index,action)=>card(index).querySelector(action==='interpret'?'.attachment-read':'.attachment-translate').click();
const leave=async()=>{document.activeElement?.blur();await qa('qaPointer',{x:3,y:3});await sleep(130);};
const hit=el=>{const r=rect(el);for(const [x,y] of [[(r.left+r.right)/2,(r.top+r.bottom)/2],[r.left+2,r.top+2],[r.right-2,r.bottom-2]]){const target=document.elementFromPoint(x,y);assert(target&&el.contains(target),'control whole hit box is reachable: '+(el.getAttribute('aria-label')||el.textContent.trim()));}};
window.__observations={geometry:[],nativeInteractions:[],tasks:[]};
await wait(()=>card(2)&&window.__saved&&window.ReaderAttachmentActions,'synthetic attachment cards');await settled();await wait(()=>card(0).querySelector('img').dataset.loaded==='true','synthetic image preview loaded');
assert($('conversation-messages').textContent.includes('OLD_HISTORY_QUESTION'),'fixture starts in existing discussion');
for(const width of [1488,1120]){
  await qa('qaResize',{width});ReaderLayout.reset();await sleep(180);
  await qa('qaSnapshot',{name:'v107-attachments-'+(width===1120?'narrow':'wide')});const pane=rect($('main'));if(width===1120)assert(Math.abs(pane.width-560)<1,'narrow reading pane is exactly 560 pixels');
  for(const index of [0,1]){
    const c=card(index);c.scrollIntoView({block:'center'});await sleep(70);const rail=rect(tools(index)),target=rect(c.querySelector(index===0?'.image-frame':'.attachment-open'));
    assert(Math.abs(rail.height-25)<.6,'attachment toolbar reserves exactly 25 pixels');if(index===0)assert(rail.bottom<=target.top-.5&&!overlaps(rail,target),'image toolbar remains above media');else assert(rail.left>=target.right+5&&!overlaps(rail,target),'compact document toolbar remains beside title without overlap');
    window.__observations.lastGeometry={width,index,card:rect(c),pane:rect($('reader-scroll')),scrollWidth:c.scrollWidth,clientWidth:c.clientWidth,rail,target,outside:[...c.querySelectorAll('*')].filter(el=>rect(el).width>0&&(rect(el).right>rect(c).right+.6||rect(el).left<rect(c).left-.6)).map(el=>({tag:el.tagName,class:el.className,box:rect(el),minWidth:getComputedStyle(el).minWidth,width:getComputedStyle(el).width,appearance:getComputedStyle(el).appearance}))};assert(rect(c).right<=rect($('reader-scroll')).right+.6&&c.scrollWidth<=c.clientWidth+1,'attachment remains inside reading pane');
    const select=c.querySelector('.attachment-more-menu'),label=select.parentElement;assert(Math.abs(rect(select).width-rect(label).width)<.6&&Math.abs(rect(select).height-rect(label).height)<.6,'native more select covers complete label');
    window.__observations.geometry.push({width,reader:pane.width,index,card:rect(c),rail,target,select:rect(select)});
  }
  for(const index of [3,4]){
    const c=card(index),open=c.querySelector('.attachment-open');c.scrollIntoView({block:'center'});await sleep(50);const r=rect(c),b=rect(open),title=rect(c.querySelector('.file-detail'));
    window.__observations.nonAITitle={width,index,card:r,open:b,title,scrollWidth:c.scrollWidth,clientWidth:c.clientWidth};
    assert(b.width>=r.width-20&&b.right<=r.right+.6&&title.right<=r.right+.6,'video/link open control and title use available card width');assert(c.scrollWidth<=c.clientWidth+1,'video/link card has no horizontal overflow');
    const feedback=rect(c.querySelector('.attachment-feedback'));assert(feedback.right<=r.right+.6,'video/link feedback stays in card');hit(open);window.__observations.geometry.push({width,reader:pane.width,index,card:r,open:b,title,feedback});
  }
  card(0).scrollIntoView({block:'center'});await sleep(50);await qa('qaSnapshot',{name:'v107-attachments-'+(width===1120?'narrow':'wide')});
}
// Native delivery checks are limited to one image and one document. A missing
// event gets at most three delivery attempts and is reported separately.
await qa('qaFocus');
for(const index of [0,1]){
  const c=card(index);c.scrollIntoView({block:'center'});await sleep(70);await leave();const before={card:rect(c),target:rect(c.querySelector(index===0?'.image-frame':'.attachment-open'))};
  assert(Number(getComputedStyle(tools(index)).opacity)===0,'tools are quiet before hover');
  let delivered=false,attempts=0;
  for(;attempts<3;attempts++){const r=rect(c);await qa('qaPointer',{x:r.left+3,y:r.top+3});await sleep(130);if(c.matches(':hover')){delivered=true;break;}await qa('qaFocus');}
  window.__observations.nativeInteractions.push({index,attempts:attempts+1,hover:c.matches(':hover'),opacity:getComputedStyle(tools(index)).opacity});
  assert(delivered,'INPUT DELIVERY: native hover was not delivered to attachment '+index);assert(Number(getComputedStyle(tools(index)).opacity)>.99,'delivered native hover reveals toolbar');
  assert(Math.abs(rect(c).height-before.card.height)<.6&&Math.abs(rect(c.querySelector(index===0?'.image-frame':'.attachment-open')).top-before.target.top)<.6,'hover keeps card height and preview/title position fixed');
  for(const control of tools(index).querySelectorAll('button,select'))hit(control);
  await leave();const focus=tools(index).querySelector('button');let focused=false;
  for(let attempt=0;attempt<3;attempt++){focus.focus({preventScroll:true});await sleep(130);if(focus.matches(':focus')){focused=true;break;}await qa('qaFocus');}
  assert(focused,'INPUT DELIVERY: native keyboard focus was not delivered to attachment '+index);assert(Number(getComputedStyle(tools(index)).opacity)>.99,'keyboard focus reveals toolbar');assert(Math.abs(rect(c).height-before.card.height)<.6,'keyboard focus keeps card height fixed');
  hit(c.querySelector('.attachment-more-menu'));if(index===1)await qa('qaSnapshot',{name:'v107-attachments-tools'});focus.blur();
}
await leave();
const checkTask=async(index,action,before)=>{
  await wait(()=>__calls.length===before+1,'one AI request for '+index+' '+action);await settled();const payload=__calls[before],sent=JSON.stringify(payload.messages),expected='SELECTED_ATTACHMENT_'+index+'_CONTENT';
  assert(payload.messages.length===3&&payload.messages[0].role==='system'&&payload.messages[1].role==='user'&&payload.messages[2].role==='user','fresh task contains only policy, selected source and current question');
  assert(sent.includes(expected)&&!sent.includes('SELECTED_ATTACHMENT_'+(1-index)+'_CONTENT'),'request contains exactly selected attachment extraction');
  for(const forbidden of ['UNSELECTED_MESSAGE_BODY','OLD_CONTEXT_MUST_NOT_ENTER_AI','OLD_HISTORY_QUESTION','OLD_HISTORY_ANSWER','OLD_INSTRUCTIONS','OLD_DRAFT','UNSELECTED_IMAGE_2'])assert(!sent.includes(forbidden),'no unrelated source/history: '+forbidden);
  assert(!sent.includes(index===0?'SELECTED_REPORT_1':'SELECTED_IMAGE_0'),'sibling attachment metadata is not sent');
  const question=payload.messages[2].content;assert(question===ReaderAttachmentActions.prompt(index===0?'image':'document',action),'correct attachment-specific task prompt');assert(action==='translate'?question.includes('逐段翻译')&&!question.includes('解读本次'):question.includes('解读本次'),'requested task intent is explicit');
  const saved=await read(),discussion=saved.discussions.find(d=>d.id===saved.settings.activeDiscussionId),snapshots=discussion.contextSnapshots;
  assert(snapshots.length===1&&snapshots[0].contextScope==='attachments'&&JSON.stringify(snapshots[0].contextAttachmentIndexes)==='['+index+']','saved discussion is scoped to only selected file');assert(saved.discussions.some(d=>d.id==='existing'&&d.messages[0].content==='OLD_HISTORY_QUESTION'),'old discussion remains saved');
  assert(__calls.length===before+1,'single click generated only one AI request');window.__observations.tasks.push({index,action,request:before+1,messages:payload.messages.length,selectedIndexes:snapshots[0].contextAttachmentIndexes});
};
// Hold both phases of the first direct task to observe processing feedback and
// duplicate suppression while extraction and AI are separately busy.
await qa('qaModes',{extraction:'hold',ai:'hold'});let before=__calls.length,extractionsBefore=__extractions.length;clickTask(0,'interpret');await wait(()=>__pendingExtractions===1,'held image extraction');
await leave();assert(shown(status(0))&&status(0).textContent.includes('正在读取'),'processing remains visible after pointer leaves');
assert(card(0).querySelector('.attachment-read').disabled&&card(1).querySelector('.attachment-translate').disabled,'all attachment AI actions lock during extraction');clickTask(0,'interpret');clickTask(1,'translate');menu(1,'add');await sleep(100);assert(__extractions.length===extractionsBefore+1&&__calls.length===before,'busy extraction rejects repeated or cross-file tasks');
await qa('qaReleaseExtraction');await wait(()=>__pendingAI===1,'held AI request');assert(shown(status(0))&&status(0).textContent.includes('解读'),'AI processing remains visible');clickTask(0,'interpret');clickTask(1,'translate');await sleep(70);assert(__extractions.length===extractionsBefore+1&&__calls.length===before+1,'busy AI rejects duplicate attachment task');await qa('qaReleaseAI');await checkTask(0,'interpret',before);
before=__calls.length;clickTask(0,'translate');await checkTask(0,'translate',before);
// Preparation failure must leave the previously active discussion and sources
// untouched. Retry uses the same document/intent after the error is visible.
const preserved=await read(),preservedDiscussions=JSON.stringify(preserved.discussions),preservedContext=$('context-list').textContent;before=__calls.length;await qa('qaModes',{extraction:'fail-next'});clickTask(1,'interpret');await wait(()=>status(1).dataset.failed==='true','document extraction failure');await settled();await leave();
const failed=await read();assert(failed.settings.activeDiscussionId===preserved.settings.activeDiscussionId&&JSON.stringify(failed.discussions)===preservedDiscussions,'failed extraction preserves active discussion and history');assert($('context-list').textContent===preservedContext,'failed extraction preserves existing discussion context');assert(__calls.length===before,'failed extraction does not send AI');assert(shown(status(1))&&status(1).textContent.includes('SYNTHETIC_EXTRACTION_FAILURE'),'error remains visible outside hover');assert(shown(card(1).querySelector('.attachment-task-retry')),'failed task offers visible retry');await qa('qaSnapshot',{name:'v107-attachments-error'});card(1).querySelector('.attachment-task-retry').click();await checkTask(1,'interpret',before);
before=__calls.length;clickTask(1,'translate');await checkTask(1,'translate',before);
// More-menu preparation is intentionally send-free, while native file actions
// retain the exact source index of the chosen attachment.
$('clear-context').click();await sleep(40);before=__calls.length;extractionsBefore=__extractions.length;menu(0,'add');await settled();assert(__extractions.length===extractionsBefore+1&&__calls.length===before,'more/add prepares once without AI');assert($('context-list').textContent.includes('SELECTED_IMAGE_0')&&!$('context-list').textContent.includes('SELECTED_REPORT_1'),'add-only context contains selected image');
for(const [index,selector] of [[0,'.image-frame'],[1,'.attachment-open'],[3,'.attachment-open'],[4,'.attachment-open']]){const count=__routes.length;card(index).querySelector(selector).click();await wait(()=>__routes.length===count+1,'native preview route');assert(__routes[count].action===([1,4].includes(index)?'previewContent':'openAttachment')&&__routes[count].payload.attachmentIndex===index,'preview opens exact attachment '+index);if([1,4].includes(index)){$('content-preview-close').click();await sleep(50);}}
const nativeMenuCount=__routes.length;card(0).scrollIntoView({block:'center'});await sleep(80);const nativeSelect=card(0).querySelector('.attachment-more-menu');nativeSelect.focus({preventScroll:true});await sleep(130);let nativeMenuResult={opened:false};
for(let attempt=0;attempt<3;attempt++){const r=rect(nativeSelect);nativeMenuResult=await qa('qaNativeMenu',{x:(r.left+r.right)/2,y:(r.top+r.bottom)/2,title:'另存为…'});if(nativeMenuResult.opened)break;}
assert(nativeMenuResult.opened,'INPUT DELIVERY: native attachment menu did not open');assert(nativeMenuResult.selected,'native attachment menu contains selectable save action');assert(['加入讨论','另存为…','在访达中显示','到微博查看'].every(title=>nativeMenuResult.choices.includes(title)),'native menu exposes all four attachment choices without clipping');await wait(()=>__routes.length===nativeMenuCount+1,'native selection dispatches save');assert(__routes[nativeMenuCount].action==='downloadAttachment'&&__routes[nativeMenuCount].payload.attachmentIndex===0,'real native menu saves exact image');window.__observations.nativeMenu=nativeMenuResult;
for(const [index,value,action] of [[1,'reveal','revealAttachment'],[1,'official','openOfficial']]){const count=__routes.length;menu(index,value);await wait(()=>__routes.length===count+1,'more route '+value);assert(__routes[count].action===action&&__routes[count].payload.attachmentIndex===index&&__routes[count].payload.messageId==='m0','more menu exact attachment route '+value);if(value==='official'){$('mode-reader').click();await wait(()=>shown($('reader-scroll')),'return to reading after official route');}}
await settled();
// An extraction started in A may finish after B replaces the account. Neither
// its result nor a retained old-card listener may enter B's discussion.
await qa('qaModes',{extraction:'hold'});before=__calls.length;const stale=card(1).querySelector('.attachment-translate');clickTask(1,'translate');await wait(()=>__pendingExtractions===1,'held extraction before account switch');await qa('qaSwitchAccount');await wait(()=>__saved.accountId==='synthetic-attachments-b'&&document.querySelector('.message-card[data-account-id="synthetic-attachments-b"]'),'new synthetic account mounted');await qa('qaReleaseExtraction');await sleep(200);await settled();
assert(__calls.length===before,'late extraction after account switch never sends AI');const switched=await read();assert(switched.discussions.length===1&&switched.settings.activeDiscussionId==='existing','new account discussion is untouched');assert(!$('context-list').textContent.includes('SELECTED_ATTACHMENT_1_CONTENT'),'late source is not joined to new account');extractionsBefore=__extractions.length;stale.click();await sleep(80);assert(__extractions.length===extractionsBefore,'retained old-card listener cannot prepare new account file');
assert(__errors.length===0,'no JavaScript runtime errors: '+JSON.stringify(__errors));
return JSON.stringify({...window.__observations,aiRequests:__calls.length,extractions:__extractions.length,nativeRoutes:__routes.map(r=>({action:r.action,index:r.payload.attachmentIndex})),selectedAttachmentOnly:true,addDoesNotSend:true,preparationFailurePreservesDiscussion:true,busyDoesNotDuplicate:true,lateAccountResultIgnored:true,screenshots:['v107-attachments-wide.png','v107-attachments-narrow.png','v107-attachments-tools.png','v107-attachments-error.png']});
"""#
}
