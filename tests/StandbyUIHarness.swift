import AppKit
import WebKit

// Synthetic accounts only; the harness never opens Weibo, reads keys, or sends AI requests.
@main final class StandbyUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!, store: StateStore!
    var phase = 0
    var nextSaveDelay: Double = 0
    var expected: [String: Any] = [:]
    let account = "synthetic-standby-main", other = "synthetic-standby-other"
    static func main() { let app = NSApplication.shared; let delegate = StandbyUIHarness(); app.delegate = delegate; app.setActivationPolicy(.prohibited); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-standby-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            let performance = temp.appendingPathComponent("reader-performance.js")
            var text = try String(contentsOf: performance, encoding: .utf8)
            text += "\nReaderPerformance.VirtualList=class extends ReaderPerformance.VirtualList{constructor(o){super(o);window.__standbyList=this;}};"
            try text.write(to: performance, atomically: true, encoding: .utf8)
            store = try StateStore(directory: temp.appendingPathComponent("private-synthetic-accounts"))
            try checkBooleanValidation()
            try store.save(state: fixture(account), accountId: account); try store.save(state: fixture(other), accountId: other)
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self, name: "app")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: configuration); web.navigationDelegate = self
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 100) { self.finish(false, "standby UI timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture(_ id: String) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let messages: [[String: Any]] = ["a", "b", "c"].flatMap { group in (0..<160).map { n in ["accountId": id, "groupId": group, "id": String(1000 + n), "senderId": "u\(n % 3)", "senderName": "成员 \(n % 3)", "sentAt": formatter.string(from: Date(timeIntervalSince1970: 1_792_281_600 + Double(n * 60))), "text": "待机合成消息 \(group) #\(n)\n仅供阅读位置验收。", "attachments": []] } }
        func anchor(_ group: String, _ message: Int) -> [String: Any] { ["accountId": id, "groupId": group, "messageId": String(1000 + message), "messageSentAt": formatter.string(from: Date(timeIntervalSince1970: 1_792_281_600 + Double(message * 60))), "offset": 0, "updatedAt": "2026-10-18T01:00:00Z"] }
        var progress: [String: Any] = [:]
        for group in ["a", "b", "c"] { progress[group] = ["auto": anchor(group, group == "a" ? 30 : 40), "manual": anchor(group, 20), "returnPoint": anchor(group, 10)] }
        return ["version": 1, "revision": 1, "accountId": id, "groups": ["a", "b", "c"].map { ["accountId": id, "id": $0, "name": "合成群 " + $0, "selected": true] }, "messages": messages, "bookmarks": [], "collections": [], "discussions": [], "progress": progress, "settings": ["baseURL": "", "model": "", "activeGroupId": "a", "mode": "reader", "readerStandby": false]]
    }
    func checkBooleanValidation() throws {
        let validation = try StateStore(directory: temp.appendingPathComponent("boolean-validation"))
        let initial = fixture(account); try validation.save(state: initial, accountId: account)
        let before = try Data(contentsOf: validation.fileURL(accountId: account))
        for invalidValue in [0, 1, "true", "false", NSNull(), [], [:]] as [Any] {
            var invalid = initial, settings = initial["settings"] as! [String: Any]
            settings["readerStandby"] = invalidValue; invalid["settings"] = settings; invalid["revision"] = 2
            var rejected = false
            do { try validation.save(state: invalid, accountId: account) } catch { rejected = true }
            guard rejected else { throw ReaderError.message("Native store accepted non-boolean standby: \(invalidValue)") }
            guard try Data(contentsOf: validation.fileURL(accountId: account)) == before else { throw ReaderError.message("Invalid standby value changed disk") }
        }
        var legacy = initial, settings = initial["settings"] as! [String: Any]
        settings.removeValue(forKey: "readerStandby"); legacy["settings"] = settings; legacy["revision"] = 3
        try validation.save(state: legacy, accountId: account)
        let restored = try StateStore(directory: validation.directory).load(accountId: account).state
        guard (restored["settings"] as? [String: Any])?["readerStandby"] == nil else { throw ReaderError.message("Legacy state gained standby flag") }
        print("PASS: native strict boolean and legacy compatibility; invalid candidates preserve disk")
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do { switch action {
        case "ready":
            let saved = try StateStore(directory: store.directory).load(accountId: account).state
            web.evaluateJavaScript("window.__expected=" + json(expected), completionHandler: nil)
            reply(id, ["state": saved, "hasAPIKey": false, "accountName": "合成待机验收", "appearance": "light"])
        case "save":
            guard let candidate = payload["state"] as? [String: Any], let accountId = candidate["accountId"] as? String, [account, other].contains(accountId) else { throw ReaderError.message("invalid synthetic state") }
            try store.save(state: candidate, accountId: accountId)
            let delay = nextSaveDelay; nextSaveDelay = 0
            if delay > 0 {
                web.evaluateJavaScript("window.__saveDelayed=true", completionHandler: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.reply(id, ["revision": candidate["revision"]!]) }
            } else { reply(id, ["revision": candidate["revision"]!]) }
        case "qaDelaySave": nextSaveDelay = 0.4; reply(id)
        case "qaInspect":
            let accountId = payload["accountId"] as? String ?? account
            guard [account, other].contains(accountId) else { throw ReaderError.message("invalid synthetic account") }
            reply(id, try StateStore(directory: store.directory).load(accountId: accountId).state)
        case "qaRemember": expected = payload; reply(id)
        case "qaSnapshot":
            let name = payload["name"] as? String ?? ""
            guard ["v102-standby-day", "v102-standby-night"].contains(name) else { throw ReaderError.message("invalid screenshot name") }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failed"); return }
                do { try data.write(to: self.output.appendingPathComponent(name + ".png")); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "ai", "testAI", "send": finish(false, "standby test must not send external requests")
        default: reply(id)
        } } catch { finish(false, error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.callAsyncJavaScript(Self.helpers + (phase == 0 ? Self.first : phase == 1 ? Self.second : Self.third), arguments: ["phase": phase], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                print("PASS phase \(self.phase): \(value)")
                if self.phase < 2 { self.phase += 1; do { self.store = try StateStore(directory: self.store.directory) } catch { self.finish(false, error.localizedDescription); return }; self.web.reload() }
                else { self.finish(true, "standby UI: two disk reopens; no selected foreground; all unread; parked viewport; independent anchors; per-group consume; normal quit; account isolation") }
            case .failure(let error): self.finish(false, error.localizedDescription + " " + String(describing: (error as NSError).userInfo))
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<160;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
const $=id=>document.getElementById(id),pick=g=>document.querySelector('.group-pick[data-group-id="'+g+'"]'),badge=g=>Number(pick(g)?.querySelector('.group-unread-badge')?.textContent||0);
let seq=0;const requests=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=requests.get(response.id);if(resolve){requests.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='standby-qa-'+(++seq);requests.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const read=async(accountId='synthetic-standby-main')=>{await window.flushBeforeQuit();return qa('qaInspect',{accountId});};
const userAnchors=s=>JSON.stringify(Object.fromEntries(Object.entries(s.progress).map(([g,p])=>[g,{auto:p.auto,manual:p.manual,returnPoint:p.returnPoint}])));
const visibleID=()=>window.__standbyList.visibleAnchor()?.messageId;
const inactive=()=>!document.querySelector('.group-row.active');
const expectStandby=()=>{assert($('group-name').textContent==='待机中','standby header visible');assert(inactive(),'no foreground group has active styling');assert(!document.querySelector('.message-card'),'no group messages displayed in standby');assert($('enter-standby').disabled,'standby action reflects current state');assert($('mode-official').disabled,'standby cannot accidentally open a remembered official group');assert(!document.querySelector('#group-list input[type=checkbox]'),'reading group list has no sync checkboxes');};
const emit=async(g,ids,accountId='synthetic-standby-main')=>{await sleep(5);window.onNativeEvent({type:'messages',accountId,groupId:g,messageSource:'live',requestStartedAt:new Date().toISOString(),messages:ids.map(id=>({id:String(id),groupId:g,senderId:'fresh',senderName:'合成新消息',text:'待机期间消息 '+id,sentAt:new Date().toISOString(),attachments:[]}))});};
const refreshGroups=()=>window.onNativeEvent({type:'groups',accountId:'synthetic-standby-main',groups:['a','b','c'].map(id=>({id,name:'合成群 '+id}))});
await wait(()=>window.__standbyList&&pick('c')&&$('group-name').textContent===(phase?'待机中':'合成群 a'),'initialized page');await sleep(400);
"""#
    static let first = #"""
assert(visibleID()==='1030','fixture auto C begins in viewport');$('manual-position').click();await sleep(450);assert(visibleID()==='1020','manual B is actual viewport before standby');
let saved=await read();assert(saved.progress.a.auto.messageId==='1030'&&saved.progress.a.manual.messageId==='1020'&&saved.progress.a.returnPoint.messageId==='1030','three independent user points are established');const before=userAnchors(saved);await qa('qaRemember',{userAnchors:before});
const setSync=async(group,selected,waitForSave=true)=>{$('manage-sync-groups').click();assert($('sync-groups-dialog').open,'sync manager opens');const check=$('sync-groups-dialog').querySelector('.sync-group-checkbox[data-group-id="'+group+'"]');assert(check,'sync manager checkbox');check.checked=selected;check.dispatchEvent(new Event('change',{bubbles:true}));$('sync-groups-form').requestSubmit();if(waitForSave)await wait(()=>!$('sync-groups-dialog').open,'sync choices saved');};
await setSync('b',false);assert(!(await read()).groups.find(g=>g.id==='b').selected,'B temporarily disabled before slow-save race');await qa('qaDelaySave');window.__saveDelayed=false;await setSync('b',true,false);await wait(()=>window.__saveDelayed,'delayed sync save in flight');
$('enter-standby').click();await sleep(550);expectStandby();saved=await read();assert(saved.settings.readerStandby===true,'standby state saved despite older checkbox completion');assert(saved.progress.a.standbyView.messageId==='1020','actual manually jumped viewport parked rather than auto C');assert(userAnchors(saved)===before,'standby does not change user anchors');
await setSync('c',false);await read();assert(inactive()&&$('group-name').textContent==='待机中','turning group sync off does not leave standby');await setSync('c',true);await read();await sleep(100);expectStandby();
refreshGroups();await sleep(120);expectStandby();
await emit('a',[1201,1202]);await emit('b',[1201,1202,1203]);await emit('c',[1201]);await wait(()=>badge('a')===2&&badge('b')===3&&badge('c')===1,'all selected groups accrue unread, including prior foreground');
await emit('a',[1201,1202]);await sleep(100);assert(badge('a')===2,'duplicate live messages do not double count in standby');
saved=await read();assert(userAnchors(saved)===before,'background messages leave all user points unchanged');assert(saved.groups.every(g=>g.selected),'synchronization group selection preserved');
for(const appearance of ['light','dark']){ReaderAppearance.restore(appearance);await sleep(100);await qa('qaSnapshot',{name:'v102-standby-'+(appearance==='light'?'day':'night')});}
assert(!window.__errors.length,'no JavaScript errors '+JSON.stringify(window.__errors));await window.flushBeforeQuit({quitting:true});return JSON.stringify({standby:true,allThreeUnread:[2,3,1],groupsRefreshSafe:true,manualViewportParked:true,independentAnchors:true,slowSyncSaveCannotLeaveStandby:true,syncManagerSafeInStandby:true,normalQuit:true});
"""#
    static let second = #"""
expectStandby();assert(badge('a')===2&&badge('b')===3&&badge('c')===1,'standby counters restored from native disk');let saved=await read();assert(userAnchors(saved)===window.__expected.userAnchors,'all anchors retained after first close/reopen');assert(saved.progress.a.standbyView.messageId==='1020','parked A viewport survives disk reopen');
pick('b').click();await sleep(450);assert($('group-name').textContent==='合成群 b'&&badge('b')===0,'click other group B clears only B');assert(badge('a')===2&&badge('c')===1,'A and C badges remain');assert(visibleID()==='1040','B restores its own auto viewport');saved=await read();assert(saved.progress.a.standbyView.messageId==='1020','visiting B does not consume A parked view');assert(saved.settings.readerStandby===false,'choosing a group leaves standby');
pick('a').click();await sleep(450);assert(visibleID()==='1020','later selecting A restores parked manual B viewport, not auto C');assert(badge('a')===0&&badge('c')===1,'only selected A is now acknowledged');saved=await read();assert(!saved.progress.a.standbyView,'only selected A parked view consumed');assert(userAnchors(saved)===window.__expected.userAnchors,'consuming parked view never overwrites three user anchors');
$('enter-standby').click();await sleep(100);expectStandby();await emit('a',[1204]);await emit('b',[1204]);await emit('c',[1202]);await wait(()=>badge('a')===1&&badge('b')===1&&badge('c')===2,'second standby continues independent counters');
saved=await read();const main=saved;const alternate=await qa('qaInspect',{accountId:'synthetic-standby-other'});window.onNativeEvent({type:'account',state:alternate,hasAPIKey:false,accountName:'另一个合成账号'});await wait(()=>$('group-name').textContent==='合成群 a'&&!inactive(),'other account opens its own active group');await sleep(400);assert(badge('a')===0&&badge('b')===0&&badge('c')===0,'other account has independent counters');assert(!($('enter-standby').disabled),'other account does not inherit standby');
await emit('b',[1300]);await sleep(120);assert(badge('b')===0,'late original-account event ignored');await emit('b',[1300],'synthetic-standby-other');await wait(()=>badge('b')===1,'other account owns its new unread');await read('synthetic-standby-other');
window.onNativeEvent({type:'account',state:main,hasAPIKey:false,accountName:'合成待机验收'});await wait(()=>$('group-name').textContent==='待机中','original standby restored after account switch');await sleep(100);expectStandby();assert(badge('a')===1&&badge('b')===1&&badge('c')===2,'original account counts restored unchanged');refreshGroups();await sleep(100);expectStandby();
saved=await read();assert(userAnchors(saved)===window.__expected.userAnchors,'account round trip retains original anchors');assert(saved.progress.a.standbyView.messageId==='1020','second parked A point remains');assert(!window.__errors.length,'no JavaScript errors '+JSON.stringify(window.__errors));await window.flushBeforeQuit({quitting:true});return JSON.stringify({diskReopen:true,clickOnlyClearsExactGroup:true,parkedViewConsumedPerGroup:true,manualViewportRestored:true,secondStandby:true,accountIsolation:true,normalQuit:true});
"""#
    static let third = #"""
expectStandby();assert(badge('a')===1&&badge('b')===1&&badge('c')===2,'normal close and second reopen preserve standby counts');let saved=await read();assert(saved.settings.readerStandby===true&&saved.progress.a.standbyView.messageId==='1020','second native restart restores standby and parked point');assert(userAnchors(saved)===window.__expected.userAnchors,'all user anchors survived both quits');
refreshGroups();await sleep(100);expectStandby();await emit('a',[1205]);await emit('b',[1205]);await emit('c',[1203]);await wait(()=>badge('a')===2&&badge('b')===2&&badge('c')===3,'every selected group remains live after reopen');
pick('a').click();await sleep(450);assert(visibleID()==='1020','parked viewport resumes after second restart');assert(badge('a')===0&&badge('b')===2&&badge('c')===3,'reopen click acknowledges only selected A');saved=await read();assert(userAnchors(saved)===window.__expected.userAnchors,'last resume preserves manual auto return points');assert(!saved.progress.a.standbyView,'consumed park is removed after second restart');assert(!window.__errors.length,'no JavaScript errors '+JSON.stringify(window.__errors));return JSON.stringify({secondDiskReopen:true,standbyRetained:true,allGroupsStillLive:true,readingPositionRestored:true,anchorsUnchanged:true});
"""#
}
