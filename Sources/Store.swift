import Foundation
import CryptoKit
import CoreFoundation

enum ReaderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct StateLoad {
    let state: [String: Any]
    let warning: String?
}

private struct StateValidator {
    let accountId: String
    private var dates: [String: Date] = [:]
    private let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let withoutFractions = ISO8601DateFormatter()
    init(accountId: String) { self.accountId = accountId }
    private func invalid(_ field: String) -> ReaderError {
        .message("本地资料字段无效：\(field)。原文件已保留，未用空数据覆盖。")
    }
    private func record(_ value: Any?, _ field: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw invalid(field) }
        return result
    }
    private func list(_ value: Any?, _ field: String) throws -> [Any] {
        guard let result = value as? [Any] else { throw invalid(field) }
        return result
    }
    @discardableResult private func text(_ value: Any?, _ field: String, empty: Bool = false) throws -> String {
        guard let result = value as? String, empty || !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid(field) }
        return result
    }
    @discardableResult private func limitedText(_ value: Any?, _ field: String, maximum: Int, empty: Bool = false) throws -> String {
        let result = try text(value, field, empty: empty)
        guard result.utf16.count <= maximum else { throw invalid(field + " 长度超过 \(maximum)") }
        return result
    }
    private func allowedFields(_ value: [String: Any], _ fields: Set<String>, _ field: String) throws {
        guard Set(value.keys).isSubset(of: fields) else { throw invalid(field + " 未知字段") }
    }
    private func preferences(_ raw: Any) throws {
        let library = try record(raw, "settings.aiPreferences")
        try allowedFields(library, ["version", "entries", "quickPrompts"], "settings.aiPreferences")
        guard try integer(library["version"], "preferences.version") == 1 else { throw invalid("preferences.version") }
        var total = 0
        for (key, limit, contentKey) in [("entries", 100, "content"), ("quickPrompts", 50, "prompt")] {
            let items = try list(library[key], "preferences." + key)
            guard items.count <= limit else { throw invalid("preferences." + key + " 数量超过 \(limit)") }
            var ids: [String] = []
            for rawItem in items {
                let item = try record(rawItem, "preferences." + key)
                let fields: Set<String> = key == "entries" ? ["id", "title", "category", "content", "enabled"] : ["id", "title", "prompt", "enabled"]
                try allowedFields(item, fields, "preferences." + key)
                ids.append(try limitedText(item["id"], "preferences.id", maximum: 160))
                total += try limitedText(item["title"], "preferences.title", maximum: 120).utf16.count
                total += try limitedText(item[contentKey], "preferences." + contentKey, maximum: 12000).utf16.count
                guard let enabled = item["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() else { throw invalid("preferences.enabled") }
                if key == "entries" {
                    guard ["writing", "format", "other"].contains(try text(item["category"], "preferences.category")) else { throw invalid("preferences.category") }
                }
            }
            try unique(ids, "preferences." + key)
        }
        guard total <= 60000 else { throw invalid("preferences 总文字长度超过 60000") }
    }
    private func number(_ value: Any?, _ field: String) throws -> Double {
        guard let result = value as? NSNumber, CFGetTypeID(result) != CFBooleanGetTypeID(), result.doubleValue.isFinite else { throw invalid(field) }
        return result.doubleValue
    }
    private func integer(_ value: Any?, _ field: String) throws -> Int {
        let result = try number(value, field)
        guard result >= 0, result <= 9_007_199_254_740_991, result.rounded(.towardZero) == result else { throw invalid(field) }
        return Int(result)
    }
    private func identity(_ value: [String: Any], _ field: String) throws {
        guard !accountId.isEmpty, value["accountId"] as? String == accountId else { throw invalid(field + ".accountId") }
    }
    @discardableResult private mutating func date(_ value: Any?, _ field: String) throws -> Date {
        let raw = try text(value, field)
        if let parsed = dates[raw] { return parsed }
        guard raw.contains("T"), let parsed = withFractions.date(from: raw) ?? withoutFractions.date(from: raw) else { throw invalid(field) }
        dates[raw] = parsed
        return parsed
    }
    private func unique(_ keys: [String], _ field: String) throws {
        guard keys.count == Set(keys).count else { throw invalid(field + " 重复 id") }
    }
    @discardableResult private mutating func message(_ raw: Any, _ field: String) throws -> [String: Any] {
        let value = try record(raw, field)
        try identity(value, field)
        for key in ["id", "groupId", "senderId"] { try text(value[key], field + "." + key) }
        for key in ["senderName", "text"] { try text(value[key], field + "." + key, empty: true) }
        try date(value["sentAt"], field + ".sentAt")
        for attachment in try list(value["attachments"], field + ".attachments") { _ = try record(attachment, field + ".attachment") }
        if let url = value["sourceURL"] { try text(url, field + ".sourceURL", empty: true) }
        return value
    }
    private func key(_ value: [String: Any]) -> String { (value["groupId"] as! String) + ":" + (value["id"] as! String) }
    private func publicWebSource(_ raw: String) -> Bool {
        guard raw.utf16.count <= 8192, !raw.contains("\\"), !raw.contains(where: { $0.isWhitespace }),
              raw.rangeOfCharacter(from: .controlCharacters) == nil,
              let parts = URLComponents(string: raw), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, (parts.port == nil || (0...65535).contains(parts.port!)),
              let url = parts.url, let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard host.utf16.count <= 253, labels.count > 1, !host.contains(":"),
              !["localhost", "local", "internal", "lan", "home"].contains(labels.last ?? ""),
              labels.allSatisfy({ $0.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil }) else { return false }
        if labels.last?.allSatisfy({ $0.isNumber }) == true {
            let numbers = labels.compactMap(Int.init)
            guard labels.count == 4, numbers.count == 4,
                  zip(labels, numbers).allSatisfy({ $0.0 == String($0.1) && $0.1 <= 255 }) else { return false }
            let a = numbers[0], b = numbers[1], c = numbers[2]
            if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) || (a == 192 && b == 0 && [0, 2].contains(c)) || (a == 192 && b == 88 && c == 99) || (a == 198 && [18, 19].contains(b)) || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113) { return false }
        }
        return true
    }
    private mutating func webDate(_ raw: Any?, _ field: String) throws {
        let value = try text(raw, field)
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { throw invalid(field) }
        try date(value, field)
    }
    private mutating func unreadDate(_ raw: Any?, _ field: String) throws {
        try webDate(raw, field)
        let value = try text(raw, field)
        // ISO8601DateFormatter can normalize nonexistent dates such as February 30.
        // A reading acknowledgement must retain an actual, unambiguous wall time.
        let parts = value.prefix(19).split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == ":" }).compactMap { Int($0) }
        guard parts.count == 6 else { throw invalid(field) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let requested = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        guard let instant = calendar.date(from: requested) else { throw invalid(field) }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        guard actual == requested else { throw invalid(field) }
    }
    private mutating func groupUnread(_ raw: Any, groupIds: Set<String>) throws {
        let unread = try record(raw, "settings.groupUnread")
        for (groupId, rawEntry) in unread {
            let field = "settings.groupUnread." + groupId
            guard groupIds.contains(groupId) else { throw invalid(field + " 群聊不存在") }
            let entry = try record(rawEntry, field)
            try allowedFields(entry, ["accountId", "groupId", "count", "acknowledgedAt", "baseline"], field)
            try identity(entry, field)
            guard try text(entry["groupId"], field + ".groupId") == groupId else { throw invalid(field + ".groupId 关联") }
            _ = try integer(entry["count"], field + ".count")
            try unreadDate(entry["acknowledgedAt"], field + ".acknowledgedAt")
            guard let rawBaseline = entry["baseline"] else { throw invalid(field + ".baseline") }
            if rawBaseline is NSNull { continue }
            let baseline = try record(rawBaseline, field + ".baseline")
            try allowedFields(baseline, ["id", "sentAt"], field + ".baseline")
            try limitedText(baseline["id"], field + ".baseline.id", maximum: 160)
            try unreadDate(baseline["sentAt"], field + ".baseline.sentAt")
        }
    }
    private mutating func webSearch(_ raw: Any) throws {
        let value = try record(raw, "discussion.webSearch")
        try allowedFields(value, ["status", "query", "searchedAt", "sources", "error"], "webSearch")
        let status = try text(value["status"], "webSearch.status")
        guard ["success", "empty", "failed"].contains(status) else { throw invalid("webSearch.status") }
        try limitedText(value["query"], "webSearch.query", maximum: 128, empty: true)
        try webDate(value["searchedAt"], "webSearch.searchedAt")
        let sources = try list(value["sources"], "webSearch.sources")
        guard sources.count <= 5, (status == "success") == !sources.isEmpty else { throw invalid("webSearch 状态与来源数量") }
        for (index, rawSource) in sources.enumerated() {
            let source = try record(rawSource, "webSearch.source")
            try allowedFields(source, ["id", "title", "url", "publishedAt", "siteName", "excerpt"], "webSearch.source")
            guard try text(source["id"], "webSearch.source.id") == "网页\(index + 1)" else { throw invalid("webSearch.source.id") }
            try limitedText(source["title"], "webSearch.source.title", maximum: 500, empty: true)
            let url = try limitedText(source["url"], "webSearch.source.url", maximum: 8192)
            guard publicWebSource(url) else { throw invalid("webSearch.source.url") }
            guard let published = source["publishedAt"] else { throw invalid("webSearch.source.publishedAt") }
            if !(published is NSNull) { try webDate(published, "webSearch.source.publishedAt") }
            try limitedText(source["siteName"], "webSearch.source.siteName", maximum: 300, empty: true)
            try limitedText(source["excerpt"], "webSearch.source.excerpt", maximum: 1200, empty: true)
        }
        if let error = value["error"] { try limitedText(error, "webSearch.error", maximum: 500, empty: true) }
    }
    private mutating func rangeSummary(_ raw: Any, discussion: [String: Any]) throws {
        let summary = try record(raw, "discussion.rangeSummary")
        try allowedFields(summary, ["version", "groupId", "startAt", "endAt", "label", "sourceCount", "coverage", "status", "batchCount", "completedBatches", "partials", "prompt", "stage", "round", "reductionCompleted", "finalText", "rounds", "error"], "rangeSummary")
        guard try integer(summary["version"], "rangeSummary.version") == 1 else { throw invalid("rangeSummary.version") }
        let groupId = try text(summary["groupId"], "rangeSummary.groupId")
        let from = try date(summary["startAt"], "rangeSummary.startAt"), to = try date(summary["endAt"], "rangeSummary.endAt")
        guard from <= to else { throw invalid("rangeSummary 起止时间") }
        try limitedText(summary["label"], "rangeSummary.label", maximum: 4096)
        try limitedText(summary["prompt"], "rangeSummary.prompt", maximum: 100000)
        let snapshots = try list(discussion["contextSnapshots"], "rangeSummary.contextSnapshots")
        let sourceCount = try integer(summary["sourceCount"], "rangeSummary.sourceCount")
        guard sourceCount > 0, sourceCount == snapshots.count else { throw invalid("rangeSummary.sourceCount 关联") }
        var previousTime = Date.distantPast, seen = Set<String>()
        for rawMessage in snapshots {
            let snapshot = try message(rawMessage, "rangeSummary.contextSnapshot")
            let stamp = try date(snapshot["sentAt"], "rangeSummary.snapshot.sentAt")
            let messageId = try text(snapshot["id"], "rangeSummary.snapshot.id")
            guard snapshot["groupId"] as? String == groupId, stamp >= from, stamp <= to, stamp >= previousTime,
                  !seen.contains(messageId) else { throw invalid("rangeSummary.contextSnapshot 出处、时间或顺序") }
            previousTime = stamp; seen.insert(messageId)
        }
        let coverage = try record(summary["coverage"], "rangeSummary.coverage")
        try allowedFields(coverage, ["complete", "reason", "from", "to", "checkedAt", "loadedCount", "pages"], "rangeSummary.coverage")
        guard let complete = coverage["complete"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID() else { throw invalid("rangeSummary.coverage.complete") }
        try limitedText(coverage["reason"], "rangeSummary.coverage.reason", maximum: 100000)
        try date(coverage["checkedAt"], "rangeSummary.coverage.checkedAt")
        guard try date(coverage["from"], "rangeSummary.coverage.from") == from,
              try date(coverage["to"], "rangeSummary.coverage.to") == to,
              try integer(coverage["loadedCount"], "rangeSummary.coverage.loadedCount") == sourceCount else { throw invalid("rangeSummary.coverage 范围或数量关联") }
        _ = try integer(coverage["pages"], "rangeSummary.coverage.pages")
        let status = try text(summary["status"], "rangeSummary.status")
        guard ["running", "complete", "failed", "interrupted"].contains(status) else { throw invalid("rangeSummary.status") }
        let batchCount = try integer(summary["batchCount"], "rangeSummary.batchCount")
        let completed = try integer(summary["completedBatches"], "rangeSummary.completedBatches")
        guard batchCount > 0, completed <= batchCount else { throw invalid("rangeSummary 批次数量") }
        let partials = try list(summary["partials"], "rangeSummary.partials")
        guard partials.count == completed else { throw invalid("rangeSummary.partials 数量关联") }
        for partial in partials { try limitedText(partial, "rangeSummary.partial", maximum: 1000000) }
        if let stage = summary["stage"] {
            guard ["map", "reduce"].contains(try text(stage, "rangeSummary.stage")) else { throw invalid("rangeSummary.stage") }
        }
        for key in ["round", "rounds"] {
            if let rawRound = summary[key] {
                let round = try integer(rawRound, "rangeSummary." + key)
                guard round >= 1, round <= 8 else { throw invalid("rangeSummary." + key) }
            }
        }
        if let reduced = summary["reductionCompleted"] { _ = try integer(reduced, "rangeSummary.reductionCompleted") }
        if let final = summary["finalText"] { try limitedText(final, "rangeSummary.finalText", maximum: 1000000) }
        if let error = summary["error"] { try limitedText(error, "rangeSummary.error", maximum: 100000, empty: true) }
        if status == "complete", completed != batchCount || summary["finalText"] == nil { throw invalid("rangeSummary 尚未完成全部批次") }
    }
    mutating func validate(_ state: [String: Any]) throws {
        guard try integer(state["version"], "version") == 1, state["accountId"] as? String == accountId else { throw invalid("version/accountId") }
        _ = try integer(state["revision"], "revision")
        let groups = try list(state["groups"], "groups")
        var groupIds: [String] = []
        for raw in groups {
            let group = try record(raw, "group"); try identity(group, "group")
            groupIds.append(try text(group["id"], "group.id"))
            try text(group["name"], "group.name", empty: true)
            guard let selected = group["selected"] as? NSNumber, CFGetTypeID(selected) == CFBooleanGetTypeID() else { throw invalid("group.selected") }
        }
        try unique(groupIds, "groups")
        var messageKeys: [String] = []
        for raw in try list(state["messages"], "messages") { messageKeys.append(key(try message(raw, "message"))) }
        try unique(messageKeys, "messages")
        var bookmarkIds: [String] = []
        for raw in try list(state["bookmarks"], "bookmarks") {
            let bookmark = try record(raw, "bookmark"); try identity(bookmark, "bookmark")
            bookmarkIds.append(try text(bookmark["id"], "bookmark.id"))
            let groupId = try text(bookmark["groupId"], "bookmark.groupId")
            let messageId = try text(bookmark["messageId"], "bookmark.messageId")
            try text(bookmark["note"], "bookmark.note", empty: true)
            try date(bookmark["createdAt"], "bookmark.createdAt")
            let messageTime = try date(bookmark["messageSentAt"], "bookmark.messageSentAt")
            guard let snapshotRaw = bookmark["snapshot"] else { throw invalid("bookmark.snapshot") }
            let snapshot = try message(snapshotRaw, "bookmark.snapshot")
            guard snapshot["id"] as? String == messageId, snapshot["groupId"] as? String == groupId,
                  try date(snapshot["sentAt"], "bookmark.snapshot.sentAt") == messageTime else { throw invalid("bookmark.snapshot 关联") }
            if let deletedAt = bookmark["deletedAt"], !(deletedAt is NSNull) { try date(deletedAt, "bookmark.deletedAt") }
        }
        try unique(bookmarkIds, "bookmarks")
        var collectionIds: [String] = []
        for raw in try list(state["collections"], "collections") {
            let collection = try record(raw, "collection"); try identity(collection, "collection")
            collectionIds.append(try text(collection["id"], "collection.id"))
            try text(collection["name"], "collection.name")
            try date(collection["createdAt"], "collection.createdAt")
            if let deletedAt = collection["deletedAt"], !(deletedAt is NSNull) { try date(deletedAt, "collection.deletedAt") }
            let references = try list(collection["messageIds"], "collection.messageIds").map { try text($0, "collection.messageId") }
            var snapshotKeys: [String] = []
            for rawMessage in try list(collection["messages"], "collection.messages") { snapshotKeys.append(key(try message(rawMessage, "collection.message"))) }
            guard references == snapshotKeys else { throw invalid("collection.messages 关联") }
            try unique(references, "collection.messageIds")
            if let discussionId = collection["discussionId"], !(discussionId is NSNull) { try text(discussionId, "collection.discussionId") }
        }
        try unique(collectionIds, "collections")
        let progress = try record(state["progress"], "progress")
        for (groupId, raw) in progress {
            try text(groupId, "progress.groupId")
            for (kind, rawAnchor) in try record(raw, "progress.group") {
                guard ["auto", "manual", "sessionStart", "returnPoint", "standbyView"].contains(kind) else { throw invalid("progress.kind") }
                let anchor = try record(rawAnchor, "progress.anchor"); try identity(anchor, "progress.anchor")
                guard anchor["groupId"] as? String == groupId else { throw invalid("progress.groupId 关联") }
                try text(anchor["messageId"], "progress.messageId")
                guard try number(anchor["offset"], "progress.offset") >= 0 else { throw invalid("progress.offset") }
                try date(anchor["updatedAt"], "progress.updatedAt")
                if let messageSentAt = anchor["messageSentAt"] { try unreadDate(messageSentAt, "progress.messageSentAt") }
            }
        }
        var discussionIds: [String] = []
        for raw in try list(state["discussions"], "discussions") {
            let discussion = try record(raw, "discussion"); try identity(discussion, "discussion")
            discussionIds.append(try text(discussion["id"], "discussion.id"))
            for field in ["createdAt", "updatedAt"] { if let value = discussion[field] { try date(value, "discussion." + field) } }
            if let rawInfo=discussion["titleInfo"] {
                let info=try record(rawInfo,"discussion.titleInfo")
                guard try integer(info["version"],"discussion.titleInfo.version")==1,
                      info["source"] as? String == "ai",
                      let fingerprint=info["fingerprint"] as? String,
                      fingerprint.range(of:"^[a-f0-9]{16}$",options:.regularExpression) != nil else { throw invalid("discussion.titleInfo") }
                try limitedText(info["model"],"discussion.titleInfo.model",maximum:240,empty:true)
                try date(info["generatedAt"],"discussion.titleInfo.generatedAt")
                let title=try text(discussion["title"],"discussion.title")
                guard title.unicodeScalars.count<=32 else { throw invalid("discussion.title length") }
            }
            if let deletedAt = discussion["deletedAt"], !(deletedAt is NSNull) { try date(deletedAt, "discussion.deletedAt") }
            if let instructions = discussion["instructions"] { try limitedText(instructions, "discussion.instructions", maximum: 12000, empty: true) }
            if let summary = discussion["rangeSummary"] { try rangeSummary(summary, discussion: discussion) }
            if let collectionId = discussion["collectionId"], !(collectionId is NSNull) { try text(collectionId, "discussion.collectionId") }
            if let snapshots = discussion["contextSnapshots"] {
                for rawMessage in try list(snapshots, "discussion.contextSnapshots") { try message(rawMessage, "discussion.contextSnapshot") }
            }
            if let turns = discussion["messages"] {
                for rawTurn in try list(turns, "discussion.messages") {
                    let turn = try record(rawTurn, "discussion.turn")
                    guard ["user", "assistant", "system"].contains(try text(turn["role"], "discussion.role")) else { throw invalid("discussion.role") }
                    try text(turn["content"], "discussion.content", empty: true)
                    if let createdAt = turn["createdAt"] { try date(createdAt, "discussion.turn.createdAt") }
                    if let error = turn["error"] { try text(error, "discussion.turn.error", empty: true) }
                    if let search = turn["webSearch"] {
                        guard turn["role"] as? String == "assistant" else { throw invalid("discussion.webSearch role") }
                        try webSearch(search)
                    }
                }
            }
        }
        try unique(discussionIds, "discussions")
        let settings = try record(state["settings"], "settings")
        for field in ["baseURL", "model"] { try text(settings[field], "settings." + field, empty: true) }
        if let library = settings["aiPreferences"] { try preferences(library) }
        if let instructions = settings["aiDraftInstructions"] { try limitedText(instructions, "settings.aiDraftInstructions", maximum: 12000, empty: true) }
        if let active = settings["activeDiscussionId"], !(active is NSNull) { try limitedText(active, "settings.activeDiscussionId", maximum: 160) }
        if let enabled = settings["webSearchEnabled"] {
            guard let flag = enabled as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw invalid("settings.webSearchEnabled") }
        }
        if let enabled = settings["readerStandby"] {
            guard let flag = enabled as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw invalid("settings.readerStandby") }
        }
        if let unread = settings["groupUnread"] { try groupUnread(unread, groupIds: Set(groupIds)) }
    }
}

final class StateStore {
    let directory: URL
    private let lock = NSRecursiveLock()
    private var highestRevision: [String: Int] = [:]
    private var acceptedData: [String: Data] = [:]
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    static func empty(accountId: String) -> [String: Any] {
        ["version": 1, "revision": 0, "accountId": accountId, "groups": [], "messages": [],
         "bookmarks": [], "collections": [], "progress": [:], "discussions": [],
         "settings": ["baseURL": "", "model": ""]]
    }
    func fileURL(accountId: String) -> URL {
        let hash = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("account-\(hash).json")
    }
    private func decode(_ data: Data, accountId: String) throws -> [String: Any] {
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ReaderError.message("本地资料格式不完整。原文件已保留，未用空数据覆盖。") }
        var validator = StateValidator(accountId: accountId)
        try validator.validate(state)
        return state
    }
    private func canonical(_ state: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(state) else { throw ReaderError.message("资料包含无法保存的值，原文件未更改。") }
        return try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    }
    private func remember(_ state: [String: Any], accountId: String) throws {
        highestRevision[accountId] = state["revision"] as? Int
        acceptedData[accountId] = try canonical(state)
    }
    private func verifiedWrite(_ data: Data, to file: URL, accountId: String) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let persisted = try decode(Data(contentsOf: file), accountId: accountId)
        guard try canonical(persisted) == data else { throw ReaderError.message("保存后验证失败。请保留资料文件并重试。") }
    }
    func load(accountId: String) throws -> StateLoad {
        lock.lock(); defer { lock.unlock() }
        let file = fileURL(accountId: accountId)
        let backup = file.appendingPathExtension("backup")
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: backup.path) {
            return StateLoad(state: Self.empty(accountId: accountId), warning: nil)
        }
        if let data = try? Data(contentsOf: file), let state = try? decode(data, accountId: accountId) {
            try remember(state, accountId: accountId)
            return StateLoad(state: state, warning: nil)
        }
        if let data = try? Data(contentsOf: backup), let state = try? decode(data, accountId: accountId) {
            try remember(state, accountId: accountId)
            return StateLoad(state: state, warning: "主资料文件无法读取，已恢复上一次安全备份；最近一次操作可能需要重新完成。")
        }
        throw ReaderError.message("本地资料及备份无法读取。已保留原文件，请不要重新初始化资料。")
    }
    func save(state: [String: Any], accountId: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !accountId.isEmpty else { throw ReaderError.message("请先登录微博，再保存账号资料。") }
        let data = try canonical(state)
        let valid = try decode(data, accountId: accountId)
        let revision = valid["revision"] as! Int
        let file = fileURL(accountId: accountId)
        let backupFile = file.appendingPathExtension("backup")
        let existingData = try? Data(contentsOf: file)
        let existing = existingData.flatMap { try? decode($0, accountId: accountId) }
        let backup = (try? Data(contentsOf: backupFile)).flatMap { try? decode($0, accountId: accountId) }
        let filesExist = FileManager.default.fileExists(atPath: file.path) || FileManager.default.fileExists(atPath: backupFile.path)
        guard !filesExist || existing != nil || backup != nil else {
            throw ReaderError.message("现有资料及备份无法验证，已拒绝覆盖唯一原文件。请先恢复资料。")
        }
        let latest = max(highestRevision[accountId] ?? -1, max(existing?["revision"] as? Int ?? -1, backup?["revision"] as? Int ?? -1))
        guard revision >= latest else { throw ReaderError.message("较旧的保存请求已拒绝，现有阅读进度未被覆盖。") }
        if revision == latest {
            let reference = [existing, backup].compactMap { $0 }.first { $0["revision"] as? Int == latest }
            if let reference, try canonical(reference) != data {
                throw ReaderError.message("相同版本包含不同资料，已拒绝覆盖现有快照。请重新载入后再保存。")
            }
            if highestRevision[accountId] == latest, let accepted = acceptedData[accountId], accepted != data {
                throw ReaderError.message("相同版本包含不同资料，已拒绝覆盖已确认的快照。")
            }
        }
        if let existing, try canonical(existing) == data {
            // A flush retry is idempotent: retain the previous recoverable revision.
            if backup == nil { try verifiedWrite(data, to: backupFile, accountId: accountId) }
            try remember(valid, accountId: accountId)
            return
        }
        if let existing, (existing["revision"] as? Int ?? -1) >= (backup?["revision"] as? Int ?? -1) {
            try verifiedWrite(canonical(existing), to: backupFile, accountId: accountId)
        } else if backup == nil {
            // Establish recovery before the first main write; do not rotate a good
            // backup to a damaged main when repairing a recovered account.
            try verifiedWrite(data, to: backupFile, accountId: accountId)
        }
        try verifiedWrite(data, to: file, accountId: accountId)
        try remember(valid, accountId: accountId)
    }
    func validate(state: [String: Any], accountId: String) throws {
        // Validation is side-effect free and lets destructive-looking transactions
        // reject a malformed target before moving any recoverable files.
        _ = try decode(canonical(state), accountId: accountId)
    }
}

// Synchronization depends on scope and message boundaries, not every saved
// reading pixel. Keep the cheap change check on main; build bounds off main.
enum SyncConfigurationPolicy {
    private static func selectedGroups(_ state: [String: Any]) -> [[String: Any]] {
        (state["groups"] as? [[String: Any]] ?? []).filter { $0["selected"] as? Bool == true }
            .map { ["id": $0["id"] ?? "", "unreadCount": $0["unreadCount"] as? Int ?? 0] }
            .sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }
    static func inputsChanged(from before: [String: Any], to after: [String: Any]) -> Bool {
        if before["accountId"] as? String != after["accountId"] as? String { return true }
        let oldCount = (before["messages"] as? NSArray)?.count ?? 0, newCount = (after["messages"] as? NSArray)?.count ?? 0
        if oldCount != newCount { return true }
        if !NSArray(array: selectedGroups(before)).isEqual(to: selectedGroups(after)) { return true }
        let oldRemoved = (before["cleanup"] as? [String: Any])?["suppressedMessageKeys"] as? [String] ?? []
        let newRemoved = (after["cleanup"] as? [String: Any])?["suppressedMessageKeys"] as? [String] ?? []
        return oldRemoved.count != newRemoved.count || oldRemoved.first != newRemoved.first || oldRemoved.last != newRemoved.last
    }
    static func configuration(state: [String: Any]) -> [String: Any] {
        let groups = selectedGroups(state), selected = Set(groups.compactMap { $0["id"] as? String })
        var ids: [String: Set<String>] = [:]
        for message in state["messages"] as? [[String: Any]] ?? [] {
            guard let group = message["groupId"] as? String, selected.contains(group), let id = message["id"] as? String else { continue }
            ids[group, default: []].insert(id)
        }
        // Cleared history is deliberately treated as already seen. New records
        // keep synchronizing, while the initial history deficit cannot refill it.
        for key in (state["cleanup"] as? [String: Any])?["suppressedMessageKeys"] as? [String] ?? [] {
            guard let separator = key.firstIndex(of: ":") else { continue }
            let group = String(key[..<separator]), id = String(key[key.index(after: separator)...])
            if selected.contains(group), !id.isEmpty { ids[group, default: []].insert(id) }
        }
        let progress = state["progress"] as? [String: [String: [String: Any]]] ?? [:]
        let configuration = groups.compactMap { group -> [String: Any]? in
            guard let id = group["id"] as? String else { return nil }
            let messages = ids[id] ?? []
            func less(_ left: String, _ right: String) -> Bool { left.count == right.count ? left < right : left.count < right.count }
            var value: [String: Any] = ["id": id, "loadedCount": messages.count, "unreadCount": group["unreadCount"] ?? 0]
            if let oldest = messages.min(by: less) { value["oldestId"] = oldest }
            if let newest = messages.max(by: less) { value["newestId"] = newest }
            if let anchor = progress[id]?["auto"]?["messageId"] as? String { value["resumeMessageId"] = anchor }
            return value
        }
        return ["accountId": state["accountId"] ?? "", "groups": configuration, "pollIntervalMs": 4000, "initialHistoryCount": 500]
    }
}
