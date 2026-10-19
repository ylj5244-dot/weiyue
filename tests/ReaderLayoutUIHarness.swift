import AppKit
import WebKit

// Uses only temporary synthetic accounts, storage and mock AI. No remote requests.
@main final class ReaderLayoutUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var mouseEventNumber = 0
    var nativePointerTarget: NSView?
    var previousApp: NSRunningApplication?
    var window: NSWindow!, web: WKWebView!, temp: URL!, store: StateStore!, output: URL!
    var state: [String: Any] = [:], calls: [[String: Any]] = [], bookmarkAttempts: [[[String: Any]]] = [], phase = 0
    var capabilityRequests: [Any] = [], holdCapabilities = false, failNextSave = false, failedSaves = 0
    let account = "synthetic-reader-layout", timestamp = "2026-10-19T01:00:00Z"
    var baselineOnly: Bool { CommandLine.arguments.contains("--baseline") }
    static func main() { let app = NSApplication.shared; let delegate = ReaderLayoutUIHarness(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            previousApp = NSWorkspace.shared.frontmostApplication
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-reader-layout-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            store = try StateStore(directory: temp.appendingPathComponent("synthetic-store")); try store.save(state: fixture(), accountId: account)
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self, name: "app")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('Network disabled in UI tests'));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 700), configuration: configuration); web.navigationDelegate = self
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.ignoresMouseEvents = true; window.appearance = NSAppearance(named: .aqua); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.acceptsMouseMovedEvents = true; window.orderBack(nil); window.makeKey(); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.makeFirstResponder(web); NSApplication.shared.activate(ignoringOtherApps: true)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 150) { self.finish(false, "reader layout timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture() -> [String: Any] {
        let texts = ["短消息。", "English short message.", "这是纯中文消息，只有中文时不需要翻译入口。", "Revenue grew while operating cash flow declined. <plain text>", "中英混排：Revenue grew by twelve percent.", "2026 · 12% · 123456", "这是一条重点关注成员的普通中文发言。", "A longer English message used to check action boundaries.\nThis line retains the full source content and does not contain a hidden instruction."]
        let formatter = ISO8601DateFormatter()
        let messages: [[String: Any]] = (0..<80).map { n -> [String: Any] in
            let senderId = n == 4 ? "same-name" : n == 2 ? "member1" : "member\(n % 3)"
            let senderName = n == 1 || n == 2 || n == 4 ? "超长中文姓名与所属机构联合调研观察员林舟" : "成员 \(n % 3)"
            let date = formatter.string(from: Date(timeIntervalSince1970: 1_792_368_000 + Double(n * 60)))
            let attachments: [[String: Any]] = []
            return ["accountId": account, "groupId": "g", "id": "m\(n)", "senderId": senderId, "senderName": senderName, "sentAt": date, "text": texts[n % texts.count], "attachments": attachments]
        }
        let discussion: [String: Any] = ["accountId": account, "id": "existing", "title": "旧讨论保持", "createdAt": timestamp, "instructions": "LEGACY_TEMPORARY_MUST_NOT_ENTER_REQUEST", "contextSnapshots": [messages[0]], "messages": [["role": "user", "content": "保留旧问题", "createdAt": timestamp], ["role": "assistant", "content": "保留旧回答", "createdAt": timestamp]]]
        let anchor: [String: Any] = ["accountId": account, "groupId": "g", "messageId": "m0", "offset": 0, "updatedAt": timestamp]
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "超长中文群聊名称——投资产业趋势联合阅读与讨论交流合成验收测试群", "selected": true]], "messages": messages, "bookmarks": [], "collections": [], "discussions": [discussion], "progress": ["g": ["manual": anchor, "returnPoint": anchor]], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic-actions", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "existing", "aiDraftInstructions": "LEGACY_DRAFT_MUST_NOT_ENTER_REQUEST"]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func error(_ id: Any, _ text: String) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": false, "error": text]) + ")", completionHandler: nil) }
    func publish() { web.evaluateJavaScript("window.__saved=" + json(state) + ";window.__calls=" + json(calls) + ";window.__bookmarkAttempts=" + json(bookmarkAttempts) + ";window.__capabilityPending=\(!capabilityRequests.isEmpty);window.__failedSaves=\(failedSaves)", completionHandler: nil) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do { switch action {
        case "ready": state = try StateStore(directory: store.directory).load(accountId: account).state; publish(); reply(id, ["state": state, "hasAPIKey": true, "accountName": "合成阅读验收", "appearance": "light"])
        case "aiCapabilities": if holdCapabilities { capabilityRequests.append(id); publish() } else { reply(id, ["thinking": false, "canDisableThinking": false]) }
        case "qaReleaseCapabilities": holdCapabilities = false; let pending = capabilityRequests; capabilityRequests = []; for request in pending { reply(request, ["thinking": false, "canDisableThinking": false]) }; publish(); reply(id)
        case "qaArmSaveFailure": failNextSave = true; reply(id)
        case "qaInspect": reply(id, try StateStore(directory: store.directory).load(accountId: account).state)
        case "save":
            if let candidate = payload["state"] as? [String: Any] { bookmarkAttempts.append(candidate["bookmarks"] as? [[String: Any]] ?? []) }
            if failNextSave { failNextSave = false; failedSaves += 1; publish(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.error(id, "合成书签磁盘保存失败") }; break }
            guard let candidate = payload["state"] as? [String: Any], candidate["accountId"] as? String == account else { throw ReaderError.message("invalid synthetic save") }
            try store.save(state: candidate, accountId: account); state = candidate; publish(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reply(id, ["revision": candidate["revision"] ?? 1]) }
        case "keyStatus": reply(id, ["hasAPIKey": true])
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "ai": calls.append(payload); publish(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reply(id, ["text": "这是本地模拟的中文回答。", "cancelled": false]) }
        case "qaResize": window.setContentSize(NSSize(width: payload["width"] as? Double ?? 1120, height: payload["height"] as? Double ?? 700)); web.setFrameSize(window.contentView!.bounds.size); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); reply(id)
        case "qaFocus":
            NSApplication.shared.activate(ignoringOtherApps: true); window.makeKey(); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.makeFirstResponder(web)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reply(id, ["key": self.window.isKeyWindow, "active": NSApplication.shared.isActive]) }
        case "qaGesture":
            let x = payload["x"] as? Double ?? 0, y = payload["y"] as? Double ?? 0, dx = payload["dx"] as? Double ?? 1
            let target = web.hitTest(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y))
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].enumerated() {
                let px = x + (index == 0 ? 0 : dx), location = web.convert(NSPoint(x: px, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.001, windowNumber: window.windowNumber, context: nil, eventNumber: index + 1, clickCount: 1, pressure: index == 2 ? 0 : 1) {
                    if index == 0 { target?.mouseDown(with: event) } else if index == 1 { target?.mouseDragged(with: event) } else { target?.mouseUp(with: event) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.reply(id) }
        case "qaMouse":
            let x = payload["x"] as? Double ?? 0, y = payload["y"] as? Double ?? 0
            let kind = payload["kind"] as? String ?? "move"
            let type: NSEvent.EventType = kind == "down" ? .leftMouseDown : kind == "drag" ? .leftMouseDragged : kind == "up" ? .leftMouseUp : .mouseMoved
            let location = web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
            mouseEventNumber += 1
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: mouseEventNumber, clickCount: 1, pressure: kind == "up" || kind == "move" ? 0 : 1) { let hit = web.hitTest(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)); if kind == "down" { nativePointerTarget = hit; nativePointerTarget?.mouseDown(with: event) } else if kind == "drag" { nativePointerTarget?.mouseDragged(with: event) } else if kind == "up" { (nativePointerTarget ?? hit)?.mouseUp(with: event) } else { hit?.mouseMoved(with: event) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.reply(id, ["key": self.window.isKeyWindow, "active": NSApplication.shared.isActive]) }
        case "qaSnapshot":
            let name = payload["name"] as? String ?? ""
            guard name.hasPrefix("v106-") && !name.contains("/") else { throw ReaderError.message("invalid screenshot") }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failed"); return }
                do { try data.write(to: self.output.appendingPathComponent(name + ".png")); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "webSearch", "testAI", "saveKey", "authorizeAI", "openExternal", "listModels": finish(false, "unexpected external action " + action)
        default: reply(id)
        } } catch { finish(false, error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.callAsyncJavaScript(Self.helpers + (baselineOnly ? Self.baseline : phase == 0 ? (CommandLine.arguments.contains("--quick") ? Self.tests.replacingOccurrences(of: "for(const size of [12,14,16,18])", with: "for(const size of [])") : Self.tests) : Self.reloadTests), arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): print("PASS phase \(self.phase): \(value)"); fflush(stdout); if self.phase == 0 && !self.baselineOnly { self.phase = 1; self.web.reload() } else { self.finish(true, "reader layout verified") }
            case .failure(let error): self.web.evaluateJavaScript("JSON.stringify({observations:window.__observations,errors:window.__errors,settings:window.__saved?.settings,calls:window.__calls,body:document.body.innerText.slice(-1200)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout); previousApp?.activate(options: []); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<220;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let seq=0;const requests=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=requests.get(response.id);if(resolve){requests.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='layout-qa-'+(++seq);requests.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]');
const box=el=>{const r=el.getBoundingClientRect();return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height};};
const read=async()=>{await window.flushBeforeQuit();return qa('qaInspect');};
const field=(id,value)=>{$(id).value=value;$(id).dispatchEvent(new Event('input',{bubbles:true}));$(id).dispatchEvent(new Event('change',{bubbles:true}));};
const shot=async name=>{await wait(()=>$('toast').hidden,'toast settled');await qa('qaSnapshot',{name});};
const resize=async w=>{await qa('qaResize',{width:w,height:800});await sleep(150);};
const point=async(x,y)=>{await qa('qaMouse',{kind:'down',x,y});await qa('qaMouse',{kind:'drag',x:x+1,y});await qa('qaMouse',{kind:'up',x:x+1,y});};
const hover=async el=>{const r=box(el);await point(r.right-5,r.top+3);await sleep(120);};
const unhover=async()=>{await point(400,5);document.activeElement?.blur();await sleep(120);};
const panes=()=>({state:ReaderLayout.getState(),sidebar:box($('sidebar')),main:box($('main')),inspector:box($('inspector')),workspace:box(document.querySelector('.workspace'))});
const pointerDrag=async(side,delta)=>{
  const el=$(side+'-divider'),r=box(el),x=r.left+r.width/2,y=r.top+Math.min(180,r.height/2),before=ReaderLayout.getState();
  let delivered=false,start=window.__pointers.length;
  const observation={side,delta,before,downAttempts:[],events:[]};window.__observations.lastNativeDrag=observation;(window.__observations.nativeDrags??=[]).push(observation);
  for(let attempt=0;attempt<3;attempt++){
    const attemptStart=window.__pointers.length,native=await qa('qaMouse',{kind:'down',x,y});
    const down=window.__pointers.slice(attemptStart).find(e=>e.name==='pointerdown'&&e.target===side+'-divider');
    observation.downAttempts.push({attempt,native,down,focused:document.hasFocus(),activeElement:document.activeElement?.id,resizing:$('app').classList.contains('is-resizing'),capture:!!down&&el.hasPointerCapture(down.pointerId)});
    observation.events=window.__pointers.slice(start);
    if(down){delivered=true;break;}
    await qa('qaMouse',{kind:'up',x,y});await sleep(50);
  }
  assert(delivered,'native pointerdown delivered to '+side);
  observation.nativeDrag=await qa('qaMouse',{kind:'drag',x:x+delta,y});
  observation.afterMove={state:ReaderLayout.getState(),resizing:$('app').classList.contains('is-resizing')};
  observation.nativeUp=await qa('qaMouse',{kind:'up',x:x+delta,y});await sleep(80);
  if($('app').classList.contains('is-resizing')){await qa('qaMouse',{kind:'up',x:x+delta,y});await sleep(50);}
  const result={before,after:ReaderLayout.getState()};Object.assign(observation,result,{events:window.__pointers.slice(start)});
  assert(!$('app').classList.contains('is-resizing'),'native pointer capture released '+side);return result;
};
window.__observations={};window.__pointers=[];
for(const name of ['pointerdown','pointermove','pointerup','pointercancel','gotpointercapture','lostpointercapture','mousedown','mousemove','mouseup'])document.addEventListener(name,e=>window.__pointers.push({name,x:e.clientX,y:e.clientY,target:e.target.id||e.target.className,button:e.button,buttons:e.buttons,pointerId:e.pointerId,isPrimary:e.isPrimary,resizing:$('app').classList.contains('is-resizing'),capture:e.pointerId!==undefined&&!!e.target.hasPointerCapture?.(e.pointerId),focused:document.hasFocus(),activeElement:document.activeElement?.id}));
for(const name of ['blur','focus'])window.addEventListener(name,()=>window.__pointers.push({name,focused:document.hasFocus(),resizing:$('app').classList.contains('is-resizing')}));
await wait(()=>card('m1')&&window.__saved&&window.ReaderLayout,'reader layout fixture ready');await sleep(180);
"""#
    static let baseline = #"""
const c=card('m1'),a=c.querySelector('.message-actions');window.__observations.initial={panes:panes(),summary:box($('reader-summary')),sync:box($('sync-bar')),controls:box(document.querySelector('.reading-position-controls')),actions:box(a),actionPosition:getComputedStyle(a).position,actionOpacity:getComputedStyle(a).opacity};
await shot('v106-baseline-layout');window.__observations.drag=await pointerDrag('sidebar',70);await shot('v106-baseline-drag');window.__observations.pointers=window.__pointers;return JSON.stringify(window.__observations);
"""#
    static let tests = #"""
const firstLine=el=>{const walker=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);let n;while(n=walker.nextNode()){if(n.textContent.trim()){const r=document.createRange();r.selectNodeContents(n);return r.getClientRects()[0];}}};
const checkbox=id=>{const c=card(id),check=c.querySelector('.message-select'),body=c.querySelector('.message-body'),line=firstLine(body),r=box(check);assert(check.closest('.message-body-row')===body.parentElement,'checkbox belongs to body row '+id);assert(Math.abs((r.top+r.bottom)/2-(line.top+line.bottom)/2)<5,'checkbox aligns to first body line '+id);assert(r.right<box(body).left,'checkbox stays left of body '+id);};
const overlap=(a,b)=>Math.min(a.right,b.right)-Math.max(a.left,b.left)>1&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>1;
const within=(a,b)=>a.left>=b.left-1&&a.right<=b.right+1&&a.top>=b.top-1&&a.bottom<=b.bottom+1;
const hit=el=>{const r=box(el),actual=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);assert(actual&&el.contains(actual),'hit testing '+el.textContent.trim());};
const header=()=>{const main=box($('main'));for(const id of ['group-name','manual-position','return-position','sync-now','load-history']){const e=$(id),r=box(e);assert(within(r,main),'header control within main '+id);if(!e.disabled)hit(e);}const sync=box($('sync-bar')),controls=box(document.querySelector('.reading-position-controls'));assert(!overlap(sync,controls),'sync and reading controls do not overlap');assert($('main').scrollWidth<=$('main').clientWidth+1,'main no horizontal overflow');};
const actions=async id=>{const c=card(id);assert(c,'message mounted '+id);c.scrollIntoView({block:'center'});await sleep(80);await unhover();const a=c.querySelector('.message-actions'),r0=box(c),line0=firstLine(c.querySelector('.message-body'));checkbox(id);assert(box(a).bottom<=box(c.querySelector('.message-body')).top+1,'action rail stays above full-width body');assert(Number(getComputedStyle(a).opacity)===0,'actions hidden without hover/focus');await hover(c);window.__observations.hover={id,card:box(c),pointers:window.__pointers.slice(-8)};assert(c.matches(':hover'),'native mouse hover reaches message');assert(Number(getComputedStyle(a).opacity)>0.99,'actions show on hover');assert(Math.abs(box(c).height-r0.height)<1,'hover does not alter message height');assert(Math.abs(firstLine(c.querySelector('.message-body')).top-line0.top)<1,'hover preserves first body line');checkbox(id);for(const b of a.querySelectorAll('button')){assert(within(box(b),box($('reader-scroll')))&&within(box(b),box(c)),'floating action within reader/card '+b.textContent);hit(b);}const ar=box(a);for(const selector of ['.message-name','.message-time','.message-body','.message-reading-markers']){const el=c.querySelector(selector);if(el&&box(el).height>0){const walker=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);let n;while(n=walker.nextNode()){if(!n.textContent.trim())continue;const range=document.createRange();range.selectNodeContents(n);for(const rect of range.getClientRects()){const visibleRect=getComputedStyle(el).overflow==='hidden'?{left:Math.max(rect.left,box(el).left),right:Math.min(rect.right,box(el).right),top:Math.max(rect.top,box(el).top),bottom:Math.min(rect.bottom,box(el).bottom)}:rect;window.__observations.lastGeometry={id,selector,actions:ar,element:box(el),text:{left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom}};assert(!overlap(ar,visibleRect),'floating actions do not obscure visible text '+selector);}}}}await unhover();const first=a.querySelector('button');for(let attempt=0;attempt<4;attempt++){window.__observations.nativeFocus=await qa('qaFocus');first.focus({preventScroll:true});await sleep(180);if(first.matches(':focus')&&Number(getComputedStyle(a).opacity)>0.99)break;}window.__observations.focus={active:document.activeElement?.outerHTML,connected:first.isConnected,disabled:first.disabled,focus:first.matches(':focus'),within:c.matches(':focus-within'),opacity:getComputedStyle(a).opacity};assert(Number(getComputedStyle(a).opacity)>0.99,'keyboard focus reveals actions');hit(first);return {card:box(c),actions:box(a),heading:box(c.querySelector('.message-heading')),body:box(c.querySelector('.message-body'))};};
header();const oldStatus=$('sync-status').textContent;$('sync-status').textContent='正在同步当前群聊的更早历史记录，网络传输进度需要保持可见且不能挤压其他按钮';header();assert(getComputedStyle($('sync-status')).textOverflow==='ellipsis','long sync text uses ellipsis');$('sync-status').textContent=oldStatus;await shot('v106-current-wide');await resize(900);await shot('v106-current-narrow');await resize(1120);const controls=box(document.querySelector('.reading-position-controls')),sync=box($('sync-bar'));assert(Math.abs(sync.top-controls.top)<12,'sync strip aligned beside reading position controls at 1120');assert(sync.left>=controls.right-1,'sync strip occupies right side of controls');window.__observations.wide={panes:panes(),sync,controls,actions:await actions('m1')};await shot('v106-floating-wide');
for(const size of [12,14,16,18]){document.documentElement.style.setProperty('--reader-size',size+'px');await actions('m0');await actions('m1');await actions('m2');}document.documentElement.style.removeProperty('--reader-size');
for(const width of [1500,1120,900]){await resize(width);ReaderLayout.reset();await sleep(100);header();for(const side of ['sidebar','inspector']){ReaderLayout.reveal(side);await sleep(60);if(ReaderLayout.getState()[side+'Collapsed'])continue;const direction=side==='sidebar'?1:-1;const sample=await pointerDrag(side,28*direction);window.__observations.lastDrag={side,width,sample,pointers:window.__pointers.slice(-12),panes:panes()};const other=side==='sidebar'?'inspector':'sidebar';assert(Math.abs(sample.after[side+'Width']-Math.min(sample.before[side+'Max'],sample.before[side+'Width']+28))<1,'pane follows pointer until bound '+side+' '+width);assert(sample.after[other+'Width']===sample.before[other+'Width'],'drag preserves other pane width');window.__observations.lastDrag={side,width,sample,pointers:window.__pointers.slice(-12),panes:panes()};assert(sample.after[side+'Width']>sample.before[side+'Width']+1||sample.before[side+'Width']>=sample.before[side+'Max']-1,'native pointer grows '+side+' at '+width);await pointerDrag(side,4000*direction);header();const s=ReaderLayout.getState();assert(Math.abs(s[side+'Width']-s[side+'Max'])<1,'drag reaches exact maximum '+side);await pointerDrag(side,100*direction);assert(ReaderLayout.getState()[side+'Width']===s[side+'Width'],'drag past max stops without drift');assert(s.centerWidth>=s.centerMin-1,'center minimum respected '+side+' '+width);await actions('m1');await pointerDrag(side,-4000*direction);header();assert(ReaderLayout.getState()[side+'Width']===ReaderLayout.getState()[side+'Min'],'pane reaches exact minimum '+side);const atMin=ReaderLayout.getState();await pointerDrag(side,-100*direction);assert(ReaderLayout.getState()[side+'Width']===atMin[side+'Width'],'drag past min stops without drift');$(side+'-divider').dispatchEvent(new KeyboardEvent('keydown',{key:side==='sidebar'?'ArrowRight':'ArrowLeft',bubbles:true}));await sleep(60);assert(ReaderLayout.getState()[side+'Width']===Math.min(atMin[side+'Min']+16,atMin[side+'Max']),'keyboard follows same boundary '+side);await actions('m1');ReaderLayout.reset();await sleep(60);}await actions('m0');await actions('m1');window.__observations['width'+width]=panes();await shot('v106-layout-'+width);}
await resize(1120);ReaderLayout.reset();await sleep(100);for(const side of ['sidebar','inspector']){$('toggle-'+side).click();await sleep(60);assert(ReaderLayout.getState()[side+'Collapsed'],'pane folds '+side);header();$('toggle-'+side).click();await sleep(60);assert(!ReaderLayout.getState()[side+'Collapsed'],'pane unfolds '+side);header();}
for(const id of ['m0','m1','m2'])checkbox(id);card('m1').querySelector('.message-select').click();assert(card('m1').querySelector('.message-select').checked&&!card('m2').querySelector('.message-select').checked,'first group message selects independently');card('m2').querySelector('.message-select').click();assert(card('m1').querySelector('.message-select').checked&&card('m2').querySelector('.message-select').checked,'continuation selects independently');card('m1').querySelector('.message-select').click();assert(!card('m1').querySelector('.message-select').checked&&card('m2').querySelector('.message-select').checked,'deselecting first preserves continuation');card('m2').querySelector('.message-select').click();const c=card('m1'),classes=[...c.querySelectorAll('.message-actions button')].map(b=>b.className);assert(['manual-progress-action','message-bookmark-action','message-collect-action','message-translate-action','message-discussion-action'].every((cl,i)=>classes[i].includes(cl)),'floating actions retain required order');assert(!card('m0').querySelector('.message-translate-action'),'Chinese-only translation remains absent');c.querySelector('.message-bookmark-action').click();await wait(()=>window.__saved.bookmarks.length===1,'bookmark persists');assert(!$('bookmark-dialog').open,'bookmark remains direct');c.querySelector('.message-translate-action').click();await wait(()=>window.__calls.length===1&&card('m1').querySelector('.inline-translation')?.dataset.status==='complete','translation remains inline');c.querySelector('.manual-progress-action').click();await wait(()=>window.__saved.progress.g?.manual?.messageId==='m1','manual point persists');checkbox('m1');await actions('m1');await shot('v106-checkbox-marked');
const sc=$('reader-scroll');sc.scrollTop=1400;sc.dispatchEvent(new Event('scroll'));await sleep(250);const before=[...document.querySelectorAll('.message-card')].find(c=>box(c).bottom>box(sc).top+4),anchor={id:before.dataset.messageId,offset:box(before).top-box(sc).top};await pointerDrag('inspector',-80);await sleep(150);const after=card(anchor.id);assert(after&&Math.abs(box(after).top-box(sc).top-anchor.offset)<5,'reading position preserved during clamped boundary drag');window.__observations.anchor=anchor;await read();assert(window.__errors.length===0,'no runtime errors '+JSON.stringify(window.__errors));return JSON.stringify(window.__observations);
"""#
    static let reloadTests = #"""
const s=await read();assert(s.bookmarks.length===1&&s.progress.g.manual.messageId==='m1','bookmark and reading point survive reload');assert(box(card('m1').querySelector('.message-actions')).bottom<=box(card('m1').querySelector('.message-body')).top+1,'action rail remains above body after reload');return JSON.stringify({reload:true});
"""#
}
