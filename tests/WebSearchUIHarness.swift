import AppKit
import WebKit

// Synthetic desktop acceptance: no credentials or external network requests.
@MainActor final class WebSearchUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var temp: URL!
    var output: URL!
    var state: [String: Any] = [:]
    var calls: [[String: Any]] = []
    var phase = 0
    var mode = "success"
    var pending: Any?
    let date = "2026-10-18T01:00:00.000Z"
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build", isDirectory: true)
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-web-qa-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.copyItem(at: source, to: temp)
            state = ["version":1,"revision":1,"accountId":"web-qa","groups":[],"messages":[],"bookmarks":[],"collections":[],"discussions":[],"progress":[:],"settings":["baseURL":"https://api.deepseek.com","model":"deepseek-flash","mode":"reader","aiDraftInstructions":"TEMP_PRIORITY_KEEP","aiPreferences":["version":1,"entries":[["id":"p","title":"Style","category":"writing","content":"PREFERENCE_KEEP","enabled":true]],"quickPrompts":[]]]]
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController.add(self,name:"app")
            config.userContentController.addUserScript(WKUserScript(source:"window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));",injectionTime:.atDocumentStart,forMainFrameOnly:true))
            web = WKWebView(frame:NSRect(x:0,y:0,width:1120,height:700),configuration:config); web.navigationDelegate=self
            window = NSWindow(contentRect:NSRect(x:-4000,y:-4000,width:1120,height:700),styleMask:[.titled],backing:.buffered,defer:false); window.contentView=web; window.appearance=NSAppearance(named:.aqua); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"),allowingReadAccessTo:temp)
            DispatchQueue.main.asyncAfter(deadline:.now()+90){self.finish(false,"timeout")}
        } catch { finish(false,error.localizedDescription) }
    }
    func json(_ value: Any) -> String { String(data:try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]),encoding:.utf8)! }
    func reply(_ id: Any,_ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive("+json(["id":id,"ok":true,"result":value])+")",completionHandler:nil) }
    func event(_ value: [String: Any]) { web.evaluateJavaScript("window.onNativeEvent("+json(value)+")",completionHandler:nil) }
    func publish() { web.evaluateJavaScript("window.__saved="+json(state)+";window.__calls="+json(calls),completionHandler:nil) }
    func metadata(_ query: String) -> [String: Any] {
        let source: [String: Any] = ["id":"网页1","title":"Official public reference <script>plain text</script>","url":query == "Second distinct reference" ? "https://example.com/second" : "https://example.com/reference","publishedAt":date,"siteName":"Official example","excerpt":"PUBLIC_EXCERPT"]
        var value: [String: Any] = ["status":mode,"query":query,"searchedAt":date,"sources":mode == "success" ? [source] : []]
        if mode == "failed" {value["error"]="Synthetic search unavailable"}
        return value
    }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let body=message.body as? [String:Any],let action=body["action"] as? String,let id=body["id"] else {return}
        let payload=body["payload"] as? [String:Any] ?? [:]
        switch action {
        case "ready":publish();reply(id,["state":state,"hasAPIKey":true,"accountName":"Synthetic QA","appearance":"light"])
        case "save":state=payload["state"] as! [String:Any];publish();reply(id,["revision":state["revision"]!])
        case "harnessMode":mode=payload["mode"] as! String;web.evaluateJavaScript("window.__mode="+json(mode),completionHandler:nil);reply(id)
        case "ai":
            calls.append(payload);publish()
            let enabled=payload["webSearchEnabled"] as? Bool == true
            let request=payload["requestId"] as? String ?? ""
            var progress:[String:Any]=["type":"aiProgress","accountId":"web-qa","requestId":request,"phase":enabled ? "searching" : "answering","detail":"Searching synthetic public web"]
            event(progress)
            if mode == "hold" { pending=id;return }
            let meta=metadata(payload["webSearchQuery"] as? String ?? "question")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.12){
                if enabled {progress["phase"]="reading";progress["webSearch"]=meta;self.event(progress)}
                let question = (payload["messages"] as? [[String:Any]])?.last?["content"] as? String ?? ""
                let answer = enabled ? "WEB_ANSWER [网页1] and unknown [网页5]" + (question == "Second distinct reference" ? " old [历史网页4-1]" : "") : question == "Explain older references while off" ? "HISTORICAL_ONLY [历史网页4-1]" : "OFFLINE_ANSWER"
                var result:[String:Any]=["text":answer]
                if enabled{result["webSearch"]=meta}
                self.reply(id,result)
            }
        case "cancelAI":if let pending {self.pending=nil;reply(pending,["cancelled":true,"text":""])};reply(id)
        case "harnessScreenshot":
            let name=payload["name"] as! String
            web.takeSnapshot(with:nil){image,error in
                guard let image,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {self.finish(false,error?.localizedDescription ?? "snapshot failed");return}
                do{try png.write(to:self.output.appendingPathComponent(name+".png"));self.web.evaluateJavaScript("window.__shot="+self.json(name),completionHandler:nil);self.reply(id)}catch{self.finish(false,error.localizedDescription)}
            }
        default:reply(id)
        }
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
        if let url=navigationAction.request.url,!url.isFileURL {web.evaluateJavaScript("window.__opened="+json(url.absoluteString),completionHandler:nil);decisionHandler(.cancel)}else{decisionHandler(.allow)}
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){
        let current=phase;phase+=1
        let script=current==0 ? Self.tests : current==1 ? Self.reloadTests : Self.providerTests
        web.callAsyncJavaScript(Self.helpers+script,arguments:[:],in:nil,in:.page){result in
            switch result {
            case .success(let value):print("PASS phase \(current): \(String(describing:value))");fflush(stdout)
                if current<2 {if current==1 {var settings=self.state["settings"] as! [String:Any];settings["baseURL"]="https://compatible.example/v1";self.state["settings"]=settings};self.web.reload()} else {self.finish(true,"web search desktop lifecycle")}
            case .failure(let error):self.web.evaluateJavaScript("JSON.stringify({errors:window.__errors,body:document.body.innerText.slice(-2000)})"){value,_ in self.finish(false,String(describing:(error as NSError).userInfo)+" "+String(describing:value))}
            }
        }
    }
    func finish(_ ok:Bool,_ text:String){print((ok ? "PASS: " : "FAIL: ")+text);fflush(stdout);if let temp{try? FileManager.default.removeItem(at:temp)};exit(ok ? 0:1)}
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw new Error(l);};
const wait=async(fn,label)=>{for(let i=0;i<200;i++){if(fn())return;await sleep(25);}throw new Error('Timeout: '+label);};
const post=(action,payload={})=>window.webkit.messageHandlers.app.postMessage({id:'qa-'+Math.random(),action,payload});
const setMode=async mode=>{post('harnessMode',{mode});await wait(()=>window.__mode===mode,'mode');};
const ask=async question=>{const count=window.__calls.length;$('ai-question').value=question;$('ai-form').requestSubmit();await wait(()=>window.__calls.length===count+1,'AI call');await wait(()=>!$('ai-send').disabled,'answer saved');return window.__calls.at(-1);};
const toggle=async enabled=>{if(($('ai-web-search').getAttribute('aria-pressed')==='true')!==enabled)$('ai-web-search').click();await wait(()=>window.__saved.settings.webSearchEnabled===enabled,'toggle saved');};
const shot=async name=>{post('harnessScreenshot',{name});await wait(()=>window.__shot===name,'screenshot');};
const current=()=>window.__saved.discussions.find(d=>d.id===window.__saved.settings.activeDiscussionId);
"""#
    static let tests = #"""
await wait(()=>window.__saved&&!$('ai-send').disabled,'ready');assert(!($('ai-web-search').getAttribute('aria-pressed')==='true')&&!$('ai-web-search').disabled,'search off by default');
let call=await ask('Public offline question');assert(call.webSearchEnabled===false&&!call.webSearchQuery,'off never searches');assert(!current().messages.at(-1).webSearch,'off has no search claims');
await toggle(true);call=await ask('Latest public release date');assert(call.webSearchEnabled&&call.webSearchQuery==='Latest public release date','enabled sends only question');assert(JSON.stringify(call.messages).includes('PREFERENCE_KEEP')&&!JSON.stringify(call.messages).includes('TEMP_PRIORITY_KEEP'),'long-term preference preserved and legacy temporary requirement excluded');assert(current().messages.at(-1).webSearch.sources.length===1,'source metadata saved');
let links=document.querySelectorAll('.web-citation');assert(links.length===1&&links[0].href==='https://example.com/reference','only returned source citation linked');links[0].click();await wait(()=>window.__opened==='https://example.com/reference','source navigation');assert(!document.querySelector('.web-sources script'),'source title rendered safely as text');document.querySelector('.web-sources').open=true;assert(document.querySelector('.web-sources').textContent.includes('检索于')&&document.querySelector('.web-sources').textContent.includes('发布于'),'retrieval and publication dates shown');
const toggleButton=$('ai-web-search');assert(toggleButton.getAttribute('aria-pressed')==='true'&&getComputedStyle(toggleButton).backgroundColor!==getComputedStyle($('ai-thinking')).backgroundColor,'enabled button is visibly lit');$('conversation').scrollTop=$('conversation').scrollHeight;ReaderAppearance.restore('light');await shot('v101-web-day');ReaderAppearance.restore('dark');await shot('v101-web-night');ReaderAppearance.restore('light');
call=await ask('Second distinct reference');assert(JSON.stringify(call.messages).includes('历史网页4-1')&&JSON.stringify(call.messages).includes('https://example.com/reference'),'followup carries old source mapping');let answerLinks=document.querySelector('.conversation-message.assistant:last-child').querySelectorAll('.web-citation');assert(answerLinks.length===2&&answerLinks[0].href==='https://example.com/second'&&answerLinks[1].href==='https://example.com/reference','new and old citations resolve independently');
await setMode('empty');await ask('Public no result query');assert(current().messages.at(-1).webSearch.status==='empty'&&Array.from(document.querySelectorAll('.web-sources')).at(-1).textContent.includes('未经联网核实'),'empty explicit');
await setMode('failed');await ask('Public failed query');assert(current().messages.at(-1).webSearch.status==='failed'&&Array.from(document.querySelectorAll('.web-sources')).at(-1).textContent.includes('Synthetic search unavailable'),'failure explicit');
await setMode('hold');const count=window.__calls.length;$('ai-question').value='Public cancellable query';$('ai-form').requestSubmit();await wait(()=>window.__calls.length===count+1,'search pending');await wait(()=>$('ai-progress-label').textContent==='正在联网搜索','visible search status');assert($('ai-web-search').disabled,'toggle locked during request');$('ai-cancel').click();await wait(()=>!$('ai-send').disabled,'cancel settled');assert(current().messages.at(-1).status==='failed','cancel keeps question retryable');
await toggle(false);await setMode('success');call=await ask('Explain older references while off');assert(call.webSearchEnabled===false,'switch off takes effect next request');assert(JSON.stringify(call.messages).includes('https://example.com/reference'),'off followup retains historical sources');assert(document.querySelector('.conversation-message.assistant:last-child .web-citation').href==='https://example.com/reference','off historical reference still opens original');await toggle(true);await ask('Public reload source');await window.flushBeforeQuit();assert(window.__errors.length===0,'no script errors');return 'off/on/off, citations, empty, failure, cancel, preference priority, snapshots';
"""#
    static let reloadTests = #"""
await wait(()=>window.__saved&&!$('ai-send').disabled,'reload');assert(($('ai-web-search').getAttribute('aria-pressed')==='true'),'switch persists after reopening');assert(current().messages.at(-1).webSearch.sources.length===1&&document.querySelectorAll('.web-citation').length===5,'saved source citations survive reload');assert(document.querySelector('.web-sources').textContent.includes('2026'),'retrieval time persists');await window.flushBeforeQuit();assert(window.__errors.length===0,'no reload errors');return 'switch and sources persist';
"""#
    static let providerTests = #"""
await wait(()=>window.__saved&&!$('ai-send').disabled,'provider reload');assert($('ai-web-search').disabled&&!($('ai-web-search').getAttribute('aria-pressed')==='true'),'unsupported provider not advertised as searchable');assert($('web-search-hint').textContent.includes('DeepSeek'),'provider limitation shown');const call=await ask('Other provider question');assert(call.webSearchEnabled===false,'no search on unsupported provider');assert(window.__errors.length===0,'no provider errors');return 'provider isolation';
"""#
}
@main struct RunWebSearchUIHarness {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let delegate=WebSearchUIHarness();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}}
