import Foundation

@main struct CacheCleanerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cleanup-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let media = root.appendingPathComponent("media"), recoveries = root.appendingPathComponent("recoveries"), trash = root.appendingPathComponent("trash")
        for directory in [media, recoveries, trash] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let cleaner = CacheCleaner(directory: media, recoveryDirectory: recoveries, trashDirectory: trash) { original in
            let target = trash.appendingPathComponent(UUID().uuidString + "-" + original.lastPathComponent)
            try fm.moveItem(at: original, to: target); return target
        }
        let remote = "https://wx1.sinaimg.cn/test.png", account = "fixture-account"
        let folder = media.appendingPathComponent(MediaPolicy.cacheKey(accountId: account, url: remote))
        let payload = try MediaPolicy.payloadURL(in: folder, name: "test.png")
        try fm.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("12345678".utf8).write(to: payload)
        try JSONSerialization.data(withJSONObject: ["name": "test.png", "mime": "image/png"]).write(to: folder.appendingPathComponent("asset.json"))
        let imported = try WorkspacePolicy.importDirectory(base: media, accountId: account).appendingPathComponent(UUID().uuidString).appendingPathComponent("test.pdf")
        try fm.createDirectory(at: imported.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("demo-pdf".utf8).write(to: imported)
        let refs: [[String: Any]] = [["kind": "image", "url": remote], ["kind": "image", "url": "http://wx1.sinaimg.cn/test.png#copy"], ["kind": "document", "localPath": imported.path]]
        let plan = try cleaner.preview(accountId: account, refs: refs)
        precondition(plan.items.count == 2 && plan.json["bytes"] as? Int64 == 16)
        precondition(plan.json["images"] as? Int == 1 && plan.json["documents"] as? Int == 1)
        precondition(fm.fileExists(atPath: payload.path) && fm.fileExists(atPath: imported.path))
        let state: [String: Any] = ["accountId": account, "version": 1, "revision": 7, "messages": [["id": "test"]]]
        let receipt = try cleaner.trash(plan: plan, beforeState: state)
        precondition(receipt.fileCount == 2 && !fm.fileExists(atPath: folder.path) && !fm.fileExists(atPath: imported.path))
        let latest = try cleaner.latestRecovery(accountId: account)
        precondition(latest?["id"] as? String == receipt.id)
        let last = try cleaner.lastReceipt(accountId: account)
        precondition((last?["beforeState"] as? [String: Any])?["revision"] as? Int == 7)
        precondition((last?["refs"] as? [[String: Any]])?.count == 3)
        let before = receipt.directory.appendingPathComponent("before.json")
        let permissions = try fm.attributesOfItem(atPath: before.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let result = try cleaner.restore(id: receipt.id, accountId: account)
        precondition(result.beforeState["revision"] as? Int == 7 && result.warnings.isEmpty)
        let restoredData = try Data(contentsOf: payload)
        precondition(restoredData == Data("12345678".utf8))
        precondition(fm.fileExists(atPath: imported.path))
        let afterRestore = try cleaner.latestRecovery(accountId: account)
        precondition(afterRestore == nil)

        // Text-only cleanup still has a durable, undoable snapshot.
        let empty = try cleaner.preview(accountId: account, refs: [])
        let textReceipt = try cleaner.trash(plan: empty, beforeState: state)
        precondition(textReceipt.fileCount == 0)
        let textRestored = try cleaner.restore(id: textReceipt.id, accountId: account)
        precondition(textRestored.beforeState["revision"] as? Int == 7)

        // Undo stays discoverable until the frontend's merged state is durable.
        let pendingUndo = try cleaner.trash(plan: empty, beforeState: state)
        _ = try cleaner.restore(id: pendingUndo.id, accountId: account, markRestored: false)
        let stillActive = try cleaner.latestRecovery(accountId: account)
        precondition(stillActive?["id"] as? String == pendingUndo.id)
        try cleaner.completeRestore(id: pendingUndo.id, accountId: account)
        let completedUndo = try cleaner.latestRecovery(accountId: account)
        precondition(completedUndo == nil)

        // Other accounts, arbitrary paths and symlink escapes cannot be deleted.
        let outside = root.appendingPathComponent("private.txt"); try Data("private".utf8).write(to: outside)
        let symlink = imported.deletingLastPathComponent().appendingPathComponent("link.pdf")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: outside)
        for bad in [outside.path, symlink.path] {
            do { _ = try cleaner.preview(accountId: account, refs: [["kind": "document", "localPath": bad]]); fatalError("outside file accepted") } catch {}
        }
        do { _ = try cleaner.preview(accountId: "other-account", refs: [["kind": "document", "localPath": imported.path]]); fatalError("cross-account import accepted") } catch {}
        do { _ = try cleaner.restore(id: receipt.id, accountId: "other-account"); fatalError("cross-account restore accepted") } catch {}
        do { _ = try cleaner.preview(accountId: account, refs: [["kind": "image", "url": "https://evil.example/test.png"]]); fatalError("external URL accepted") } catch {}
        let outsideData = try Data(contentsOf: outside)
        precondition(outsideData == Data("private".utf8))

        // A mid-batch failure rolls back every earlier move.
        var count = 0
        let failing = CacheCleaner(directory: media, recoveryDirectory: recoveries, trashDirectory: trash) { original in
            count += 1
            if count == 2 { throw ReaderError.message("fixture failure") }
            let target = trash.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(at: original, to: target); return target
        }
        do { _ = try failing.trash(plan: plan, beforeState: state); fatalError("expected trash failure") } catch {}
        precondition(fm.fileExists(atPath: payload.path) && fm.fileExists(atPath: imported.path))

        // New files created after cleanup are preserved by undo.
        let again = try cleaner.trash(plan: plan, beforeState: state)
        try fm.createDirectory(at: imported.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("newer-file".utf8).write(to: imported)
        let newer = try cleaner.restore(id: again.id, accountId: account)
        let newerData = try Data(contentsOf: imported)
        precondition(!newer.warnings.isEmpty && newerData == Data("newer-file".utf8))
        print("PASS: cleanup previews, category counts, private recovery snapshots, reversible trash, rollback and scoped path protection")
    }
}
