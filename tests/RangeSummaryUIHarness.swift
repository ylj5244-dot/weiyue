import AppKit
import WebKit

// Only synthetic data and an ephemeral WebKit store. No account files, credentials,
// external navigation, real Weibo traffic, or real AI requests are used.
@MainActor final class RangeSummaryUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
    var web: WKWebView!
    var window: NSWindow!
    var state: [String: Any] = [:]
    var allMessages: [[String: Any]] = []
    var temp: URL!
    var output: URL!
    var phase = 0
    var mode = "complete"
    var modeAICalls = 0
    var aiPayloads: [[String: Any]] = []
    var rangePayloads: [[String: Any]] = []
    var uploadActions: [String] = []
    var cancellationActions: [String] = []
    var pendingLoad: Any?
    var pendingAI: Any?
    var results = ""
    let account = "range-synthetic-account"
    let base = ISO8601DateFormatter().date(from: "2026-10-17T01:00:00Z")!
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build", isDirectory: true)
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-range-ui-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.copyItem(at: source, to: temp)
            state = fixture()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name: "app")
            configuration.setURLSchemeHandler(self, forURLScheme: "weiyue-media")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__uiErrors=[];window.addEventListener('error',e=>window.__uiErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__uiErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 700), configuration: configuration)
            web.navigationDelegate = self
            window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1120, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = web; window.appearance = NSAppearance(named: .aqua); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { self.finish(false, "native range UI timed out") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture() -> [String: Any] {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func message(_ id: String, _ seconds: Double, _ group: String = "g") -> [String: Any] {
            let index = Int(seconds)
            return ["accountId": account, "groupId": group, "id": id, "senderId": "u\(abs(index) % 7)", "senderName": "测试成员 \(abs(index) % 7)", "sentAt": formatter.string(from: base.addingTimeInterval(seconds)), "text": "Synthetic message \(id). " + String(repeating: "Group ideas and evidence. ", count: 2), "attachments": index % 37 == 0 ? [["type": "image", "name": "synthetic-\(id).png", "url": "https://never-upload.invalid/SECRET_ATTACHMENT_\(id).png"], ["type": "file", "name": "synthetic-\(id).pdf", "url": "https://never-upload.invalid/SECRET_DOCUMENT_\(id).pdf"]] : []]
        }
        allMessages = (0..<600).map { message(String($0), Double($0)) }
        allMessages.append(message("end-last", 599.999))
        allMessages.append(message("before", -0.001)); allMessages.append(message("after", 600))
        allMessages += (0..<10).map { message("other-\($0)", Double($0), "h") }
        let local = allMessages.filter { ($0["id"] as? String).flatMap(Int.init).map { $0 >= 300 } ?? true }
        let timestamp = formatter.string(from: base)
        let anchor: [String: Any] = ["accountId": account, "groupId": "g", "messageId": "400", "offset": 11, "updatedAt": timestamp]
        let library: [String: Any] = ["version": 1, "entries": [["id": "p1", "title": "Writing", "category": "writing", "content": "RANGE_QA_WRITING: use connected paragraphs.", "enabled": true], ["id": "p2", "title": "Format", "category": "format", "content": "RANGE_QA_FORMAT: preserve exact citations.", "enabled": true]], "quickPrompts": []]
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "时段测试群", "selected": true], ["accountId": account, "id": "h", "name": "另一个测试群", "selected": true]], "messages": local, "collections": [], "discussions": [], "bookmarks": [], "progress": ["g": ["auto": anchor]], "settings": ["baseURL": "https://api.deepseek.com", "webSearchEnabled": true, "model": "synthetic-range-text", "activeGroupId": "g", "mode": "reader", "aiPreferences": library, "aiDraftInstructions": "RANGE_QA_TEMP: this discussion uses concise conclusions."]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func reject(_ id: Any, _ text: String) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": false, "error": text]) + ")", completionHandler: nil) }
    func event(_ value: [String: Any]) { web.evaluateJavaScript("window.onNativeEvent(" + json(value) + ")", completionHandler: nil) }
    func publish() { web.evaluateJavaScript("window.__saved=" + json(state) + ";window.__aiPayloads=" + json(aiPayloads) + ";window.__rangePayloads=" + json(rangePayloads) + ";window.__uploads=" + json(uploadActions) + ";window.__cancellations=" + json(cancellationActions), completionHandler: nil) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        switch action {
        case "harnessTrace": print("TRACE: \(payload["step"] ?? "unknown")"); fflush(stdout); reply(id)
        case "ready":
            publish(); reply(id, ["state": state, "hasAPIKey": true, "accountName": "Synthetic range QA", "appearance": "light"])
        case "save":
            state = payload["state"] as! [String: Any]; publish(); reply(id, ["revision": state["revision"]!])
        case "harnessMode":
            mode = payload["mode"] as! String; modeAICalls = 0; print("Range mode: \(mode)"); fflush(stdout)
            web.evaluateJavaScript("window.__mode=" + json(mode), completionHandler: nil); reply(id)
        case "harnessScreenshot":
            let name = payload["name"] as! String
            guard name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { finish(false, "Invalid screenshot name"); return }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failure"); return }
                do { try png.write(to: self.output.appendingPathComponent(name + ".png")); self.web.evaluateJavaScript("window.__screenshot=" + self.json(name), completionHandler: nil); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "loadRange":
            rangePayloads.append(payload); publish()
            let request = payload["requestId"] as! String
            event(["type": "rangeProgress", "accountId": account, "groupId": "g", "requestId": request, "pages": 2, "loadedCount": 300, "text": "正在核对测试历史"])
            if mode == "hold-load" { pendingLoad = id; return }
            if mode == "load-error" { reject(id, "Synthetic historical access failure"); return }
            let partial = mode == "partial"
            let messages = partial ? Array(allMessages.prefix(80)) : allMessages
            let coverage: [String: Any] = ["complete": !partial, "reason": partial ? "测试历史只取得前 80 条；其余消息未能加载，不能确认完整。" : "已连续核对测试时段，范围内可访问消息已加载完整。", "pages": partial ? 1 : 7, "checkedAt": "2026-10-18T00:00:00.000Z"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reply(id, ["messages": messages, "coverage": coverage]) }
        case "harnessReleaseLoad":
            if let pendingLoad { self.pendingLoad = nil; reply(pendingLoad, ["messages": allMessages, "coverage": ["complete": true, "reason": "已连续核对测试时段，范围内可访问消息已加载完整。", "pages": 7, "checkedAt": "2026-10-18T00:00:00.000Z"]]) }; reply(id)
        case "cancelRange":
            cancellationActions.append(action); publish()
            if let pendingLoad { self.pendingLoad = nil; reply(pendingLoad, ["messages": [], "coverage": ["complete": false, "reason": "Cancelled"]]) }; reply(id)
        case "ai":
            aiPayloads.append(payload); modeAICalls += 1; publish()
            let request = payload["requestId"] as! String
            if mode == "hold-ai" { pendingAI = id; event(["type": "aiProgress", "accountId": account, "requestId": request, "phase": "waiting"]); return }
            if mode == "fail-second" && modeAICalls == 2 { reject(id, "Synthetic AI batch failure"); return }
            let messages = payload["messages"] as? [[String: Any]] ?? []
            let joined = messages.map { $0["content"] as? String ?? "" }.joined(separator: "\n")
            let isMerge = joined.contains("<分段摘要资料>"), isFollowup = joined.contains("<既有总结>")
            let prefix = isFollowup ? "FOLLOWUP_QA" : isMerge ? "FINAL_QA" : "MAP_QA"
            var citation = "1"
            if !isMerge && !isFollowup, let match = joined.range(of: "\\[消息[0-9]+\\]（片段", options: .regularExpression) { citation = joined[match].filter(\.isNumber) }
            let answer = prefix + " 合成测试结论 [消息" + citation + "]" + (isMerge ? "，对照观点 [消息401]，结束分钟 [消息601]。" : "。")
            event(["type": "aiProgress", "accountId": account, "requestId": request, "phase": "answering", "contentDelta": answer])
            if mode == "truncated" || mode == "filtered" {
                event(["type": "aiProgress", "accountId": account, "requestId": request, "warning": mode == "truncated" ? "回复达到服务输出长度上限，内容可能不完整。" : "服务的内容过滤器终止了输出。"])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { var result: [String: Any] = ["text": answer]; if payload["webSearchEnabled"] as? Bool == true { result["webSearch"] = ["status":"success","query":payload["webSearchQuery"] as? String ?? "summary","searchedAt":"2026-10-18T00:00:00Z","sources":[["id":"网页1","title":"Public reference","url":"https://example.com/reference","publishedAt":NSNull(),"siteName":"Example","excerpt":"Synthetic public reference"]]] }; self.reply(id,result) }
        case "harnessReleaseAI":
            if let pendingAI { self.pendingAI = nil; reply(pendingAI, ["text": "MAP_QA 合成测试结论 [消息1]。"]) }; reply(id)
        case "cancelAI":
            cancellationActions.append(action); publish()
            if let pendingAI { self.pendingAI = nil; reply(pendingAI, ["cancelled": true, "text": ""]) }; reply(id)
        case "extractAttachment", "prepareImported", "importDocument":
            uploadActions.append(action); publish(); reject(id, "Range summary must not read attachment content")
        case "attachmentPreview": reply(id, ["url": "weiyue-media://synthetic/image.png"])
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        default: reply(id)
        }
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let current = phase; phase += 1; print("Range UI phase \(current) started"); fflush(stdout)
        web.callAsyncJavaScript(Self.helpers + (current == 0 ? Self.firstTests : Self.reloadTests), arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                self.results += String(describing: value) + "\n"
                if current == 0 { self.web.reload() } else { self.finish(true, self.results) }
            case .failure(let error):
                self.web.evaluateJavaScript("JSON.stringify({errors:window.__uiErrors,body:document.body.innerText.slice(-3000),ai:window.__aiPayloads?.length,range:window.__rangePayloads?.length})") { value, _ in self.finish(false, error.localizedDescription + "\n" + String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false, error.localizedDescription) }
    func finish(_ success: Bool, _ text: String) { print((success ? "PASS: " : "FAIL: ") + text); fflush(stdout); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms));
const assert=(value,label)=>{if(!value)throw new Error(label);};
const trace=step=>window.webkit.messageHandlers.app.postMessage({id:'trace-'+Math.random(),action:'harnessTrace',payload:{step}});
const wait=async(fn,label)=>{for(let i=0;i<180;i++){if(fn())return;await sleep(25);}throw new Error('Timeout: '+label);};
const field=(id,value)=>{$(id).value=value;$(id).dispatchEvent(new Event('input',{bubbles:true}));};
const post=(action,payload={})=>window.webkit.messageHandlers.app.postMessage({id:'test-'+Math.random(),action,payload});
const mode=async value=>{window.__mode=null;post('harnessMode',{mode:value});await wait(()=>window.__mode===value,'native mock mode');};
const shot=async name=>{post('harnessScreenshot',{name});await wait(()=>window.__screenshot===name,'screenshot '+name);};
const minute=iso=>{const d=new Date(iso),p=x=>String(x).padStart(2,'0');return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+'T'+p(d.getHours())+':'+p(d.getMinutes());};
const active=()=>window.__saved.discussions.find(d=>d.id===window.__saved.settings.activeDiscussionId);
const visible=()=>{const top=$('reader-scroll').getBoundingClientRect().top;return [...document.querySelectorAll('.message-card')].find(c=>c.getBoundingClientRect().bottom>top+15);};
const open=async()=>{await wait(()=>!$('open-range-summary').disabled,'range available');$('open-range-summary').click();assert($('range-summary-dialog').open,'range opens');field('range-summary-start',minute('2026-10-17T01:00:00.000Z'));field('range-summary-end',minute('2026-10-17T01:09:00.000Z'));await sleep(150);};
const submit=()=>{$('range-summary-form').requestSubmit();};
const choose=name=>[...document.querySelectorAll('.group-pick')].find(b=>b.textContent.includes(name)).click();
const taskDetails=()=>{$('range-background-view').click();assert($('range-summary-dialog').open,'task details reopen');};
const done=async()=>{await wait(()=>!$('range-summary-dialog').open&&!$('ai-send').disabled,'summary completion');assert(active()?.rangeSummary.status==='complete','summary saved complete');};
const checkPreferences=payload=>{const sys=payload.messages.filter(m=>m.role==='system').map(m=>m.content).join('\n');for(const marker of ['RANGE_QA_WRITING','RANGE_QA_FORMAT'])assert(sys.includes(marker),'all requests carry '+marker);assert(!sys.includes('RANGE_QA_TEMP'),'legacy temporary requirement is excluded from every map/reduce request');assert(payload.sources?.length===0,'range summary sends no attachment sources');assert(!JSON.stringify(payload).includes('SECRET_ATTACHMENT_')&&!JSON.stringify(payload).includes('SECRET_DOCUMENT_'),'attachment URLs excluded');};
const inViewport=id=>{const r=$(id).getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth;};
"""#
    static let firstTests = #"""
trace('waiting ready');await wait(()=>window.__saved&&$('result-count').textContent.includes('303'),'ready local archive');trace('ready');
await sleep(160);assert(visible()?.dataset.messageId==='400','initial deep reader position restored');
const originalAnchor={...window.__saved.progress.g.auto};
field('message-search','Synthetic message 599.');await wait(()=>$('result-count').textContent.startsWith('1 '),'reader filter active');
trace('opening');await open();trace('opened');assert($('range-summary-count').textContent.includes('301'),'preview includes all cached time-range records despite current reader filter');assert($('range-summary-coverage').textContent.includes('不能确认完整'),'local count is not false completeness');
assert(inViewport('range-summary-submit'),'primary action visible at 1120x700');assert(inViewport('range-summary-start')&&inViewport('range-summary-end'),'datetime fields visible');
trace('screenshots');ReaderAppearance.restore('light');await shot('v100-range-day');ReaderAppearance.restore('dark');await shot('v100-range-night');ReaderAppearance.restore('light');
trace('before hold load');await mode('hold-load');const callsBefore=window.__aiPayloads.length,cancelBefore=window.__cancellations.length;submit();
assert(!$('range-summary-dialog').open,'start automatically returns to main reader');await wait(()=>$('range-background-detail').textContent.includes('300'),'background loading progress counts visible');
assert(!$('range-background-progress').hidden&&!$('range-background-stop').hidden,'right-side task has visible progress and explicit stop');
choose('另一个测试群');await wait(()=>$('group-name').textContent==='另一个测试群','group switching during background load');assert($('range-background-source').textContent.includes('时段测试群'),'task retains original group after switching');
taskDetails();$('range-summary-dialog').dispatchEvent(new Event('cancel',{cancelable:true}));assert(!$('range-summary-dialog').open,'Escape collapses busy task');taskDetails();$('range-summary-dialog').dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:0,clientY:0}));assert(!$('range-summary-dialog').open,'backdrop click collapses busy task');taskDetails();submit();$('range-summary-close').click();assert(!$('range-summary-dialog').open,'close button collapses busy task');
await sleep(80);assert(window.__cancellations.length===cancelBefore,'collapsing never requests cancellation');assert(window.__rangePayloads.length===1,'only one background task dispatched');await shot('v102-range-background-loading');
$('enter-standby').click();await wait(()=>$('group-name').textContent==='待机中'&&window.__saved.settings.readerStandby===true,'standby entered while history is loading');assert(!document.querySelector('.group-row.active'),'standby has no active reading group');assert(!$('range-background-progress').hidden&&!$('range-background-stop').hidden&&$('range-background-detail').textContent.includes('300'),'standby preserves visible live task and message count');assert($('range-background-source').textContent.includes('时段测试群'),'standby keeps original task source');$('open-range-summary').click();assert($('range-summary-dialog').open,'busy task remains accessible while standby has no current group');$('range-summary-close').click();await sleep(80);assert(window.__cancellations.length===cancelBefore,'standby never cancels background task');await shot('v102-range-background-standby');
trace('release load');await mode('hold-ai');post('harnessReleaseLoad');await wait(()=>$('range-background-label').textContent.includes('梳理消息'),'background batch progress');assert($('range-background-detail').textContent.includes('601'),'background batch shows all source messages');await mode('complete');post('harnessReleaseAI');await done();
assert($('group-name').textContent==='待机中'&&!document.querySelector('.group-row.active')&&window.__saved.settings.readerStandby===true,'background completion preserves standby without selecting a group');assert($('range-background-label').textContent==='时段总结已完成','successful completion stays visible in right sidebar');

trace('completed first summary');const summary=active(),payloads=window.__aiPayloads.slice(callsBefore),mapCalls=payloads.filter(p=>p.messages.some(m=>m.content.includes('<聊天资料>'))),reduceCalls=payloads.filter(p=>p.messages.some(m=>m.content.includes('<分段摘要资料>')));
assert(summary.contextSnapshots.length===601&&summary.rangeSummary.sourceCount===601,'601 complete messages selected, not reader-filter subset');assert(summary.contextSnapshots[0].id==='0'&&summary.contextSnapshots.at(-1).id==='end-last','start and final millisecond of end minute included');assert(!summary.contextSnapshots.some(m=>m.groupId!=='g'||['before','after'].includes(m.id)),'other groups and times excluded');assert(mapCalls.length>6&&reduceCalls.length>=1,'actual native requests include multiple batches and final synthesis');
assert(mapCalls.every(p=>p.webSearchEnabled===false),'map batches never search');assert(payloads.filter(p=>p.webSearchEnabled===true).length===1,'only final synthesis searches once');assert(summary.messages.at(-1).webSearch.sources.length===1,'final summary saves web sources');
assert(summary.rangeSummary.completedBatches===mapCalls.length,'durable completed count matches actual map requests');assert(summary.rangeSummary.coverage.complete===true,'complete coverage saved');assert(!String(summary.instructions||'').includes('RANGE_QA_TEMP'),'summary does not inherit removed temporary instructions');payloads.forEach(checkPreferences);assert(window.__uploads.length===0,'no automatic document extraction or image upload');
const mapped=mapCalls.map(p=>p.messages.map(m=>m.content).join('\n')).join('\n');for(const source of summary.contextSnapshots)assert(mapped.includes('"id":"'+source.id+'"'),'every message appears in real batch payload: '+source.id);
assert(window.__saved.progress.g.auto.messageId===originalAnchor.messageId&&Math.abs(window.__saved.progress.g.auto.offset-originalAnchor.offset)<2,'summarization preserves saved reader anchor: '+JSON.stringify({before:originalAnchor,after:window.__saved.progress.g.auto}));assert(document.querySelectorAll('.summary-source-button').length===20,'source list bounded to 20 rows');assert(document.querySelector('.citation-link')&&$('conversation-messages').textContent.includes('FINAL_QA'),'completed answer displays clickable citations');
const cite=n=>[...$('conversation-messages').querySelectorAll('.citation-link')].find(b=>b.textContent==='[消息'+n+']');cite(401).click();await sleep(100);assert(document.querySelector('.target-message')?.dataset.messageId==='400','citation jumps to cached original');assert($('group-name').textContent==='时段测试群'&&document.querySelector('.group-row.active .group-pick')?.dataset.groupId==='g','summary citation leaves standby and enters the original source group');cite(1).click();await sleep(100);assert(document.querySelector('.target-message')?.dataset.messageId==='0','citation jumps to saved source even if not in local archive');assert(!window.__saved.messages.some(m=>m.groupId==='g'&&m.id==='0'),'snapshot jump does not invent a cached original');
assert(document.querySelector('.target-message input[type=checkbox]').disabled,'uncached source cannot be selected as a cached original');const snapshotAnchor={...window.__saved.progress.g.auto};$('reader-scroll').dispatchEvent(new WheelEvent('wheel',{deltaY:1,bubbles:true}));$('reader-scroll').scrollTop+=1;$('reader-scroll').dispatchEvent(new Event('scroll'));await sleep(650);await window.flushBeforeQuit();assert(window.__saved.progress.g.auto.messageId===snapshotAnchor.messageId,'scrolling and flushing on a source snapshot preserves valid anchor');assert($('return-position').hidden===false,'citation jump retains return-to-reading position');$('return-position').click();await sleep(100);assert(visible()?.dataset.messageId==='400','return resumes previous original after snapshot jump');
cite(1).click();await sleep(60);choose('另一个测试群');await wait(()=>$('group-name').textContent==='另一个测试群','switch away from snapshot');choose('时段测试群');await wait(()=>visible()?.dataset.messageId==='400','switch back restores valid original anchor');await shot('v100-range-result');
await window.flushBeforeQuit();assert(window.__uiErrors.length===0,'no first-phase JS errors: '+JSON.stringify(window.__uiErrors));return JSON.stringify({phase:'complete and reload',sources:601,mapCalls:mapCalls.length,reduceCalls:reduceCalls.length,preciseBoundaries:true,filterIndependent:true,allPreferences:true,citations:true,missingSourceSnapshot:true,anchorPreserved:true,backgroundLoading:true,backgroundSwitchGroup:true,collapseDoesNotCancel:true,rightPanelProgress:true,standbyBackgroundCompletion:true,standbyCitationReturnsToSource:true});
"""#
    static let reloadTests = #"""
trace('reload starting');await wait(()=>active()?.rangeSummary.status==='complete'&&$('conversation-messages').textContent.includes('FINAL_QA'),'saved summary restored');trace('reload restored');
assert(active().contextSnapshots.length===601,'all summary sources persisted');assert($('conversation-messages').querySelectorAll('.citation-link').length>=3,'citations restored after reload');assert(visible()?.dataset.messageId==='400','reader anchor survives summary reload');
trace('before followup');await wait(()=>!$('ai-send').disabled,'model capabilities ready after reload');const beforeFollowup=window.__aiPayloads.length;field('ai-question','QA follow-up: explain the disagreements');$('ai-form').requestSubmit();await wait(()=>window.__aiPayloads.length===beforeFollowup+1&&!$('ai-send').disabled,'follow-up complete');const follow=window.__aiPayloads.at(-1);checkPreferences(follow);assert(follow.messages.some(m=>m.content.includes('<既有总结>')),'follow-up uses compact summary');assert(!follow.messages.some(m=>m.content.includes('<聊天资料>')),'follow-up does not resend full archive');assert(JSON.stringify(follow).length<16000,'follow-up payload bounded');
await mode('partial');await open();const beforePartial=window.__aiPayloads.length;submit();await wait(()=>!$('range-summary-partial').hidden,'incomplete result decision');assert(!$('range-summary-dialog').open&&$('range-background-label').textContent==='消息尚未加载完整','incomplete task stays visible without reopening modal');choose('另一个测试群');taskDetails();assert($('range-summary-group').textContent==='时段测试群','partial decision retains original task group');assert(window.__aiPayloads.length===beforePartial,'incomplete range does not silently call AI');assert($('range-summary-partial').textContent.includes('80'),'partial button names exact count');assert($('range-summary-coverage').textContent.includes('不能确认完整'),'known omissions displayed');await shot('v100-range-incomplete');$('range-summary-partial').click();await done();assert(active().rangeSummary.coverage.complete===false&&active().contextSnapshots.length===80&&active().contextSnapshots.every(m=>m.groupId==='g'),'explicit partial summary retains original group and incomplete label');assert($('group-name').textContent==='另一个测试群','partial completion preserves current reading group');choose('时段测试群');const partialCalls=window.__aiPayloads.slice(beforePartial);partialCalls.forEach(checkPreferences);assert(partialCalls.every(p=>p.messages.some(m=>m.content.includes('其余消息未能加载'))),'known omissions propagated to every AI request');
await mode('load-error');await open();const beforeError=window.__aiPayloads.length;submit();await wait(()=>!$('range-summary-partial').hidden,'historical error fallback');taskDetails();assert($('range-summary-coverage').textContent.includes('Synthetic historical access failure'),'actual load error surfaced');assert(window.__aiPayloads.length===beforeError,'load failure needs explicit partial choice');$('range-summary-close').click();
await mode('hold-load');await open();const beforeLoadCancel=window.__aiPayloads.length;submit();await wait(()=>!$('range-summary-cancel').hidden,'loading cancel available');assert(!$('range-summary-close').disabled,'running dialog can collapse safely');assert(!$('range-summary-dialog').open,'loading runs with modal closed');$('range-background-stop').click();await wait(()=>$('range-background-stop').hidden,'load cancellation settled');assert(window.__aiPayloads.length===beforeLoadCancel,'cancelling history never calls AI');assert($('range-summary-progress-label').textContent==='已停止'||$('range-summary-coverage').textContent.includes('已停止读取'),'cancel state visible');$('range-summary-close').click();
await mode('hold-ai');await open();const beforeAICancel=window.__aiPayloads.length;submit();await wait(()=>window.__aiPayloads.length===beforeAICancel+1,'AI batch awaiting cancellation');assert(!$('range-summary-dialog').open,'AI batches run outside modal');$('range-background-stop').click();await wait(()=>$('range-background-stop').hidden,'AI cancellation settled');await sleep(120);assert(window.__aiPayloads.length===beforeAICancel+1,'no subsequent batch after cancel');assert(active().rangeSummary.status==='interrupted','cancelled discussion saved for later');$('range-summary-close').click();
for(const cause of ['truncated','filtered']){await mode(cause);await open();const beforeCutoff=window.__aiPayloads.length;submit();await wait(()=>!$('range-summary-error').hidden,'model cutoff surfaced');assert(window.__aiPayloads.length===beforeCutoff+1,'model cutoff prevents further requests');assert(active().rangeSummary.status==='failed'&&active().rangeSummary.completedBatches===0,'cutoff never counted as a complete batch');assert($('range-summary-error').textContent.includes('提前中止')&&$('range-background-detail').textContent.includes('提前中止'),'cutoff explanation visible in background panel');$('range-summary-close').click();}
await mode('fail-second');await open();const beforeFailure=window.__aiPayloads.length;submit();await wait(()=>!$('range-summary-error').hidden,'second batch failure');assert(window.__aiPayloads.length===beforeFailure+2,'failure stops after second request');assert(active().rangeSummary.status==='failed'&&active().rangeSummary.partials.length===1,'completed partial saved after later failure');assert($('range-summary-error').textContent.includes('Synthetic AI batch failure')&&$('range-background-detail').textContent.includes('Synthetic AI batch failure'),'actual AI failure displayed in background panel');$('range-summary-close').click();const partialDetails=$('conversation-messages').querySelector('details.summary-sources');assert(partialDetails,'saved partial remains inspectable');partialDetails.open=true;await wait(()=>partialDetails.textContent.includes('MAP_QA'),'saved partial renders on demand');
await mode('complete');const retry=[...$('conversation-messages').querySelectorAll('button')].find(b=>b.textContent==='重新生成这段总结');assert(retry,'failed summary has retry');const beforeRetry=window.__aiPayloads.length;retry.click();assert(!$('range-background-progress').hidden&&!$('range-background-stop').hidden,'retry is monitored in background panel');await wait(()=>active().rangeSummary.status==='complete'&&!$('ai-send').disabled,'retry completion');assert(window.__aiPayloads.length>beforeRetry+6,'retry runs complete batches');window.__aiPayloads.forEach(checkPreferences);
$('manage-sync-groups').click();const oldGroupCheck=$('sync-groups-dialog').querySelector('.sync-group-checkbox[data-group-id="g"]');assert(oldGroupCheck,'old task group is editable in sync manager');oldGroupCheck.click();$('sync-groups-form').requestSubmit();await wait(()=>!$('sync-groups-dialog').open&&window.__saved.groups.find(g=>g.id==='g').selected===false,'old task group deselected');choose('另一个测试群');assert(!$('open-range-summary').disabled,'new task entry follows current group rather than completed task group');$('open-range-summary').click();assert($('range-summary-dialog').open&&$('range-summary-group').textContent==='另一个测试群','new task opens for newly selected group');$('range-summary-close').click();
assert(window.__uploads.length===0,'no attachment processing throughout scenarios');assert(window.__uiErrors.length===0,'no reload-phase JS errors: '+JSON.stringify(window.__uiErrors));await window.flushBeforeQuit();
return JSON.stringify({phase:'reload and failures',summaryReload:true,citationsReload:true,compactFollowup:true,explicitPartial:true,loadError:true,cancelLoad:true,cancelAI:true,failurePreservesPartials:true,retry:true,partialRetainsOriginalGroup:true,newTaskAfterPreviousGroupDeselected:true,totalAIRequests:window.__aiPayloads.length,totalRangeLoads:window.__rangePayloads.length});
"""#
}
@main struct RunRangeSummaryUIHarness {
    static func main() { let app = NSApplication.shared; app.setActivationPolicy(.prohibited); let delegate = RangeSummaryUIHarness(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } }
}
