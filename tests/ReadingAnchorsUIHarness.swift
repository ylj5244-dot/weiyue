import AppKit
import WebKit

@main final class ReadingAnchorsUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!, store: StateStore!, phase = 0
    var state: [String: Any] = [:]
    let account = "synthetic-reading-anchors"
    static func main() { let app = NSApplication.shared; let delegate = ReadingAnchorsUIHarness(); app.delegate = delegate; app.setActivationPolicy(.prohibited); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-reading-anchors-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            let index = temp.appendingPathComponent("index.html")
            let performance = temp.appendingPathComponent("reader-performance.js")
            var sourceText = try String(contentsOf: performance, encoding: .utf8)
            sourceText += "\nReaderPerformance.VirtualList=class extends ReaderPerformance.VirtualList{constructor(o){super(o);window.__readingList=this;}};"
            try sourceText.write(to: performance, atomically: true, encoding: .utf8)
            store = try StateStore(directory: temp.appendingPathComponent("private-fixture")); state = fixture(); try store.save(state: state, accountId: account)
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self, name: "app")
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 1000), configuration: configuration); web.navigationDelegate = self
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.orderBack(nil)
            web.loadFileURL(index, allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 80) { self.finish(false, "reading anchors UI timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let messages: [[String: Any]] = ["one", "two", "single"].flatMap { group in (0..<(group == "single" ? 1 : 160)).map { n in ["accountId": account, "groupId": group, "id": "m\(n)", "senderId": "u\(n % 3)", "senderName": "成员 \(n % 3)", "sentAt": formatter.string(from: Date(timeIntervalSince1970: 1_792_281_600 + Double(n * 60))), "text": "合成消息 \(group) #\(n)\n只用于阅读位置验收。", "attachments": []] } }
        let anchor: [String: Any] = ["accountId": account, "groupId": "one", "messageId": "m10", "offset": 0, "updatedAt": "2026-10-18T01:00:00Z"]
        return ["version": 1, "revision": 1, "accountId": account, "groups": ["one", "two", "single"].map { ["accountId": account, "id": $0, "name": "合成群 " + $0, "selected": true] }, "messages": messages, "bookmarks": [], "collections": [], "discussions": [], "progress": ["one": ["auto": anchor]], "settings": ["baseURL": "", "model": "", "activeGroupId": "one", "mode": "reader"]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do { switch action {
        case "ready": state = try store.load(accountId: account).state; reply(id, ["state": state, "hasAPIKey": false, "accountName": "合成验收", "appearance": "light"])
        case "save": guard let candidate = payload["state"] as? [String: Any] else { throw ReaderError.message("missing state") }; try store.save(state: candidate, accountId: account); state = candidate; reply(id, ["revision": candidate["revision"]!])
        case "anchorInspect": web.evaluateJavaScript("window.__anchorState=" + json(try StateStore(directory: store.directory).load(accountId: account).state), completionHandler: nil); reply(id)
        case "anchorSnapshot":
            let name = payload["name"] as? String ?? ""
            guard ["v102-reading-day", "v102-reading-night"].contains(name) else { throw ReaderError.message("invalid screenshot name") }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failed"); return }
                do { try data.write(to: self.output.appendingPathComponent(name + ".png")); self.web.evaluateJavaScript("window.__anchorShot=" + self.json(name), completionHandler: nil); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "ai": finish(false, "reading test must not send AI requests")
        default: reply(id)
        } } catch { finish(false, error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.callAsyncJavaScript(Self.tests, arguments: ["phase": phase], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                print("PASS phase \(self.phase): \(value)")
                if self.phase == 0 { self.phase = 1; do { self.store = try StateStore(directory: self.store.directory); self.state = try self.store.load(accountId: self.account).state } catch { self.finish(false, error.localizedDescription); return }; self.web.reload() }
                else { self.finish(true, "manual/auto/return isolated; pending scroll; groups; disk reopen; dates; single/last message; direct highlights") }
            case .failure(let error): self.finish(false, error.localizedDescription + " " + String(describing: (error as NSError).userInfo))
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let tests = #"""
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<120;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
const $=id=>document.getElementById(id),card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]');
await wait(()=>window.__readingList&&card(phase?'m30':'m10'),'restored initial auto viewport'); await sleep(400);
const read=async()=>{await window.flushBeforeQuit();window.__anchorState=null;window.webkit.messageHandlers.app.postMessage({id:'inspect-'+Math.random(),action:'anchorInspect',payload:{}});await wait(()=>window.__anchorState,'native disk read');return window.__anchorState;};
const userScroll=async(id,group='one')=>{$('reader-scroll').dispatchEvent(new WheelEvent('wheel',{deltaY:120}));window.__readingList.scrollTo('synthetic-reading-anchors:'+group+':'+id,0);$('reader-scroll').dispatchEvent(new Event('scroll'));await sleep(30);};
const mark=async(id)=>{const b=card(id).querySelector('.manual-progress-action');assert(b,'manual action exists');if(b.closest('details'))b.closest('details').open=true;b.click();await sleep(70);};
const activeTarget=id=>{const c=card(id),r=c&&c.getBoundingClientRect(),v=$('reader-scroll').getBoundingClientRect();return !!c&&c.classList.contains('target-message')&&r.bottom>v.top&&r.top<v.bottom;};
const group=async id=>{document.querySelector('.group-pick[data-group-id="'+id+'"]').click();await sleep(450);};
if(phase===0){
  await userScroll('m20');await mark('m20');await sleep(750);let s=await read();assert(s.progress.one.manual?.messageId==='m20','manual B must be distinct from automatic progress after pending scroll settles');
  await userScroll('m30');await sleep(750);s=await read();assert(s.progress.one.auto.messageId==='m30','auto C follows user scrolling');assert(s.progress.one.manual.messageId==='m20','manual B never overwritten by scrolling C');
  $('manual-position').click();await sleep(100);assert(activeTarget('m20'),'manual button visibly highlights B');s=await read();assert(s.progress.one.auto.messageId==='m30','manual navigation does not overwrite auto C');assert(s.progress.one.returnPoint.messageId==='m30','manual jump records return C');
  assert(!$('resume-position'),'automatic progress button has been removed');
  $('return-position').click();await sleep(100);assert(activeTarget('m30'),'return button highlights pre-jump C');s=await read();assert(s.progress.one.returnPoint.messageId==='m30','return button does not overwrite itself');
  for(const id of ['manual-position','return-position']){assert(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/.test($(id).textContent),'message date and time shown '+id);assert($(id).title.includes('消息时间'),'full message timestamp in tooltip');}
  await group('two');assert($('manual-position').hidden&&$('return-position').hidden,'empty position controls stay hidden and do not inherit the first group');await userScroll('m20','two');await mark('m20');await sleep(750);await userScroll('m40','two');await sleep(750);s=await read();assert(s.progress.one.manual.messageId==='m20'&&s.progress.two.manual.messageId==='m20','same ID anchors remain scoped');assert(s.progress.two.auto.messageId==='m40','second auto remains independent');
  await group('single');await mark('m0');$('manual-position').click();await sleep(100);assert(activeTarget('m0'),'single-message list still highlights exact manual target');
  await group('two');await userScroll('m159','two');await mark('m159');$('manual-position').click();await sleep(100);assert(activeTarget('m159'),'last message clamped near bottom still highlights target');
  await group('one');await userScroll('m30');await sleep(750);await read();return 'phase 0 fully persisted';
}
let s=await read();assert(s.progress.one.manual.messageId==='m20'&&s.progress.one.auto.messageId==='m30','native disk reopen retained independent B/C');assert(s.progress.two.manual.messageId==='m159'&&s.progress.single.manual.messageId==='m0','other group manual points persisted');
$('manual-position').click();await sleep(100);assert(activeTarget('m20'),'manual B is reachable after disk reopen');await group('two');$('manual-position').click();await sleep(100);assert(activeTarget('m159'),'other group final message reachable after reopen');await group('one');$('manual-position').click();await sleep(100);assert(activeTarget('m20'),'switch back retains first group manual B');await read();
for(const appearance of ['light','dark']){ReaderAppearance.restore(appearance);await sleep(80);const name='v102-reading-'+(appearance==='light'?'day':'night');window.__anchorShot='';window.webkit.messageHandlers.app.postMessage({id:name,action:'anchorSnapshot',payload:{name}});await wait(()=>window.__anchorShot===name,'screenshot '+appearance);}
return 'phase 1 persisted state restored';
"""#
}
