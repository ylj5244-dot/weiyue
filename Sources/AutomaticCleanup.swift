import Foundation

enum AutomaticCleanup {
    // Run only on the serial storage queue, after downloads and frontend writes
    // are paused. The first commit preserves retry references across a crash.
    static func run(store: StateStore, cleaner: CacheCleaner, accountId: String,
                    revision: Int, protectedMessages: [[String: Any]], now: Date = Date()) throws -> [String: Any] {
        let before = try store.load(accountId: accountId).state
        guard before["revision"] as? Int == revision else { throw ReaderError.message("资料正在更新，自动清理将稍后重试。") }
        let plan = try RetentionPolicy.plan(state: before, protectedMessages: protectedMessages, now: now)
        try store.save(state: plan.state, accountId: accountId)
        var committed = plan.state
        do { try store.compactBackup(state: committed, accountId: accountId) }
        catch { return ["state": committed, "warning": "记录已整理，备份更新未完成，缓存文件保留，稍后重试。"] }
        let removed = cleaner.removeExpiredRemote(accountId: accountId, refs: plan.refs)
        var next = committed, cleanup = next["cleanup"] as? [String: Any] ?? [:]
        cleanup["autoPendingAssets"] = removed.pending; next["cleanup"] = cleanup
        var settings = next["settings"] as? [String: Any] ?? [:], auto = settings["autoCleanup"] as? [String: Any] ?? [:]
        auto["lastFreedBytes"] = removed.bytes
        auto["lastError"] = removed.warnings.isEmpty ? "" : "部分缓存未清理，将稍后重试。"
        settings["autoCleanup"] = auto; next["settings"] = settings
        next["revision"] = (committed["revision"] as? Int ?? 0) + 1
        do {
            try store.save(state: next, accountId: accountId); committed = next
            try store.compactBackup(state: next, accountId: accountId)
        } catch {
            // Never send the pre-cleanup revision to the frontend after a commit.
            return ["state": committed, "warning": "自动清理已执行，结果统计暂未完整保存，将稍后重试。"]
        }
        return ["state": committed, "warning": auto["lastError"] ?? "", "protectedCount": plan.protectedCount]
    }
}
