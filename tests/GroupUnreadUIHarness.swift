import AppKit
import WebKit

// Synthetic account only; no Weibo session, real files, keys or external AI.
@MainActor final class GroupUnreadUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var temp: URL!
    var output: URL!
    var state: [String: Any] = [:]
    var phase = 0
    var results = ""
    let account = "unread-qa-account"
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build", isDirectory: true)
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-unread-qa-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.copyItem(at: source, to: temp); state = fixture()
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController.add(self, name: "app")
            config.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x:0,y:0,width:1120,height:700), configuration:config); web.navigationDelegate=self
            window = NSWindow(contentRect:NSRect(x:-4000,y:-4000,width:1120,height:700), styleMask:[.titled], backing:.buffered, defer:false)
            window.contentView=web;window.appearance=NSAppearance(named:.aqua);window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo:temp)
            DispatchQueue.main.asyncAfter(deadline:.now()+60) {self.finish(false,"unread UI harness timed out")}
        } catch {finish(false,error.localizedDescription)}
    }
    func fixture() -> [String: Any] {
        var messages: [[String:Any]]=[]; var progress: [String:Any]=[:]
        let groups = ["a","b","c"].map {id -> [String:Any] in ["accountId":account,"id":id,"name":"Synthetic group " + id,"selected":true]}
        for group in ["a","b","c"] {
            for index in 0..<80 {messages.append(["accountId":account,"id":String(1000+index),"groupId":group,"senderId":"u","senderName":"Synthetic member","text":"Saved reading message \(group) \(index)","sentAt":"2026-10-17T01:00:00.000Z","attachments":[]])}
            progress[group] = ["auto":["accountId":account,"groupId":group,"messageId":group == "a" ? "1030" : "1020","offset":7,"updatedAt":"2026-10-17T01:00:00.000Z"]]
        }
        return ["version":1,"revision":1,"accountId":account,"groups":groups,"messages":messages,"collections":[],"bookmarks":[],"discussions":[],"progress":progress,"settings":["baseURL":"","model":"","activeGroupId":"a","mode":"reader"]]
    }
    func json(_ value: Any) -> String {String(data:try! JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys]),encoding:.utf8)!}
    func reply(_ id:Any,_ result:[String:Any]=[:]) {web.evaluateJavaScript("window.nativeReceive(" + json(["id":id,"ok":true,"result":result]) + ")",completionHandler:nil)}
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body=message.body as? [String:Any],let action=body["action"] as? String,let id=body["id"] else{return}
        let payload=body["payload"] as? [String:Any] ?? [:]
        switch action {
        case "ready":web.evaluateJavaScript("window.__saved="+json(state),completionHandler:nil);reply(id,["state":state,"hasAPIKey":false,"accountName":"Synthetic account","appearance":"light"])
        case "save":
            if let saved=payload["state"] as? [String:Any] {if saved["accountId"] as? String == account {state=saved};web.evaluateJavaScript("window.__saved="+json(saved),completionHandler:nil);reply(id,["revision":saved["revision"] ?? 0])}else{finish(false,"missing state")}
        case "qaShot":
            let name=payload["name"] as? String ?? "v101-unread"
            web.takeSnapshot(with:nil) {image,error in
                guard let image,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else{self.finish(false,error?.localizedDescription ?? "snapshot failed");return}
                do {try png.write(to:self.output.appendingPathComponent(name+".png"));self.reply(id)}catch{self.finish(false,error.localizedDescription)}
            }
        case "qaDone":
            results += (payload["result"] as? String ?? "") + "\n"
            if phase == 0 {phase=1;web.reload()}else{finish(true,results)}
        case "qaFail":finish(false,payload["error"] as? String ?? "unknown JS failure")
        case "ai","testAI","send":finish(false,"unexpected external action: "+action)
        default:reply(id)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = "(async()=>{try{"+Self.helpers+(phase == 0 ? Self.first : Self.reopen)+"}catch(error){qa('qaFail',{error:String(error.stack||error)});}})();void 0;"
        web.evaluateJavaScript(script) {_,error in if let error {self.finish(false,error.localizedDescription)}}
    }
    func finish(_ success:Bool,_ detail:String) {
        print((success ? "PASS: " : "FAIL: ")+detail)
        if let temp {try? FileManager.default.removeItem(at:temp)}
        fflush(stdout);exit(success ? 0 : 1)
    }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const assert=(value,label)=>{if(!value)throw new Error(label)};
const wait=async(predicate,label)=>{for(let n=0;n<250;n++){if(predicate())return;await sleep(20)}throw new Error('Timed out: '+label)};
let seq=0;const requests=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=requests.get(response.id);if(resolve){requests.delete(response.id);resolve(response.result)}else receive(response)};
const qa=(action,payload={})=>new Promise(resolve=>{const id='qa-'+(++seq);requests.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload})});
const pick=group=>document.querySelector('.group-pick[data-group-id="'+group+'"]');
const badge=group=>Number(pick(group)?.querySelector('.group-unread-badge')?.textContent||0);
const visible=element=>{const r=element.getBoundingClientRect();return r.width>0&&r.height>0&&r.top>=0&&r.bottom<=innerHeight&&element.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))};
const emit=(group,ids,{source='live',requestStartedAt=new Date().toISOString(),accountId='unread-qa-account'}={})=>window.onNativeEvent({type:'messages',accountId,groupId:group,messageSource:source,requestStartedAt,messages:ids.map(id=>({id:String(id),groupId:group,senderId:'u',senderName:'Synthetic member',text:'Fresh synthetic '+id,sentAt:new Date().toISOString(),attachments:[]}))});
const anchors=()=>JSON.stringify(Object.fromEntries(Object.entries(window.__saved.progress).map(([id,value])=>[id,value.auto])));
await wait(()=>window.__saved?.settings?.groupUnread&&$('group-name').textContent==='Synthetic group a','initialized account and read position');await sleep(30);
"""#
    static let first = #"""
const oldAnchors=anchors();assert(badge('a')===0&&badge('b')===0&&badge('c')===0,'first cache does not create badges');
emit('b',[600,601],{source:'history'});emit('b',[1104],{source:'refresh'});emit('b',[1105],{source:'replay'});await sleep(180);assert(badge('b')===0,'backfill, refresh and replay remain quiet');
emit('b',[1101,1102]);emit('c',[1101]);emit('a',[1101]);await wait(()=>badge('b')===2&&badge('c')===1,'inactive groups independently update');assert(badge('a')===0,'foreground group has no badge');
emit('b',[1101,1102]);await sleep(180);assert(badge('b')===2,'duplicate messages do not increment');
emit('b',[1103],{source:'passive'});emit('b',[1108,1109]);emit('b',[1106,1107]);await wait(()=>badge('b')===7,'all newest-first live pages counted');
assert(pick('b').getAttribute('aria-label').includes('7 条新消息'),'badge has accessible exact count');assert(visible(pick('b').querySelector('.group-unread-badge')),'badge actually visible at 1120x700');
await window.flushBeforeQuit();assert(anchors()===oldAnchors,'background sync preserves all reading anchors');assert(window.__saved.settings.groupUnread.b.count===7&&window.__saved.settings.groupUnread.c.count===1,'counts saved');
ReaderAppearance.restore('light');await qa('qaShot',{name:'v101-unread-day'});ReaderAppearance.restore('dark');await qa('qaShot',{name:'v101-unread-night'});ReaderAppearance.restore('light');
assert(window.__errors.length===0,'no page errors '+JSON.stringify(window.__errors));await window.flushBeforeQuit({quitting:true});await qa('qaDone',{result:JSON.stringify({backgroundGroups:true,initialCacheQuiet:true,backfillAndReplayQuiet:true,dedup:true,multiPageCount:7,foregroundQuiet:true,anchorsUnchanged:true,dayNightBadgeVisible:true})});
"""#
    static let reopen = #"""
assert(badge('b')===7&&badge('c')===1,'counts survive close and reopen');const oldAnchors=anchors();
emit('b',[1101,1109]);await sleep(160);assert(badge('b')===7,'reopened cache replay deduplicated');
const olderRequest=new Date().toISOString();await sleep(20);pick('b').click();await wait(()=>$('group-name').textContent==='Synthetic group b'&&badge('b')===0,'click B clears only its badge');assert(badge('c')===1,'C reminder preserved');
await window.flushBeforeQuit();assert(anchors()===oldAnchors,'click returns to original saved anchor');const card=document.querySelector('.message-card[data-message-id="1020"]');assert(card,'B saved reading anchor remains mounted');
pick('a').click();await sleep(20);emit('b',[1110],{requestStartedAt:olderRequest});await sleep(180);assert(badge('b')===0,'late request before click cannot resurrect badge');
await sleep(20);emit('b',[1111]);await wait(()=>badge('b')===1,'later genuine message counts');await window.flushBeforeQuit();const kept=structuredClone(window.__saved);
const other=structuredClone(kept);other.accountId='unread-other-account';other.revision++;delete other.settings.groupUnread;
for(const field of ['groups','messages'])other[field].forEach(item=>item.accountId=other.accountId);for(const value of Object.values(other.progress))for(const anchor of Object.values(value))anchor.accountId=other.accountId;
window.onNativeEvent({type:'account',state:other,accountName:'Synthetic other account',hasAPIKey:false});await wait(()=>window.__saved.accountId==='unread-other-account','other account saves');assert(badge('b')===0&&badge('c')===0,'account-specific counts isolated');emit('b',[1200]);await sleep(180);assert(badge('b')===0,'late prior-account event ignored');
window.onNativeEvent({type:'account',state:kept,accountName:'Synthetic account',hasAPIKey:false});await sleep(180);assert(badge('b')===1&&badge('c')===1,'return to account restores reminders');
const many=structuredClone(kept);many.settings.groupUnread.b.count=1002;window.onNativeEvent({type:'account',state:many,accountName:'Synthetic account',hasAPIKey:false});await sleep(40);assert(pick('b').querySelector('.group-unread-badge').textContent==='999+'&&pick('b').getAttribute('aria-label').includes('1002 条新消息'),'large counts stay compact with exact accessible count');assert(visible(pick('b').querySelector('.group-unread-badge')),'large badge fits sidebar');window.onNativeEvent({type:'account',state:kept,accountName:'Synthetic account',hasAPIKey:false});
assert(window.__errors.length===0,'no reload errors '+JSON.stringify(window.__errors));await window.flushBeforeQuit();await qa('qaDone',{result:JSON.stringify({reopen:true,clickClearsExactGroup:true,restoresReadingAnchor:true,lateRequestGuard:true,nextNewArrival:true,accountIsolation:true})});
"""#
}
@main struct RunGroupUnreadUIHarness {
    static func main() {let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let delegate=GroupUnreadUIHarness();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}
}
