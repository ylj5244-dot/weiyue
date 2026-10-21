import Foundation

// Synthetic-only benchmark. Build with the same optimization as the release:
// swiftc -O Sources/Store.swift tests/StorePerformanceBenchmark.swift -o build/store-performance
// Run without arguments for a report; --check enforces a deliberately generous
// regression budget rather than a device-specific subsecond target.
@main struct StorePerformanceBenchmark {
    static let account = "synthetic-save-performance"
    static let stamp = "2026-10-19T00:00:00.000Z"
    static func fixture(count: Int) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.date(from: stamp)!
        var state = StateStore.empty(accountId: account)
        state["revision"] = 1
        state["groups"] = [["id": "g", "accountId": account, "name": "Synthetic", "selected": true]]
        let messages: [[String: Any]] = (0..<count).map { index in
            var message: [String: Any] = ["id": String(9_007_199_254_740_993 + index), "accountId": account, "groupId": "g", "senderId": "u-\(index % 30)"]
            message["senderName"] = "合成成员 \(index % 30)"
            message["text"] = "消息 \(index) " + String(repeating: "完整消息与 English analysis。", count: 10)
            message["sentAt"] = formatter.string(from: start.addingTimeInterval(Double(index)))
            message["attachments"] = index % 10 == 0 ? [["type": "image", "url": "https://example.com/\(index).jpg"]] : []
            return message
        }
        state["messages"] = messages
        state["bookmarks"] = messages.prefix(200).enumerated().map { index, message in
            ["id": "bookmark-\(index)", "accountId": account, "groupId": "g", "messageId": message["id"]!,
             "createdAt": stamp, "messageSentAt": message["sentAt"]!, "note": "合成备注 \(index)",
             "snapshot": message, "deletedAt": NSNull()] as [String: Any]
        }
        return state
    }
    static func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func main() throws {
        var failed = false
        for count in [6_000, 10_000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-save-benchmark-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try StateStore(directory: root)
            var state = fixture(count: count)
            let initial = try milliseconds { try store.save(state: state, accountId: account) }
            var samples: [Double] = []
            for revision in 2...4 {
                state["revision"] = revision
                state["progress"] = ["g": ["manual": ["accountId": account, "groupId": "g", "messageId": String(9_007_199_254_740_993 + count - revision), "offset": 0, "updatedAt": stamp]]]
                samples.append(try milliseconds { try store.save(state: state, accountId: account) })
            }
            let retry = try milliseconds { try store.save(state: state, accountId: account) }
            let restart = try StateStore(directory: root)
            let reopen = try milliseconds {
                let loaded = try restart.load(accountId: account)
                precondition((loaded.state["messages"] as? [Any])?.count == count)
                precondition(loaded.state["revision"] as? Int == 4)
            }
            let median = samples.sorted()[samples.count / 2]
            let report: [String: Any] = ["messages": count, "bytes": try Data(contentsOf: store.fileURL(accountId: account)).count,
                                       "firstSaveMs": initial, "toggleSaveMs": samples, "toggleMedianMs": median,
                                       "idempotentSaveMs": retry, "restartLoadMs": reopen]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            // This must fail for the repeated full-validation implementation.
            // It still permits substantial variance on a busy developer machine.
            if CommandLine.arguments.contains("--check"), median > 1_500 { failed = true }
        }
        if failed { fputs("FAIL: repeated small edits exceed the 1500 ms save budget\n", stderr); exit(1) }
    }
}
