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

        // Saves and retention compactions can interleave between accounts. A
        // stale compaction may fail, but must never rotate away a newer state or
        // accept another account's cached validation result.
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let account = "compact-\(index % 2)", revision = index / 2 + 1
            var candidate = StateStore.empty(accountId: account)
            candidate["revision"] = revision
            candidate["groups"] = [["id": "g", "accountId": account, "name": "Synthetic", "selected": true]]
            candidate["messages"] = [["id": "m-\(revision)", "accountId": account, "groupId": "g", "senderId": "u", "senderName": "Synthetic", "text": "Revision \(revision)", "sentAt": "2026-10-19T00:00:00.000Z", "attachments": []]]
            do {
                try store.save(state: candidate, accountId: account)
                try store.compactBackup(state: candidate, accountId: account)
            } catch { /* Newer concurrent work must reject a stale save/compaction. */ }
        }
        for account in ["compact-0", "compact-1"] {
            let accepted = try store.load(accountId: account).state
            precondition(accepted["revision"] as? Int == 20)
            let messages = accepted["messages"] as! [[String: Any]]
            precondition(messages.count == 1 && messages[0]["accountId"] as? String == account)
            try store.compactBackup(state: accepted, accountId: account)
            let file = store.fileURL(accountId: account)
            let mainBytes = try Data(contentsOf: file), backupBytes = try Data(contentsOf: file.appendingPathExtension("backup"))
            precondition(mainBytes == backupBytes)
        }

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
        print("PASS: concurrent state isolation, revision monotonicity, safe backup compaction, reversible validation, suppressed sync bounds; 1,000 progress checks on 10,000 messages: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }
}
