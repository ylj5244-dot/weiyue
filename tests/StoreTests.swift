import Foundation

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}
private func rejects(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure(description: "Accepted invalid operation: \(label)")
}

@main struct StoreTests {
    static let account = "9007199254740993123"
    static let stamp = "2026-10-18T01:02:03.456Z"
    static func fixture(revision: Int = 1, count: Int = 1) -> [String: Any] {
        var state = StateStore.empty(accountId: account)
        let message: [String: Any] = ["id": "9007199254740993001", "accountId": account, "groupId": "group-a", "senderId": "user-1", "senderName": "同名", "text": "完整消息", "sentAt": stamp, "attachments": [["type": "image", "url": "https://example.com/image.jpg"]]]
        state["revision"] = revision
        state["groups"] = [["id": "group-a", "accountId": account, "name": "甲群", "selected": true]]
        state["messages"] = [message]
        state["bookmarks"] = (0..<count).map { ["id": "bookmark-\($0)", "accountId": account, "groupId": "group-a", "messageId": "9007199254740993001", "createdAt": stamp, "messageSentAt": stamp, "note": "标记 \($0)", "snapshot": message, "deletedAt": NSNull()] as [String: Any] }
        state["collections"] = [["id": "collection-1", "accountId": account, "name": "资料", "createdAt": stamp, "messageIds": ["group-a:9007199254740993001"], "messages": [message], "discussionId": NSNull()]]
        state["progress"] = ["group-a": ["auto": ["accountId": account, "groupId": "group-a", "messageId": "9007199254740993001", "offset": 18, "updatedAt": stamp]]]
        state["discussions"] = [["id": "discussion-1", "accountId": account, "createdAt": stamp, "title": "资料讨论", "collectionId": "collection-1", "contextSnapshots": [message], "messages": [["role": "user", "content": "问题", "createdAt": stamp, "status": "failed", "error": "已取消"]]]]
        state["extension"] = ["preserve": [1, 2, 3]]
        return state
    }
    static func bytes(_ state: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) }
    static func withStore(_ body: (StateStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("weibo-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(StateStore(directory: root))
    }
    static func modelHistoryFixture() throws -> [String: Any] {
        // Exercise the real browser model -> JSON bridge -> native store boundary.
        let script = #"""
        const M = require('./Resources/ui/model.js');
        const P = require('./Resources/ui/preferences.js');
        const R = require('./Resources/ui/range-summary.js');
        const W = require('./Resources/ui/web-search.js');
        const state = M.createState('9007199254740993123');
        const now = '2026-10-18T01:02:03.456Z';
        const batch = (groupId,start,count) => Array.from({length:count}, (_,n) => ({
          id:String(9007199254740993000n+BigInt(start+n)), groupId,
          senderId:'9007199254740993999', senderName:'同名', text:'消息 '+(start+n),
          sentAt:new Date(Date.UTC(2026,9,18)+(start+n)*1000).toISOString(), attachments:[]
        }));
        M.upsertGroups(state,[{id:'bulk-a',name:'历史群',selected:true,unreadCount:500,
          observedUnreadSnapshot:{count:500,observedAt:now}},
          {id:'bulk-b',name:'另一群',selected:true}]);
        for (const groupId of ['bulk-a','bulk-b']) {
          M.ingestMessages(state,groupId,batch(groupId,500,20));
          for (const [index,kind] of ['auto','sessionStart','returnPoint','manual'].entries())
            M.setProgress(state,{groupId,messageId:String(9007199254740993500n+BigInt(index)),kind,offset:(index+1)*10,now});
          for(let n=0;n<10;n++) M.addBookmark(state,{groupId,messageId:String(9007199254740993500n+BigInt(n)),note:groupId+' #'+n,now});
        }
        M.ingestMessages(state,'bulk-a',batch('bulk-a',0,500).reverse());
        M.ingestMessages(state,'bulk-a',batch('bulk-a',510,20));
        M.selectGroup(state,'bulk-a',false); M.selectGroup(state,'bulk-a',true);
        const revision=state.revision;
        M.ingestMessages(state,'bulk-a',batch('bulk-a',510,20));
        if(state.revision!==revision) throw new Error('Duplicate live batch changed revision');
        state.settings.ui={activeGroupId:'bulk-b',mode:'reader',fontSize:19};
        state.settings.aiPreferences=P.validate({version:1,entries:[{id:'native-js',title:'写作风格',category:'writing',content:'完整的段落 🌏',enabled:true}],quickPrompts:P.defaults().quickPrompts});
        state.settings.aiDraftInstructions='本次使用表格';
        state.settings.activeDiscussionId=null;
        state.sync={'bulk-a':{oldestId:'9007199254740993000',newestId:'9007199254740993529',hasMore:true,anchorReached:true}};
        const from='2026-10-18T00:00:00.000Z', to='2026-10-18T00:10:59.999Z';
        const sources=R.select(state.messages,{accountId:state.accountId,groupId:'bulk-a',startMs:Date.parse(from),endMs:Date.parse(to)});
        const summary={version:1,groupId:'bulk-a',startAt:from,endAt:to,label:'本机时段测试',sourceCount:sources.length,
          coverage:{complete:true,reason:'已核对',from,to,checkedAt:now,loadedCount:sources.length,pages:6},
          status:'interrupted',batchCount:R.plan(sources).length,completedBatches:1,partials:['分批结果 [消息1]'],prompt:'梳理观点',stage:'map',error:'已取消'};
        state.discussions.push({id:'range-model-native',accountId:state.accountId,createdAt:now,contextSnapshots:sources,messages:[],rangeSummary:summary});
        M.deleteDiscussions(state,['range-model-native'],now);
        state.settings.webSearchEnabled=true;
        state.discussions[0].messages.push({role:'assistant',content:'网页回答 [网页1]',webSearch:W.normalize({status:'success',query:'最新资料',searchedAt:now,sources:[{id:'网页1',title:'来源',url:'https://example.com/news',publishedAt:null,siteName:'Example',excerpt:'新闻摘要'}]})});
        state.revision++;
        process.stdout.write(JSON.stringify(M.normalizeState(state)));
        """#
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TestFailure(description: "Model/native fixture failed: " + detail)
        }
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TestFailure(description: "Missing model fixture") }
        return state
    }
    static func preferencesFixture(revision: Int = 1) -> [String: Any] {
        var state = fixture(revision: revision)
        state["settings"] = ["baseURL": "", "model": "", "aiPreferences": ["version": 1,
            "entries": [["id": "writing-1", "title": "写作风格", "category": "writing", "content": "完整段落 👩🏽‍💻 \"引号\"\n</script> & \\ ${literal}", "enabled": true]],
            "quickPrompts": [["id": "quick-1", "title": "自定义问题", "prompt": "请说明关键分歧，并标注出处。", "enabled": true]]],
            "aiDraftInstructions": "本次请用表格", "activeDiscussionId": "discussion-1"]
        var discussions = state["discussions"] as! [[String: Any]]
        discussions[0]["instructions"] = "本次只写完整的三段"
        state["discussions"] = discussions
        return state
    }
    static func rangeSummaryFixture(revision: Int = 1, count: Int = 1501) -> [String: Any] {
        var state = fixture(revision: revision)
        let from = "2026-10-18T01:00:00.000Z", to = "2026-10-18T02:00:59.999Z"
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.date(from: from)!
        let sources: [[String: Any]] = (0..<count).map { index in
            ["id": "summary-message-\(index)", "accountId": account, "groupId": "group-a", "senderId": "member", "senderName": "成员", "text": "原消息 \(index)", "sentAt": formatter.string(from: start.addingTimeInterval(Double(index))), "attachments": [], "contextScope": "text"]
        }
        let summary: [String: Any] = ["version": 1, "groupId": "group-a", "startAt": from, "endAt": to, "label": "2026-10-18 09:00 至 10:00", "sourceCount": count,
            "coverage": ["complete": true, "reason": "已核对完整时段", "from": from, "to": to, "checkedAt": stamp, "loadedCount": count, "pages": 16],
            "status": "complete", "batchCount": 2, "completedBatches": 2, "partials": ["分批结果 [消息1]", "分批结果 [消息2]"], "prompt": "梳理群聊", "stage": "reduce", "round": 1, "reductionCompleted": 1, "rounds": 1, "finalText": "汇总 [消息1] [消息2]"]
        state["discussions"] = [["id": "range-discussion", "accountId": account, "createdAt": stamp, "instructions": "使用完整段落", "contextSnapshots": sources, "messages": [["role": "user", "content": "梳理群聊"], ["role": "assistant", "content": "汇总 [消息1] [消息2]"]], "rangeSummary": summary]]
        return state
    }
    static func webSearchFixture(revision: Int = 1) -> [String: Any] {
        var state = preferencesFixture(revision: revision)
        var settings = state["settings"] as! [String: Any]; settings["webSearchEnabled"] = true; state["settings"] = settings
        let metadata: [String: Any] = ["status": "success", "query": "最新资料", "searchedAt": stamp, "sources": [["id": "网页1", "title": "新闻来源", "url": "https://example.com/news#section", "publishedAt": NSNull(), "siteName": "Example", "excerpt": "检索取得的原始摘要"]]]
        var discussions = state["discussions"] as! [[String: Any]]
        discussions[0]["messages"] = [["role": "assistant", "content": "回答 [网页1]", "webSearch": metadata]]
        state["discussions"] = discussions
        return state
    }
    static func unreadFixture(revision: Int = 1) -> [String: Any] {
        var state = fixture(revision: revision)
        var settings = state["settings"] as! [String: Any]
        settings["groupUnread"] = ["group-a": ["accountId": account, "groupId": "group-a", "count": 27,
            "acknowledgedAt": stamp, "baseline": ["id": "removed-from-message-cache", "sentAt": "2026-10-18T08:00:00+08:00"]]]
        state["settings"] = settings
        return state
    }
    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("AI discussion titles persist and invalid metadata cannot overwrite saved history", {
                try withStore { store in
                    var state=fixture(), discussions=state["discussions"] as! [[String:Any]]
                    let info:[String:Any] = ["version":1,"source":"ai","fingerprint":"0123456789abcdef","model":"synthetic","generatedAt":stamp]
                    discussions[0]["title"]="需求与供给的变化"; discussions[0]["titleInfo"]=info;state["discussions"]=discussions
                    try store.save(state:state,accountId:account)
                    let saved=try Data(contentsOf:store.fileURL(accountId:account))
                    try expect(try bytes(store.load(accountId:account).state)==bytes(state),"AI title metadata lost on reopen")
                    for patch:[String:Any] in [["source":"invented"],["version":true],["version":3],["fingerprint":"bad"],["generatedAt":"yesterday"],["model":9]] {
                        var changed=state, items=discussions, bad=info
                        patch.forEach { bad[$0.key]=$0.value };items[0]["titleInfo"]=bad;changed["discussions"]=items;changed["revision"]=2
                        try rejects("title metadata") { try store.save(state:changed,accountId:account) }
                        try expect(try Data(contentsOf:store.fileURL(accountId:account))==saved,"Invalid title overwrote saved history")
                    }
                }
            }),
            ("manual anchor and source timestamp persist independently, while invalid timestamps leave disk unchanged", {
                try withStore { store in
                    var state = fixture()
                    var progress = state["progress"] as! [String: [String: [String: Any]]]
                    var manual = progress["group-a"]!["auto"]!
                    manual["messageSentAt"] = stamp; manual["offset"] = 0
                    progress["group-a"]!["manual"] = manual
                    state["progress"] = progress
                    try store.save(state: state, accountId: account)
                    let persisted = try Data(contentsOf: store.fileURL(accountId: account))
                    let restored = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(restored) == bytes(state), "Manual point or timestamp lost after disk reopen")
                    let anchors = restored["progress"] as! [String: [String: [String: Any]]]
                    try expect(anchors["group-a"]?["auto"]?["messageSentAt"] == nil, "Legacy auto timestamp was invented")
                    try expect(anchors["group-a"]?["manual"]?["messageSentAt"] as? String == stamp, "Manual message time missing")
                    for badDate in ["invalid", "2026-02-30T01:02:03Z", 123, NSNull()] as [Any] {
                        var invalid = state; var bad = progress
                        bad["group-a"]!["manual"]!["messageSentAt"] = badDate
                        invalid["progress"] = bad; invalid["revision"] = 2
                        try rejects("invalid manual message timestamp") { try store.save(state: invalid, accountId: account) }
                        try expect(try Data(contentsOf: store.fileURL(accountId: account)) == persisted, "Invalid manual anchor changed disk")
                    }
                    var legacy = fixture(revision: 3); legacy["messages"] = []
                    try store.save(state: legacy, accountId: account)
                    let legacyAnchors = try StateStore(directory: store.directory).load(accountId: account).state["progress"] as! [String: [String: [String: Any]]]
                    try expect(legacyAnchors["group-a"]?["manual"] == nil, "Old automatic progress silently migrated into a manual point")
                }
            }),
            ("group unread counts and acknowledged baselines survive restart and cache cleanup, with legacy and empty baselines supported", {
                try withStore { store in
                    var state = unreadFixture()
                    state["messages"] = []
                    try store.save(state: state, accountId: account)
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(state), "Unread count or removed-cache baseline changed after restart")
                    for (revision, count) in [(2, 0), (3, 9_007_199_254_740_991)] {
                        var settings = state["settings"] as! [String: Any]
                        settings["groupUnread"] = ["group-a": ["accountId": account, "groupId": "group-a", "count": count, "acknowledgedAt": stamp, "baseline": NSNull()]]
                        state["settings"] = settings; state["revision"] = revision
                        try store.save(state: state, accountId: account)
                        try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(state), "Unread boundary count or null baseline changed after restart")
                    }
                    var settings = state["settings"] as! [String: Any]
                    settings["groupUnread"] = [String: Any](); state["settings"] = settings; state["revision"] = 4
                    try store.save(state: state, accountId: account)
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(state), "Empty unread library changed")
                    let legacy = fixture(revision: 5)
                    try store.save(state: legacy, accountId: account)
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(legacy), "Legacy state without unread fields no longer opens")
                }
            }),
            ("invalid unread account, group, count, dates, baseline and unknown fields atomically preserve the accepted account file", {
                var changes: [(String, (inout [String: Any]) -> Void)] = [
                    ("other account", { $0["accountId"] = "other-account" }), ("other group", { $0["groupId"] = "group-b" }),
                    ("unknown field", { $0["unexpected"] = true }),
                    ("baseline scalar", { $0["baseline"] = "message-1" }),
                    ("baseline id empty", { $0["baseline"] = ["id": " ", "sentAt": stamp] }),
                    ("baseline id too long", { $0["baseline"] = ["id": String(repeating: "😀", count: 81), "sentAt": stamp] }),
                    ("baseline missing id", { $0["baseline"] = ["sentAt": stamp] }),
                    ("baseline missing time", { $0["baseline"] = ["id": "message-1"] }),
                    ("baseline extra field", { $0["baseline"] = ["id": "message-1", "sentAt": stamp, "extra": true] })
                ]
                for key in ["accountId", "groupId", "count", "acknowledgedAt", "baseline"] {
                    changes.append(("missing " + key, { $0.removeValue(forKey: key) }))
                }
                for count in [true, false, -1, 0.5, 9_007_199_254_740_992, "1", NSNull()] as [Any] {
                    changes.append(("invalid count", { $0["count"] = count }))
                }
                for date in ["bad", "2026-10-18", "2026-10-18T01:02:03", "2026-02-30T01:02:03Z", "2026-10-18T25:02:03Z", 123, NSNull()] as [Any] {
                    changes.append(("invalid acknowledgement date", { $0["acknowledgedAt"] = date }))
                    changes.append(("invalid baseline date", { $0["baseline"] = ["id": "message-1", "sentAt": date] }))
                }
                try withStore { store in
                    try store.save(state: unreadFixture(), accountId: account)
                    let file = store.fileURL(accountId: account), original = try Data(contentsOf: file)
                    for (label, change) in changes {
                        var state = unreadFixture(revision: 2), settings = state["settings"] as! [String: Any], unread = settings["groupUnread"] as! [String: [String: Any]], entry = unread["group-a"]!
                        change(&entry); unread["group-a"] = entry; settings["groupUnread"] = unread; state["settings"] = settings
                        try rejects(label) { try store.save(state: state, accountId: account) }
                        try expect(try Data(contentsOf: file) == original, "Rejected unread change altered account data: " + label)
                    }
                    for raw in [NSNull(), [], 1, ["missing-group": ["accountId": account, "groupId": "missing-group", "count": 0, "acknowledgedAt": stamp, "baseline": NSNull()]], ["group-a": NSNull()]] as [Any] {
                        var state = unreadFixture(revision: 2), settings = state["settings"] as! [String: Any]
                        settings["groupUnread"] = raw; state["settings"] = settings
                        try rejects("invalid unread map or absent group") { try store.save(state: state, accountId: account) }
                        try expect(try Data(contentsOf: file) == original, "Rejected unread map altered account data")
                    }
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(unreadFixture()), "Rejected unread data changed subsequent restart")
                }
            }),
            ("web search settings, dated source metadata and success/empty/failure records survive restart and discussion restoration", {
                try withStore { store in
                    var state = webSearchFixture()
                    try store.save(state: state, accountId: account)
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(state), "Web source metadata changed after restart")
                    var discussions = state["discussions"] as! [[String: Any]], turns = discussions[0]["messages"] as! [[String: Any]]
                    let originalMetadata = try JSONSerialization.data(withJSONObject: turns[0]["webSearch"]!, options: [.sortedKeys])
                    for status in ["empty", "failed"] {
                        let metadata: [String: Any] = ["status": status, "query": String(repeating: "😀", count: 64), "searchedAt": stamp, "sources": [], "error": status == "failed" ? "检索服务不可用" : ""]
                        turns.append(["role": "assistant", "content": "按现有资料回答", "webSearch": metadata])
                    }
                    discussions[0]["messages"] = turns; discussions[0]["deletedAt"] = stamp; state["discussions"] = discussions; state["revision"] = 2
                    var settings = state["settings"] as! [String: Any]; settings["activeDiscussionId"] = NSNull(); state["settings"] = settings
                    try store.save(state: state, accountId: account)
                    let deleted = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(deleted) == bytes(state), "Deleted web discussion lost metadata")
                    discussions[0]["deletedAt"] = NSNull(); state["discussions"] = discussions; state["revision"] = 3
                    try store.save(state: state, accountId: account)
                    let restored = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(restored) == bytes(state), "Restored web discussion lost metadata")
                    let restoredTurns = ((restored["discussions"] as! [[String: Any]])[0]["messages"] as! [[String: Any]])
                    try expect(try JSONSerialization.data(withJSONObject: restoredTurns[0]["webSearch"]!, options: [.sortedKeys]) == originalMetadata, "Search source dates were rewritten")
                }
            }),
            ("invalid web-search switches, oversized metadata and unsafe source URLs cannot overwrite a valid account file", {
                let changes: [(inout [String: Any]) -> Void] = [
                    { $0["status"] = "unknown" }, { $0["status"] = "empty" }, { $0["sources"] = [] }, { $0["query"] = String(repeating: "x", count: 129) },
                    { $0["searchedAt"] = "2026-10-18" }, { $0["extra"] = true }, { $0["error"] = String(repeating: "x", count: 501) },
                    { m in var s = m["sources"] as! [[String: Any]]; s[0]["id"] = "网页2"; m["sources"] = s },
                    { m in var s = m["sources"] as! [[String: Any]]; s[0]["title"] = String(repeating: "x", count: 501); m["sources"] = s },
                    { m in var s = m["sources"] as! [[String: Any]]; s[0]["siteName"] = String(repeating: "x", count: 301); m["sources"] = s },
                    { m in var s = m["sources"] as! [[String: Any]]; s[0]["excerpt"] = String(repeating: "x", count: 1201); m["sources"] = s },
                    { m in var s = m["sources"] as! [[String: Any]]; s[0]["publishedAt"] = "yesterday"; m["sources"] = s },
                    { m in var s = m["sources"] as! [[String: Any]]; s[0].removeValue(forKey: "publishedAt"); m["sources"] = s },
                    { m in let first = (m["sources"] as! [[String: Any]])[0]; m["sources"] = (1...6).map { index in var item = first; item["id"] = "网页\(index)"; return item } }
                ]
                let unsafeURLs = ["javascript:alert(1)", "file:///etc/passwd", "https://user@example.com", "https://@example.com", "https://localhost", "https://host.local", "https://host.internal", "https://host.lan", "https://host.home", "https://127.0.0.1", "https://127.1", "https://2130706433", "https://0x7f000001", "https://0177.0.0.1", "https://10.0.0.1", "https://172.16.0.1", "https://192.168.0.1", "https://169.254.169.254", "https://100.64.0.1", "https://192.0.2.1", "https://198.18.0.1", "https://198.51.100.1", "https://203.0.113.1", "https://224.0.0.1", "https://[::1]", "https://[2001:4860:4860::8888]", "https://example.com:65536/news", "https://example.com:70000/news", "https://example.com/" + String(repeating: "x", count: 8192)]
                try withStore { store in
                    try store.save(state: webSearchFixture(), accountId: account)
                    let file = store.fileURL(accountId: account), accepted = try Data(contentsOf: file)
                    var allChanges = changes
                    allChanges += unsafeURLs.map { url in { metadata in var sources = metadata["sources"] as! [[String: Any]]; sources[0]["url"] = url; metadata["sources"] = sources } }
                    for change in allChanges {
                        var state = webSearchFixture(revision: 2), discussions = state["discussions"] as! [[String: Any]], turns = discussions[0]["messages"] as! [[String: Any]], metadata = turns[0]["webSearch"] as! [String: Any]
                        change(&metadata); turns[0]["webSearch"] = metadata; discussions[0]["messages"] = turns; state["discussions"] = discussions
                        try rejects("invalid web-search metadata") { try store.save(state: state, accountId: account) }
                    }
                    for wrong in [1, "true", NSNull()] as [Any] {
                        var state = webSearchFixture(revision: 2), settings = state["settings"] as! [String: Any]; settings["webSearchEnabled"] = wrong; state["settings"] = settings
                        try rejects("invalid web-search choice") { try store.save(state: state, accountId: account) }
                    }
                    var wrongRole = webSearchFixture(revision: 2), discussions = wrongRole["discussions"] as! [[String: Any]], turns = discussions[0]["messages"] as! [[String: Any]]
                    turns[0]["role"] = "user"; discussions[0]["messages"] = turns; wrongRole["discussions"] = discussions
                    try rejects("web search attached to user") { try store.save(state: wrongRole, accountId: account) }
                    try expect(try Data(contentsOf: file) == accepted, "Invalid search metadata changed accepted data")
                }
            }),
            ("deleted discussion history remains recoverable after native restart without removing original materials", {
                try withStore { store in
                    var initial = rangeSummaryFixture()
                    var initialSettings = initial["settings"] as! [String: Any]; initialSettings["activeDiscussionId"] = "range-discussion"; initial["settings"] = initialSettings
                    try store.save(state: initial, accountId: account)
                    var deleted = initial, discussions = initial["discussions"] as! [[String: Any]], settings = initialSettings
                    discussions[0]["deletedAt"] = stamp; settings["activeDiscussionId"] = NSNull()
                    deleted["discussions"] = discussions; deleted["settings"] = settings; deleted["revision"] = 2
                    try store.save(state: deleted, accountId: account)
                    let reopened = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(reopened) == bytes(deleted), "Deleted discussion/source map changed on restart")
                    for field in ["messages", "groups", "bookmarks", "collections", "progress"] {
                        try expect(try JSONSerialization.data(withJSONObject: reopened[field]!, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: initial[field]!, options: [.sortedKeys]), "Deleting discussion changed " + field)
                    }
                    var restored = deleted
                    discussions[0]["deletedAt"] = NSNull(); restored["discussions"] = discussions; restored["revision"] = 3
                    try store.save(state: restored, accountId: account)
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(restored), "Restored discussion/source map changed on restart")
                    let file = store.fileURL(accountId: account), accepted = try Data(contentsOf: file)
                    let invalid: [Any] = ["", "yesterday", "2026-10-18", 123, true, ["invalid": true]]
                    for value in invalid {
                        var candidate = restored, badDiscussions = discussions
                        badDiscussions[0]["deletedAt"] = value; candidate["discussions"] = badDiscussions; candidate["revision"] = 4
                        try rejects("invalid discussion.deletedAt") { try store.save(state: candidate, accountId: account) }
                    }
                    try expect(try Data(contentsOf: file) == accepted, "Invalid deletion date changed accepted data")
                }
            }),
            ("time range summary preserves 1501 source snapshots, citations and interrupted checkpoints across native restart", {
                try withStore { store in
                    let state = rangeSummaryFixture()
                    try store.save(state: state, accountId: account)
                    let restored = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(restored) == bytes(state), "Final summary or source map changed on restart")
                    var partial = state, discussions = partial["discussions"] as! [[String: Any]], summary = discussions[0]["rangeSummary"] as! [String: Any]
                    summary["status"] = "interrupted"; summary["error"] = "已取消"; summary["stage"] = "map"
                    summary["completedBatches"] = 1; summary["partials"] = ["分批结果 [消息1]"]; summary.removeValue(forKey: "finalText")
                    discussions[0]["rangeSummary"] = summary; partial["discussions"] = discussions; partial["revision"] = 2
                    partial["messages"] = []
                    try store.save(state: partial, accountId: account)
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(partial), "Interrupted result lost sources after original archive was cleared")
                }
            }),
            ("invalid time range metadata and cross-account/group/out-of-range/duplicate snapshots never overwrite a valid file", {
                let changes: [(String, (inout [String: Any]) -> Void)] = [
                    ("version", { $0["version"] = true }), ("unknown field", { $0["unknown"] = true }), ("status", { $0["status"] = "done" }),
                    ("source count", { $0["sourceCount"] = 1 }), ("boolean count", { $0["sourceCount"] = true }), ("infinite count", { $0["sourceCount"] = Double.infinity }),
                    ("batch count", { $0["batchCount"] = 0 }), ("fractional batch", { $0["batchCount"] = 1.5 }), ("completed count", { $0["completedBatches"] = 3 }),
                    ("missing partials", { $0["partials"] = [] }), ("empty partial", { $0["partials"] = ["", "second"] }),
                    ("missing final", { $0.removeValue(forKey: "finalText") }), ("empty final", { $0["finalText"] = "" }),
                    ("bad date", { $0["startAt"] = "invalid" }), ("reversed date", { $0["endAt"] = "2026-10-17T00:00:00Z" }), ("wrong group", { $0["groupId"] = "foreign" }),
                    ("coverage count", { s in var c = s["coverage"] as! [String: Any]; c["loadedCount"] = 9; s["coverage"] = c }),
                    ("coverage type", { s in var c = s["coverage"] as! [String: Any]; c["complete"] = 1; s["coverage"] = c }),
                    ("coverage range", { s in var c = s["coverage"] as! [String: Any]; c["from"] = "2026-10-17T00:00:00Z"; s["coverage"] = c }),
                    ("coverage check", { s in var c = s["coverage"] as! [String: Any]; c["checkedAt"] = "invalid"; s["coverage"] = c }),
                    ("coverage pages", { s in var c = s["coverage"] as! [String: Any]; c["pages"] = -1; s["coverage"] = c }),
                    ("stage", { $0["stage"] = "other" }), ("round", { $0["round"] = 0 }), ("rounds", { $0["rounds"] = 9 }), ("reduction count", { $0["reductionCompleted"] = -1 }),
                    ("label length", { $0["label"] = String(repeating: "x", count: 4097) }), ("output length", { $0["partials"] = [String(repeating: "x", count: 1000001), "second"] })
                ]
                try withStore { store in
                    try store.save(state: rangeSummaryFixture(count: 3), accountId: account)
                    let file = store.fileURL(accountId: account), original = try Data(contentsOf: file)
                    for (label, change) in changes {
                        var state = rangeSummaryFixture(revision: 2, count: 3), discussions = state["discussions"] as! [[String: Any]], summary = discussions[0]["rangeSummary"] as! [String: Any]
                        change(&summary); discussions[0]["rangeSummary"] = summary; state["discussions"] = discussions
                        try rejects("range summary " + label) { try store.save(state: state, accountId: account) }
                    }
                    let snapshotChanges: [(inout [[String: Any]]) -> Void] = [
                        { $0[0]["accountId"] = "foreign" }, { $0[0]["groupId"] = "foreign" }, { $0[0]["id"] = $0[1]["id"] },
                        { $0[0]["sentAt"] = "2026-10-17T00:00:00Z" }, { $0.reverse() }, { $0.removeLast() }
                    ]
                    for change in snapshotChanges {
                        var state = rangeSummaryFixture(revision: 2, count: 3), discussions = state["discussions"] as! [[String: Any]], sources = discussions[0]["contextSnapshots"] as! [[String: Any]]
                        change(&sources); discussions[0]["contextSnapshots"] = sources; state["discussions"] = discussions
                        try rejects("range snapshot relation") { try store.save(state: state, accountId: account) }
                    }
                    try expect(try Data(contentsOf: file) == original, "Rejected summary changed the accepted account file")
                }
            }),
            ("personal preferences, custom prompts and per-discussion instructions survive native restart and remain account scoped", {
                try withStore { store in
                    let initial = preferencesFixture()
                    try store.save(state: initial, accountId: account)
                    var restored = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(initial) == bytes(restored), "Preference text or settings changed on restart")
                    var settings = restored["settings"] as! [String: Any]
                    var library = settings["aiPreferences"] as! [String: Any]
                    var entries = library["entries"] as! [[String: Any]]
                    entries[0]["enabled"] = false; entries[0]["content"] = "修改后的写作风格"
                    library["entries"] = entries; library["quickPrompts"] = []
                    settings["aiPreferences"] = library; settings["activeDiscussionId"] = NSNull(); settings["aiDraftInstructions"] = ""
                    restored["settings"] = settings; restored["revision"] = 2
                    try store.save(state: restored, accountId: account)
                    let edited = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(edited) == bytes(restored), "Edit/disable/deletion did not persist")
                    library["entries"] = []; settings["aiPreferences"] = library; restored["settings"] = settings; restored["revision"] = 3
                    try store.save(state: restored, accountId: account)
                    let deleted = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try bytes(deleted) == bytes(restored), "Explicit empty preferences revived defaults")
                    let other = try StateStore(directory: store.directory).load(accountId: "other-account").state
                    try expect((other["settings"] as? [String: Any])?["aiPreferences"] == nil, "Preferences leaked to another account")
                    try expect((other["discussions"] as? [Any])?.isEmpty == true, "Discussion instructions leaked to another account")
                    try Data("damaged".utf8).write(to: store.fileURL(accountId: account))
                    let recovered = try StateStore(directory: store.directory).load(accountId: account)
                    try expect(recovered.warning != nil, "Preference backup recovery omitted warning")
                    try expect(try bytes(recovered.state) == bytes(edited), "Preference backup failed to restore last valid edit")
                }
            }),
            ("invalid preference fields and sizes are rejected without changing an accepted account file", {
                let libraryChanges: [(String, (inout [String: Any]) -> Void)] = [
                    ("wrong version", { $0["version"] = true }),
                    ("null entries", { $0["entries"] = NSNull() }),
                    ("wrong quick type", { $0["quickPrompts"] = "bad" }),
                    ("duplicate entries", { lib in let list = lib["entries"] as! [[String: Any]]; lib["entries"] = list + list }),
                    ("duplicate prompts", { lib in let list = lib["quickPrompts"] as! [[String: Any]]; lib["quickPrompts"] = list + list }),
                    ("unknown field", { $0["apiKey"] = "must-not-be-saved" }),
                    ("unknown category", { lib in var list = lib["entries"] as! [[String: Any]]; list[0]["category"] = "unknown"; lib["entries"] = list }),
                    ("wrong enabled type", { lib in var list = lib["entries"] as! [[String: Any]]; list[0]["enabled"] = 1; lib["entries"] = list }),
                    ("empty content", { lib in var list = lib["entries"] as! [[String: Any]]; list[0]["content"] = " "; lib["entries"] = list }),
                    ("long UTF16 content", { lib in var list = lib["entries"] as! [[String: Any]]; list[0]["content"] = String(repeating: "😀", count: 6001); lib["entries"] = list }),
                    ("long title", { lib in var list = lib["entries"] as! [[String: Any]]; list[0]["title"] = String(repeating: "x", count: 121); lib["entries"] = list }),
                    ("long id", { lib in var list = lib["entries"] as! [[String: Any]]; list[0]["id"] = String(repeating: "x", count: 161); lib["entries"] = list }),
                    ("too many entries", { lib in let first = (lib["entries"] as! [[String: Any]])[0]; lib["entries"] = (0..<101).map { n in var entry = first; entry["id"] = "e-\(n)"; return entry } }),
                    ("too many prompts", { lib in let first = (lib["quickPrompts"] as! [[String: Any]])[0]; lib["quickPrompts"] = (0..<51).map { n in var entry = first; entry["id"] = "q-\(n)"; return entry } }),
                    ("over total text", { lib in let first = (lib["entries"] as! [[String: Any]])[0]; lib["entries"] = (0..<5).map { n in var entry = first; entry["id"] = "e-\(n)"; entry["content"] = String(repeating: "x", count: 12000); return entry } })
                ]
                try withStore { store in
                    try store.save(state: preferencesFixture(), accountId: account)
                    let file = store.fileURL(accountId: account), original = try Data(contentsOf: file)
                    for (name, change) in libraryChanges {
                        var candidate = preferencesFixture(revision: 2), settings = candidate["settings"] as! [String: Any], library = settings["aiPreferences"] as! [String: Any]
                        change(&library); settings["aiPreferences"] = library; candidate["settings"] = settings
                        try rejects(name) { try store.save(state: candidate, accountId: account) }
                        try expect(try Data(contentsOf: file) == original, "Invalid preference save changed original")
                    }
                    let instructionChanges: [(inout [String: Any]) -> Void] = [
                        { state in var settings = state["settings"] as! [String: Any]; settings["aiDraftInstructions"] = String(repeating: "x", count: 12001); state["settings"] = settings },
                        { state in var settings = state["settings"] as! [String: Any]; settings["aiDraftInstructions"] = NSNull(); state["settings"] = settings },
                        { state in var settings = state["settings"] as! [String: Any]; settings["activeDiscussionId"] = 123; state["settings"] = settings },
                        { state in var settings = state["settings"] as! [String: Any]; settings["activeDiscussionId"] = ""; state["settings"] = settings },
                        { state in var discussions = state["discussions"] as! [[String: Any]]; discussions[0]["instructions"] = NSNull(); state["discussions"] = discussions },
                        { state in var discussions = state["discussions"] as! [[String: Any]]; discussions[0]["instructions"] = String(repeating: "x", count: 12001); state["discussions"] = discussions }
                    ]
                    for change in instructionChanges {
                        var candidate = preferencesFixture(revision: 2); change(&candidate)
                        try rejects("invalid instructions") { try store.save(state: candidate, accountId: account) }
                    }
                    try expect(try Data(contentsOf: file) == original, "Invalid instructions changed original")
                    var boundary = preferencesFixture(revision: 2), settings = boundary["settings"] as! [String: Any], library = settings["aiPreferences"] as! [String: Any], entries = library["entries"] as! [[String: Any]]
                    entries[0]["content"] = String(repeating: "😀", count: 6000); library["entries"] = entries; settings["aiPreferences"] = library; boundary["settings"] = settings
                    try store.save(state: boundary, accountId: account)
                    try expect(try bytes(StateStore(directory: store.directory).load(accountId: account).state) == bytes(boundary), "Exact UTF-16 boundary not retained")
                }
            }),
            ("1000 complete bookmarks and 64-bit string IDs survive restart without losing fields", {
                try withStore { store in
                    let state = fixture(count: 1000)
                    try store.save(state: state, accountId: account)
                    let restart = try StateStore(directory: store.directory)
                    let restored = try restart.load(accountId: account)
                    try expect(try bytes(restored.state) == bytes(state), "Restart changed valid state")
                    let other = try restart.load(accountId: "other-account")
                    try expect((other.state["bookmarks"] as? [Any])?.isEmpty == true, "Account state mixed")
                }
            }),
            ("the first successful save already has a usable backup", {
                try withStore { store in
                    let state = fixture()
                    try store.save(state: state, accountId: account)
                    let file = store.fileURL(accountId: account)
                    try expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("backup").path), "First save had no backup")
                    try Data("broken main".utf8).write(to: file)
                    let restored = try StateStore(directory: store.directory).load(accountId: account)
                    try expect(restored.warning != nil, "Backup recovery omitted warning")
                    try expect(try bytes(restored.state) == bytes(state), "First backup lost content")
                }
            }),
            ("valid JSON with damaged entity semantics falls back to a valid backup", {
                let corruptions: [(inout [String: Any]) -> Void] = [
                    { $0["bookmarks"] = [NSNull()] },
                    { s in var a = s["messages"] as! [[String: Any]]; a[0]["accountId"] = "foreign"; s["messages"] = a },
                    { s in var a = s["bookmarks"] as! [[String: Any]]; a[0]["messageId"] = "wrong-message"; s["bookmarks"] = a }
                ]
                for corrupt in corruptions {
                    try withStore { store in
                        let original = fixture()
                        try store.save(state: original, accountId: account)
                        try store.save(state: fixture(revision: 2, count: 2), accountId: account)
                        var invalid = fixture(revision: 2, count: 2); corrupt(&invalid)
                        try bytes(invalid).write(to: store.fileURL(accountId: account))
                        let restart = try StateStore(directory: store.directory)
                        let recovered = try restart.load(accountId: account)
                        try expect(recovered.warning != nil, "Semantic corruption skipped backup")
                        try expect(try bytes(recovered.state) == bytes(original), "Wrong recovery snapshot")
                        try restart.save(state: recovered.state, accountId: account)
                        try expect(try restart.load(accountId: account).warning == nil, "Recovered snapshot did not repair main")
                    }
                }
            }),
            ("a damaged only copy cannot be overwritten by a later save", {
                try withStore { store in
                    let file = store.fileURL(accountId: account)
                    let damaged = Data("damaged unique original".utf8)
                    try damaged.write(to: file)
                    try rejects("load corrupt only copy") { _ = try store.load(accountId: account) }
                    try rejects("overwrite corrupt only copy") { try store.save(state: fixture(revision: 99), accountId: account) }
                    try expect(try Data(contentsOf: file) == damaged, "Damaged original was overwritten")
                    try Data("also damaged".utf8).write(to: file.appendingPathExtension("backup"))
                    try rejects("overwrite two corrupt copies") { try store.save(state: fixture(revision: 100), accountId: account) }
                    try expect(try Data(contentsOf: file) == damaged, "Unique original changed")
                }
            }),
            ("equal revisions are idempotent only for equal content and never rotate away the backup", {
                try withStore { store in
                    try store.save(state: fixture(), accountId: account)
                    let current = fixture(revision: 2, count: 2)
                    try store.save(state: current, accountId: account)
                    let file = store.fileURL(accountId: account)
                    let backup = file.appendingPathExtension("backup")
                    let previousBackup = try Data(contentsOf: backup)
                    try store.save(state: current, accountId: account)
                    try expect(try Data(contentsOf: backup) == previousBackup, "Idempotent save rotated backup")
                    var conflict = current; conflict["bookmarks"] = []
                    try rejects("conflicting same revision") { try store.save(state: conflict, accountId: account) }
                    try expect(try Data(contentsOf: file) == bytes(current), "Conflict changed main")
                    try expect(try Data(contentsOf: backup) == previousBackup, "Conflict changed backup")
                    try rejects("stale revision") { try store.save(state: fixture(), accountId: account) }
                }
            }),
            ("invalid entity IDs, accounts, snapshot relations, arrays and revisions are rejected atomically", {
                let invalid: [(String, (inout [String: Any]) -> Void)] = [
                    ("numeric message id", { s in var a = s["messages"] as! [[String: Any]]; a[0]["id"] = 9007199254740992; s["messages"] = a }),
                    ("foreign group", { s in var a = s["groups"] as! [[String: Any]]; a[0]["accountId"] = "foreign"; s["groups"] = a }),
                    ("foreign snapshot", { s in var a = s["bookmarks"] as! [[String: Any]]; var m = a[0]["snapshot"] as! [String: Any]; m["accountId"] = "foreign"; a[0]["snapshot"] = m; s["bookmarks"] = a }),
                    ("collection mismatch", { s in var a = s["collections"] as! [[String: Any]]; a[0]["messageIds"] = ["group-a:wrong"]; s["collections"] = a }),
                    ("duplicate message", { s in var a = s["messages"] as! [[String: Any]]; a.append(a[0]); s["messages"] = a }),
                    ("invalid attachments", { s in var a = s["messages"] as! [[String: Any]]; a[0]["attachments"] = "not-array"; s["messages"] = a }),
                    ("wrong progress group", { s in s["progress"] = ["group-b": ["auto": ["accountId": account, "groupId": "group-a", "messageId": "9007199254740993001", "offset": 0, "updatedAt": stamp]]] }),
                    ("foreign discussion", { s in var a = s["discussions"] as! [[String: Any]]; a[0]["accountId"] = "foreign"; s["discussions"] = a }),
                    ("foreign discussion context", { s in var a = s["discussions"] as! [[String: Any]]; var m = a[0]["contextSnapshots"] as! [[String: Any]]; m[0]["accountId"] = "foreign"; a[0]["contextSnapshots"] = m; s["discussions"] = a }),
                    ("invalid discussion messages", { s in var a = s["discussions"] as! [[String: Any]]; a[0]["messages"] = "not-array"; s["discussions"] = a }),
                    ("boolean revision", { $0["revision"] = true }),
                    ("fractional revision", { $0["revision"] = 2.5 }),
                    ("boolean version", { $0["version"] = true })
                ]
                try withStore { store in
                    try store.save(state: fixture(), accountId: account)
                    let file = store.fileURL(accountId: account)
                    let original = try Data(contentsOf: file)
                    for (name, corrupt) in invalid {
                        var candidate = fixture(revision: 2); corrupt(&candidate)
                        try rejects(name) { try store.save(state: candidate, accountId: account) }
                        try expect(try Data(contentsOf: file) == original, "Invalid save changed original")
                    }
                }
            }),
            ("saved snapshots and anchors survive missing original messages", {
                try withStore { store in
                    var state = fixture(); state["messages"] = []
                    try store.save(state: state, accountId: account)
                    try expect(try bytes(store.load(accountId: account).state) == bytes(state), "Missing original removed snapshot")
                }
            }),
            ("model history/live overlap and group changes survive native restart with eight anchors, 20 markers and sync metadata", {
                try withStore { store in
                    let state = try modelHistoryFixture()
                    try store.save(state: state, accountId: account)
                    let reopened = try StateStore(directory: store.directory)
                    var restored = try reopened.load(accountId: account).state
                    try expect(try bytes(restored) == bytes(state), "Native restart changed model-produced data")
                    try expect((restored["messages"] as? [Any])?.count == 550, "History/live overlap lost or duplicated messages")
                    try expect((restored["bookmarks"] as? [Any])?.count == 20, "Independent markers were lost")
                    let progress = restored["progress"] as! [String: [String: [String: Any]]]
                    for groupId in ["bulk-a", "bulk-b"] {
                        try expect(progress[groupId]?["auto"]?["messageId"] as? String == "9007199254740993500", "Auto anchor moved")
                        try expect(progress[groupId]?["sessionStart"]?["messageId"] as? String == "9007199254740993501", "Session anchor moved")
                        try expect(progress[groupId]?["returnPoint"]?["messageId"] as? String == "9007199254740993502", "Return anchor moved")
                        try expect(progress[groupId]?["returnPoint"]?["offset"] as? Int == 30, "Anchor offset lost")
                        try expect(progress[groupId]?["manual"]?["messageId"] as? String == "9007199254740993503", "Manual anchor moved")
                        try expect(progress[groupId]?["manual"]?["messageSentAt"] as? String == "2026-10-18T00:08:23.000Z", "Manual source timestamp changed")
                    }
                    let oldBookmarks = try JSONSerialization.data(withJSONObject: restored["bookmarks"]!, options: [.sortedKeys])
                    let oldProgress = try JSONSerialization.data(withJSONObject: restored["progress"]!, options: [.sortedKeys])
                    var settings = restored["settings"] as! [String: Any]
                    var ui = settings["ui"] as! [String: Any]; ui["activeGroupId"] = "bulk-a"; settings["ui"] = ui
                    restored["settings"] = settings; restored["revision"] = (restored["revision"] as! Int) + 1
                    try reopened.save(state: restored, accountId: account)
                    let again = try StateStore(directory: store.directory).load(accountId: account).state
                    try expect(try JSONSerialization.data(withJSONObject: again["bookmarks"]!, options: [.sortedKeys]) == oldBookmarks, "Changing active group rewrote markers")
                    try expect(try JSONSerialization.data(withJSONObject: again["progress"]!, options: [.sortedKeys]) == oldProgress, "Changing active group rewrote anchors")
                    try expect(try bytes(again) == bytes(restored), "UI/sync metadata changed on second restart")
                }
            })
        ]
        var failed = 0
        for (name, run) in cases {
            do { try run(); print("PASS: \(name)") }
            catch { failed += 1; print("FAIL: \(name): \(error)") }
        }
        print("Store: \(cases.count - failed)/\(cases.count) passed")
        if failed > 0 { exit(1) }
    }
}
