import Foundation
import CoreFoundation

struct RetentionPlan {
    var state: [String: Any]
    let refs: [[String: Any]]
    let removedCount: Int
    let protectedCount: Int
    let cutoff: Date
}

enum RetentionPolicy {
    static func settings(_ state: [String: Any]) throws -> (enabled: Bool, days: Int) {
        guard let value = (state["settings"] as? [String: Any])?["autoCleanup"] as? [String: Any] else { return (false, 3) }
        guard let flag = value["enabled"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let days = value["retentionDays"] as? NSNumber, CFGetTypeID(days) != CFBooleanGetTypeID(),
              days.doubleValue.rounded() == days.doubleValue, (1...4).contains(days.intValue) else {
            throw ReaderError.message("自动清理设置无效，请重新选择保留天数。")
        }
        return (flag.boolValue, days.intValue)
    }

    private static func messageKey(_ message: [String: Any]) -> String {
        (message["groupId"] as? String ?? "") + ":" + (message["id"] as? String ?? "")
    }
    static func assetKey(_ ref: [String: Any]) -> String? {
        guard ref["localPath"] == nil, let raw = ref["url"] as? String,
              let url = try? MediaPolicy.remoteURL(raw) else { return nil }
        return url.absoluteString
    }
    private static func assets(_ message: [String: Any]) -> [[String: Any]] {
        guard message["localPath"] == nil else { return [] }
        return (message["attachments"] as? [[String: Any]] ?? []).compactMap { attachment in
            guard let type = attachment["type"] as? String, ["image", "document", "video"].contains(type),
                  let raw = attachment["url"] as? String,
                  let url = try? MediaPolicy.remoteURL(raw) else { return nil }
            return ["kind": type == "image" ? "image" : "document", "url": url.absoluteString]
        }
    }

    static func plan(state: [String: Any], protectedMessages: [[String: Any]] = [], now: Date = Date()) throws -> RetentionPlan {
        let preference = try settings(state)
        guard preference.enabled, let account = state["accountId"] as? String, !account.isEmpty else { throw ReaderError.message("自动清理未开启。") }
        let formatter = ISO8601DateFormatter(), fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> Date? { guard let text = value as? String else { return nil }; return fractions.date(from: text) ?? formatter.date(from: text) }
        let cutoff = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1000) / 1000 - Double(preference.days) * 86400)
        var protectedKeys = Set<String>(), snapshots = protectedMessages.filter { $0["accountId"] as? String == account }
        for item in state["bookmarks"] as? [[String: Any]] ?? [] {
            if let group = item["groupId"] as? String, let id = item["messageId"] as? String { protectedKeys.insert(group + ":" + id) }
            if let snapshot = item["snapshot"] as? [String: Any] { snapshots.append(snapshot) }
        }
        for item in state["collections"] as? [[String: Any]] ?? [] {
            (item["messageIds"] as? [String] ?? []).forEach { protectedKeys.insert($0) }
            snapshots += item["messages"] as? [[String: Any]] ?? []
        }
        for item in state["discussions"] as? [[String: Any]] ?? [] { snapshots += item["contextSnapshots"] as? [[String: Any]] ?? [] }
        snapshots.forEach { protectedKeys.insert(messageKey($0)) }
        for (group, anchors) in state["progress"] as? [String: [String: [String: Any]]] ?? [:] {
            for anchor in anchors.values { if let id = anchor["messageId"] as? String { protectedKeys.insert(group + ":" + id) } }
        }
        let messages = state["messages"] as? [[String: Any]] ?? []
        var kept: [[String: Any]] = [], expired: [[String: Any]] = [], protectedCount = 0
        for message in messages {
            guard let stamp = date(message["sentAt"]), stamp < cutoff, message["localPath"] == nil,
                  message["groupId"] as? String != "local-files" else { kept.append(message); continue }
            if protectedKeys.contains(messageKey(message)) { protectedCount += 1; kept.append(message) }
            else { expired.append(message) }
        }
        var cleanup = state["cleanup"] as? [String: Any] ?? [:]
        let protectedAssets = Set((kept + snapshots).flatMap(assets).compactMap(assetKey))
        var candidates: [String: [String: Any]] = [:]
        let pending = cleanup["autoPendingAssets"] as? [[String: Any]] ?? []
        for ref in expired.flatMap(assets) + pending {
            guard let key = assetKey(ref), !protectedAssets.contains(key), ["image", "document"].contains(ref["kind"] as? String ?? "") else { continue }
            candidates[key] = ["kind": ref["kind"]!, "url": key]
        }
        // A compact watermark prevents old history from filling the cache again.
        // Existing protected messages remain mergeable, even behind the watermark.
        let prior = date(cleanup["autoCutoffAt"]) ?? Date.distantPast
        cleanup["autoCutoffAt"] = fractions.string(from: max(prior, cutoff))
        let refs = candidates.keys.sorted().compactMap { candidates[$0] }
        cleanup["autoPendingAssets"] = refs
        cleanup["lastAutoCleanedAt"] = formatter.string(from: now)
        var result = state
        result["messages"] = kept
        result["cleanup"] = cleanup
        result["revision"] = (state["revision"] as? Int ?? 0) + 1
        var settings = state["settings"] as? [String: Any] ?? [:]
        var auto = settings["autoCleanup"] as? [String: Any] ?? [:]
        auto["lastRunAt"] = formatter.string(from: now)
        auto["lastRemovedCount"] = expired.count
        auto["lastFreedBytes"] = 0
        auto["lastError"] = ""
        settings["autoCleanup"] = auto
        result["settings"] = settings
        return RetentionPlan(state: result, refs: refs, removedCount: expired.count, protectedCount: protectedCount, cutoff: cutoff)
    }
}
