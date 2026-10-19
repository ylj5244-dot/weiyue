import Foundation

private final class TitleStubProtocol: URLProtocol {
    struct Reply { var text: String; var status = 200; var delay = 0.002 }
    static var response: (URLRequest) throws -> Reply = { _ in throw URLError(.badServerResponse) }
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.response(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
                guard !stopped else { return }
                let object: [String: Any] = reply.status == 200
                    ? ["choices": [["message": ["content": reply.text], "finish_reason": "stop"]]]
                    : ["error": ["message": reply.text]]
                let data = try! JSONSerialization.data(withJSONObject: object)
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

@main struct DiscussionTitleTests {
    static var assertions = 0
    static func check(_ value: Bool, _ note: String) { assertions += 1; precondition(value, note) }
    static func rejects(_ note: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError(note) } catch { assertions += 1 }
    }
    static let account = "synthetic-title-account"
    static let base = "https://api.deepseek.com"
    static let model = "deepseek-flash"
    static func fixture(_ turns: [[String: Any]]? = nil) -> [String: Any] {
        var state = StateStore.empty(accountId: account)
        state["settings"] = ["baseURL": base, "model": model]
        state["discussions"] = [["id": "topic", "accountId": account, "title": "Old title", "messages": turns ?? [
            ["role": "user", "content": "为什么光模块公司的利润会受到 1.6T 产品放量影响？", "status": "sent"],
            ["role": "assistant", "content": "讨论集中在 1.6T 产品的销量、单价、良率和毛利率。", "reasoning": "PRIVATE_REASONING"]
        ], "contextSnapshots": [["accountId": account, "text": "原始资料：光模块产品迭代", "attachments": [["raw": "RAW_ATTACHMENT_BYTES"]]]]]]
        return state
    }
    static func payload(_ extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["accountId": account, "discussionId": "topic", "baseURL": base, "model": model]
        extra.forEach { result[$0.key] = $0.value }; return result
    }
    static func request(_ state: [String: Any]) throws -> DiscussionTitleRequest {
        try DiscussionTitlePolicy.request(state: state, activeAccountId: account, payload: payload())
    }
    static func editDiscussion(_ state: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var discussions = state["discussions"] as! [[String: Any]]; change(&discussions[0]); state["discussions"] = discussions
    }
    static func spin(until done: () -> Bool, timeout: Double = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        check(done(), "Synthetic title request timed out")
    }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(bytes, count: count) }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
#if DISCUSSION_TITLE_APP_TESTS
    static func appIntegration(configuration: URLSessionConfiguration) throws {
        // Construct only the delegate object. Never launch its app, windows,
        // account store, official browser or actual credential lookup.
        let app = AppDelegate()
        app.accountId = account; app.currentState = fixture()
        let injected = DiscussionTitleCoordinator(client: AIClient(configuration: configuration, keyReader: { _, _ in "synthetic-title-key" }))
        app.discussionTitles = injected
        var waiting: ((Result<Void, Error>) -> Void)?, replies: [Result<String, Error>] = []
        try injected.start(request(fixture()), authorize: { waiting = $0 }, isCurrent: { true }, completion: { replies.append($0) })
        rejects("Invalid primary request should fail validation") { try app.startAIRequest(id: "test", payload: [:], messages: []) }
        check(!injected.isActive && replies.count == 1, "Actual native primary entry point must cancel a title synchronously, before validation or other work")
        waiting?(.success(()))
        app.aiBridgeOperation = UUID(); app.aiBridgeGeneration = app.aiGeneration
        rejects("Title admitted while actual native AI operation active") { try app.startDiscussionTitle(id: "test", payload: payload()) }
        app.aiBridgeOperation = nil; app.contentOperation = UUID()
        rejects("Title admitted while extraction active") { try app.startDiscussionTitle(id: "test", payload: payload()) }
        check(app.contentOperation != nil, "Refusing title must leave extraction untouched")
        app.contentOperation = nil; app.terminationRequested = true
        rejects("Title admitted during actual native shutdown") { try app.startDiscussionTitle(id: "test", payload: payload()) }
    }
#endif
    static func main() throws {
        for (raw, expected) in [("标题：**1.6T 光模块利润驱动**", "1.6T 光模块利润驱动"), ("  “现金流与利润差异” \n", "现金流与利润差异"), ("Title: `融资担保比例变化`", "融资担保比例变化"), ("# 技术进步与产品毛利", "技术进步与产品毛利"), ("\"标题：_光模块定价变化_\"", "光模块定价变化"), ("*资料对比方法*", "资料对比方法")] {
            let actual: String
            do { actual = try DiscussionTitlePolicy.normalizedTitle(raw) }
            catch { fatalError("Valid wrapper rejected: \(raw): \(error)") }
            check(actual == expected, "Simple title wrappers must normalize without rewriting the topic")
        }
        for invalid in ["", "   ", "---", "😀🌙", "{\"title\":\"主题\"}", "[\"主题\"]", "- 光模块盈利", "1. 光模块盈利", "1.光模块盈利", "一、光模块盈利", "•光模块盈利", "主题\n解释：因为…", "<think>分析</think>主题", "理由：这是最佳标题", "[盈利](https://example.invalid)", "**未闭合", String(repeating: "题", count: 33)] {
            rejects("Malformed/model reasoning title accepted: " + invalid) { _ = try DiscussionTitlePolicy.normalizedTitle(invalid) }
        }
        check(try DiscussionTitlePolicy.normalizedTitle(String(repeating: "题", count: 32)).count == 32, "32-character title is accepted")
        var state = fixture()
        let initial = try request(state)
        check(initial.baseURL == base && initial.model == model && initial.thinking == "disabled", "Configured provider/model and confirmed thinking toggle are retained")
        check(initial.source.turns.count == 2 && initial.source.context.contains("1.6T"), "Title context contains actual question and answer")
        check(!initial.source.context.contains("PRIVATE_REASONING") && !initial.source.context.contains("RAW_ATTACHMENT_BYTES"), "Reasoning and raw attachments must not enter title context")
        let arbitrary = try DiscussionTitlePolicy.request(state: state, activeAccountId: account, payload: payload(["messages": [["role": "user", "content": "ARBITRARY_PAYLOAD"]]]))
        check(!arbitrary.source.context.contains("ARBITRARY_PAYLOAD"), "Bridge messages must never override persisted discussion content")
        for extra in [["accountId": "other"], ["discussionId": "missing"], ["baseURL": "https://other.invalid/v1"], ["model": "other-model"]] {
            rejects("Cross-account/missing/unconfigured title request accepted") { _ = try DiscussionTitlePolicy.request(state: state, activeAccountId: account, payload: payload(extra)) }
        }
        editDiscussion(&state) { $0["accountId"] = "other" }
        rejects("Foreign discussion accepted") { _ = try request(state) }
        state = fixture(); editDiscussion(&state) { $0["deletedAt"] = "2026-10-19T00:00:00Z" }
        rejects("Deleted discussion accepted") { _ = try request(state) }
        state = fixture(); state["accountId"] = "other"
        rejects("Foreign state accepted") { _ = try request(state) }
        state = fixture(); editDiscussion(&state) { $0["title"] = "Metadata update"; $0["updatedAt"] = "2026-10-19T00:00:00Z" }
        check(DiscussionTitlePolicy.isCurrent(initial, state: state, activeAccountId: account), "Only metadata changes must not invalidate source")
        editDiscussion(&state) { var turns = $0["messages"] as! [[String: Any]]; turns[1]["content"] = "Answer changed"; $0["messages"] = turns }
        check(!DiscussionTitlePolicy.isCurrent(initial, state: state, activeAccountId: account), "Changed answer must reject late title")

        var many: [[String: Any]] = [["role": "system", "content": "SYSTEM_SECRET"]]
        for index in 0..<16 { many.append(["role": index % 2 == 0 ? "user" : "assistant", "content": "TURN_\(index): " + String(repeating: "测", count: 1600)]) }
        many.append(many[1]); many.append(["role": "user", "status": "pending", "content": "PENDING_TOPIC"])
        many.append(["role": "user", "status": "failed", "content": "FAILED_QUESTION 现金流为何承压", "error": "FAILED_ERROR_DETAIL"])
        many.append(["role": "assistant", "status": "interrupted", "content": "INTERRUPTED_ANSWER 解释营运资金占用", "error": "INTERRUPTED_ERROR_DETAIL"])
        state = fixture(many)
        editDiscussion(&state) { $0["contextSnapshots"] = (0..<5).map { ["accountId": account, "text": "SNAPSHOT_\($0):" + String(repeating: "资", count: 1200)] }; $0["rangeSummary"] = ["label": "时段范围", "error": "RANGE_ERROR"] }
        let sampled = try request(state)
        check(sampled.source.turns.count == 10, "Use first 2 + last 8 unique useful turns")
        check(sampled.source.turns[0].content.hasPrefix("TURN_0:") && sampled.source.turns[1].content.hasPrefix("TURN_1:"), "Original question and first answer remain")
        check(sampled.source.turns[2].content.hasPrefix("TURN_10:"), "Middle turns are omitted deterministically")
        check(sampled.source.turns.allSatisfy { $0.content.count <= 1400 } && sampled.source.context.count <= 14000, "Outbound title context is bounded")
        for excluded in ["SYSTEM_SECRET", "PENDING_TOPIC", "FAILED_ERROR_DETAIL", "INTERRUPTED_ERROR_DETAIL", "RANGE_ERROR", "SNAPSHOT_3:", "SNAPSHOT_4:"] {
            check(!sampled.source.context.contains(excluded), "Excluded title data leaked: " + excluded)
        }
        check(sampled.source.context.contains("FAILED_QUESTION") && sampled.source.context.contains("INTERRUPTED_ANSWER"), "Failed question and partial answer retain their topic, excluding their error fields")
        editDiscussion(&state) { var turns = $0["messages"] as! [[String: Any]]; turns[5]["content"] = "Unsampled content changed"; $0["messages"] = turns }
        check(!DiscussionTitlePolicy.isCurrent(sampled, state: state, activeAccountId: account), "Native guard rejects even changed unsampled turns")
        let secretTurns: [[String: Any]] = [
            ["role": "user", "content": "为什么请求失败？ API Key: sk-syntheticABCDEFG\nAuthorization: Bearer fakeCredential123\n{\"api_key\":\"jsonSecretABCDEFG\",\"access_token\":\"tokenSecretABCDEFG\"}\ntoken = plainTokenABCDEFG\n保留问题"],
            ["role": "assistant", "content": "<think>HIDDEN_REASONING</think>配置检查。data:image/png;base64,RAWFAKEBYTES=="],
            ["role": "assistant", "status": "failed", "content": "HTTP 500 INTERNAL_SERVER_ERROR", "error": "HTTP 500 INTERNAL_SERVER_ERROR"]
        ]
        let clean = try request(fixture(secretTurns))
        for excluded in ["sk-syntheticABCDEFG", "fakeCredential123", "jsonSecretABCDEFG", "tokenSecretABCDEFG", "plainTokenABCDEFG", "HIDDEN_REASONING", "RAWFAKEBYTES", "INTERNAL_SERVER_ERROR"] { check(!clean.source.context.contains(excluded), "Credential/error/raw content leaked") }
        check(clean.source.context.contains("保留问题"), "Sanitization retains useful topic text")
        rejects("Pending-only empty discussion accepted") { _ = try request(fixture([["role": "user", "status": "pending", "content": "Not sent"]])) }
        check(try DiscussionTitlePolicy.thinking(baseURL: "https://api.openai.com/v1", model: "o3") == "auto", "Models that require thinking stay usable")
        check(try DiscussionTitlePolicy.thinking(baseURL: "https://compatible.invalid/v1", model: "custom") == "auto", "Unknown compatible model remains usable without invented toggle")

        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TitleStubProtocol.self]
        var lookups: [(String, String)] = []
        let titleClient = AIClient(configuration: configuration, keyReader: { lookups.append(($0, $1)); return "synthetic-title-key" })
        let coordinator = DiscussionTitleCoordinator(client: titleClient)
        var activeState = fixture(), requestCount = 0, completed: [Result<String, Error>] = []
        TitleStubProtocol.response = { request in
            requestCount += 1
            let payload = try body(request), messages = payload["messages"] as! [[String: Any]]
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-title-key", "Title uses injected account-scoped credentials")
            check(payload["model"] as? String == model && (payload["thinking"] as? [String: String])?["type"] == "disabled", "Actual title request uses configured model and disables thinking where supported")
            check(messages.count == 2 && messages[0]["role"] as? String == "system" && messages[1]["content"] as? String == initial.source.context, "Title sends its own instruction plus persisted bounded data")
            check(payload["tools"] == nil && payload["web_search"] == nil && messages.allSatisfy { $0["content"] is String }, "Title request never asks for search/tools or image/file parts")
            return .init(text: "标题：1.6T 产品的利润驱动")
        }
        try coordinator.start(initial, authorize: { $0(.success(())) }, isCurrent: { DiscussionTitlePolicy.isCurrent(initial, state: activeState, activeAccountId: account) }, completion: { completed.append($0) })
        spin { !completed.isEmpty }
        check(try completed[0].get() == "1.6T 产品的利润驱动" && coordinator.isActive == false && requestCount == 1, "Valid title completes once, without retry")
        check(lookups.count == 1 && lookups[0].0 == account && lookups[0].1 == base, "Credential scope exactly matches current account/provider")

        var authorizeLater: ((Result<Void, Error>) -> Void)?
        completed = []
        try coordinator.start(initial, authorize: { authorizeLater = $0 }, isCurrent: { true }, completion: { completed.append($0) })
        rejects("Parallel title admitted") { try coordinator.start(initial, authorize: { $0(.success(())) }, isCurrent: { true }, completion: { _ in }) }
        coordinator.cancel(); authorizeLater?(.success(()))
        check(completed.count == 1 && requestCount == 1 && coordinator.isActive == false, "Cancellation during credential lookup resolves once and prevents network dispatch")
        if case .success = completed[0] { fatalError("Cancelled title succeeded") }

        completed = []; requestCount = 0
        TitleStubProtocol.response = { _ in requestCount += 1; return .init(text: "过期标题", delay: 0.1) }
        try coordinator.start(initial, authorize: { $0(.success(())) }, isCurrent: { DiscussionTitlePolicy.isCurrent(initial, state: activeState, activeAccountId: account) }, completion: { completed.append($0) })
        spin { requestCount == 1 }
        editDiscussion(&activeState) { $0["deletedAt"] = "2026-10-19T00:00:00Z" }
        spin { completed.count == 1 }
        if case .success = completed[0] { fatalError("Deleted discussion received late title") }
        check(!coordinator.isActive, "Stale result releases its own operation")

        completed = []; activeState = fixture(); requestCount = 0
        var generationCurrent = true
        try coordinator.start(initial, authorize: { $0(.success(())) }, isCurrent: { generationCurrent }, completion: { completed.append($0) })
        spin { requestCount == 1 }; generationCurrent = false; coordinator.cancelIfInvalidated()
        check(completed.count == 1 && !coordinator.isActive, "Account/quit/generation invalidation cancels immediately")
        generationCurrent = true
        try coordinator.start(initial, authorize: { $0(.success(())) }, isCurrent: { true }, completion: { completed.append($0) })
        spin { completed.count == 2 }
        check(try completed[1].get() == "过期标题", "Late completion from old identity does not clear a replacement title")
        check(requestCount == 2, "Cancellation does not trigger a hidden retry")

        completed = []; requestCount = 0
        TitleStubProtocol.response = { _ in requestCount += 1; return .init(text: "{\"title\":\"bad\"}") }
        try coordinator.start(initial, authorize: { $0(.success(())) }, isCurrent: { true }, completion: { completed.append($0) })
        spin { completed.count == 1 }; if case .success = completed[0] { fatalError("Malformed title response accepted") }
        check(requestCount == 1, "Invalid output must never cause an automatic retry")
        completed = []; requestCount = 0
        try coordinator.start(initial, authorize: { $0(.failure(ReaderError.message("Synthetic credential unavailable"))) }, isCurrent: { true }, completion: { completed.append($0) })
        check(completed.count == 1 && requestCount == 0, "Missing authorization fails without contacting provider")

        let primary = AIClient(configuration: configuration, keyReader: { _, _ in "synthetic-primary-key" })
        var primaryResult: Result<String, Error>?
        requestCount = 0; completed = []
        TitleStubProtocol.response = { request in
            requestCount += 1
            let messages = try body(request)["messages"] as! [[String: Any]]
            let isPrimary = messages[0]["content"] as? String == "PRIMARY_ACTIVE"
            return .init(text: isPrimary ? "Primary answer retained" : "Title to cancel", delay: 0.15)
        }
        try primary.send(accountId: account, baseURL: base, model: model, messages: [["role": "user", "content": "PRIMARY_ACTIVE"]]) { primaryResult = $0 }
        try coordinator.start(initial, authorize: { $0(.success(())) }, isCurrent: { true }, completion: { completed.append($0) })
        spin { requestCount == 2 }; coordinator.cancel()
        spin { primaryResult != nil }
        check(try primaryResult!.get() == "Primary answer retained", "Cancel title must never cancel independent primary AI transport")
        check(completed.count == 1, "Cancelled title has exactly one completion while primary finishes")
#if DISCUSSION_TITLE_APP_TESTS
        try appIntegration(configuration: configuration)
#endif
        print("PASS: \(assertions) title checks; persisted account-scoped source, bounded/sanitized context, strict output, configured provider, independent cancellation and stale result guards; fake keyReader + URLProtocol only")
    }
}
