import Foundation

enum StorageUsage {
    // Sum allocated sizes without following links. Includes every account and
    // recovery copy under the app's data directory, not unrelated browser data.
    static func scan(directory: URL) throws -> [String: Any] {
        let root = directory.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard root.resolvingSymlinksInPath() == root else { throw ReaderError.message("资料目录包含符号链接，未统计外部文件。") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var failure: Error?
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in failure = error; return false }) else {
            throw ReaderError.message("暂时无法统计资料目录，请稍后重试。")
        }
        let labels = [("data", "聊天与账号资料"), ("attachments", "图片、视频与文档"), ("recovery", "备份与清理恢复"), ("other", "字体、皮肤及其他")]
        var allocated: [String: Int64] = [:], logical: [String: Int64] = [:], counts: [String: Int] = [:]
        var skipped = 0
        for case let file as URL in entries {
            let info = try file.resourceValues(forKeys: Set(keys))
            if info.isSymbolicLink == true { skipped += 1; continue }
            guard info.isRegularFile == true else { continue }
            // Foundation may enumerate /var as /private/var on macOS. Resolve
            // that system alias before comparing; symlink entries were skipped.
            let canonical = file.resolvingSymlinksInPath().path
            guard canonical.hasPrefix(prefix) else { skipped += 1; continue }
            let relative = String(canonical.dropFirst(prefix.count))
            let category: String
            if relative.hasPrefix("附件/") { category = "attachments" }
            else if relative.hasPrefix("清理记录/") || relative.hasSuffix(".backup") { category = "recovery" }
            else if !relative.contains("/"), relative.hasPrefix("account-"), relative.hasSuffix(".json") { category = "data" }
            else { category = "other" }
            let bytes = Int64(info.fileSize ?? 0)
            allocated[category, default: 0] += Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0)
            logical[category, default: 0] += bytes
            counts[category, default: 0] += 1
        }
        if let failure { throw failure }
        return ["totalBytes": allocated.values.reduce(0, +), "logicalBytes": logical.values.reduce(0, +),
                "fileCount": counts.values.reduce(0, +), "skippedSymlinks": skipped,
                "measuredAt": ISO8601DateFormatter().string(from: Date()),
                "categories": labels.map { ["id": $0.0, "name": $0.1, "bytes": allocated[$0.0, default: 0], "logicalBytes": logical[$0.0, default: 0], "fileCount": counts[$0.0, default: 0]] as [String: Any] }]
    }
}
