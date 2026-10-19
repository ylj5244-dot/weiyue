import AppKit
import WebKit

// Uses real UI and state validation with synthetic, deliberately held AI responses.
@main final class DiscussionTitlesUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, source: URL!, output: URL!, store: StateStore!
    var state: [String:Any] = [:], titleCalls:[[String:Any]]=[], aiCalls=0, cancels=0, phase=0
    var pendingTitle:Any?, lastCancelledTitle:Any?, pendingAI:Any?
    let account="synthetic-title-qa", stamp="2026-10-19T01:00:00.000Z"
    static func main(){let app=NSApplication.shared;let delegate=DiscussionTitlesUIHarness();app.delegate=delegate;app.setActivationPolicy(.prohibited);app.run()}
    func applicationDidFinishLaunching(_ notification:Notification){
        do {
            source=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            output=source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            temp=FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-title-ui-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
            let ui=temp.appendingPathComponent("ui");try FileManager.default.copyItem(at:source,to:ui)
            store=try StateStore(directory:temp.appendingPathComponent("state"));state=fixture();try store.save(state:state,accountId:account)
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.userContentController.add(self,name:"app")
            config.userContentController.addUserScript(WKUserScript(source:"window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));",injectionTime:.atDocumentStart,forMainFrameOnly:true))
            web=WKWebView(frame:NSRect(x:0,y:0,width:1440,height:920),configuration:config);web.navigationDelegate=self
            window=NSWindow(contentRect:web.frame,styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.contentView=web;window.title="Synthetic discussion titles QA";window.orderBack(nil)
            web.loadFileURL(ui.appendingPathComponent("index.html"),allowingReadAccessTo:ui)
            DispatchQueue.main.asyncAfter(deadline:.now()+65){self.finish(false,"UI harness timeout")}
        }catch{finish(false,error.localizedDescription)}
    }
    func fixture()->[String:Any]{
        var value=StateStore.empty(accountId:account);value["revision"]=1
        let message:[String:Any]=["id":"message","accountId":account,"groupId":"g","senderId":"member","senderName":"测试成员","text":"供给受到产能、交付和客户预算的共同影响。","sentAt":stamp,"attachments":[]]
        value["groups"]=[["id":"g","accountId":account,"name":"合成测试群","selected":true]];value["messages"]=[message]
        value["discussions"]=[("one","请分析光模块的需求和供给"),("two","对比客户预算与交付周期"),("deleted","已删除的讨论")].map { id,question -> [String:Any] in
            var d:[String:Any]=["id":id,"accountId":account,"title":question,"createdAt":stamp,"contextSnapshots":[message],"messages":[["role":"user","content":question],["role":"assistant","content":"这里是合成的讨论内容。"]]]
            if id=="deleted" {d["deletedAt"]=stamp};return d
        }
        value["settings"]=["baseURL":"https://synthetic.invalid/v1","model":"synthetic","activeGroupId":"g","mode":"reader","activeDiscussionId":"one"]
        return value
    }
    func json(_ value:Any)->String{String(data:try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]),encoding:.utf8)!}
    func reply(_ id:Any,_ result:Any=[:]){web.evaluateJavaScript("window.nativeReceive("+json(["id":id,"ok":true,"result":result])+")",completionHandler:nil)}
    func error(_ id:Any,_ message:String){web.evaluateJavaScript("window.nativeReceive("+json(["id":id,"ok":false,"error":message])+")",completionHandler:nil)}
    func publish(){web.evaluateJavaScript("window.__saved="+json(state)+";window.__titleCalls="+json(titleCalls)+";window.__aiCalls=\(aiCalls);window.__titleCancels=\(cancels)",completionHandler:nil)}
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){
        guard let body=message.body as? [String:Any],let action=body["action"] as? String,let id=body["id"] else{return}
        let payload=body["payload"] as? [String:Any] ?? [:]
        do {switch action {
        case "ready":state=try store.load(accountId:account).state;publish();reply(id,["state":state,"hasAPIKey":true,"accountName":"合成测试","appearance":"light"])
        case "aiCapabilities":reply(id,["thinking":false,"canDisableThinking":false])
        case "save":guard let value=payload["state"] as? [String:Any] else{throw ReaderError.message("invalid save")};try store.save(state:value,accountId:account);state=try store.load(accountId:account).state;publish();reply(id,["revision":state["revision"]!])
        case "titleDiscussion":if pendingTitle != nil {throw ReaderError.message("overlapping title requests")};pendingTitle=id;titleCalls.append(payload);publish()
        case "cancelDiscussionTitle":if let current=pendingTitle {pendingTitle=nil;lastCancelledTitle=current;cancels+=1;error(current,"synthetic title cancelled")};publish();reply(id)
        case "ai":aiCalls+=1;pendingAI=id;publish()
        case "cancelAI":if let current=pendingAI {pendingAI=nil;reply(current,["cancelled":true])};reply(id)
        case "qaResolveTitle":if let current=pendingTitle{pendingTitle=nil;reply(current,["title":payload["title"] as? String ?? ""])};reply(id)
        case "qaResolveAI":if let current=pendingAI{pendingAI=nil;reply(current,["text":"硅光与传统封装在成本、规模和交付上各有约束。这是合成回复。"])};reply(id)
        case "qaLateTitle":if let current=lastCancelledTitle{reply(current,["title":"不得写入的迟到标题"])};reply(id)
        case "qaSnapshot":
            let name=payload["name"] as? String ?? "v109-history"
            guard name.range(of:"^[a-z0-9-]+$",options:.regularExpression) != nil else{throw ReaderError.message("invalid snapshot")}
            web.takeSnapshot(with:nil){image,error in
                do {guard let image,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else{throw error ?? ReaderError.message("snapshot failed")}
                    try png.write(to:self.output.appendingPathComponent(name+".png"));self.reply(id)
                }catch{self.error(id,error.localizedDescription)}
            }
        default:reply(id)
        }}catch{self.error(id,error.localizedDescription)}
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){decisionHandler(action.request.url?.isFileURL == true ? .allow:.cancel)}
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){
        let script=Self.prelude+(phase==0 ? Self.first:Self.second)
        web.callAsyncJavaScript(script,arguments:[:],in:nil,in:.page,completionHandler:{result in
            switch result {
            case .failure(let error):self.finish(false,error.localizedDescription)
            case .success(let value):
                print("PASS phase \(self.phase): \(String(describing:value))")
                if self.phase==0 {self.phase=1;self.web.reload()}
                else{self.finish(true,"AI history titles, priority, pause, retry, deletion, saved reload and layout")}
            }
        })
    }
    func finish(_ success:Bool,_ message:String){print((success ? "PASS: ":"FAIL: ")+message);if let temp{try? FileManager.default.removeItem(at:temp)};fflush(stdout);exit(success ? 0:1)}
    static let prelude = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms));
const assert=(value,label)=>{if(!value)throw new Error(label);};
const wait=async(fn,label)=>{for(let i=0;i<400;i++){if(fn())return;await sleep(20);}throw new Error('Timeout: '+label);};
const post=(action,payload={})=>new Promise((resolve,reject)=>{const id='qa-'+Math.random();const original=window.nativeReceive;window.nativeReceive=response=>{original(response);if(response.id===id){window.nativeReceive=original;response.ok?resolve(response.result):reject(new Error(response.error));}};window.webkit.messageHandlers.app.postMessage({id,action,payload});});
const history=()=>{if($('discussion-list').hidden)$('discussion-history').click();};
const row=id=>$('discussion-items').querySelector('[data-discussion-id="'+id+'"]');
const saved=id=>window.__saved.discussions.find(d=>d.id===id);
await wait(()=>window.__saved&&$('discussion-title').textContent.trim()&& !$('ai-send').disabled,'ready');
"""#
    static let first = #"""
assert(window.__titleCalls.length===0,'history backfill does not run before opening history');
history();await wait(()=>window.__titleCalls.length===1,'first automatic title');
assert(row('one').querySelector('strong').textContent==='请分析光模块的需求和供给','fallback preserved before result');
assert(!window.__titleCalls.some(c=>c.discussionId==='deleted'),'deleted discussions are excluded');
await post('qaResolveTitle',{title:'标题：光模块供需与交付周期'});await wait(()=>saved('one').titleInfo&&window.__titleCalls.length===2,'first saved, next requested');
assert(row('one').querySelector('strong').textContent==='光模块供需与交付周期','AI title displayed on history home');
assert(saved('one').messages[0].content==='请分析光模块的需求和供给','original question preserved');
$('discussion-title-action').click();await wait(()=>window.__titleCancels===1,'pause cancels title');
assert($('discussion-title-progress').textContent.includes('暂停'),'pause shown');assert(!$('ai-send').disabled,'title queue never locks primary composer');
$('discussion-title-action').click();await wait(()=>window.__titleCalls.length===3,'resume restarts pending title');
$('new-discussion').click();$('ai-question').value='比较硅光和传统封装';$('ai-form').requestSubmit();await wait(()=>window.__aiCalls===1&&window.__titleCancels===2,'primary AI preempts title');
assert(!$('ai-cancel').hidden,'main stop remains visible');
await post('qaResolveAI');await wait(()=>window.__titleCalls.length===4,'older title resumes after primary response');
await post('qaResolveTitle',{title:'客户预算与交付周期'});await wait(()=>saved('two').titleInfo&&window.__titleCalls.length===5,'new discussion auto title');
const newId=window.__titleCalls[4].discussionId;assert(!['one','two','deleted'].includes(newId),'new discussion receives title');
await post('qaResolveTitle',{title:'{"title":"不接受 JSON"}'});history();await wait(()=>$('discussion-title-progress').textContent.includes('未完成'),'bad model output retry visible');
assert(saved(newId).title==='比较硅光和传统封装','bad output preserves meaningful fallback');
$('discussion-title-action').click();await wait(()=>window.__titleCalls.length===6,'retry explicit');
await post('qaResolveTitle',{title:'硅光与传统封装的成本及交付约束'});await wait(()=>saved(newId).titleInfo&&row(newId)?.querySelector('strong').textContent.includes('成本'),'new title saved and visible');
assert($('discussion-title').textContent===saved(newId).title,'active discussion heading updates');
for(const el of $('discussion-items').querySelectorAll('.discussion-row'))assert(el.scrollWidth<=el.clientWidth+1,'no history horizontal overflow');
assert(saved('one').contextSnapshots.length===1&&saved('two').messages.length===2,'sources and prior turns preserved');
await post('qaSnapshot',{name:'v109-ai-history-day'});
ReaderAppearance.restore('dark');await post('qaSnapshot',{name:'v109-ai-history-night'});ReaderAppearance.restore('light');
$('close-discussion-history').click();$('ai-question').value='继续讨论交付约束';$('ai-form').requestSubmit();await wait(()=>window.__aiCalls===2,'followup main AI');await post('qaResolveAI');await wait(()=>window.__titleCalls.length===7,'followup schedules refreshed title');
history();row(newId).querySelector('.discussion-delete').click();$('discussion-delete-form').requestSubmit();await wait(()=>saved(newId).deletedAt&&!$('discussion-delete-dialog').open,'delete while title pending');
await post('qaLateTitle');await sleep(100);assert(saved(newId).title==='硅光与传统封装的成本及交付约束','late callback cannot alter deleted history');
assert(!row(newId),'deleted discussion not reinserted by title job');
await window.flushBeforeQuit();assert(window.__errors.length===0,'no UI errors '+JSON.stringify(window.__errors));return 'backfill, new+updated discussion, preemption, pause/retry, deletion and stale reply passed';
"""#
    static let second = #"""
history();await sleep(200);assert(saved('one').title==='光模块供需与交付周期'&&saved('two').title==='客户预算与交付周期','titles persisted through disk reload');
assert(row('one').querySelector('strong').textContent===saved('one').title,'saved title renders after reload');
assert(window.__titleCalls.length===7,'no repeated request for fresh or deleted title');
assert(window.__saved.discussions.filter(d=>d.deletedAt).length===2,'deleted history preserved');
assert(window.__errors.length===0,'reload has no errors');return 'disk reload preserves titles and avoids duplicate generation';
"""#
}
