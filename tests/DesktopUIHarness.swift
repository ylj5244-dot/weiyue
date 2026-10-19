import AppKit
import WebKit

// Isolated integration host: all data, saves, AI events and cleanup are synthetic.
// It copies only shipped UI resources, uses a nonpersistent WebKit store, blocks
// network navigation and never opens the installed app or its user data.
@MainActor final class DesktopUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
    var web: WKWebView!
    var window: NSWindow!
    var state: [String: Any] = [:]
    var beforeCleanup: [String: Any]?
    var temp: URL!
    var outputDirectory: URL!
    var aiCalls = 0
    var aiPayloads: [[String: Any]] = []
    var failNextSave = false
    var delayNextSave = false
    var navigationPhase = 0
    var savedAppearance = "system"
    var initialResults = ""
    var lastStep = "launch"
    let startedAt = Date()
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("UI harness starting");fflush(stdout)
        do {
            let source = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            outputDirectory=source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build",isDirectory:true)
            temp=FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-ui-test-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.copyItem(at:source,to:temp)
            state=fixture()
            let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent();configuration.userContentController.add(self,name:"app");configuration.setURLSchemeHandler(self,forURLScheme:"weiyue-media")
            let capture = "window.__uiErrors=[];window.addEventListener('error',e=>window.__uiErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__uiErrors.push(String(e.reason)));"
            configuration.userContentController.addUserScript(WKUserScript(source:capture,injectionTime:.atDocumentStart,forMainFrameOnly:true))
            web=WKWebView(frame:NSRect(x:0,y:0,width:1488,height:1056),configuration:configuration);web.navigationDelegate=self
            window=NSWindow(contentRect:NSRect(x:-4000,y:-4000,width:1488,height:1056),styleMask:[.titled],backing:.buffered,defer:false);window.contentView=web;window.appearance=NSAppearance(named:.aqua);window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"),allowingReadAccessTo:temp)
            // This suite now includes three reload phases and many delayed AI/save
            // operations. An offscreen WebKit host may throttle timers between phases.
            DispatchQueue.main.asyncAfter(deadline:.now()+120){self.finish(false,"timeout waiting for UI integration at \(self.lastStep)")}
        } catch {finish(false,error.localizedDescription)}
    }
    func fixture()->[String:Any] {
        let account="synthetic-account",formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let messages:[[String:Any]]=(0..<5000).map { i -> [String:Any] in
            let sentAt=formatter.string(from:Date(timeIntervalSince1970:1_792_281_600+Double(i*60)))
            let attachments:[[String:String]]=i%13 == 0 ? [["type":"image","name":"Synthetic picture","url":"https://synthetic.invalid/image/\(i).png"]] : []
            return ["accountId":account,"id":String(i),"groupId":i<4500 ? "g" : "h","senderId":"u\(i%30)","senderName":"Sample \(i%30)","text":"Synthetic message \(i). "+String(repeating:"Reading notes. ",count:i%7+1),"sentAt":sentAt,"attachments":attachments]
        }
        let timestamp=messages[0]["sentAt"]!
        let collections:[[String:Any]]=(0..<3).map {i in let message=messages[20+i];return ["id":"c\(i)","accountId":account,"name":"Sample collection \(i)","createdAt":timestamp,"messages":[message],"messageIds":["g:\(20+i)"],"discussionId":NSNull()] }
        let anchor:[String:Any]=["accountId":account,"groupId":"g","messageId":"500","offset":13,"updatedAt":timestamp]
        return ["version":1,"revision":1,"accountId":account,"groups":[["accountId":account,"id":"g","name":"Synthetic group","selected":true],["accountId":account,"id":"h","name":"Second group","selected":true]],"messages":messages,"collections":collections,"discussions":[],"bookmarks":[["accountId":account,"id":"b","groupId":"g","messageId":"4000","createdAt":timestamp,"messageSentAt":messages[4000]["sentAt"]!,"note":"Deep history target","snapshot":messages[4000],"deletedAt":NSNull()]],"progress":["g":["auto":anchor]],"settings":["baseURL":"https://synthetic.invalid/v1","model":"synthetic-text","activeGroupId":"g","mode":"reader"]]
    }
    func jsJSON(_ value:Any)->String {String(data:try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]),encoding:.utf8)!}
    func personalizationSnapshot()->[String:Any] { ["settings":state["settings"] ?? [:],"discussions":state["discussions"] ?? []] }
    func reply(_ id:Any,_ value:Any=[:]) {web.evaluateJavaScript("window.nativeReceive("+jsJSON(["id":id,"ok":true,"result":value])+")",completionHandler:nil)}
    func event(_ value:[String:Any]) {web.evaluateJavaScript("window.onNativeEvent("+jsJSON(value)+")",completionHandler:nil)}
    func completeSave(_ id:Any,_ payload:[String:Any]) {
        if failNextSave {failNextSave=false;web.evaluateJavaScript("window.nativeReceive("+jsJSON(["id":id,"ok":false,"error":"Synthetic save failure: test storage unavailable."])+")",completionHandler:nil);return}
        if let value=payload["state"] as? [String:Any]{state=value}
        let auto=((state["progress"] as? [String:Any])?["g"] as? [String:Any])?["auto"] ?? [:]
        web.evaluateJavaScript("window.__harnessSavedAuto="+jsJSON(auto)+";window.__harnessSavedPersonalization="+jsJSON(personalizationSnapshot()),completionHandler:nil);reply(id,["revision":state["revision"]!])
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let body=message.body as? [String:Any],let action=body["action"] as? String,let id=body["id"] else{return}
        if action == "ready" { print("UI harness ready received");fflush(stdout) }
        if ["harnessResize","harnessScreenshot","harnessFailNextSave","ai","cleanupPreview","cleanupApply","cleanupUndo"].contains(action) { lastStep=action;print("UI harness +\(Int(Date().timeIntervalSince(startedAt)))s: \(action)");fflush(stdout) }
        let payload=body["payload"] as? [String:Any] ?? [:]
        switch action {
        case "harnessTrace":lastStep=payload["step"] as? String ?? "unknown";print("UI harness +\(Int(Date().timeIntervalSince(startedAt)))s: \(lastStep)");fflush(stdout);reply(id)
        case "ready":
            let auto=((state["progress"] as? [String:Any])?["g"] as? [String:Any])?["auto"] ?? [:]
            web.evaluateJavaScript("window.__harnessExpectedRestoredAuto="+jsJSON(auto),completionHandler:nil)
            web.evaluateJavaScript("window.__harnessRestoredPersonalization="+jsJSON(personalizationSnapshot())+";window.__harnessAICalls=\(aiCalls);window.__harnessAIPayloads="+jsJSON(aiPayloads),completionHandler:nil)
            reply(id,["state":state,"hasAPIKey":true,"accountName":"Synthetic QA","appearance":savedAppearance])
        case "aiCapabilities":
            // Archive hydration is not the AI readiness barrier. Keep a small
            // deterministic delay so every reload tests the disabled-control gap.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15){self.reply(id,["thinking":false,"canDisableThinking":false])}
        case "saveAppearance":savedAppearance=payload["appearance"] as! String;web.evaluateJavaScript("window.__harnessAppearanceSaved="+jsJSON(savedAppearance),completionHandler:nil);reply(id,["appearance":savedAppearance])
        case "harnessSystemAppearance":
            let mode=payload["mode"] as! String
            window.appearance=NSAppearance(named:mode == "dark" ? .darkAqua : .aqua)
            web.appearance=window.appearance
            web.evaluateJavaScript("window.__harnessHostAppearance="+jsJSON(mode),completionHandler:nil);reply(id)

        case "harnessResize":
            let width=payload["width"] as! Double,height=payload["height"] as! Double
            window.setContentSize(NSSize(width:width,height:height));web.frame=NSRect(x:0,y:0,width:width,height:height)
            reply(id)
        case "harnessScreenshot":
            let name=payload["name"] as! String
            guard name.range(of:"^[a-z0-9-]+$",options:.regularExpression) != nil else {finish(false,"invalid screenshot name");return}
            web.takeSnapshot(with:nil){ image,error in
                guard let image,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {self.finish(false,error?.localizedDescription ?? "cannot capture synthetic UI");return}
                do {let path=self.outputDirectory.appendingPathComponent(name+".png");try png.write(to:path);self.web.evaluateJavaScript("window.__harnessScreenshot="+self.jsJSON(name),completionHandler:nil);self.reply(id,["path":path.path])}catch{self.finish(false,error.localizedDescription)}
            }
        case "harnessFailNextSave":failNextSave=true;delayNextSave=payload["delay"] as? Bool ?? false;web.evaluateJavaScript("window.__harnessSaveFailureArmed=true",completionHandler:nil);reply(id)
        case "save":
            if delayNextSave {delayNextSave=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.4){self.completeSave(id,payload)}}else{completeSave(id,payload)}
        case "attachmentPreview":reply(id,["url":"weiyue-media://synthetic/image.png"])
        case "storageLocations":reply(id,["dataPath":temp.path,"attachmentsPath":temp.path])
        case "cleanupStatus":reply(id,beforeCleanup == nil ? [:] : ["receipt":["id":"synthetic-receipt"]])
        case "cleanupPreview":reply(id,["fileCount":0,"bytes":0])
        case "cleanupApply":beforeCleanup=state;state=payload["state"] as! [String:Any];reply(id,["state":state])
        case "cleanupUndo":reply(id,["beforeState":beforeCleanup!,"id":"synthetic-receipt","warnings":[]])
        case "ai":
            aiCalls+=1;let request=payload["requestId"] as! String
            aiPayloads.append(payload)
            web.evaluateJavaScript("window.__harnessAICalls=\(aiCalls);window.__harnessAIPayloads="+jsJSON(aiPayloads),completionHandler:nil)
            event(["type":"aiProgress","accountId":"synthetic-account","requestId":request,"phase":"waiting"])
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.event(["type":"aiProgress","accountId":"synthetic-account","requestId":request,"phase":"thinking","reasoningDelta":"Check the synthetic notes."])}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4){self.event(["type":"aiProgress","accountId":"synthetic-account","requestId":request,"phase":"answering","contentDelta":"Translated synthetic"])}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.9){self.event(["type":"aiProgress","accountId":"synthetic-account","requestId":request,"phase":"answering","contentDelta":" answer."]);self.reply(id,["text":"Translated synthetic answer."])}
        default:reply(id)
        }
    }
    func webView(_ webView:WKWebView,start urlSchemeTask:WKURLSchemeTask){
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:24,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let data=bitmap.representation(using:.png,properties:[:])!
        urlSchemeTask.didReceive(URLResponse(url:urlSchemeTask.request.url!,mimeType:"image/png",expectedContentLength:data.count,textEncodingName:nil));urlSchemeTask.didReceive(data);urlSchemeTask.didFinish()
    }
    func webView(_ webView:WKWebView,stop urlSchemeTask:WKURLSchemeTask){}
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)}
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){
        let phase=navigationPhase;navigationPhase+=1;lastStep="navigation phase \(phase)";print(phase > 0 ? "UI harness +\(Int(Date().timeIntervalSince(startedAt)))s reload \(phase) complete" : "UI harness navigation complete");fflush(stdout)
        let script=phase == 0 ? Self.tests : phase == 1 ? Self.reloadTests : Self.draftReloadTests
        web.callAsyncJavaScript(script,arguments:[:],in:nil,in:.page){result in
            switch result {
            case .success(let value):
                if phase == 2 {self.finish(true,self.initialResults+"\nDraft reload: "+String(describing:value))}
                else {self.initialResults+=(phase == 0 ? "" : "\nReload: ")+String(describing:value);self.web.evaluateJavaScript("localStorage.removeItem('weiyue.appearance.v1')"){_,_ in self.web.reload()}}
            case .failure(let error):self.web.evaluateJavaScript("JSON.stringify({errors:window.__uiErrors,body:document.body.innerText.slice(-1600)})"){value,_ in self.finish(false,error.localizedDescription+"\n"+String(describing:(error as NSError).userInfo)+"\n"+String(describing:value))}
            }
        }
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error){finish(false,error.localizedDescription)}
    func finish(_ success:Bool,_ text:String){print((success ? "PASS: " : "FAIL: ")+text);fflush(stdout);if let temp{try? FileManager.default.removeItem(at:temp)};exit(success ? 0 : 1)}
    static let tests = #"""
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const $=id=>document.getElementById(id),assert=(value,label)=>{if(!value)throw new Error(label);};
const wait=async(fn,label)=>{for(let i=0;i<100;i++){if(fn())return;await sleep(30);}throw new Error('Timeout: '+label);};
const visible=()=>{const top=$('reader-scroll').getBoundingClientRect().top;return [...document.querySelectorAll('.message-card')].find(card=>card.getBoundingClientRect().bottom>top+15);};
const ids=()=>[...document.querySelectorAll('.collection-card')];
const trace=step=>window.webkit.messageHandlers.app.postMessage({id:'trace-'+Math.random(),action:'harnessTrace',payload:{step}});
trace('waiting for archive and image');
await wait(()=>$('result-count').textContent.includes('4500'),'ready');
await wait(()=>[...document.querySelectorAll('.image-frame img')].some(img=>img.dataset.loaded==='true'&&img.naturalWidth===32),'synthetic image decode');await sleep(150);
assert(document.querySelectorAll('.message-card').length<=100,'DOM must stay below 100 cards');
assert(visible().dataset.messageId==='500','restore saved deep reading position');
const initialCount=document.querySelectorAll('.message-card').length;
const frameIntervals=[],scrollWork=[],scrollView=$('reader-scroll');let previousFrame=null,maxMountedCards=initialCount;
trace('scrolling 100 animation frames');
for(let i=0;i<100;i++){
  const begin=performance.now();scrollView.dispatchEvent(new WheelEvent('wheel',{deltaY:37+(i%8)*17,bubbles:true}));scrollView.scrollTop+=37+(i%8)*17;scrollView.dispatchEvent(new Event('scroll'));
  const timestamp=await new Promise(resolve=>requestAnimationFrame(resolve));
  if(previousFrame!==null)frameIntervals.push(timestamp-previousFrame);previousFrame=timestamp;
  maxMountedCards=Math.max(maxMountedCards,document.querySelectorAll('.message-card').length);
  visible();scrollWork.push(performance.now()-begin);
  if(i%20===19)trace('scroll frame '+(i+1));
}
trace('scroll frames complete');
const percentile=(values,fraction)=>{const sorted=values.slice().sort((a,b)=>a-b);return +sorted[Math.min(sorted.length-1,Math.floor(sorted.length*fraction))].toFixed(2);};
assert(Number(visible().dataset.messageId)>550,'100 scroll steps must actually advance beyond initial message 500: '+visible().dataset.messageId);
assert(maxMountedCards<=100,'scrolling never mounts a full archive');
await sleep(1100);assert(window.__harnessSavedAuto?.messageId===visible().dataset.messageId,'user scroll persists the actual advanced reading anchor');
const beforeSync=visible().dataset.messageId;const beforeSyncOffset=$('reader-scroll').getBoundingClientRect().top-visible().getBoundingClientRect().top;
window.onNativeEvent({type:'messages',accountId:'synthetic-account',groupId:'g',messages:[{accountId:'synthetic-account',id:'100',groupId:'g',senderId:'u10',senderName:'Sample 10',text:'Changed history with a real image placeholder',sentAt:new Date(1792281600000+100*60000).toISOString(),attachments:[{type:'image',name:'Synthetic picture',url:'https://synthetic.invalid/late-picture.png'}]}]});await sleep(300);
assert(visible().dataset.messageId===beforeSync,'sync render must preserve real user scroll position');assert(Math.abs(($('reader-scroll').getBoundingClientRect().top-visible().getBoundingClientRect().top)-beforeSyncOffset)<2,'sync render must preserve line offset: before='+beforeSyncOffset+', after='+($('reader-scroll').getBoundingClientRect().top-visible().getBoundingClientRect().top));
const scrolling={samples:100,frameIntervalMedianMs:percentile(frameIntervals,.5),frameIntervalP95Ms:percentile(frameIntervals,.95),inputToNextFrameMedianMs:percentile(scrollWork,.5),inputToNextFrameP95Ms:percentile(scrollWork,.95),maxMountedCards};
$('nav-bookmarks').click();$('bookmarks-list').querySelector('.card-bottom button').click();await sleep(100);
assert(visible().dataset.messageId==='4000','bookmark must mount and jump to far history');
assert(document.querySelectorAll('.message-card').length<=100,'deep jump DOM bound');
$('coverage-action').click();await sleep(250);const latest=document.querySelector('[data-message-id=\"4499\"]');const latestGeometry={lastTop:latest?.getBoundingClientRect().top,lastBottom:latest?.getBoundingClientRect().bottom,viewBottom:$('reader-scroll').getBoundingClientRect().bottom,scrollTop:$('reader-scroll').scrollTop,scrollHeight:$('reader-scroll').scrollHeight,clientHeight:$('reader-scroll').clientHeight};if(!(latest&&latestGeometry.lastTop<latestGeometry.viewBottom)){window.__harnessScreenshot='';window.webkit.messageHandlers.app.postMessage({id:'latest-failure-shot',action:'harnessScreenshot',payload:{name:'v105-latest-failure'}});await wait(()=>window.__harnessScreenshot==='v105-latest-failure','latest failure evidence');}assert(latest && latestGeometry.lastTop<latestGeometry.viewBottom,'view latest must show final message '+JSON.stringify(latestGeometry));
$('nav-collections').click();assert(ids().length===3,'fixture collections');
ids()[0].querySelector('.collection-delete').click();assert($('collection-delete-summary').textContent.includes('1'),'single delete confirmation count');$('collection-delete-form').requestSubmit();await wait(()=>!$('collection-delete-dialog').open,'single delete');assert(ids().length===2,'single delete');
$('collections-undo').click();await wait(()=>ids().length===3,'single undo');
$('collections-select-all').click();$('collections-bulk-action').click();assert($('collection-delete-summary').textContent.includes('3'),'batch count');$('collection-delete-form').requestSubmit();await wait(()=>!$('collection-delete-dialog').open,'batch delete');assert(ids().length===0,'batch removes active refs');
$('collections-deleted').click();assert(ids().length===3,'recently deleted persistent view');$('collections-select-all').click();$('collections-bulk-action').click();await wait(()=>ids().length===0,'batch restore');$('collections-active').click();assert(ids().length===3,'all restored');
ids()[0].querySelector('.collection-title').click();const q=$('ai-question');q.value='Translate the synthetic notes';q.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true,cancelable:true}));await sleep(50);assert(!window.__harnessAICalls,'IME Enter must not submit');q.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true,cancelable:true}));await sleep(50);assert(!window.__harnessAICalls,'Shift Enter must not submit');q.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));await wait(()=>window.__harnessAICalls===1,'Enter submit');await wait(()=>$('ai-stream-answer')?.textContent.includes('Translated synthetic'),'SSE incremental display');assert(!$('ai-progress').hidden,'progress visible during stream');assert($('ai-stream-thought').textContent.includes('Check'),'thinking delta visible');await wait(()=>$('ai-progress').hidden,'stream completion');assert($('conversation-messages').textContent.includes('Translated synthetic answer.'),'complete reply persists');
const field=(id,value)=>{const el=$(id);el.value=value;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));};
trace('personal preferences and quick prompts');
const libraryRows=()=>[...$('preferences-items').querySelectorAll('button[data-preference-id]')];
const libraryRow=title=>{const el=libraryRows().find(row=>row.textContent.includes(title));assert(el,'preference row exists: '+title);return el;};
const openLibrary=(quick=false)=>{if(!$('settings-dialog').open)$('settings-button').click();$('open-preferences').click();assert($('preferences-dialog').open,'preference library opens while AI is idle');$(quick?'preferences-tab-quick':'preferences-tab-entries').click();};
const saveLibrary=async()=>{$('preferences-form').requestSubmit();await wait(()=>!$('preferences-dialog').open,'preference library durable save');};
const addPreference=(title,content,category='writing')=>{$('preference-add').click();field('preference-title',title);field('preference-content',content);if(!$('preference-category-row').hidden)field('preference-category',category);};
const sendSynthetic=async question=>{const count=window.__harnessAICalls||0;field('ai-question',question);$('ai-form').requestSubmit();await wait(()=>window.__harnessAICalls===count+1,'synthetic personalization request');await wait(()=>$('ai-progress').hidden&&!$('ai-send').disabled,'synthetic personalization completion');return window.__harnessAIPayloads[window.__harnessAIPayloads.length-1];};
const systemText=payload=>payload.messages.filter(message=>message.role==='system').map(message=>message.content).join('\n');
const resize=async(width,height)=>{window.webkit.messageHandlers.app.postMessage({id:'test-resize-'+width,action:'harnessResize',payload:{width,height}});await wait(()=>innerWidth===width&&innerHeight===height,'resize isolated native view');await sleep(80);};
const screenshot=async name=>{window.__harnessScreenshot='';window.webkit.messageHandlers.app.postMessage({id:'test-shot-'+name,action:'harnessScreenshot',payload:{name}});await wait(()=>window.__harnessScreenshot===name,'synthetic screenshot '+name);};
const errorVisible=id=>{const el=$(id),rect=el.getBoundingClientRect(),body=el.closest('.settings-dialog-body').getBoundingClientRect();return !el.hidden&&rect.height>0&&rect.top>=Math.max(body.top,0)-1&&rect.bottom<=Math.min(body.bottom,innerHeight)+1;};
const assertSavingCannotClose=dialogId=>{const dialog=$(dialogId),cancel=dialog.querySelector('.dialog-footer [data-close-preferences]');assert(cancel.disabled,'cancel is disabled while saving');cancel.click();const escape=new Event('cancel',{cancelable:true});dialog.dispatchEvent(escape);assert(escape.defaultPrevented&&dialog.open,'Escape cannot pretend to cancel a save already in progress');};
await wait(()=>!$('open-preferences').disabled,'AI completion settles before preference editing');
await resize(1120,700);
openLibrary();assert(libraryRows().length===0,'old account starts with no invented personal preferences');
addPreference('QA writing','QA_WRITING_ORIGINAL: use connected paragraphs.');addPreference('QA format','QA_FORMAT_DISABLED_LATER: use comparison tables.','format');addPreference('QA remove','QA_DELETE_AFTER_FIRST: keep this only for the first request.','other');$('preferences-tab-quick').click();$('preferences-tab-entries').click();assert(libraryRows().length===3,'switching library tabs preserves unsaved entries');libraryRow('QA writing').click();assert($('preference-content').value.includes('QA_WRITING_ORIGINAL'),'switching tabs preserves edited content');
window.webkit.messageHandlers.app.postMessage({id:'test-fail-next-save',action:'harnessFailNextSave',payload:{delay:true}});await wait(()=>window.__harnessSaveFailureArmed,'arm synthetic save failure');$('preferences-form').requestSubmit();assertSavingCannotClose('preferences-dialog');await wait(()=>!$('preferences-error').hidden,'preference save failure displayed');assert($('preferences-dialog').open,'failed save keeps editor open');assert($('preferences-error').textContent.includes('Synthetic save failure'),'failed save shows actual storage error');await wait(()=>errorVisible('preferences-error'),'library save error visible at 1120x700');assert(!$('preferences-save').disabled,'failed save allows retry');assert(!$('preferences-dialog').querySelector('.dialog-footer [data-close-preferences]').disabled,'failed save restores cancel control');await saveLibrary();
assert(window.__harnessSavedPersonalization.settings.aiPreferences.entries.length===3,'saved library reaches native storage');
openLibrary();libraryRow('QA writing').click();ReaderAppearance.restore('light');await sleep(80);assert(errorVisible('preferences-guide'),'reopened library starts at visible guidance after prior save error');await screenshot('v05-preferences-day');ReaderAppearance.restore('dark');await sleep(80);await screenshot('v05-preferences-night');$('preferences-tab-quick').click();await screenshot('v05-quick-night');ReaderAppearance.restore('light');await sleep(80);await screenshot('v05-quick-day');$('preferences-dialog').querySelector('.dialog-footer [data-close-preferences="library"]').click();ReaderAppearance.restore('system');
$('new-discussion').click();assert(!$('open-temporary-preferences')&&!$('temporary-preferences-dialog'),'removed discussion requirement controls are absent');
const firstSystem=systemText(await sendSynthetic('QA first personalized discussion'));
for(const marker of ['QA_WRITING_ORIGINAL','QA_FORMAT_DISABLED_LATER','QA_DELETE_AFTER_FIRST'])assert(firstSystem.includes(marker),'first request includes '+marker);
assert(!firstSystem.includes('QA_TEMP_FIRST'),'first request contains no removed discussion requirements');
openLibrary();libraryRow('QA writing').click();field('preference-content','QA_WRITING_UPDATED: use calm, complete paragraphs.');libraryRow('QA format').click();$('preference-enabled').click();libraryRow('QA remove').click();$('preference-delete').click();await saveLibrary();
const updatedSystem=systemText(await sendSynthetic('QA second request after library edits'));
assert(updatedSystem.includes('QA_WRITING_UPDATED')&&!updatedSystem.includes('QA_TEMP_FIRST'),'same discussion picks up current long-term defaults');
for(const marker of ['QA_WRITING_ORIGINAL','QA_FORMAT_DISABLED_LATER','QA_DELETE_AFTER_FIRST'])assert(!updatedSystem.includes(marker),'edited, disabled or deleted preference removed from next request: '+marker);
openLibrary();libraryRow('QA writing').click();field('preference-content','QA_FAILED_REPLACEMENT: this failed change must never become active.');window.__harnessSaveFailureArmed=false;window.webkit.messageHandlers.app.postMessage({id:'test-fail-replacement-save',action:'harnessFailNextSave',payload:{}});await wait(()=>window.__harnessSaveFailureArmed,'arm failed replacement');$('preferences-form').requestSubmit();await wait(()=>!$('preferences-error').hidden,'failed replacement displayed');$('preferences-dialog').querySelector('.dialog-footer [data-close-preferences="library"]').click();
const failedSystem=systemText(await sendSynthetic('QA request after failed save and cancel'));assert(failedSystem.includes('QA_WRITING_UPDATED')&&!failedSystem.includes('QA_FAILED_REPLACEMENT'),'failed save followed by cancel must not apply the failed preference');
openLibrary();libraryRow('QA writing').click();field('preference-content','QA_UNSAVED_DRAFT: never send this.');$('preferences-dialog').querySelector('.dialog-footer [data-close-preferences="library"]').click();
$('new-discussion').click();assert(!$('open-temporary-preferences'),'new discussion has no temporary requirement entry');
const newSystem=systemText(await sendSynthetic('QA new personalized discussion'));
assert(newSystem.includes('QA_WRITING_UPDATED'),'new discussion automatically inherits enabled long-term preference');assert(!newSystem.includes('QA_TEMP_FIRST')&&!newSystem.includes('QA_UNSAVED_DRAFT'),'new discussion excludes previous temporary requirements and discarded edit');
openLibrary(true);assert(libraryRows().length===2,'legacy quick prompts receive two editable defaults');addPreference('QA quick one','QA_QUICK_ORIGINAL: explain the selected notes.');addPreference('QA quick two','QA_QUICK_DELETE: temporary shortcut.');await saveLibrary();
let quickButtons=[...$('quick-prompts').querySelectorAll('button[data-quick-prompt-id]')];assert(quickButtons.length===4,'custom quick prompts join visible defaults');const callsBeforeQuick=window.__harnessAICalls;
field('ai-question','');quickButtons.find(button=>button.textContent==='QA quick one').click();await sleep(100);assert($('ai-question').value==='QA_QUICK_ORIGINAL: explain the selected notes.','quick prompt fills editable question');assert(window.__harnessAICalls===callsBeforeQuick,'quick prompt never auto-sends');
openLibrary(true);libraryRow('QA quick one').click();field('preference-content','QA_QUICK_UPDATED: review the reasoning in these notes.');$('preference-move-up').click();$('preference-move-up').click();libraryRow('QA quick two').click();$('preference-delete').click();const defaultQuick=libraryRows().find(row=>!row.textContent.includes('QA quick one'));defaultQuick.click();$('preference-enabled').click();await saveLibrary();
quickButtons=[...$('quick-prompts').querySelectorAll('button[data-quick-prompt-id]')];assert(quickButtons.length===2,'deleted and disabled quick prompts disappear');assert(quickButtons[0].textContent==='QA quick one','custom quick prompt order is reflected in composer');field('ai-question','');quickButtons[0].click();assert($('ai-question').value==='QA_QUICK_UPDATED: review the reasoning in these notes.','edited custom prompt fills new text');assert(window.__harnessAICalls===callsBeforeQuick,'editing and sorting shortcuts never trigger AI');field('ai-question','');
const reloadSystem=systemText(await sendSynthetic('QA request before closing and reopening'));
assert(reloadSystem.includes('QA_WRITING_UPDATED')&&!reloadSystem.includes('QA_TEMP_RELOAD'),'current request carries durable long-term defaults');
const personalization={requests:window.__harnessAICalls-1,longTermCRUD:true,disabledExcluded:true,removedTemporaryUI:true,newDiscussionIsolated:true,cancelDiscarded:true,draftTabsRetained:true,saveFailureRetry:true,saveCannotBeCancelledMidflight:true,errorVisibleAt1120x700:true,quickCRUD:true,quickOrder:true,quickFillOnly:true};
await resize(1488,1056);
$('settings-button').click();$('open-cleanup').click();$('cleanup-text').click();$('cleanup-preview').click();await wait(()=>!$('cleanup-apply').disabled,'cleanup preview');assert($('cleanup-summary').textContent.includes('文字：'),'cleanup counts visible');$('cleanup-apply').click();await wait(()=>$('cleanup-summary').textContent.includes('清理完成'),'cleanup apply');assert($('bookmark-count').textContent==='1','cleanup preserves bookmark');assert($('collection-count').textContent==='3','cleanup preserves collections');const cleanedCount=$('result-count').textContent;window.onNativeEvent({type:'messages',accountId:'synthetic-account',groupId:'g',messages:[{accountId:'synthetic-account',id:'1',groupId:'g',senderId:'u1',senderName:'Sample',text:'Old text replay must stay cleared',sentAt:'2026-10-18T00:01:00.000Z',attachments:[]}]});await sleep(200);assert($('result-count').textContent===cleanedCount,'live replay cannot resurrect cleaned text');$('cleanup-undo').click();await wait(()=>$('cleanup-summary').textContent.includes('已恢复'),'cleanup undo');$('cleanup-dialog').close();$('settings-dialog').close();$('nav-chats').click();await wait(()=>$('result-count').textContent.includes('4500'),'history restored after cleanup undo');
assert(document.querySelectorAll('.message-card').length<=100,'restored DOM remains bounded');
const colors=()=>({body:getComputedStyle(document.body).backgroundColor,panel:getComputedStyle(document.documentElement).getPropertyValue('--panel').trim(),text:getComputedStyle(document.documentElement).getPropertyValue('--text').trim(),readerText:getComputedStyle(document.querySelector('.message-body')).color});
const hostAppearance=async(mode)=>{window.webkit.messageHandlers.app.postMessage({id:'test-host-appearance',action:'harnessSystemAppearance',payload:{mode}});await wait(()=>window.__harnessHostAppearance===mode&&matchMedia('(prefers-color-scheme: dark)').matches===(mode==='dark'),'native '+mode+' appearance');};
await hostAppearance('dark');ReaderAppearance.restore('light');await sleep(60);const light=colors();assert(document.documentElement.dataset.colorScheme==='light','explicit light overrides native dark');
ReaderAppearance.restore('dark');await sleep(60);const dark=colors();assert(document.documentElement.dataset.colorScheme==='dark','explicit dark selection');for(const key of Object.keys(light))assert(light[key]!==dark[key],'computed '+key+' changes between light and dark');
ReaderAppearance.restore('system');assert(document.documentElement.dataset.colorScheme==='dark','system mode matches native dark');await hostAppearance('light');await wait(()=>document.documentElement.dataset.colorScheme==='light','system follows native light change');assert(JSON.stringify(colors())===JSON.stringify(light),'system light uses the explicit light palette');
ReaderAppearance.restore('dark');assert(JSON.stringify(colors())===JSON.stringify(dark),'explicit dark overrides native light');
$('appearance-select').value='dark';$('appearance-select').dispatchEvent(new Event('change',{bubbles:true}));await wait(()=>window.__harnessAppearanceSaved==='dark','selector saves appearance through native bridge');
const appearance={light,dark,nativeModes:['aqua','darkAqua'],explicitOverridesSystem:true,nativeSave:true};
assert(window.__uiErrors.length===0,'no script errors: '+JSON.stringify(window.__uiErrors));await window.flushBeforeQuit();
return JSON.stringify({personalization,appearance,scrolling,initialMountedCards:initialCount,finalMountedCards:document.querySelectorAll('.message-card').length,archiveMessages:5000,checks:['synthetic image decoded','deep restore','scroll actually advances','scroll auto anchor persists','sync preserves anchor with images','bookmark jump','view latest','single delete and undo','bulk delete and restore','IME and Shift Enter','Enter submit','incremental AI and thinking','cleanup preview apply undo','cleaned history replay filtering','no script errors']});
"""#
    static let reloadTests = #"""
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));const assert=(value,label)=>{if(!value)throw new Error(label);};
for(let i=0;i<100&&!document.getElementById('result-count').textContent.includes('4500');i++)await sleep(30);
assert(document.getElementById('result-count').textContent.includes('4500'),'reload restored synthetic archive');await sleep(180);
assert(ReaderAppearance.getPreference()==='dark','native ready restores preference after localStorage removal');assert(document.getElementById('appearance-select').value==='dark','selector restored');assert(document.documentElement.dataset.colorScheme==='dark','resolved theme restored');assert(!matchMedia('(prefers-color-scheme: dark)').matches,'native host remains light to prove explicit override on reload');assert(getComputedStyle(document.body).backgroundColor==='rgb(32, 36, 40)','dark CSS applies after reload');
const top=document.getElementById('reader-scroll').getBoundingClientRect().top;const visible=[...document.querySelectorAll('.message-card')].find(card=>card.getBoundingClientRect().bottom>top+15);assert(visible.dataset.messageId===window.__harnessExpectedRestoredAuto.messageId,'reload restores saved reading message');assert(Math.abs(Math.max(0,top-visible.getBoundingClientRect().top)-window.__harnessExpectedRestoredAuto.offset)<2,'reload restores saved line offset');assert(window.__uiErrors.length===0,'no reload errors');
const $=id=>document.getElementById(id),wait=async(fn,label)=>{for(let i=0;i<100;i++){if(fn())return;await sleep(30);}throw new Error('Timeout: '+label);};
await wait(()=>!$('open-preferences').disabled&&!$('ai-send').disabled,'reloaded AI controls ready');
const restored=window.__harnessRestoredPersonalization,library=restored.settings.aiPreferences,active=restored.discussions.find(discussion=>discussion.id===restored.settings.activeDiscussionId);
assert(library.entries.length===2,'deleted long-term entry stays deleted after reload');assert(library.entries.find(entry=>entry.title==='QA format').enabled===false,'disabled preference stays disabled after reload');assert(library.entries.find(entry=>entry.title==='QA writing').content.includes('QA_WRITING_UPDATED'),'edited preference persists after reload');
assert(active&&!active.instructions,'active discussion has no newly invented temporary instructions');assert($('discussion-title').textContent===active.title,'active discussion restored in visible UI');assert($('conversation-messages').textContent.includes('QA request before closing and reopening'),'active conversation messages restored');
assert(!$('open-temporary-preferences')&&!$('temporary-preferences-dialog'),'removed temporary editor stays absent after reload');
const historyOpen=title=>{$('discussion-history').click();const row=[...$('discussion-list').querySelectorAll('.discussion-row')].find(item=>item.querySelector('strong').textContent===title);assert(row,'saved discussion appears in history: '+title);row.click();};
historyOpen('QA first personalized discussion');assert($('discussion-title').textContent==='QA first personalized discussion','older conversation remains reachable');historyOpen(active.title);
const quickButtons=[...$('quick-prompts').querySelectorAll('button[data-quick-prompt-id]')];assert(quickButtons.length===2&&quickButtons[0].textContent==='QA quick one','quick deletion, disable and order persist after reload');const oldCount=window.__harnessAICalls;quickButtons[0].click();assert($('ai-question').value==='QA_QUICK_UPDATED: review the reasoning in these notes.','custom quick text survives reload');assert(window.__harnessAICalls===oldCount,'restored quick shortcut still does not auto-send');
const send=async question=>{const count=window.__harnessAICalls;$('ai-question').value=question;$('ai-form').requestSubmit();await wait(()=>window.__harnessAICalls===count+1,'request after reopen');await wait(()=>$('ai-progress').hidden&&!$('ai-send').disabled,'completion after reopen');return window.__harnessAIPayloads.at(-1).messages.filter(message=>message.role==='system').map(message=>message.content).join('\n');};
const afterReload=await send('QA request after reopening');assert(afterReload.includes('QA_WRITING_UPDATED')&&!afterReload.includes('QA_TEMP_RELOAD'),'reopened discussion sends saved long-term defaults');for(const marker of ['QA_WRITING_ORIGINAL','QA_FORMAT_DISABLED_LATER','QA_DELETE_AFTER_FIRST'])assert(!afterReload.includes(marker),'reopened request excludes inactive data: '+marker);
assert(window.__uiErrors.length===0,'no personalization reload script errors');$('new-discussion').click();await window.flushBeforeQuit();
return JSON.stringify({appearance:'dark',localStorageClearedBeforeReload:true,nativeReadyRestored:true,readingMessage:visible.dataset.messageId,personalizationRestored:true,checks:['computed palette','system change','explicit priority','native preference save','reload theme and reading anchor','preference edits disable deletion persisted','active discussion restored','removed per-discussion requirement UI remains absent','quick edits order disable deletion persisted','request after reload uses saved preferences']});
"""#
    static let draftReloadTests = #"""
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms)),$=id=>document.getElementById(id),assert=(value,label)=>{if(!value)throw new Error(label);};
const wait=async(fn,label)=>{for(let i=0;i<100;i++){if(fn())return;await sleep(30);}throw new Error('Timeout: '+label);};
await wait(()=>$('result-count').textContent.includes('4500'),'unsent draft reload ready');
const controlsPendingAtArchiveReady=$('ai-send').disabled;assert(!$('open-preferences').disabled,'local preferences are editable before delayed AI capability response');
await wait(()=>!$('ai-send').disabled,'unsent draft AI controls ready');
const restored=window.__harnessRestoredPersonalization;assert(restored.settings.activeDiscussionId===null,'new discussion remains independent after reload');assert(!restored.settings.aiDraftInstructions,'new unsent discussion creates no temporary instructions');
assert($('discussion-title').textContent==='新讨论','reopened unsent discussion stays new');assert(!$('open-temporary-preferences')&&!$('temporary-preferences-dialog'),'new discussion retains simplified controls');
const count=window.__harnessAICalls;$('ai-question').value='QA first message from restored draft';$('ai-form').requestSubmit();await wait(()=>window.__harnessAICalls===count+1,'restored draft first request');await wait(()=>$('ai-progress').hidden&&!$('ai-send').disabled,'restored draft reply');
const system=window.__harnessAIPayloads.at(-1).messages.filter(message=>message.role==='system').map(message=>message.content).join('\n');assert(system.includes('QA_WRITING_UPDATED')&&!system.includes('QA_DRAFT_RELOAD'),'first new-discussion request uses saved defaults without draft requirements');assert(!system.includes('QA_TEMP_RELOAD')&&!system.includes('QA_TEMP_FIRST'),'restored draft excludes earlier discussion requirements');
await window.flushBeforeQuit();const saved=window.__harnessSavedPersonalization,active=saved.discussions.find(discussion=>discussion.id===saved.settings.activeDiscussionId);assert(active&&!active.instructions,'first send creates a discussion without temporary instructions');assert(!saved.settings.aiDraftInstructions,'first send invents no pending temporary draft');assert(window.__uiErrors.length===0,'no draft reload errors');
return JSON.stringify({unsentDraftRestored:true,controlsPendingAtArchiveReady,waitedForAIReadiness:true,firstRequestContainsSavedPreferences:true,noTemporaryInstructions:true});
"""#
}
@main struct RunDesktopUIHarness {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let delegate=DesktopUIHarness();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}}
