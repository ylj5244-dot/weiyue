import Foundation

@main struct StoreConcurrencyTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-concurrent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StateStore(directory: root)
        let failures = NSLock()
        var invalidReads = 0
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            var state = StateStore.empty(accountId: "synthetic")
            state["revision"] = index + 1
            do { try store.save(state: state, accountId: "synthetic") }
            catch { /* A concurrent higher revision correctly rejects older work. */ }
            do {
                let loaded = try store.load(accountId: "synthetic")
                if (loaded.state["revision"] as? Int ?? 0) < index + 1 {
                    failures.lock(); invalidReads += 1; failures.unlock()
                }
            } catch { failures.lock(); invalidReads += 1; failures.unlock() }
        }
        let latest = try store.load(accountId: "synthetic")
        precondition(latest.state["revision"] as? Int == 40 && invalidReads == 0)
        var future = latest.state; future["revision"] = 100
        try store.validate(state: future, accountId: "synthetic")
        let afterValidation = try store.load(accountId: "synthetic")
        precondition(afterValidation.state["revision"] as? Int == 40)

        var state = StateStore.empty(accountId: "synthetic")
        state["groups"] = [["id": "g", "selected": true, "unreadCount": 8], ["id": "hidden", "selected": false]]
        state["messages"] = [["groupId": "g", "id": "100"], ["groupId": "g", "id": "999"], ["groupId": "hidden", "id": "1"]]
        state["cleanup"] = ["suppressedMessageKeys": ["g:2", "g:100", "g:1234", "hidden:99999"]]
        let configuration = SyncConfigurationPolicy.configuration(state: state)
        let groups = configuration["groups"] as! [[String: Any]]
        precondition(groups.count == 1 && groups[0]["loadedCount"] as? Int == 4)
        precondition(groups[0]["oldestId"] as? String == "2" && groups[0]["newestId"] as? String == "1234")
        var progressOnly = state
        progressOnly["revision"] = 1; progressOnly["progress"] = ["g": ["auto": ["messageId": "100", "offset": 99]]]
        precondition(!SyncConfigurationPolicy.inputsChanged(from: state, to: progressOnly))
        var changedCount = state; changedCount["messages"] = []
        precondition(SyncConfigurationPolicy.inputsChanged(from: state, to: changedCount))
        var changedScope = state; changedScope["groups"] = [["id": "g", "selected": false]]
        precondition(SyncConfigurationPolicy.inputsChanged(from: state, to: changedScope))
        var changedUnread = state; changedUnread["groups"] = [["id": "g", "selected": true, "unreadCount": 9]]
        precondition(SyncConfigurationPolicy.inputsChanged(from: state, to: changedUnread))
        var cleared = state; cleared["cleanup"] = ["suppressedMessageKeys": ["g:2"]]
        precondition(SyncConfigurationPolicy.inputsChanged(from: state, to: cleared))

        state["messages"] = (0..<10_000).map { ["groupId": "g", "id": String($0), "text": "Synthetic content"] }
        var scrolling = state; scrolling["progress"] = ["g": ["auto": ["messageId": "1", "offset": 12]]]
        let start = Date()
        for _ in 0..<1_000 { precondition(!SyncConfigurationPolicy.inputsChanged(from: state, to: scrolling)) }
        print("PASS: concurrent state isolation, revision monotonicity, reversible validation, suppressed sync bounds; 1,000 progress checks on 10,000 messages: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }
}
