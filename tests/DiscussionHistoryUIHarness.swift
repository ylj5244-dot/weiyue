import AppKit
import WebKit

// Ephemeral host: only synthetic messages, durable in-memory saves, and mock AI.
@MainActor final class DiscussionHistoryUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var temp: URL!
    var output: URL!
    var state: [String: Any] = [:]
    var phase = 0
    var failNextSave = false
    var delayNextSave = false
    var armedDeletionState: [String: String] = [:]
    var syncSequence = 0
    var aiCalls = 0
    var pendingAI: Any?
    var results = ""
    var actionCounts: [String: Int] = [:]
    var lastStage = "launch"
    let startedAt = Date()
    let account = "history-qa-account"
    let timestamp = "2026-10-17T01:00:00.000Z"
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build", isDirectory: true)
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-history-qa-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.copyItem(at: source, to: temp); state = fixture()
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController.add(self, name: "app")
            config.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 700), configuration: config); web.navigationDelegate = self
            window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1120, height: 700), styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.appearance = NSAppearance(named: .aqua); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            for seconds in [10, 30, 60] { DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { self.diagnostics("checkpoint \(seconds)s") } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                self.diagnostics("deadline")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.finish(false, "discussion history harness timed out; last stage: \(self.lastStage); actions: \(self.actionCounts)") }
            }
        } catch { finish(false, error.localizedDescription) }
    }
    func message(_ id: String) -> [String: Any] { ["accountId": account, "id": id, "groupId": "g", "senderId": "u", "senderName": "QA", "text": "SOURCE_KEEP_" + id, "sentAt": timestamp, "attachments": []] }
    func fixture() -> [String: Any] {
        let messages = (0..<3).map { message(String($0)) }
        let summary: [String: Any] = ["version": 1, "groupId": "g", "startAt": timestamp, "endAt": "2026-10-17T01:00:59.999Z", "label": "QA time range", "sourceCount": 1, "coverage": ["complete": true, "reason": "QA complete", "from": timestamp, "to": "2026-10-17T01:00:59.999Z", "checkedAt": timestamp, "loadedCount": 1, "pages": 1], "status": "complete", "batchCount": 1, "completedBatches": 1, "partials": ["PARTIAL_KEEP [消息1]"], "prompt": "SUMMARY_PROMPT_KEEP", "finalText": "SUMMARY_KEEP [消息1]"]
        var discussions: [[String: Any]] = []
        for i in 0..<4 {
            let answer = i == 0 ? "SUMMARY_KEEP [消息1]" : "ANSWER_KEEP_\(i)"
            let turns: [[String: Any]] = [["role": "user", "content": "QA question", "createdAt": timestamp], ["role": "assistant", "content": answer, "createdAt": timestamp]]
            var discussion: [String: Any] = ["id": ["active", "other", "third", "old-deleted"][i], "accountId": account, "createdAt": timestamp, "title": ["Active summary", "Other discussion", "Third discussion", "Previously deleted"][i], "contextSnapshots": [messages[i % 3]], "instructions": "TEMP_KEEP", "messages": turns]
            discussion["collectionId"] = i == 0 ? "c" as Any : NSNull()
            discussions.append(discussion)
        }
        discussions[0]["rangeSummary"] = summary
        var interrupted = summary; interrupted["status"] = "running"; interrupted["completedBatches"] = 0; interrupted["partials"] = []
        discussions[3]["rangeSummary"] = interrupted; discussions[3]["deletedAt"] = timestamp
        let library: [String: Any] = ["version": 1, "entries": [["id": "pref", "title": "QA style", "category": "writing", "content": "PREFERENCE_KEEP", "enabled": true]], "quickPrompts": []]
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "History QA", "selected": true]], "messages": messages, "collections": [["accountId": account, "id": "c", "name": "COLLECTION_KEEP", "createdAt": timestamp, "messages": [messages[0]], "messageIds": ["g:0"], "discussionId": "active"]], "bookmarks": [["accountId": account, "id": "b", "groupId": "g", "messageId": "0", "createdAt": timestamp, "messageSentAt": timestamp, "note": "BOOKMARK_KEEP", "snapshot": messages[0], "deletedAt": NSNull()]], "discussions": discussions, "progress": [:], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "active", "aiPreferences": library]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)! }
    func reply(_ id: Any, _ result: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": result]) + ")", completionHandler: nil) }
    func publish() { web.evaluateJavaScript("window.__saved=" + json(state) + ";window.__aiCalls=\(aiCalls)", completionHandler: nil) }
    func save(_ id: Any, _ payload: [String: Any]) { state = payload["state"] as! [String: Any]; publish(); reply(id, ["revision": state["revision"]!]) }
    func deletionState(_ value: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (value["discussions"] as? [[String: Any]] ?? []).compactMap { discussion in
            guard let id = discussion["id"] as? String else { return nil }
            return (id, discussion["deletedAt"] as? String ?? "")
        })
    }
    func diagnostics(_ reason: String) {
        print("History diagnostics \(reason), elapsed=\(Date().timeIntervalSince(startedAt)), phase=\(phase), stage=\(lastStage), actions=\(actionCounts)"); fflush(stdout)
        web.evaluateJavaScript("JSON.stringify({stage:window.__qaStage,stageAt:window.__qaStageAt,now:Date.now(),visibility:document.visibilityState,focus:document.hasFocus(),errors:window.__errors,title:document.getElementById('discussion-title')?.textContent,saveStatus:document.getElementById('save-status')?.textContent,historyError:document.getElementById('discussion-history-error')?.textContent,deleteError:document.getElementById('discussion-delete-error')?.textContent,titleProgress:document.getElementById('discussion-title-progress')?.textContent,active:window.__saved?.settings.activeDiscussionId})") { value, error in
            print("History page diagnostics \(reason): \(String(describing: value)); error=\(String(describing: error))"); fflush(stdout)
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        actionCounts[action, default: 0] += 1
        if action != "harnessStage" {
            let saved = payload["state"] as? [String: Any]
            let deleted = (saved?["discussions"] as? [[String: Any]] ?? []).filter { $0["deletedAt"] is String }.compactMap { $0["id"] as? String }
            print("History action \(Date().timeIntervalSince(startedAt)): \(action), failNext=\(failNextSave), revision=\(String(describing: saved?["revision"])), deleted=\(deleted)"); fflush(stdout)
        }
        switch action {
        case "harnessStage": lastStage = payload["label"] as? String ?? "unknown"; print("History stage \(Date().timeIntervalSince(startedAt)): \(lastStage)"); fflush(stdout); reply(id)
        case "ready": publish(); reply(id, ["state": state, "hasAPIKey": true, "accountName": "Synthetic QA", "appearance": "light"])
        case "aiCapabilities":
            // Restoring a discussion title happens before asynchronous capability
            // readiness. Exercise that gap rather than assuming a synchronous host.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15){self.reply(id,["thinking":false,"canDisableThinking":false])}
        case "harnessArm":
            failNextSave = payload["fail"] as? Bool ?? false; delayNextSave = payload["delay"] as? Bool ?? false
            // Background title preparation may save first. Inject only into the
            // deletion/restoration transaction this scenario is exercising.
            armedDeletionState = deletionState(state)
            web.evaluateJavaScript("window.__armed=true", completionHandler: nil); reply(id)
        case "save":
            let changesDeletion = deletionState(payload["state"] as! [String: Any]) != armedDeletionState
            if failNextSave && changesDeletion {
                failNextSave = false; syncSequence += 1
                let incoming = self.message("new-sync-\(syncSequence)")
                web.evaluateJavaScript("window.onNativeEvent(" + json(["type": "messages", "accountId": account, "groupId": "g", "messages": [incoming]]) + ")", completionHandler: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.web.evaluateJavaScript("window.nativeReceive(" + self.json(["id": id, "ok": false, "error": "Synthetic save failure with incoming sync"]) + ")", completionHandler: nil) }
            } else if delayNextSave && changesDeletion { delayNextSave = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.save(id, payload) } }
            else { save(id, payload) }
        case "ai": aiCalls += 1; pendingAI = id; publish()
        case "cancelAI": if let pendingAI { self.pendingAI = nil; reply(pendingAI, ["cancelled": true, "text": ""]) }; reply(id)
        case "harnessScreenshot":
            let name = payload["name"] as! String
            guard name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { finish(false, "invalid screenshot name"); return }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot error"); return }
                do { try png.write(to: self.output.appendingPathComponent(name + ".png")); self.web.evaluateJavaScript("window.__shot=" + self.json(name), completionHandler: nil); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        default: reply(id)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let current = phase; phase += 1; print("History UI phase \(current)"); fflush(stdout)
        web.callAsyncJavaScript(Self.helpers + (current == 0 ? Self.tests : Self.reloadTests), arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): self.results += String(describing: value) + "\n"; if current == 0 { self.web.reload() } else { self.finish(true, self.results) }
            case .failure(let error): self.web.evaluateJavaScript("JSON.stringify({errors:window.__errors,body:document.body.innerText.slice(-3000),state:window.__saved?.discussions.map(d=>({id:d.id,deletedAt:d.deletedAt})),active:window.__saved?.settings.activeDiscussionId})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func finish(_ success: Bool, _ text: String) { print((success ? "PASS: " : "FAIL: ") + text); fflush(stdout); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw new Error(l);};
const wait=async(fn,label)=>{window.__qaStage=label;window.__qaStageAt=Date.now();window.webkit.messageHandlers.app.postMessage({id:'stage-'+Math.random(),action:'harnessStage',payload:{label}});const deadline=Date.now()+4000;while(Date.now()<deadline){if(fn())return;await sleep(25);}throw new Error('Timeout: '+label+'; elapsed='+ (Date.now()-window.__qaStageAt));};
const post=(action,payload={})=>window.webkit.messageHandlers.app.postMessage({id:'qa-'+Math.random(),action,payload});
const readyAIControls=async()=>wait(()=>!$('ai-send').disabled&&!$('open-preferences').disabled,'AI controls ready after capability lookup');
const history=(deleted=false)=>{if($('discussion-list').hidden)$('discussion-history').click();$(deleted?'discussions-deleted':'discussions-active').click();};
const row=id=>$('discussion-items').querySelector('[data-discussion-id="'+id+'"]');
const saved=id=>window.__saved.discussions.find(d=>d.id===id);
const count=()=>window.__saved.discussions.filter(d=>!d.deletedAt).length;
const arm=async(fail=false,delay=false)=>{window.__armed=false;post('harnessArm',{fail,delay});await wait(()=>window.__armed,'arm save');};
const confirm=async()=>{$('discussion-delete-form').requestSubmit();await wait(()=>!$('discussion-delete-dialog').open,'delete saved');};
const remove=async id=>{history();row(id).querySelector('.discussion-delete').click();assert($('discussion-delete-dialog').open,'confirmation opens');await confirm();};
const open=id=>{history();row(id).querySelector('.discussion-row').click();};
const shot=async name=>{post('harnessScreenshot',{name});await wait(()=>window.__shot===name,'screenshot');};
const clickable=(element,label)=>{const r=element.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;assert(r.width>0&&r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth,label+' is in viewport');assert(element.contains(document.elementFromPoint(x,y)),label+' is not obscured by conversation or source panes');};
const checkHistoryVisibility=()=>{for(const id of ['discussions-active','discussions-deleted','close-discussion-history'])clickable($(id),id);clickable($('discussions-clear').hidden?$('discussions-restore-all'):$('discussions-clear'),'history bulk action');for(const item of $('discussion-items').querySelectorAll('.discussion-history-item')){clickable(item.querySelector('.discussion-row'),'discussion row');clickable(item.querySelector('.discussion-delete,.discussion-restore'),'row delete/restore');}};
const assertPreserved=()=>{assert(window.__saved.bookmarks.length===1&&window.__saved.bookmarks[0].note==='BOOKMARK_KEEP','bookmark intact');assert(window.__saved.collections.length===1&&window.__saved.collections[0].name==='COLLECTION_KEEP','collection intact');assert(window.__saved.collections[0].discussionId==='active','collection reference intact');assert(window.__saved.settings.aiPreferences.entries[0].content==='PREFERENCE_KEEP','preferences intact');assert(saved('active').contextSnapshots[0].text==='SOURCE_KEEP_0'&&saved('active').rangeSummary.finalText==='SUMMARY_KEEP [消息1]'&&saved('active').rangeSummary.partials[0]==='PARTIAL_KEEP [消息1]','summary and source snapshots intact');};
"""#
    static let tests = #"""
await wait(()=>$('discussion-title').textContent==='Active summary','active summary ready');const controlsPendingAtTitleReady=$('open-preferences').disabled;await readyAIControls();assert(saved('old-deleted').rangeSummary.status==='running','deleted running summary is not recovered on initialization');history();assert($('discussion-items').querySelectorAll('.discussion-row').length===3,'active history excludes deleted');assert(!$('discussions-clear').disabled,'clear history available');checkHistoryVisibility();
row('other').querySelector('.discussion-delete').click();assert($('discussion-delete-summary').textContent.includes('1 条'),'single confirmation exact count');$('discussion-delete-cancel').click();assert(!saved('other').deletedAt&&count()===3,'cancel single leaves state intact');
row('other').querySelector('.discussion-delete').click();await arm(true);$('discussion-delete-form').requestSubmit();await wait(()=>!$('discussion-delete-error').hidden&&!$('discussion-delete-confirm').disabled,'save failure surfaced');assert(!saved('other').deletedAt,'failed deletion rolled back');assert(window.__saved.messages.some(m=>m.id==='new-sync-1'),'incoming message preserved during rollback');assert(window.__saved.settings.activeDiscussionId==='active','failure retains active discussion');await confirm();assert(saved('other').deletedAt&&window.__saved.settings.activeDiscussionId==='active','noncurrent deletion preserves current');
await remove('active');assert($('discussion-title').textContent==='新讨论'&&$('context-count').textContent==='已选 0 条'&&$('ai-question').value==='','delete current returns empty new discussion');assert(window.__saved.settings.activeDiscussionId===null,'deleted active ID cleared durably');assertPreserved();
$('nav-collections').click();document.querySelector('.collection-title').click();assert($('discussion-title').textContent==='新讨论'&&!window.__saved.settings.activeDiscussionId,'collection cannot reopen deleted discussion');assert($('context-count').textContent==='已选 1 条','collection sources remain accessible');
history(true);checkHistoryVisibility();row('active').querySelector('.discussion-restore').click();await wait(()=>!saved('active').deletedAt&&!row('active'),'restore current summary');assert(!$('discussion-list').hidden,'restoring an item keeps history open');assert($('discussion-title').textContent==='新讨论','restore does not auto-open discussion');open('active');assert($('conversation-messages').textContent.includes('SUMMARY_KEEP')&&$('conversation-messages').querySelector('.citation-link'),'restored range summary and citation intact');
history();ReaderAppearance.restore('light');await shot('v100-history-day');ReaderAppearance.restore('dark');await shot('v100-history-night');ReaderAppearance.restore('light');$('discussions-clear').click();assert($('discussion-delete-summary').textContent.includes('2 条'),'clear confirmation exact active count');await shot('v100-history-clear');$('discussion-delete-cancel').click();assert(count()===2,'clear cancel does not delete');$('discussions-clear').click();await arm(false,true);$('discussion-delete-form').requestSubmit();assert($('discussion-delete-close').disabled&&$('discussion-delete-cancel').disabled,'cannot dismiss while durable save pending');const escape=new Event('cancel',{cancelable:true});$('discussion-delete-dialog').dispatchEvent(escape);assert(escape.defaultPrevented,'Escape cannot abandon save');$('ai-question').value='MUST_NOT_SEND_WHILE_SAVING';$('ai-form').requestSubmit();assert($('new-discussion').disabled,'new discussion locked while deleting');await wait(()=>!$('discussion-delete-dialog').open,'clear durable completion');assert(count()===0&&window.__aiCalls===0,'clear deletes all active and refuses competing AI');assert($('discussion-title').textContent==='新讨论','clear current returns new');assertPreserved();
history(true);assert($('discussion-items').querySelectorAll('.discussion-row').length===4,'all deleted items retained');$('discussions-restore-all').click();await wait(()=>count()===4,'restore all');open('other');$('ai-question').value='Hold AI for busy guards';$('ai-form').requestSubmit();await wait(()=>window.__aiCalls===1,'AI pending');history();assert($('discussions-clear').disabled&&row('active').querySelector('.discussion-delete').disabled,'history deletion disabled during AI');const beforeBusy=count();$('discussions-clear').click();$('discussion-delete-form').requestSubmit();await sleep(80);assert(count()===beforeBusy&&!$('discussion-delete-dialog').open,'programmatic busy delete refused');$('ai-cancel').click();await wait(()=>!$('ai-send').disabled,'AI cancellation settled');await remove('other');await remove('active');assert(count()===2,'deleted history ready for reload');assertPreserved();await window.flushBeforeQuit();assert(window.__errors.length===0,'no history script errors '+JSON.stringify(window.__errors));return JSON.stringify({controlsPendingAtTitleReady,capabilityReadinessAwaited:true,singleDelete:true,cancel:true,clearCount:true,clearCancel:true,clearSave:true,restore:true,restoreAll:true,currentResets:true,summaryAndSourcesIntact:true,collectionDoesNotReopenDeleted:true,saveFailureRollbackKeepsSync:true,busyGuards:true});
"""#
    static let reloadTests = #"""
await wait(()=>window.__saved&&$('discussion-title').textContent==='新讨论','deleted current stays new after reopen');await readyAIControls();history();assert($('discussion-items').querySelectorAll('.discussion-row').length===2&&!row('active')&&!row('other'),'deleted discussions remain absent after reload');assertPreserved();assert(window.__saved.messages.some(m=>m.id==='new-sync-1'),'concurrent sync survived reload');
$('nav-collections').click();document.querySelector('.collection-title').click();assert($('discussion-title').textContent==='新讨论','reopened collection still cannot resurrect deleted discussion');history(true);const previousDeletedAt=saved('other').deletedAt;await arm(true);row('other').querySelector('.discussion-restore').click();await wait(()=>!$('discussion-history-error').hidden&&!row('other').querySelector('.discussion-restore').disabled,'restore failure surfaced');assert(saved('other').deletedAt===previousDeletedAt,'failed restoration retains original deleted timestamp');assert(window.__saved.messages.some(m=>m.id==='new-sync-2'),'restore rollback preserves second incoming message');row('other').querySelector('.discussion-restore').click();await wait(()=>!saved('other').deletedAt,'restore retry');row('active').querySelector('.discussion-restore').click();await wait(()=>!saved('active').deletedAt,'summary restore after reopen');open('active');assert($('conversation-messages').querySelector('.citation-link'),'restored citation remains clickable');$('conversation-messages').querySelector('.citation-link').click();await sleep(100);assert(document.querySelector('.target-message')?.dataset.messageId==='0','restored summary citation jumps to original');assertPreserved();await window.flushBeforeQuit();assert(window.__errors.length===0,'no reload errors '+JSON.stringify(window.__errors));return JSON.stringify({softDeletionReload:true,collectionLinkSafeAfterReload:true,restoreFailureRollbackKeepsSync:true,restoreRetry:true,summaryRestoreCitation:true,originalDataAndPreferencesIntact:true});
"""#
}
@main struct RunDiscussionHistoryUIHarness { static func main() { let app = NSApplication.shared; app.setActivationPolicy(.prohibited); let delegate = DiscussionHistoryUIHarness(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } } }
