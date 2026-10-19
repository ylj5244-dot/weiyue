import AppKit
import WebKit

// Synthetic UI acceptance only. Never uses a login, API key or network service.
@MainActor final class CompactAIUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var temp: URL!
    var output: URL!
    var state: [String: Any] = [:]
    var calls: [[String: Any]] = []
    var phase = 0
    var baseline = false
    var staleCapabilityReply: Any?
    let date = "2026-10-18T01:00:00.000Z"
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            baseline=CommandLine.arguments.contains("--baseline")
            output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build",isDirectory:true)
            temp=FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-compact-qa-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.copyItem(at:source,to:temp)
            let sourceMessage:[String:Any] = ["accountId":"compact-qa","groupId":"group-a","id":"101","senderId":"person-a","senderName":"林舟","text":"关注讨论中的事实和判断，把需要查证的问题保留下来。","sentAt":date,"attachments":[]]
            let longAnswer=(1...18).map { "\($0). 阅读与判断\n把讨论的重点放在可核实的事实、每个人的观点以及仍然存在的分歧上。对关键结论保留出处，方便继续追问，也方便回到原消息核对。这里是用于布局验收的模拟回复。" }.joined(separator:"\n\n")
            let prefs:[String:Any] = ["version":1,"entries":[["id":"style","title":"写作风格","category":"writing","content":"完整段落表达","enabled":true]],"quickPrompts":[["id":"quick1","title":"梳理核心观点","prompt":"请梳理核心观点。","enabled":true],["id":"quick2","title":"整理分歧","prompt":"请整理分歧。","enabled":true],["id":"quick3","title":"查找论据","prompt":"请查找论据。","enabled":true]]]
            state=["version":1,"revision":1,"accountId":"compact-qa","groups":[["id":"group-a","name":"阅读讨论群","selected":true]],"messages":[sourceMessage],"bookmarks":[],"collections":[],"discussions":[["id":"discussion-a","accountId":"compact-qa","title":"从讨论中提炼可用的判断","createdAt":date,"contextSnapshots":[sourceMessage],"instructions":"本次尽量简洁","messages":[["role":"user","content":"请梳理这段讨论的主要观点。","createdAt":date],["role":"assistant","content":longAnswer,"createdAt":date]]]],"progress":[:],"settings":["activeDiscussionId":"discussion-a","activeGroupId":"group-a","baseURL":"https://api.deepseek.com","model":"deepseek-flash","thinking":"auto","mode":"reader","aiPreferences":prefs]]
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.userContentController.add(self,name:"app")
            config.userContentController.addUserScript(WKUserScript(source:"window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));",injectionTime:.atDocumentStart,forMainFrameOnly:true))
            web=WKWebView(frame:NSRect(x:0,y:0,width:1120,height:700),configuration:config);web.navigationDelegate=self
            window=NSWindow(contentRect:NSRect(x:-4000,y:-4000,width:1120,height:700),styleMask:[.titled],backing:.buffered,defer:false);window.contentView=web;window.appearance=NSAppearance(named:.aqua);window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"),allowingReadAccessTo:temp)
            DispatchQueue.main.asyncAfter(deadline:.now()+120){self.finish(false,"timeout")}
        } catch {finish(false,error.localizedDescription)}
    }
    func json(_ value:Any)->String{String(data:try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]),encoding:.utf8)!}
    func reply(_ id:Any,_ value:Any=[:]){web.evaluateJavaScript("window.nativeReceive("+json(["id":id,"ok":true,"result":value])+")",completionHandler:nil)}
    func event(_ value:[String:Any]){web.evaluateJavaScript("window.onNativeEvent("+json(value)+")",completionHandler:nil)}
    func publish(){web.evaluateJavaScript("window.__saved="+json(state)+";window.__calls="+json(calls),completionHandler:nil)}
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){
        guard let body=message.body as? [String:Any],let action=body["action"] as? String,let id=body["id"] else{return}
        let payload=body["payload"] as? [String:Any] ?? [:]
        switch action {
        case "harnessStep":print("STEP: \(payload["label"] ?? "")");fflush(stdout);reply(id)
        case "ready":publish();reply(id,["state":state,"hasAPIKey":true,"accountName":"布局验收","appearance":"light"])
        case "save":state=payload["state"] as! [String:Any];publish();reply(id,["revision":state["revision"]!])
        case "aiCapabilities":
            let model=payload["model"] as? String ?? ""
            let cap:[String:Any]=model=="deepseek-flash" ? ["thinking":true,"canDisableThinking":true] : model=="fixed-model" || model=="stale-model" ? ["thinking":true,"canDisableThinking":false] : model=="no-thinking" ? ["thinking":false,"canDisableThinking":false] : [:]
            if model=="stale-model" {staleCapabilityReply=id;web.evaluateJavaScript("window.__staleReleased=false",completionHandler:nil);return}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.04){self.reply(id,cap)}
        case "ai":print("STEP: native AI call");fflush(stdout);calls.append(payload);publish();reply(id,["text":"模拟回复完成，实际请求参数已检查。"])
        case "harnessReleaseStale":
            if let pending=staleCapabilityReply {reply(pending,["thinking":true,"canDisableThinking":false]);staleCapabilityReply=nil}
            web.evaluateJavaScript("window.__staleReleased=true",completionHandler:nil);reply(id)
        case "harnessConfigure":
            var settings=state["settings"] as! [String:Any];settings["model"]=payload["model"]!;if let base=payload["baseURL"] as? String{settings["baseURL"]=base};if let thinking=payload["thinking"]{settings["thinking"]=thinking};state["settings"]=settings
            if let account=payload["accountId"] as? String,state["accountId"] as? String != account {state["accountId"]=account;state["groups"]=[];state["messages"]=[];state["discussions"]=[];state["progress"]=[:];settings.removeValue(forKey:"activeDiscussionId");settings.removeValue(forKey:"activeGroupId");settings.removeValue(forKey:"groupUnread");state["settings"]=settings}
            publish();event(["type":"account","state":state,"hasAPIKey":true,"accountName":"布局验收"]);reply(id)
        case "harnessScreenshot":
            let name=payload["name"] as! String
            web.takeSnapshot(with:nil){image,error in
                guard let image,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else{self.finish(false,error?.localizedDescription ?? "snapshot failed");return}
                do{try png.write(to:self.output.appendingPathComponent(name+".png"));self.web.evaluateJavaScript("window.__shot="+self.json(name),completionHandler:nil);self.reply(id)}catch{self.finish(false,error.localizedDescription)}
            }
        default:reply(id)
        }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){
        let current=phase;phase+=1
        let script=baseline ? Self.baselineTests : current==0 ? Self.tests : Self.reloadTests
        web.callAsyncJavaScript(Self.helpers+script,arguments:[:],in:nil,in:.page){result in
            switch result {
            case .success(let value):print("PASS phase \(current): \(String(describing:value))");fflush(stdout)
                if !self.baseline && current==0 {self.web.reload()}else{self.finish(true,self.baseline ? "baseline geometry" : "compact AI controls, layout, migration and reopening")}
            case .failure(let error):self.web.evaluateJavaScript("JSON.stringify({errors:window.__errors,body:document.body.innerText.slice(-1400)})"){value,_ in self.finish(false,String(describing:(error as NSError).userInfo)+" "+String(describing:value))}
            }
        }
    }
    func finish(_ ok:Bool,_ text:String){print((ok ? "PASS: " : "FAIL: ")+text);fflush(stdout);if let temp{try? FileManager.default.removeItem(at:temp)};exit(ok ? 0:1)}
    static let helpers = #"""
const step=label=>window.webkit.messageHandlers.app.postMessage({id:'step',action:'harnessStep',payload:{label}});
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw new Error(l);};
const wait=async(fn,label)=>{for(let i=0;i<240;i++){if(fn())return;await sleep(25);}throw new Error('Timeout: '+label);};
const post=(action,payload={})=>window.webkit.messageHandlers.app.postMessage({id:'qa-'+Math.random(),action,payload});
const shot=async name=>{post('harnessScreenshot',{name});await wait(()=>window.__shot===name,'screenshot');};
const rect=id=>{const r=$(id).getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,bottom:r.bottom,right:r.right};};
const pressed=id=>$(id).getAttribute('aria-pressed')==='true';
const ask=async question=>{step('ask '+question+' disabled='+$('ai-send').disabled);const before=window.__calls.length;$('ai-question').value=question;$('ai-form').requestSubmit();await wait(()=>window.__calls.length===before+1,'AI call');step('AI received');await wait(()=>!$('ai-send').disabled,'saved answer');step('answer saved');return window.__calls.at(-1);};
const configure=async(model,thinking)=>{post('harnessConfigure',{model,...(thinking?{thinking}:{})});await wait(()=>window.__saved.settings.model===model&&$('ai-model-label').textContent===model&&!$('ai-send').disabled,'model capabilities');};
const visible=id=>{const r=rect(id);return r.width>0&&r.height>0&&r.y>=0&&r.bottom<=innerHeight;};
const fit=()=>{const a=rect('ai-web-search'),b=rect('ai-thinking'),side=rect('inspector');assert(Math.abs(a.y-b.y)<1,'options share one row');assert(a.right<=b.x&&b.right<=side.right,'two controls fit without overlap');assert(visible('ai-send')&&visible('ai-question'),'composer stays on screen');assert($('inspector').scrollWidth<=$('inspector').clientWidth+1,'sidebar has no horizontal overflow');return rect('conversation');};
"""#
    static let baselineTests = #"""
await wait(()=>window.__saved&&!$('ai-send').disabled,'ready');await sleep(150);$('conversation').scrollTop=0;return JSON.stringify({window:[innerWidth,innerHeight],sidebar:rect('inspector').width,conversation:rect('conversation'),composer:document.querySelector('.composer-section').getBoundingClientRect().height});
"""#
    static let tests = #"""
step('waiting initial capability');await wait(()=>window.__saved&&!$('ai-send').disabled&&!$('ai-thinking').disabled,'ready');step('ready');await wait(()=>window.__saved.settings.thinking==='disabled','old auto migration saved');
assert(!pressed('ai-thinking')&&!pressed('ai-web-search'),'both toggles initially off');assert(!$('context-disclosure').open&&$('context-count').textContent.includes('1'),'materials collapsed with discoverable count');
step('geometry');const size=fit();step('reply height '+size.height);assert(size.height>=330,'reply viewport gains real height at 1120x700');assert($('conversation').scrollHeight>size.height*2,'long answer has scrollable area');$('conversation').scrollTop=500;await sleep(30);assert($('conversation').scrollTop>=490,'long reply scroll advances');$('conversation').scrollTop=0;
$('context-disclosure').open=true;await sleep(30);assert(visible('context-list')&&$('context-list').textContent.includes('林舟'),'materials can be opened');assert(visible('import-ai-document')&&visible('save-ai-context'),'document and saving actions discoverable');$('context-disclosure').open=false;
step('preferences');if(!$('settings-dialog').open)$('settings-button').click();$('open-preferences').click();assert($('preferences-dialog').open,'preferences reachable');document.querySelector('[data-close-preferences="library"]').click();
assert(!$('open-temporary-preferences')&&!$('temporary-preferences-dialog')&&!$('temporary-preferences-chip'),'removed per-discussion requirement UI is absent');
const count=window.__calls.length;document.querySelector('.quick-prompt-button').click();assert($('ai-question').value==='请梳理核心观点。'&&window.__calls.length===count,'custom quick prompt remains editable and does not send');$('ai-question').value='';
step('screenshots');ReaderAppearance.restore('light');await shot('v102-ai-compact-day');ReaderAppearance.restore('dark');await shot('v102-ai-compact-night');ReaderAppearance.restore('light');
ReaderLayout.restore({inspectorWidth:280,sidebarWidth:220});await sleep(80);const narrow=fit();assert(narrow.height>=330,'narrow sidebar preserves reply height');await shot('v102-ai-compact-narrow');ReaderLayout.restore({inspectorWidth:330,sidebarWidth:220});
step('requests');let call=await ask('Default disabled request');assert(call.thinking==='disabled'&&call.webSearchEnabled===false,'grey explicitly sends disabled to supported model');
$('ai-thinking').click();await wait(()=>window.__saved.settings.thinking==='enabled','thinking saved');step('thinking toggle saved');assert(pressed('ai-thinking'),'thinking lit');$('ai-web-search').click();await wait(()=>window.__saved.settings.webSearchEnabled===true,'search saved');assert(pressed('ai-web-search'),'search lit');assert(getComputedStyle($('ai-thinking')).backgroundColor===getComputedStyle($('ai-web-search')).backgroundColor,'both use same active appearance');call=await ask('Both options enabled');assert(call.thinking==='enabled'&&call.webSearchEnabled===true,'both toggles sent');
$('ai-thinking').click();$('ai-web-search').click();await wait(()=>window.__saved.settings.thinking==='disabled'&&window.__saved.settings.webSearchEnabled===false,'both off saved');call=await ask('Both options disabled');assert(call.thinking==='disabled'&&call.webSearchEnabled===false,'second click really disables both');
step('models');await configure('fixed-model');assert($('ai-thinking').disabled&&pressed('ai-thinking')&&$('thinking-state').textContent==='常开','fixed-thinking model honestly lit and disabled');assert(window.__saved.settings.thinking==='disabled','fixed model does not mutate saved user preference');call=await ask('Fixed thinking request');assert(call.thinking==='enabled','fixed-thinking request is enabled');
await configure('no-thinking');assert($('ai-thinking').disabled&&!pressed('ai-thinking')&&$('thinking-state').textContent==='模型默认','unsupported option explicitly says model default');call=await ask('No confirmed thinking control');assert(call.thinking==='auto','unsupported provider not sent invalid thinking flag');
await configure('unknown-model');assert($('ai-thinking').disabled&&$('thinking-state').textContent==='模型默认','unrecognized capabilities are labelled honestly');call=await ask('Unknown capabilities request');assert(call.thinking==='auto','unknown models remain compatible');
await configure('deepseek-flash');assert(!pressed('ai-thinking')&&!$('ai-thinking').disabled,'previous off preference restored');
step('stale model race');post('harnessConfigure',{model:'stale-model'});await wait(()=>$('thinking-state').textContent==='确认中','capability request pending');assert($('ai-send').disabled,'sending blocked while capabilities unknown');post('harnessConfigure',{model:'deepseek-flash',accountId:'second-account'});await wait(()=>window.__saved.accountId==='second-account'&&!$('ai-send').disabled,'new account ready');post('harnessReleaseStale');await wait(()=>window.__staleReleased,'late capability released');await sleep(80);assert(!pressed('ai-thinking')&&!$('ai-thinking').disabled,'stale account capability reply cannot override new state');
step('unconfigured account race');post('harnessConfigure',{model:'stale-model'});await wait(()=>$('thinking-state').textContent==='确认中','second pending capability');post('harnessConfigure',{model:'',baseURL:'',accountId:'unconfigured-account'});await wait(()=>window.__saved.accountId==='unconfigured-account'&&!$('ai-send').disabled,'unconfigured account unlocked');post('harnessReleaseStale');await wait(()=>window.__staleReleased,'unconfigured old reply released');await sleep(80);assert(!$('open-preferences').disabled&&!$('ai-send').disabled,'unconfigured account is not stuck loading');if(!$('settings-dialog').open)$('settings-button').click();$('open-preferences').click();assert($('preferences-dialog').open,'unconfigured account can open preferences');document.querySelector('[data-close-preferences="library"]').click();post('harnessConfigure',{model:'deepseek-flash',baseURL:'https://api.deepseek.com'});await wait(()=>window.__saved.settings.model==='deepseek-flash'&&!$('ai-thinking').disabled,'configured account ready');
$('ai-thinking').click();await wait(()=>window.__saved.settings.thinking==='enabled','explicit on saved before restart');await window.flushBeforeQuit();assert(window.__errors.length===0,'no errors');return JSON.stringify({window:[innerWidth,innerHeight],sidebar:330,replyHeight:size.height,narrowReplyHeight:narrow.height,checks:['auto migration','actual payload off/on/off','fixed/unknown models','stale account reply','long scroll','materials/preferences/quick prompts','day/night/narrow screenshots']});
"""#
    static let reloadTests = #"""
await wait(()=>window.__saved&&!$('ai-send').disabled&&!$('ai-thinking').disabled,'reloaded');assert(pressed('ai-thinking')&&window.__saved.settings.thinking==='enabled','enabled retained across reopening');assert(!pressed('ai-web-search'),'search off retained');const call=await ask('Restored enabled preference');assert(call.thinking==='enabled','reopened request respects visible enabled state');assert(window.__errors.length===0,'no reload errors');return 'thinking preference and effective request survive reopening';
"""#
}
@main struct RunCompactAIUIHarness {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let delegate=CompactAIUIHarness();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}}
