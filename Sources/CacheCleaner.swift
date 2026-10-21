import Foundation

struct CacheCleanupItem {
    let original: URL
    let kind: String
    let bytes: Int64
}

struct CacheCleanupPlan {
    let accountId: String
    let items: [CacheCleanupItem]
    let refs: [[String: Any]]
    var json: [String: Any] {
        ["fileCount": items.count, "bytes": items.reduce(Int64(0)) { $0 + $1.bytes },
         "images": items.filter { $0.kind == "image" }.count,
         "documents": items.filter { $0.kind == "document" }.count]
    }
}

struct CacheCleanupReceipt {
    let id: String
    let createdAt: String
    let directory: URL
    let fileCount: Int
    let bytes: Int64
    var json: [String: Any] {
        ["id": id, "createdAt": createdAt, "fileCount": fileCount, "bytes": bytes,
         "recoveryPath": directory.path]
    }
}

struct CacheCleanupRestore {
    let beforeState: [String: Any]
    let warnings: [String]
}

// Manual cleanup uses the system Trash and an account-scoped undo snapshot.
// Opt-in retention only removes verified remote cache files after state commits.
// Call on the app's serial file queue, with downloads paused during mutations.
final class CacheCleaner {
    typealias TrashOperation = (URL) throws -> URL
    private let directory: URL
    private let recoveryDirectory: URL
    private let trashDirectory: URL
    private let trashOperation: TrashOperation
    private let fm = FileManager.default

    init(directory: URL, recoveryDirectory: URL,
         trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true),
         trashOperation: @escaping TrashOperation = CacheCleaner.systemTrash) {
        self.directory = directory.standardizedFileURL
        self.recoveryDirectory = recoveryDirectory.standardizedFileURL
        self.trashDirectory = trashDirectory.standardizedFileURL
        self.trashOperation = trashOperation
    }

    static func systemTrash(_ file: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
        guard let resulting else { throw ReaderError.message("文件已移入废纸篓，但系统没有返回恢复路径；可在访达的废纸篓中找回。") }
        return resulting as URL
    }

    private func child(_ file: URL, of root: URL) throws -> URL {
        let normalized = file.standardizedFileURL
        guard normalized.path.hasPrefix(root.standardizedFileURL.path + "/"),
              normalized.resolvingSymlinksInPath().path == normalized.path,
              root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else {
            throw ReaderError.message("清理路径不在允许的本地资料目录内，或包含符号链接。")
        }
        return normalized
    }

    private func accountFolder(_ accountId: String) throws -> URL {
        guard !accountId.isEmpty else { throw ReaderError.message("请先登录，再管理本地缓存。") }
        return try child(recoveryDirectory.appendingPathComponent(MediaPolicy.cacheKey(accountId: accountId, url: "cleanup-recovery"), isDirectory: true), of: recoveryDirectory)
    }

    private func receiptFolder(id: String, accountId: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ReaderError.message("清理恢复记录无效。") }
        return try child(try accountFolder(accountId).appendingPathComponent(id, isDirectory: true), of: recoveryDirectory)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw ReaderError.message("清理记录包含符号链接，未读取。")
        }
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ReaderError.message("清理记录无法读取，文件仍可从系统废纸篓找回。")
        }
        return value
    }

    private func writeJSON(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func preview(accountId: String, refs: [[String: Any]]) throws -> CacheCleanupPlan {
        guard !accountId.isEmpty else { throw ReaderError.message("请先登录，再管理本地缓存。") }
        var items: [String: CacheCleanupItem] = [:]
        for ref in refs {
            guard let kind = ref["kind"] as? String, ["image", "document"].contains(kind) else {
                throw ReaderError.message("只能按图片或文档清理本地文件。")
            }
            let original: URL, payload: URL
            if let path = ref["localPath"] as? String {
                let local = URL(fileURLWithPath: path)
                let scoped = try WorkspacePolicy.importDirectory(base: directory, accountId: accountId)
                _ = try child(local, of: scoped)
                guard fm.fileExists(atPath: local.path) else { continue }
                payload = try WorkspacePolicy.importedFile(path: path, base: directory, accountId: accountId)
                original = payload
            } else if let raw = ref["url"] as? String {
                let remote = try MediaPolicy.remoteURL(raw)
                let folder = try child(directory.appendingPathComponent(MediaPolicy.cacheKey(accountId: accountId, url: remote.absoluteString), isDirectory: true), of: directory)
                let manifest = folder.appendingPathComponent("asset.json")
                guard fm.fileExists(atPath: manifest.path) else { continue }
                _ = try child(manifest, of: directory)
                let info = try readJSON(manifest)
                guard let name = info["name"] as? String else { throw ReaderError.message("附件缓存目录无效，未进行清理。") }
                payload = try child(MediaPolicy.payloadURL(in: folder, name: name), of: directory)
                guard fm.fileExists(atPath: payload.path) else { continue }
                original = folder
                try rejectSymlinks(in: folder)
            } else { throw ReaderError.message("缺少可验证的文件来源，未进行清理。") }
            try MediaPolicy.validateCompletedFile(payload)
            let attributes = try fm.attributesOfItem(atPath: payload.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            items[original.path] = CacheCleanupItem(original: original, kind: kind, bytes: size)
        }
        return CacheCleanupPlan(accountId: accountId, items: items.values.sorted { $0.original.path < $1.original.path }, refs: refs)
    }

    func removeExpiredRemote(accountId: String, refs: [[String: Any]]) -> (bytes: Int64, pending: [[String: Any]], warnings: [String]) {
        var bytes: Int64 = 0, pending: [[String: Any]] = [], warnings: [String] = []
        var seen = Set<String>()
        for ref in refs {
            do {
                guard ref["localPath"] == nil, let raw = ref["url"] as? String else { throw ReaderError.message("自动清理仅处理远程附件缓存。") }
                let url = try MediaPolicy.remoteURL(raw)
                guard seen.insert(url.absoluteString).inserted else { continue }
                guard ["image", "document"].contains(ref["kind"] as? String ?? "") else { throw ReaderError.message("自动清理附件类型无效。") }
                // The hash binds this directory to the current account + remote
                // URL. Incomplete downloads can lack a manifest; remove their
                // residual bytes too, while rejecting links anywhere below it.
                let safe = try child(directory.appendingPathComponent(MediaPolicy.cacheKey(accountId: accountId, url: url.absoluteString), isDirectory: true), of: directory)
                guard fm.fileExists(atPath: safe.path) else { continue }
                try rejectSymlinks(in: safe)
                var allocated: Int64 = 0
                guard let entries = fm.enumerator(at: safe, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else {
                    throw ReaderError.message("缓存目录暂时无法读取，稍后重试。")
                }
                for case let file as URL in entries {
                    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
                    if info.isRegularFile == true { allocated += Int64(info.totalFileAllocatedSize ?? info.fileSize ?? 0) }
                }
                try fm.removeItem(at: safe)
                bytes += allocated
            } catch { pending.append(ref); warnings.append(error.localizedDescription) }
        }
        return (bytes, pending, warnings)
    }

    private func rejectSymlinks(in folder: URL) throws {
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw ReaderError.message("附件目录暂时无法读取，未进行清理。")
        }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ReaderError.message("附件目录含有符号链接，未进行清理。")
            }
        }
    }

    func trash(plan: CacheCleanupPlan, beforeState: [String: Any]) throws -> CacheCleanupReceipt {
        guard beforeState["accountId"] as? String == plan.accountId else { throw ReaderError.message("账号已变化，未进行清理。") }
        let id = UUID().uuidString, createdAt = ISO8601DateFormatter().string(from: Date())
        let folder = try receiptFolder(id: id, accountId: plan.accountId)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeJSON(beforeState, to: folder.appendingPathComponent("before.json"))
        var receipt: [String: Any] = ["id": id, "accountId": plan.accountId, "createdAt": createdAt,
                                      "createdAtTimestamp": Date().timeIntervalSince1970,
                                      "status": "active", "moves": [], "refs": plan.refs,
                                      "fileCount": plan.items.count, "bytes": plan.items.reduce(Int64(0)) { $0 + $1.bytes }]
        let manifest = folder.appendingPathComponent("receipt.json")
        try writeJSON(receipt, to: manifest)
        var moves: [[String: String]] = []
        do {
            for item in plan.items {
                let original = try child(item.original, of: directory)
                guard fm.fileExists(atPath: original.path) else { continue }
                let moved = try trashOperation(original)
                // The system returned the recovery path; never accept a web-supplied path.
                moves.append(["originalPath": original.path, "trashPath": moved.path, "kind": item.kind])
                receipt["moves"] = moves
                try writeJSON(receipt, to: manifest)
            }
        } catch {
            var recoveryFailed = false
            for move in moves.reversed() {
                guard let original = move["originalPath"], let trash = move["trashPath"] else { continue }
                if !fm.fileExists(atPath: original) {
                    do { try fm.moveItem(atPath: trash, toPath: original) } catch { recoveryFailed = true }
                }
            }
            receipt["status"] = recoveryFailed ? "active" : "rolled-back"
            try? writeJSON(receipt, to: manifest)
            if recoveryFailed { throw ReaderError.message("部分文件清理未完成；已保留恢复记录，可从应用清理记录或系统废纸篓找回。") }
            throw error
        }
        return CacheCleanupReceipt(id: id, createdAt: createdAt, directory: folder, fileCount: moves.count, bytes: plan.items.reduce(0) { $0 + $1.bytes })
    }

    func restore(id: String, accountId: String, markRestored: Bool = true) throws -> CacheCleanupRestore {
        let folder = try receiptFolder(id: id, accountId: accountId), manifest = folder.appendingPathComponent("receipt.json")
        var receipt = try readJSON(manifest)
        let before = try readJSON(folder.appendingPathComponent("before.json"))
        guard receipt["accountId"] as? String == accountId, before["accountId"] as? String == accountId,
              let moves = receipt["moves"] as? [[String: String]] else { throw ReaderError.message("清理记录不属于当前账号，未恢复。") }
        var warnings: [String] = []
        var validated: [(URL, URL)] = []
        for move in moves {
            guard let original = move["originalPath"], let trash = move["trashPath"] else { throw ReaderError.message("清理恢复记录不完整。") }
            validated.append((try child(URL(fileURLWithPath: original), of: directory), try child(URL(fileURLWithPath: trash), of: trashDirectory)))
        }
        for (original, trash) in validated {
            if fm.fileExists(atPath: original.path) {
                if fm.fileExists(atPath: trash.path) { warnings.append("已保留重新下载的文件：" + original.lastPathComponent + "；旧副本仍在废纸篓。") }
                continue
            }
            guard fm.fileExists(atPath: trash.path) else { warnings.append("文件已不在废纸篓：" + original.lastPathComponent + "。远程附件可再次下载。"); continue }
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: trash, to: original)
        }
        if markRestored {
            receipt["status"] = "restored"
            try writeJSON(receipt, to: manifest)
        }
        return CacheCleanupRestore(beforeState: before, warnings: warnings)
    }

    func completeRestore(id: String, accountId: String) throws {
        let file = try receiptFolder(id: id, accountId: accountId).appendingPathComponent("receipt.json")
        var receipt = try readJSON(file)
        guard receipt["accountId"] as? String == accountId else { throw ReaderError.message("清理记录不属于当前账号。") }
        receipt["status"] = "restored"
        try writeJSON(receipt, to: file)
    }

    func latestRecovery(accountId: String) throws -> [String: Any]? {
        let folder = try accountFolder(accountId)
        guard fm.fileExists(atPath: folder.path) else { return nil }
        let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let candidates = children.compactMap { item -> [String: Any]? in
            guard UUID(uuidString: item.lastPathComponent) != nil,
                  let safe = try? child(item, of: recoveryDirectory),
                  var receipt = try? readJSON(safe.appendingPathComponent("receipt.json")),
                  receipt["accountId"] as? String == accountId, receipt["status"] as? String == "active" else { return nil }
            receipt.removeValue(forKey: "moves"); receipt["recoveryPath"] = safe.path; return receipt
        }
        return candidates.sorted { ($0["createdAtTimestamp"] as? Double ?? 0) > ($1["createdAtTimestamp"] as? Double ?? 0) }.first
    }

    func lastReceipt(accountId: String) throws -> [String: Any]? {
        guard var receipt = try latestRecovery(accountId: accountId), let id = receipt["id"] as? String else { return nil }
        let folder = try receiptFolder(id: id, accountId: accountId)
        let before = try readJSON(folder.appendingPathComponent("before.json"))
        guard before["accountId"] as? String == accountId else { throw ReaderError.message("清理快照不属于当前账号，未读取。") }
        receipt["beforeState"] = before
        return receipt
    }
}
