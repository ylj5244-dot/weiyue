import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum MediaPolicy {
    static let maximumDownloadBytes: Int64 = 200_000_000

    static func allowsRedirect(to url: URL?) -> Bool {
        // Redirect decisions cannot substitute the HTTPS URL returned by remoteURL.
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        return (try? remoteURL(url.absoluteString)) != nil
    }
    static func payloadURL(in folder: URL, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..",
              name == URL(fileURLWithPath: name).lastPathComponent,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ReaderError.message("附件文件名无效。")
        }
        return folder.appendingPathComponent("payload", isDirectory: true).appendingPathComponent(name)
    }
    static func validateCompletedFile(_ file: URL) throws {
        let info = try FileManager.default.attributesOfItem(atPath: file.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? NSNumber else { throw ReaderError.message("附件未能保存。") }
        guard size.int64Value <= maximumDownloadBytes else {
            throw ReaderError.message("附件超过 200 MB，请使用官方聊天下载。")
        }
    }
    static func remoteURL(_ raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil,
              ["weibo.com", "weibo.cn", "sinaimg.cn", "sinaimg.com", "sina.com.cn", "weibocdn.com"].contains(where: {host == $0 || host.hasSuffix("." + $0)})
        else { throw ReaderError.message("附件地址不是可验证的微博文件来源，请在官方聊天中打开。") }
        parts.scheme = "https"; parts.fragment = nil
        guard let url = parts.url else { throw ReaderError.message("附件地址无效。") }
        return url
    }
    static func cacheKey(accountId: String, url: String) -> String {
        SHA256.hash(data: Data((accountId + "\n" + url).utf8)).map { String(format:"%02x", $0) }.joined()
    }
    static func filename(_ raw: String, mime: String) -> String {
        var name = URL(fileURLWithPath: raw).lastPathComponent
            .components(separatedBy: .controlCharacters).joined().replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name == "." || name == ".." { name = "微博附件" }
        name = String(name.prefix(180))
        let ext = (name as NSString).pathExtension.lowercased()
        if ["app","command","sh","exe","dmg","pkg","js","html","htm","scpt","workflow"].contains(ext) { return name + ".download" }
        let known = ["application/pdf":"pdf", "image/jpeg":"jpg", "image/png":"png", "image/gif":"gif", "image/webp":"webp", "text/plain":"txt", "application/msword":"doc", "application/vnd.openxmlformats-officedocument.wordprocessingml.document":"docx", "application/vnd.ms-excel":"xls", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":"xlsx", "application/vnd.openxmlformats-officedocument.presentationml.presentation":"pptx"]
        if ext.isEmpty, let extensionName = known[mime] ?? UTType(mimeType: mime)?.preferredFilenameExtension { name += "." + extensionName }
        return name
    }
}

// Download waiters belong to the operation, so clearing the store's job index
// cannot discard their cancellation replies. Resolution is exactly once.
final class MediaCompletionGroup<Value> {
    private var callbacks: [(Result<Value, Error>) -> Void] = []
    private var result: Result<Value, Error>?
    func append(_ callback: @escaping (Result<Value, Error>) -> Void) {
        if let result { callback(result) } else { callbacks.append(callback) }
    }
    func resolve(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiting = callbacks
        callbacks.removeAll()
        waiting.forEach { $0(result) }
    }
}
