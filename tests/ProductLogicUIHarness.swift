import AppKit
import WebKit

// All stores, accounts, credentials and AI responses in this host are synthetic.
@main final class ProductLogicUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!, store: StateStore!
    var state: [String: Any] = [:], phase = 0
    var calls: [[String: Any]] = [], nextAI = "success", cancelCalls = 0, officialCalls = 0
    var held: (id: Any, request: String, account: String)?
    var failNextSave = false
    let account = "synthetic-product-main", other = "synthetic-product-other", anchorAccount = "synthetic-product-notice-anchor", timestamp = "2026-10-19T01:00:00Z"
    static func main() { let app = NSApplication.shared; let delegate = ProductLogicUIHarness(); app.delegate = delegate; app.setActivationPolicy(.prohibited); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-product-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            store = try StateStore(directory: temp.appendingPathComponent("synthetic-accounts"))
            try store.save(state: fixture(account), accountId: account); try store.save(state: fixture(other), accountId: other); try store.save(state: anchorFixture(), accountId: anchorAccount)
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self, name: "app")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('Network is disabled in synthetic UI tests'));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1488, height: 1000), configuration: configuration); web.navigationDelegate = self
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.appearance = NSAppearance(named: .aqua); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { self.finish(false, "product logic UI timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture(_ accountId: String) -> [String: Any] {
        let senders = ["notice-bot", "粉丝群", "normal-admin", "follow-1", "same-name-other-id", "writer-2", "follow-1"]
        let names = ["粉丝群", "系统助手", "粉丝群管理员", "林舟", "林舟", "周宁", "林舟"]
        let texts = ["精确名称系统通知，专注阅读隐藏但原始数据保留。", "精确 ID 系统通知，专注阅读隐藏但原始数据保留。", "近似名称的普通成员消息必须保留。", "Revenue grew 12% while operating cash flow declined. <not markup>", "DO_NOT_SEND_OTHER_MESSAGE: same display name, different member ID.", "A separate English statement for the retry path.", "A final statement used to test cancellation and late replies."]
        let formatter = ISO8601DateFormatter()
        var messages: [[String: Any]] = (0..<names.count).map { n -> [String: Any] in
            let date = formatter.string(from: Date(timeIntervalSince1970: 1_792_281_600 + Double(n * 60)))
            return ["accountId": accountId, "groupId": "g", "id": String(n), "senderId": senders[n], "senderName": names[n], "sentAt": date, "text": texts[n], "attachments": []]
        }
        messages.append(["accountId": accountId, "groupId": "h", "id": "3", "senderId": "follow-1", "senderName": "林舟", "sentAt": timestamp, "text": "Different group, same member and message ID; its translation must stay separate.", "attachments": []])
        let discussion: [String: Any] = ["accountId": accountId, "id": "kept-discussion", "title": "RIGHT_DISCUSSION_KEEP", "createdAt": timestamp, "instructions": "CURRENT_INSTRUCTION_KEEP", "contextSnapshots": [messages[4]], "messages": [["role": "user", "content": "RIGHT_QUESTION_KEEP", "createdAt": timestamp], ["role": "assistant", "content": "RIGHT_ANSWER_KEEP", "createdAt": timestamp]]]
        let groups: [[String: Any]] = [["accountId": accountId, "id": "g", "name": "产品逻辑 · 合成验收", "selected": true], ["accountId": accountId, "id": "h", "name": "另一个合成群", "selected": true], ["accountId": accountId, "id": "off", "name": "暂不同步的合成群", "selected": false]]
        return ["version": 1, "revision": 1, "accountId": accountId, "groups": groups, "messages": messages, "bookmarks": [], "collections": [], "discussions": [discussion], "progress": [:], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic-first", "activeGroupId": "g", "mode": "reader", "activeDiscussionId": "kept-discussion", "groupUnread": ["h": ["accountId": accountId, "groupId": "h", "count": 3, "acknowledgedAt": timestamp, "baseline": ["id": "3", "sentAt": timestamp]]]]]
    }
    func anchorFixture() -> [String: Any] {
        var result = fixture(anchorAccount), messages: [[String: Any]] = []
        let formatter = ISO8601DateFormatter()
        for group in ["g", "h"] {
            for n in 0..<160 {
                let notice = n == (group == "g" ? 80 : 159)
                let date = formatter.string(from: Date(timeIntervalSince1970: 1_792_281_600 + Double(n * 60)))
                messages.append(["accountId": anchorAccount, "groupId": group, "id": "anchor\(n)", "senderId": notice ? "notice-bot" : "member\(n % 3)", "senderName": notice ? "粉丝群" : "合成成员 \(n % 3)", "sentAt": date, "text": "隐藏通知自动续读回归 #\(n)\n只在临时合成磁盘中使用。", "attachments": []])
            }
        }
        result["messages"] = messages
        result["progress"] = Dictionary(uniqueKeysWithValues: ["g", "h"].map { group in
            (group, ["auto": ["accountId": anchorAccount, "groupId": group, "messageId": group == "g" ? "anchor80" : "anchor159", "offset": 73, "updatedAt": timestamp]])
        })
        return result
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func error(_ id: Any, _ text: String) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": false, "error": text]) + ")", completionHandler: nil) }
    func event(_ value: [String: Any]) { web.evaluateJavaScript("window.onNativeEvent(" + json(value) + ")", completionHandler: nil) }
    func publish() { web.evaluateJavaScript("window.__saved=" + json(state) + ";window.__calls=" + json(calls) + ";window.__cancelCalls=\(cancelCalls);window.__officialCalls=\(officialCalls)", completionHandler: nil) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do { switch action {
        case "ready": state = try store.load(accountId: phase == 2 ? anchorAccount : account).state; publish(); reply(id, ["state": state, "hasAPIKey": true, "accountName": "合成产品验收", "appearance": "light"])
        case "qaArmSaveFailure": failNextSave = true; reply(id)
        case "save":
            if failNextSave { failNextSave = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.error(id, "合成磁盘保存失败") }; break }
            guard let candidate = payload["state"] as? [String: Any], let accountId = candidate["accountId"] as? String, [account, other, anchorAccount].contains(accountId) else { throw ReaderError.message("invalid synthetic account save") }
            try store.save(state: candidate, accountId: accountId); state = candidate; publish(); reply(id, ["revision": candidate["revision"] ?? 1])
        case "qaInspect": reply(id, try StateStore(directory: store.directory).load(accountId: payload["accountId"] as? String ?? account).state)
        case "qaSwitchAccount":
            let accountId = payload["accountId"] as? String ?? account; guard [account, other].contains(accountId) else { throw ReaderError.message("invalid synthetic switch") }
            state = try store.load(accountId: accountId).state; publish(); event(["type": "account", "state": state, "accountName": "合成产品验收", "hasAPIKey": true]); reply(id)
        case "qaArmAI": nextAI = payload["mode"] as? String ?? "success"; reply(id)
        case "qaReleaseLateAI":
            if let held { event(["type": "aiProgress", "accountId": held.account, "requestId": held.request, "phase": "answering", "contentDelta": "LATE_REPLY_MUST_NOT_APPEAR"]); reply(held.id, ["text": "LATE_REPLY_MUST_NOT_APPEAR", "cancelled": false]); self.held = nil }; reply(id)
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "keyStatus": reply(id, ["hasAPIKey": true])
        case "aiCapabilities": reply(id, ["thinking": false, "canDisableThinking": false])
        case "ai":
            calls.append(payload); publish(); let mode = nextAI; nextAI = "success"
            let request = payload["requestId"] as? String ?? "", accountId = payload["accountId"] as? String ?? state["accountId"] as! String
            if mode == "fail" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.error(id, "合成翻译失败，可安全重试") }; break }
            event(["type": "aiProgress", "accountId": accountId, "requestId": request, "phase": "answering", "contentDelta": mode == "hold" ? "尚未完成的合成译文" : "收入增长了 12%，"])
            if mode == "hold" { held = (id, request, accountId); break }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.reply(id, ["text": "收入增长了 12%，但经营现金流下降。<script>只是文字</script>", "cancelled": false]) }
        case "cancelAI": cancelCalls += 1; if let held { reply(held.id, ["text": "尚未完成的合成译文", "cancelled": true]) }; publish(); reply(id)
        case "openOfficial": officialCalls += 1; publish(); reply(id)
        case "qaSnapshot":
            let name = payload["name"] as? String ?? ""
            guard ["v104-product-day", "v104-product-night", "v104-sync-dialog", "v104-follow-dialog", "v104-product-reloaded"].contains(name) else { throw ReaderError.message("invalid screenshot name") }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failed"); return }
                do { try data.write(to: self.output.appendingPathComponent(name + ".png")); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "webSearch", "testAI", "saveKey", "authorizeAI", "openExternal": finish(false, "product UI harness must not use external services or real credentials: " + action)
        default: reply(id)
        } } catch { finish(false, error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.callAsyncJavaScript(Self.helpers + (phase == 0 ? Self.tests : phase == 1 ? Self.reloadTests : Self.hiddenAnchorTests), arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): print("PASS phase \(self.phase): \(value)"); fflush(stdout); if self.phase < 2 { self.phase += 1; self.web.reload() } else { self.finish(true, "product logic, persistent sources, inline translation and hidden-notice anchor recovery verified") }
            case .failure(let error): self.web.evaluateJavaScript("JSON.stringify({errors:window.__errors,settings:window.__saved?.settings,calls:window.__calls,body:document.body.innerText.slice(-2400)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<220;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
let seq=0;const requests=new Map(),receive=window.nativeReceive;window.nativeReceive=response=>{const resolve=requests.get(response.id);if(resolve){requests.delete(response.id);resolve(response.result);}else receive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='product-qa-'+(++seq);requests.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]'),pick=g=>document.querySelector('.group-pick[data-group-id="'+g+'"]');
const read=async(accountId='synthetic-product-main')=>{await window.flushBeforeQuit();return qa('qaInspect',{accountId});};
const field=(id,value)=>{$(id).value=value;$(id).dispatchEvent(new Event('input',{bubbles:true}));$(id).dispatchEvent(new Event('change',{bubbles:true}));};
const visible=el=>{if(!el||el.hidden)return false;const r=el.getBoundingClientRect(),s=getComputedStyle(el);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
const right=()=>JSON.stringify({discussionId:window.__saved.settings.activeDiscussionId,discussions:window.__saved.discussions,title:$('discussion-title').textContent,conversation:$('conversation-messages').textContent,context:$('context-list').textContent,question:$('ai-question').value});
const unchanged=before=>{assert(right()===before,'message operation preserves right discussion, references, history and draft');if(window.__rightContextNodes)assert(window.__rightContextNodes.every((node,n)=>node===$('context-list').childNodes[n]),'inline translation does not rebuild right reference DOM');};
const shot=async name=>{await wait(()=>$('toast').hidden,'toast settled');await qa('qaSnapshot',{name});};
const group=async g=>{pick(g).click();await wait(()=>document.querySelector('.message-card')?.dataset.groupId===g,'group '+g);await sleep(100);};
const inline=id=>card(id)?.querySelector('.inline-translation'),translated=id=>inline(id)?.dataset.status==='complete';
const translate=async(id,mode='success')=>{await qa('qaArmAI',{mode});const before=window.__calls.length;card(id).querySelector('.message-translate-action').click();await wait(()=>window.__calls.length===before+1,'translation request '+id);return window.__calls.at(-1);};
const followButton=id=>$('reader-follow-results').querySelector('[data-sender-id="'+id+'"] [data-action="follow"]');
const setModel=async model=>{$('settings-button').click();field('api-model',model);$('settings-form').requestSubmit();await wait(()=>!$('settings-dialog').open&&window.__saved.settings.model===model&&!$('ai-send').disabled,'chosen model saved');};
await wait(()=>document.querySelector('.message-card')&&$('discussion-title').textContent==='RIGHT_DISCUSSION_KEEP'&&!$('ai-send').disabled,'product fixture ready');await sleep(100);
"""#
    static let tests = #"""
for(const [id,label] of [['nav-chats','群聊'],['nav-bookmarks','书签'],['nav-collections','资料库']])assert($(id).textContent.replace(/\d+/g,'').trim()===label,'clear navigation label '+label);
assert(!$('resume-position'),'automatic reading button removed');assert($('manual-position').hidden&&$('return-position').hidden,'empty manual and return controls hidden');assert(!document.querySelector('#group-list input[type=checkbox]'),'group reading list has no sync checkboxes');
assert(!card('0')&&!card('1')&&card('2')&&card('4'),'only exact system sender name or ID is hidden');let s=await read();assert(s.messages.filter(m=>m.groupId==='g').length===7&&s.messages.some(m=>m.id==='0'&&m.senderName==='粉丝群'),'raw notice messages remain on disk');
$('manage-sync-groups').click();assert($('sync-groups-dialog').open,'sync management opens');const sync=id=>$('sync-groups-dialog').querySelector('.sync-group-checkbox[data-group-id="'+id+'"]');assert(sync('g').checked&&sync('h').checked&&!sync('off').checked,'sync manager restores saved selections');const syncRect=$('sync-groups-dialog').getBoundingClientRect(),syncFooter=$('sync-groups-dialog').querySelector('.dialog-footer').getBoundingClientRect();assert(syncRect.bottom-syncFooter.bottom<=8,'sync manager ends directly after footer without excess blank height');await shot('v104-sync-dialog');sync('off').click();$('sync-groups-dialog').querySelector('[data-close-dialog="sync-groups-dialog"]').click();assert(!(await read()).groups.find(g=>g.id==='off').selected,'cancel sync editing leaves saved selection');$('manage-sync-groups').click();sync('h').click();await qa('qaArmSaveFailure');$('sync-groups-form').requestSubmit();await wait(()=>!$('sync-groups-error').hidden&&!$('save-sync-groups').disabled,'failed sync save reported');s=await read();assert(s.groups.find(g=>g.id==='h').selected&&s.settings.groupUnread.h.count===3,'failed sync save preserves selected group and unread counter on disk');assert(pick('h').querySelector('.group-unread-badge')?.textContent==='3','failed sync save keeps visible unread badge');$('sync-groups-dialog').querySelector('[data-close-dialog="sync-groups-dialog"]').click();$('manage-sync-groups').click();sync('off').click();sync('h').click();$('sync-groups-form').requestSubmit();await wait(()=>!$('sync-groups-dialog').open,'sync choices durable');s=await read();assert(s.groups.find(g=>g.id==='off').selected&&!s.groups.find(g=>g.id==='h').selected,'sync choices persist together');assert(window.__officialCalls===0&&card('3').dataset.groupId==='g','sync selection causes no navigation');
assert($('open-preferences').closest('#settings-dialog'),'long-term preferences live in settings');assert(!$('open-temporary-preferences')&&!$('temporary-preferences-dialog')&&!$('temporary-preferences-chip'),'removed discussion requirements have no UI');assert(!$('open-preferences').closest('#inspector'),'right reading area no longer contains global preferences');$('settings-button').click();$('open-preferences').click();assert($('preferences-dialog').open&&!$('settings-dialog').open,'preferences open without stacked settings modal');document.querySelector('[data-close-preferences="library"]').click();
if(!$('settings-dialog').open)$('settings-button').click();$('open-followed-members').click();assert($('reader-personalization-dialog').open,'followed member manager opens');field('reader-follow-search','林舟');await wait(()=>followButton('follow-1')&&followButton('same-name-other-id'),'same-name identities selectable');followButton('follow-1').click();field('reader-follow-id','future-member');field('reader-follow-name','尚未发言的关注成员');$('reader-follow-add').click();await shot('v104-follow-dialog');$('reader-follow-save').click();await wait(()=>!$('reader-personalization-dialog').open,'follow selection persisted');s=await read();assert(s.settings.followedMembers.some(m=>m.senderId==='follow-1')&&s.settings.followedMembers.some(m=>m.senderId==='future-member'),'seen and arbitrary member IDs saved');assert(card('3').classList.contains('reader-followed')&&card('6').classList.contains('reader-followed')&&!card('4').classList.contains('reader-followed'),'follow emphasis uses stable member ID, not display name');assert(visible(card('3').querySelector('.reader-followed-badge')),'followed member badge is visible');
if(!$('settings-dialog').open)$('settings-button').click();$('open-followed-members').click();field('reader-follow-id','discarded-member');field('reader-follow-name','取消的成员');$('reader-follow-add').click();$('reader-follow-cancel').click();assert(!(await read()).settings.followedMembers.some(m=>m.senderId==='discarded-member'),'cancel followed-member draft does not persist');
await group('h');assert(card('3').classList.contains('reader-followed'),'same account follows same member across groups');assert(!inline('3'),'translation scoped to this group');await group('g');
{const action=card('3').querySelector('.manual-progress-action');if(action.closest('details'))action.closest('details').open=true;action.click();}await wait(()=>!$('manual-position').hidden,'manual control appears only after setting a point');assert($('return-position').hidden,'return remains hidden until navigation');$('manual-position').click();await wait(()=>!$('return-position').hidden,'return appears after a real reading jump');assert(document.querySelector('.reading-position-controls').getBoundingClientRect().height<=42,'reading position controls stay compact');
$('ai-question').value='RIGHT_DRAFT_KEEP';const before=right();card('3').querySelector('.message-collect-action').click();assert(!$('collection-dialog').open,'single-message toggle saves without naming dialog');await wait(()=>card('3').querySelector('.message-collect-action').getAttribute('aria-pressed')==='true'&&!card('3').querySelector('.message-collect-action').disabled,'single message collection saved');s=await read();const collected=s.collections.find(c=>!c.deletedAt&&c.messages.length===1&&c.messages[0].groupId==='g'&&c.messages[0].id==='3');assert(collected?.name,'direct collection receives automatic title');assert(collected?.messages.length===1&&collected.messages[0].id==='3'&&collected.messages[0].text.includes('Revenue grew'),'collection contains full source snapshot');assert(card('3')&&$('chat-view').hidden===false,'saving collection stays in reader');unchanged(before);
await setModel('synthetic-second');window.__rightContextNodes=[...$('context-list').childNodes];let payload=await translate('3');assert(payload.model==='synthetic-second'&&payload.baseURL==='https://synthetic.invalid/v1','inline translation uses current saved model');assert(payload.messages.length===2&&payload.messages[1].role==='user'&&payload.messages[1].content===s.messages.find(m=>m.groupId==='g'&&m.id==='3').text,'only chosen message text is submitted');assert(!JSON.stringify(payload.messages).includes('DO_NOT_SEND_OTHER_MESSAGE')&&!JSON.stringify(payload.messages).includes('CURRENT_INSTRUCTION_KEEP')&&payload.sources.length===0&&payload.webSearchEnabled===false,'translation excludes discussion, other references and search');await wait(()=>translated('3'),'inline translation completes');assert(card('3').querySelector('.inline-translation-text').textContent.includes('收入增长了 12%')&&!card('3').querySelector('script'),'translation is rendered as text beneath its message');assert(inline('3').getBoundingClientRect().top>=card('3').querySelector('.message-body').getBoundingClientRect().bottom,'translation sits below original message');unchanged(before);
await translate('5','fail');await wait(()=>inline('5')?.dataset.status==='error','translation failure shown locally');assert(inline('5').textContent.includes('合成翻译失败'),'inline failure includes actual error');unchanged(before);const retryCount=window.__calls.length;inline('5').querySelector('.inline-translation-retry').click();await wait(()=>window.__calls.length===retryCount+1&&translated('5'),'inline retry succeeds');assert(window.__calls.at(-1).model==='synthetic-second','retry uses selected model');unchanged(before);
await translate('6','hold');await wait(()=>inline('6')?.dataset.status==='loading','cancellable inline stream');inline('6').querySelector('.inline-translation-cancel').click();await wait(()=>inline('6')?.dataset.status==='cancelled','inline cancellation explicit');await wait(()=>window.__cancelCalls>=1,'cancel reaches host request');unchanged(before);
ReaderAppearance.restore('light');await shot('v104-product-day');ReaderAppearance.restore('dark');await shot('v104-product-night');ReaderAppearance.restore('light');
await qa('qaArmAI',{mode:'hold'});inline('6').querySelector('.inline-translation-retry').click();await wait(()=>inline('6')?.dataset.status==='loading','second held inline request');await read();await qa('qaSwitchAccount',{accountId:'synthetic-product-other'});await wait(()=>window.__saved.accountId==='synthetic-product-other'&&card('3')&&!card('3').classList.contains('reader-followed'),'other account has no inherited followed members');await qa('qaReleaseLateAI');await sleep(200);assert(!document.body.textContent.includes('LATE_REPLY_MUST_NOT_APPEAR')&&!inline('3'),'late reply cannot leak into other account');const alternate=await read('synthetic-product-other');assert(!(alternate.settings.followedMembers||[]).length&&!alternate.collections.length,'other account local settings and collections remain separate');
await qa('qaSwitchAccount',{accountId:'synthetic-product-main'});await wait(()=>window.__saved.accountId==='synthetic-product-main'&&card('3')?.classList.contains('reader-followed'),'original account restored');await wait(()=>translated('3'),'saved translation restored after account switch');s=await read();assert(s.collections.some(c=>!c.deletedAt&&c.messages.length===1&&c.messages[0].groupId==='g'&&c.messages[0].id==='3')&&s.messages.length===8,'collection and original source messages retained');assert(!document.body.textContent.includes('LATE_REPLY_MUST_NOT_APPEAR'),'original account also ignores cancelled late response');assert(window.__errors.length===0,'no product script errors '+JSON.stringify(window.__errors));await window.flushBeforeQuit();return JSON.stringify({navigationNames:true,compactAnchors:true,syncManager:true,syncFailurePreservesUnread:true,preferencesPlacement:true,exactNoticeFilter:true,rawMessagesRetained:true,followByID:true,arbitraryFollowID:true,cancelDraft:true,crossGroupFollow:true,persistentCollection:true,rightPanelUnchanged:true,rightContextDOMRetained:true,currentModelOnly:true,onlyChosenText:true,inlineTranslation:true,errorRetry:true,cancel:true,lateReplyAccountIsolation:true});
"""#
    static let reloadTests = #"""
const callsBefore=window.__calls.length,s=await read();assert(s.settings.model==='synthetic-second','selected model survives disk reload');assert(s.settings.followedMembers.some(m=>m.senderId==='future-member')&&card('3').classList.contains('reader-followed')&&!card('4').classList.contains('reader-followed'),'followed member preferences restore from native disk');assert(translated('3')&&translated('5'),'inline translations restore beneath correct messages');assert(window.__calls.length===callsBefore,'restoring cached translations does not send AI requests');assert(!card('0')&&!card('1')&&s.messages.some(m=>m.id==='0'),'system notice filtering remains reversible at data layer');assert(s.collections.some(c=>!c.deletedAt&&c.messages.length===1&&c.messages[0].groupId==='g'&&c.messages[0].id==='3'),'single collection persists across real disk reopen');assert(!s.groups.find(g=>g.id==='h').selected&&s.groups.find(g=>g.id==='off').selected,'sync management persists');assert(!$('resume-position')&&!$('manual-position').hidden,'only configured manual position is shown');await shot('v104-product-reloaded');
const action=card('5').querySelector('.message-discussion-action');assert(!action.closest('details')&&visible(action),'secondary add-to-discussion action is directly reachable');assert(action===card('5').querySelector('.message-actions button:last-child'),'discussion follows common message actions');action.click();await wait(()=>$('context-list').textContent.includes('A separate English statement'),'intentional add-to-discussion still adds the selected reference');assert(window.__calls.length===callsBefore,'adding to discussion does not auto-send');assert(window.__errors.length===0,'no reload script errors');return JSON.stringify({nativeDiskReload:true,followedMembers:true,inlineTranslationCache:true,collectionSnapshot:true,syncSelections:true,discussionSecondaryAction:true});
"""#
    static let hiddenAnchorTests = #"""
const viewport=$('reader-scroll');await wait(()=>card('anchor81'),'next visible message after saved hidden notice');await sleep(300);
let rect=card('anchor81').getBoundingClientRect(),view=viewport.getBoundingClientRect();assert(viewport.scrollTop>1000&&rect.top>=view.top-2&&rect.top<=view.top+24,'disk restore uses next visible message and resets hidden-notice offset');assert(!card('anchor80'),'hidden midpoint notice is not rendered');
await group('h');await wait(()=>card('anchor158'),'final visible message after trailing hidden notice');await sleep(300);rect=card('anchor158').getBoundingClientRect();view=viewport.getBoundingClientRect();assert(viewport.scrollTop>1000&&rect.bottom>view.top&&rect.top<view.bottom,'trailing hidden notice restores near final visible message');assert(!card('anchor159'),'hidden trailing notice is not rendered');
const saved=await read('synthetic-product-notice-anchor');assert(saved.messages.length===320&&saved.messages.some(m=>m.groupId==='g'&&m.id==='anchor80')&&saved.messages.some(m=>m.groupId==='h'&&m.id==='anchor159'),'anchor recovery retains every raw notice on disk');assert(window.__errors.length===0,'hidden notice recovery has no script errors');return JSON.stringify({hiddenNoticeAutoAnchor:true,nextVisibleMessage:true,offsetReset:true,finalVisibleFallback:true,rawNoticesRetained:true});
"""#
}
