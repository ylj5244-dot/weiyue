import Foundation
import Security
import CryptoKit

// Testable without touching a keychain. Callers serialize every real operation
// because the legacy interaction flag belongs to this process, not a single query.
enum KeychainInteractionPolicy {
    static func perform<T>(allowInteraction: Bool,
                           get: () -> (OSStatus, Bool),
                           set: (Bool) -> OSStatus,
                           operation: () throws -> T) throws -> T {
        let previous = get()
        guard previous.0 == errSecSuccess else {
            throw ReaderError.message("无法确认系统钥匙串的交互状态，本次未读取密钥。请稍后重试。")
        }
        guard set(allowInteraction) == errSecSuccess else {
            _ = set(previous.1)
            throw ReaderError.message("无法安全设置钥匙串交互方式，本次未读取密钥。请稍后重试。")
        }
        var restoration = errSecSuccess
        let result: Result<T, Error> = {
            defer { restoration = set(previous.1) }
            return Result { try operation() }
        }()
        guard restoration == errSecSuccess else {
            throw ReaderError.message("系统钥匙串交互状态未能恢复，请关闭并重新打开微阅后重试。")
        }
        return try result.get()
    }
}

enum SecretStore {
    private static let service = "local.weiyue.WeiboReader.ai"
    private static var authorizedKeys: [String: String] = [:]
    private static let cacheLock = NSLock()
    private static let keychainLock = NSRecursiveLock()
    private static var cacheGeneration = 0
    private static func cached(_ scope: String) -> String? { cacheLock.lock(); defer { cacheLock.unlock() }; return authorizedKeys[scope] }
    private static func generation() -> Int { cacheLock.lock(); defer { cacheLock.unlock() }; return cacheGeneration }
    private static func remember(_ value: String?, scope: String, generation: Int) {
        cacheLock.lock()
        // Account switches must not be undone by an older authorization finishing later.
        if generation == cacheGeneration { authorizedKeys[scope] = value }
        cacheLock.unlock()
        UserDefaults.standard.set(value != nil, forKey: "knownAIKey." + scope)
    }
    static func clearSession() { cacheLock.lock(); cacheGeneration += 1; authorizedKeys.removeAll(); cacheLock.unlock() }
    static func knownPresence(accountId: String, baseURL: String) -> Bool? {
        guard let scope = try? storageAccount(accountId: accountId, baseURL: baseURL) else { return false }
        return UserDefaults.standard.object(forKey: "knownAIKey." + scope) as? Bool
    }
    // Bind keys to the exact canonical request endpoint, including its API/tenant
    // path. Even the same host must not silently reuse a key for another path.
    static func storageAccount(accountId: String, baseURL: String) throws -> String {
        guard !accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderError.message("请先确认微博账号，再配置该账号的 API 密钥。")
        }
        let endpoint = try AIClient.endpoint(baseURL).absoluteString
        let identity = try JSONSerialization.data(withJSONObject: ["accountId": accountId, "endpoint": endpoint], options: [.sortedKeys])
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return "api-key-v2-" + digest
    }
    private static func query(accountId: String, baseURL: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: try storageAccount(accountId: accountId, baseURL: baseURL)]
    }
    private static func withKeychainInteraction<T>(_ allowed: Bool, operation: () throws -> T) throws -> T {
        // The legacy API is intentional: existing items are in the file-based
        // macOS keychain, whose UI behavior is not controlled by UIFail alone.
        try KeychainInteractionPolicy.perform(allowInteraction: allowed, get: {
            var previous: DarwinBoolean = false
            let status = SecKeychainGetUserInteractionAllowed(&previous)
            return (status, previous.boolValue)
        }, set: { SecKeychainSetUserInteractionAllowed($0) }, operation: operation)
    }
    // Startup uses knownPresence only. A user-initiated AI operation may probe an
    // already-authorized legacy item in the background with all prompts disabled.
    // Only the explicit authorization action enables prompts; ACLs stay untouched.
    static func read(accountId: String, baseURL: String, allowInteraction: Bool = false) throws -> String? {
        let scope = try storageAccount(accountId: accountId, baseURL: baseURL)
        if let key = cached(scope) { return key }
        guard !Thread.isMainThread else {
            throw ReaderError.message("密钥尚未准备完成，请重试；如需系统确认，可在设置中点击「授权已保存的 Key」。")
        }
        let expectedGeneration = generation()
        keychainLock.lock(); defer { keychainLock.unlock() }
        if let key = cached(scope) { return key }
        let key: String? = try withKeychainInteraction(allowInteraction) {
            var query = try query(accountId: accountId, baseURL: baseURL)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            // Also constrain Data Protection items, if a future version introduces them.
            query[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                throw ReaderError.message("macOS 需要确认新版微阅访问已保存的 Key。请在设置中点击「授权已保存的 Key」，并完成系统钥匙串提示；无需更换模型或密钥。")
            }
            if status == errSecUserCanceled { throw ReaderError.message("已取消钥匙串授权，原密钥与模型配置均已保留。") }
            guard status == errSecSuccess, let data = result as? Data,
                  let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                throw ReaderError.message("无法读取当前账号及 API 地址的钥匙串密钥，请在设置中重新确认。")
            }
            return key
        }
        remember(key, scope: scope, generation: expectedGeneration); return key
    }
    static func save(_ key: String, accountId: String, baseURL: String) throws {
        let query = try query(accountId: accountId, baseURL: baseURL)
        let scope = try storageAccount(accountId: accountId, baseURL: baseURL)
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 8192 else { throw ReaderError.message("API 密钥过长，请检查是否误粘贴了其他内容。") }
        guard !Thread.isMainThread else { throw ReaderError.message("密钥保存尚未就绪，请关闭设置后重新操作。") }
        let expectedGeneration = generation()
        keychainLock.lock(); defer { keychainLock.unlock() }
        try withKeychainInteraction(true) {
            if clean.isEmpty {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw ReaderError.message("未能移除系统钥匙串中的密钥，原配置已保留。") }
                return
            }
            let fields: [String: Any] = [kSecValueData as String: Data(clean.utf8)]
            var status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query; insert[kSecValueData as String] = Data(clean.utf8)
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(insert as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw ReaderError.message("系统钥匙串保存失败，密钥没有保存到普通文件。") }
        }
        remember(clean.isEmpty ? nil : clean, scope: scope, generation: expectedGeneration)
    }
}

struct AIRequestGate {
    private(set) var active: UUID?
    mutating func begin() throws -> UUID {
        guard active == nil else { throw ReaderError.message("已有讨论正在生成，请等待或先取消。") }
        let id = UUID(); active = id; return id
    }
    mutating func cancel() { active = nil }
    mutating func finish(_ id: UUID) -> Bool {
        guard active == id else { return false }
        active = nil; return true
    }
}

final class AIClient: NSObject, URLSessionTaskDelegate {
    private var streaming: AIStreamingTransport?
    private let requestQueue = DispatchQueue(label: "local.weiyue.ai.request", qos: .userInitiated)
    private var modelsTask: URLSessionDataTask?
    private var requests = AIRequestGate()
    private var modelRequests = AIRequestGate()
    private let configuration: URLSessionConfiguration
    private let keyReader: (String, String) throws -> String?
    init(configuration: URLSessionConfiguration = .ephemeral,
         keyReader: @escaping (String, String) throws -> String? = { try SecretStore.read(accountId: $0, baseURL: $1) }) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.urlCache = nil
        config.httpShouldSetCookies = false
        self.configuration = config
        self.keyReader = keyReader
        super.init()
    }
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    static func endpoint(_ raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw ReaderError.message("请输入 HTTPS API 地址，不要在地址中放置密钥、查询参数或账号密码。") }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if !parts.path.hasSuffix("/chat/completions") { parts.path += "/chat/completions" }
        guard let url = parts.url else { throw ReaderError.message("API 地址无法解析。") }
        return url
    }
    static func modelsEndpoint(_ raw: String) throws -> URL {
        let completionURL = try endpoint(raw)
        guard var parts = URLComponents(url: completionURL, resolvingAgainstBaseURL: false) else {
            throw ReaderError.message("模型列表地址无法解析。")
        }
        parts.path = String(parts.path.dropLast("/chat/completions".count)) + "/models"
        guard let url = parts.url else { throw ReaderError.message("模型列表地址无法解析。") }
        return url
    }
    private static func safeErrorField(_ raw: Any?, secret: String, limit: Int) -> String? {
        let original: String
        if let value = raw as? String { original = value }
        else if let value = raw as? NSNumber { original = value.stringValue }
        else { return nil }
        var safe = original
        if !secret.isEmpty { safe = safe.replacingOccurrences(of: secret, with: "[已隐藏]") }
        safe = safe.replacingOccurrences(of: #"(?i)\bBearer\s+[^\s\"'<>;,\]\)]+"#, with: "Bearer [已隐藏]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"[\p{Cc}\p{Cf}]"#, with: " ", options: .regularExpression)
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return nil }
        return safe.count > limit ? String(safe.prefix(limit)) + "…" : safe
    }
    static func serviceError(statusCode: Int, data: Data?, secret: String) -> ReaderError {
        let guidance: String
        switch statusCode {
        case 400, 422: guidance = "请求参数无效，请检查模型名称与消息格式。"
        case 401, 403: guidance = "请检查当前账号及 API 地址的密钥和模型权限。"
        case 404: guidance = "API 路径或模型不存在，请检查地址并获取模型列表。"
        case 405: guidance = "API 不支持此请求方式，请检查服务地址。"
        case 413: guidance = "请求材料过大，请减少选中的消息。"
        case 429: guidance = "调用频率或余额受限，请稍后重试。"
        case 300..<400: guidance = "API 地址发生重定向。为保护密钥，已停止请求，请填写最终地址。"
        case 500..<600: guidance = "服务暂时不可用，可以稍后重试。"
        default: guidance = "请求被服务拒绝，请检查 API 配置。"
        }
        var description = statusCode == 200 ? "AI 服务在生成过程中报告错误。" : "AI 服务返回 \(statusCode)。\(guidance)"
        if let data, data.count <= 1_000_000,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            if let message = safeErrorField(error["message"], secret: secret, limit: 700) { description += "\n服务信息：" + message }
            if let code = safeErrorField(error["code"], secret: secret, limit: 120) { description += "\n错误代码：" + code }
            if let param = safeErrorField(error["param"], secret: secret, limit: 120) { description += "\n参数：" + param }
        }
        return .message(description)
    }
    private static func parseModels(_ data: Data) throws -> [[String: String]] {
        guard data.count <= 2_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]], entries.count <= 10_000 else {
            throw ReaderError.message("服务返回的模型列表格式不正确，请检查是否支持 GET /models。")
        }
        var result: [[String: String]] = [], seen = Set<String>()
        for entry in entries {
            guard let rawID = entry["id"] as? String, !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReaderError.message("服务返回的模型列表缺少有效模型 ID。")
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(id).inserted else { continue }
            let label = ((entry["name"] as? String) ?? (entry["display_name"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(["id": id, "name": label.isEmpty ? id : label])
        }
        return result
    }
    private func key(accountId: String, baseURL: String) throws -> String {
        guard let key = try keyReader(accountId, baseURL), !key.isEmpty else {
            throw ReaderError.message("当前账号及 API 地址尚未保存密钥。切换账号或服务地址后，请在设置中单独配置。")
        }
        return key
    }
    func cancel() {
        requests.cancel(); streaming?.cancel(); streaming = nil
        modelRequests.cancel(); modelsTask?.cancel(); modelsTask = nil
    }
    func listModels(accountId: String, baseURL: String, completion: @escaping (Result<[[String: String]], Error>) -> Void) throws {
        guard modelRequests.active == nil else { throw ReaderError.message("正在获取模型列表，请稍候或先取消。") }
        let url = try Self.modelsEndpoint(baseURL)
        // Key lookup deliberately uses the configured completion scope, rather
        // than inventing a second credential scope for its /models companion.
        let key = try key(accountId: accountId, baseURL: baseURL)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let requestID = try modelRequests.begin()
        let newTask = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<[[String: String]], Error>
            if let error { result = .failure(error) }
            else if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                result = .failure(Self.serviceError(statusCode: response.statusCode, data: data, secret: key))
            } else if let data {
                result = Result { try Self.parseModels(data) }
            } else { result = .failure(ReaderError.message("服务未返回模型列表。")) }
            DispatchQueue.main.async {
                guard let self, self.modelRequests.finish(requestID) else {
                    completion(.failure(URLError(.cancelled))); return
                }
                self.modelsTask = nil; completion(result)
            }
        }
        modelsTask = newTask; newTask.resume()
    }
    static func capabilities(baseURL: String, model: String) throws -> [String: Any] {
        AIModelPolicy.capabilities(endpoint: try endpoint(baseURL), model: model)
    }
    func send(accountId: String, baseURL: String, model: String, messages: [[String: Any]],
              thinking: String = "auto", allowImages: Bool = false, allowPDF: Bool = false,
              onProgress: (([String: Any]) -> Void)? = nil,
              completion: @escaping (Result<String, Error>) -> Void) throws {
        guard requests.active == nil else { throw ReaderError.message("已有讨论正在生成，请等待或先取消。") }
        let url = try Self.endpoint(baseURL)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else { throw ReaderError.message("请先设置模型名称。") }
        let key = try key(accountId: accountId, baseURL: baseURL)
        let requestID = try requests.begin()
        // Base64 file payloads may reach tens of MB. Validation and JSON encoding
        // must never block scrolling or a user's attempt to cancel the request.
        onProgress?(["phase": "preparing", "elapsed": 0.0])
        requestQueue.async { [weak self] in
            let prepared = Result { try AIModelPolicy.requestBody(endpoint: url, model: cleanModel, messages: messages,
                thinking: thinking, allowImages: allowImages, allowPDF: allowPDF) }
            DispatchQueue.main.async {
                guard let self, self.requests.active == requestID else { completion(.failure(URLError(.cancelled))); return }
                do {
                    let payload = try prepared.get()
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                    request.httpMethod = "POST"; request.httpBody = payload
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    let transport = AIStreamingTransport(configuration: self.configuration, request: request, secret: key, progress: { [weak self] event in
                        guard let self, self.requests.active == requestID else { return }
                        onProgress?(event)
                    }, completion: { [weak self] result in
                        guard let self, self.requests.finish(requestID) else { completion(.failure(URLError(.cancelled))); return }
                        self.streaming = nil; completion(result)
                    })
                    self.streaming = transport; transport.start()
                } catch {
                    _ = self.requests.finish(requestID); completion(.failure(error))
                }
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Provider capabilities are deliberately conservative. Compatible endpoints can
// opt into documented multimodal support; model names alone never identify a provider.
enum AIModelPolicy {
    static func provider(_ endpoint: URL) -> String {
        switch endpoint.host?.lowercased() {
        case "api.deepseek.com": return "deepseek"
        case "api.openai.com": return "openai"
        default: return "compatible"
        }
    }
    private static func isModel(_ model: String, _ name: String) -> Bool { model == name || model.hasPrefix(name + "-") }
    static func capabilities(endpoint: URL, model: String) -> [String: Any] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), source = provider(endpoint)
        var images = false, pdf = false, thinking = false, canDisable = false
        if source == "deepseek" {
            images = ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"].contains(model)
            thinking = images || model == "deepseek-v4-pro"; canDisable = thinking
        } else if source == "openai" {
            let general = ["gpt-4o", "gpt-4.1", "gpt-5", "gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.5", "gpt-6", "gpt-6.1", "o1", "o3", "o4-mini"].contains { isModel(model, $0) }
            let specialized = ["audio", "realtime", "transcribe", "tts", "image", "search", "codex"].contains { model.contains($0) }
            images = general && !specialized && !model.hasPrefix("o1-mini") && !model.hasPrefix("o1-preview")
            pdf = images
            thinking = !specialized && ["gpt-5", "gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.5", "gpt-6", "gpt-6.1", "o1", "o3", "o4-mini"].contains { isModel(model, $0) }
            canDisable = ["gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-6-sol", "gpt-6-luna"].contains { isModel(model, $0) }
        }
        return ["provider": source, "images": images, "pdf": pdf, "thinking": thinking, "canDisableThinking": canDisable]
    }
    static func requestBody(endpoint: URL, model: String, messages: [[String: Any]], thinking: String,
                            allowImages: Bool, allowPDF: Bool) throws -> Data {
        guard !messages.isEmpty, messages.count <= 200 else { throw ReaderError.message("讨论内容格式不正确，未发送到 AI。") }
        let capabilities = capabilities(endpoint: endpoint, model: model), source = provider(endpoint)
        let images = capabilities["images"] as? Bool == true || (source == "compatible" && allowImages)
        let pdf = capabilities["pdf"] as? Bool == true || (source == "compatible" && allowPDF)
        var normalized: [[String: Any]] = [], textSize = 0, attachmentCount = 0
        for message in messages {
            guard let role = message["role"] as? String, ["system", "user", "assistant"].contains(role) else { throw ReaderError.message("讨论角色格式不正确，未发送到 AI。") }
            if let content = message["content"] as? String {
                textSize += content.utf8.count; normalized.append(["role": role, "content": content]); continue
            }
            guard role == "user", let parts = message["content"] as? [[String: Any]], !parts.isEmpty, parts.count <= 100 else {
                throw ReaderError.message("AI 附件只能放在用户材料中，请重新选择材料。")
            }
            var cleanParts: [[String: Any]] = []
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    guard let text = part["text"] as? String else { throw ReaderError.message("文字材料格式不正确。") }
                    textSize += text.utf8.count; cleanParts.append(["type": "text", "text": text])
                case "image_url":
                    guard images else { throw ReaderError.message("当前服务或模型尚未确认支持直接读图。请选择支持视觉的模型（例如 DeepSeek Flash），或改用本地文字识别。") }
                    guard let value = part["image_url"] as? [String: Any], let url = value["url"] as? String,
                          ["data:image/jpeg;base64,", "data:image/png;base64,", "data:image/gif;base64,", "data:image/webp;base64,"].contains(where: { url.hasPrefix($0) }),
                          let separator = url.firstIndex(of: ","), url.distance(from: separator, to: url.endIndex) > 1 else {
                        throw ReaderError.message("图片材料格式不正确，需使用已下载的 JPEG、PNG、GIF 或 WebP 图片。")
                    }
                    attachmentCount += 1
                    cleanParts.append(["type": "image_url", "image_url": ["url": url, "detail": "auto"]])
                case "file":
                    guard pdf else { throw ReaderError.message("当前模型不支持直接接收 PDF 文件。支持视觉的模型可读取 PDF 页面图片，或选择读取文档正文。") }
                    guard let value = part["file"] as? [String: Any], let data = value["file_data"] as? String,
                          data.hasPrefix("data:application/pdf;base64,"), data.count > 28,
                          let filename = value["filename"] as? String, filename.lowercased().hasSuffix(".pdf"), filename.count <= 250 else {
                        throw ReaderError.message("文件直读当前支持 PDF，请将 Word 等文件导出为 PDF，或选择读取正文。")
                    }
                    attachmentCount += 1
                    cleanParts.append(["type": "file", "file": ["filename": filename, "file_data": data]])
                default: throw ReaderError.message("不支持此 AI 材料格式，未发送。")
                }
            }
            normalized.append(["role": role, "content": cleanParts])
        }
        guard textSize <= 1_000_000, attachmentCount <= 60 else { throw ReaderError.message("本次材料过多，请减少选中的消息或文件后重试。") }
        var body: [String: Any] = ["model": model, "messages": normalized, "stream": true]
        // Unknown compatible APIs may reject optional streaming parameters.
        if source != "compatible" { body["stream_options"] = ["include_usage": true] }
        guard ["auto", "enabled", "disabled"].contains(thinking) else { throw ReaderError.message("深度思考选项无效，请重新选择。") }
        if thinking != "auto" {
            guard capabilities["thinking"] as? Bool == true else { throw ReaderError.message("当前服务或模型没有已确认的思考开关，请重新保存模型设置后重试。") }
            guard thinking != "disabled" || capabilities["canDisableThinking"] as? Bool == true else {
                throw ReaderError.message("此模型不能完全关闭思考，请使用支持关闭思考的模型。")
            }
            if source == "deepseek" { body["thinking"] = ["type": thinking] }
            if source == "openai" { body["reasoning_effort"] = thinking == "enabled" ? "high" : "none" }
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        guard payload.count <= 36_000_000 else { throw ReaderError.message("图片或文档材料合计过大，请分批发送（本次上限约 25 MB 原文件）。") }
        return payload
    }
}

// Parse complete UTF-8 lines, never individual network chunks: Chinese text and
// SSE boundaries may both split at any byte. Event data can span several lines.
struct AIEventStreamParser {
    private var buffer = Data()
    private var eventLines: [String] = []
    private var eventBytes = 0
    mutating func append(_ bytes: Data, final: Bool = false) throws -> [String] {
        buffer.append(bytes)
        var events: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            try consume(line, into: &events)
        }
        guard buffer.count <= 1_000_000 else { throw ReaderError.message("AI 返回了过长的流数据，已停止接收。") }
        if final {
            if !buffer.isEmpty { try consume(buffer, into: &events); buffer.removeAll() }
            if !eventLines.isEmpty { events.append(eventLines.joined(separator: "\n")); eventLines.removeAll(); eventBytes = 0 }
        }
        return events
    }
    private mutating func consume(_ bytes: Data, into events: inout [String]) throws {
        guard let line = String(data: bytes, encoding: .utf8) else { throw ReaderError.message("AI 返回的流数据编码不正确。") }
        if line.isEmpty {
            if !eventLines.isEmpty { events.append(eventLines.joined(separator: "\n")); eventLines.removeAll(); eventBytes = 0 }
        } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.first == " " { value.removeFirst() }
            eventBytes += value.utf8.count
            guard eventBytes <= 1_000_000 else { throw ReaderError.message("AI 返回了过长的流事件，已停止接收。") }
            eventLines.append(value)
        }
    }
}

// One transport per generation keeps cancellation, buffers and callback ownership
// independent. The serial delegate queue performs parsing away from the UI thread.
private final class AIStreamingTransport: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private let secret: String
    private let started = Date()
    private let progress: ([String: Any]) -> Void
    private let completion: (Result<String, Error>) -> Void
    private var parser = AIEventStreamParser()
    private var body = Data(), statusCode = 0, receivedBytes = 0
    private var eventStream = false, ended = false, sawDone = false, sawFinish = false
    private var content = "", contentBytes = 0, reasoningBytes = 0
    private var usage: [String: Any]?
    private var streamError: Error?
    init(configuration: URLSessionConfiguration, request: URLRequest, secret: String,
         progress: @escaping ([String: Any]) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        self.secret = secret; self.progress = progress; self.completion = completion
        super.init()
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.task = session.dataTask(with: request)
    }
    func start() { emit(["phase": "connecting"]); task.resume() }
    func cancel() { task.cancel() }
    private func emit(_ fields: [String: Any]) {
        var value = fields; value["elapsed"] = Date().timeIntervalSince(started)
        DispatchQueue.main.async { [progress] in progress(value) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        eventStream = response.mimeType?.lowercased() == "text/event-stream"
        if (200..<300).contains(statusCode) { emit(["phase": "waiting"]) }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        emit(["phase": "uploading", "uploadedBytes": totalBytesSent, "totalUploadBytes": max(0, totalBytesExpectedToSend)])
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard streamError == nil else { return }
        receivedBytes += data.count
        guard receivedBytes <= 20_000_000 else { fail(ReaderError.message("AI 返回内容过长，已停止接收。")); return }
        if !(200..<300).contains(statusCode) {
            if body.count < 1_000_000 { body.append(data.prefix(1_000_000 - body.count)) }; return
        }
        if eventStream {
            do { try process(parser.append(data)) } catch { fail(error) }
        } else {
            body.append(data)
            // A few compatible services omit the SSE content type. Detect only a
            // clear SSE prefix, never treat an arbitrary JSON response as chunks.
            if let prefix = String(data: body.prefix(200), encoding: .utf8), prefix.hasPrefix("data:") || prefix.hasPrefix(":") || prefix.hasPrefix("event:") {
                eventStream = true
                do { try process(parser.append(body)); body.removeAll() } catch { fail(error) }
            }
        }
    }
    private func process(_ events: [String]) throws {
        for event in events {
            if event.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { sawDone = true; continue }
            guard !sawDone else { continue }
            guard let data = event.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReaderError.message("AI 返回了无法解析的流事件。")
            }
            if json["error"] != nil { throw AIClient.serviceError(statusCode: 200, data: data, secret: secret) }
            if let actualUsage = json["usage"] as? [String: Any] {
                let keys = ["prompt_tokens", "completion_tokens", "total_tokens", "prompt_cache_hit_tokens", "prompt_cache_miss_tokens"]
                var clean: [String: Any] = [:]
                for key in keys { if let number = actualUsage[key] as? NSNumber, number.doubleValue >= 0 { clean[key] = number } }
                if let details = actualUsage["completion_tokens_details"] as? [String: Any], let number = details["reasoning_tokens"] as? NSNumber { clean["reasoning_tokens"] = number }
                usage = clean; if !clean.isEmpty { emit(["usage": clean]) }
            }
            guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { continue }
            reportFinishReason(choice["finish_reason"])
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                reasoningBytes += reasoning.utf8.count
                guard reasoningBytes <= 10_000_000 else { throw ReaderError.message("模型思考内容过长，已停止接收。") }
                emit(["phase": "thinking", "reasoningDelta": reasoning])
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                content += text; contentBytes += text.utf8.count
                guard contentBytes <= 10_000_000 else { throw ReaderError.message("模型回答过长，已停止接收。") }
                emit(["phase": "answering", "contentDelta": text])
            }
            if let refusal = delta["refusal"] as? String, !refusal.isEmpty { content += refusal; emit(["phase": "answering", "contentDelta": refusal]) }
        }
    }
    // A compatible server may ignore stream=true and return one JSON body.
    // Its finish reason has the same meaning as SSE and must reach the UI before
    // completion, so a truncated batch cannot silently become a full summary.
    private func reportFinishReason(_ value: Any?) {
        guard let reason = value as? String, !reason.isEmpty else { return }
        sawFinish = true
        if reason == "length" { emit(["warning": "模型达到本次输出上限，回答可能尚未结束；可继续追问。", "finishReason": reason]) }
        if reason == "content_filter" { emit(["warning": "服务的内容过滤器终止了输出。", "finishReason": reason]) }
    }
    private func fail(_ error: Error) { streamError = error; task.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !ended else { return }; ended = true
        let result: Result<String, Error> = Result {
            if let streamError { throw streamError }
            if let error { throw error }
            guard (200..<300).contains(statusCode) else { throw AIClient.serviceError(statusCode: statusCode, data: body, secret: secret) }
            if eventStream {
                try process(parser.append(Data(), final: true))
                guard sawDone || sawFinish else { throw ReaderError.message("AI 连接在回答完成前中断，已收到的部分文字仍保留，请重试或继续提问。") }
            } else {
                guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    throw ReaderError.message("模型返回格式不正确，请检查所选服务是否兼容 Chat Completions。")
                }
                if json["error"] != nil { throw AIClient.serviceError(statusCode: 200, data: body, secret: secret) }
                guard let choices = json["choices"] as? [[String: Any]],
                      let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }),
                      let message = choice["message"] as? [String: Any], let text = message["content"] as? String, !text.isEmpty else {
                    throw ReaderError.message("模型未返回可显示的文字。请检查所选服务是否兼容 Chat Completions。")
                }
                reportFinishReason(choice["finish_reason"])
                content = text; emit(["phase": "answering", "contentDelta": text, "buffered": true])
            }
            guard !content.isEmpty else { throw ReaderError.message("模型已结束但尚未返回回答文字，请检查模型或重新提问。") }
            return content
        }
        if case .success = result {
            var fields: [String: Any] = ["phase": "completed"]
            if let usage { fields["usage"] = usage }; emit(fields)
        }
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { [completion] in completion(result) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

// Native source identity is rechecked at send time; saved UI snapshots cannot
// authorize a different account or a changed attachment at the same array index.
enum AIInputPolicy {
    static func sourceAttachment(_ source: [String: Any], state: [String: Any], accountId: String) throws -> [String: Any] {
        guard !accountId.isEmpty, state["accountId"] as? String == accountId,
              let group = source["groupId"] as? String, let mid = source["messageId"] as? String,
              let index = source["attachmentIndex"] as? Int,
              let message = (state["messages"] as? [[String: Any]])?.first(where: { $0["groupId"] as? String == group && $0["id"] as? String == mid }),
              message["accountId"] as? String == accountId,
              let attachments = message["attachments"] as? [[String: Any]], attachments.indices.contains(index),
              let expected = source["expectedAttachment"] as? [String: Any] else {
            throw ReaderError.message("这份资料已不在当前账号的消息中，请回原消息重新选择。")
        }
        let item = attachments[index]
        guard ["url", "type", "name"].allSatisfy({ (expected[$0] as? String ?? "") == (item[$0] as? String ?? "") }),
              ["image", "document"].contains(item["type"] as? String ?? "") else {
            throw ReaderError.message("附件已变化或不支持直读，请回原消息重新选择。")
        }
        return item
    }
    static func messages(_ messages: [[String: Any]], appending parts: [[String: Any]]) throws -> [[String: Any]] {
        guard !messages.isEmpty, messages.count <= 200, messages.allSatisfy({ $0["content"] is String && ["system", "user", "assistant"].contains($0["role"] as? String ?? "") }) else {
            throw ReaderError.message("讨论内容格式无效，请重新选择材料。")
        }
        guard !parts.isEmpty else { return messages }
        var output = messages
        guard let index = output.lastIndex(where: { $0["role"] as? String == "user" }), let text = output[index]["content"] as? String else { throw ReaderError.message("请先填写要向 AI 提出的问题。") }
        output[index]["content"] = [["type": "text", "text": text]] + parts
        return output
    }
}
