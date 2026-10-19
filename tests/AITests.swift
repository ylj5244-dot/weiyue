import Foundation

private final class StubAIProtocol: URLProtocol {
    static var response: (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.badServerResponse) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct AITests {
    static func wait<T>(_ start: (@escaping (Result<T, Error>) -> Void) throws -> Void) throws -> Result<T, Error> {
        var result: Result<T, Error>?
        try start { result = $0 }
        let deadline = Date().addingTimeInterval(3)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard let result else { throw ReaderError.message("Simulated request timed out") }
        return result
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; output.append(buffer, count: count)
        }
        return output
    }
    static func main() throws {
        let base = try AIClient.endpoint("https://api.example.com/v1")
        let full = try AIClient.endpoint("https://api.example.com/v1/chat/completions")
        precondition(base.absoluteString == "https://api.example.com/v1/chat/completions")
        precondition(full.absoluteString == "https://api.example.com/v1/chat/completions")
        let normalized = try AIClient.endpoint(" HTTPS://API.EXAMPLE.COM:443/v1/ ")
        precondition(normalized.absoluteString == full.absoluteString, "Equivalent endpoint spelling must not change Keychain scope")
        for invalid in ["http://example.com", "https://key@example.com", "https://example.com?key=secret", "file:///tmp/a"] {
            do { _ = try AIClient.endpoint(invalid); fatalError("accepted unsafe URL") } catch {}
        }
        // Exercise the real key used in every Keychain lookup/update/delete without
        // creating credentials or requesting access to the user's system keychain.
        let accountA = "9007199254740993001", accountB = "9007199254740993002"
        let aPrimary = try SecretStore.storageAccount(accountId: accountA, baseURL: "https://api.example.com/v1")
        let aEquivalent = try SecretStore.storageAccount(accountId: accountA, baseURL: "HTTPS://API.EXAMPLE.COM:443/v1/chat/completions/")
        let bPrimary = try SecretStore.storageAccount(accountId: accountB, baseURL: "https://api.example.com/v1")
        let aOtherOrigin = try SecretStore.storageAccount(accountId: accountA, baseURL: "https://other.example.com/v1")
        let aOtherPort = try SecretStore.storageAccount(accountId: accountA, baseURL: "https://api.example.com:8443/v1")
        let aOtherPath = try SecretStore.storageAccount(accountId: accountA, baseURL: "https://api.example.com/v2")
        precondition(aPrimary == aEquivalent, "Canonical equivalent endpoints should share their own key")
        precondition(Set([aPrimary, bPrimary, aOtherOrigin, aOtherPort, aOtherPath]).count == 5, "Accounts, origins and tenant/API paths must have isolated credentials")
        precondition(aPrimary != "api-key", "Legacy unscoped credentials must never be read implicitly")
        for invalidAccount in ["", "   "] {
            do { _ = try SecretStore.storageAccount(accountId: invalidAccount, baseURL: "https://api.example.com/v1"); fatalError("unidentified account accepted") } catch {}
        }
        do { _ = try SecretStore.storageAccount(accountId: accountA, baseURL: "http://api.example.com/v1"); fatalError("unsafe credential scope accepted") } catch {}
        var requests = AIRequestGate()
        let old = try requests.begin()
        requests.cancel()
        let next = try requests.begin()
        precondition(!requests.finish(old))
        precondition(requests.active == next)
        do { _ = try requests.begin(); fatalError("parallel AI request accepted") } catch {}
        precondition(requests.finish(next))
        precondition(requests.active == nil)
        for (raw, expected) in [
            ("https://api.deepseek.com", "https://api.deepseek.com/models"),
            ("https://api.example.com/v1", "https://api.example.com/v1/models"),
            ("https://api.example.com/tenant/v2/chat/completions/", "https://api.example.com/tenant/v2/models")
        ] { let actual = try AIClient.modelsEndpoint(raw); precondition(actual.absoluteString == expected) }
        let fakeKey = "unit-secret-never-real"
        let errorData = try JSONSerialization.data(withJSONObject: ["error": ["message": "The supported API model names are deepseek-flash, deepseek-v4-pro, but you passed DeepSeek-V4.1-Flash-1017. Key=" + fakeKey + " Authorization: Bearer another-test-token", "code": "invalid_model", "param": "model"]])
        let detail = AIClient.serviceError(statusCode: 400, data: errorData, secret: fakeKey).localizedDescription
        precondition(detail.contains("参数无效") && detail.contains("deepseek-flash") && detail.contains("invalid_model") && detail.contains("model"))
        precondition(!detail.contains(fakeKey) && !detail.contains("another-test-token") && !detail.contains("暂时不可用"))
        let longData = try JSONSerialization.data(withJSONObject: ["error": ["message": String(repeating: "内容", count: 2000) + fakeKey, "code": fakeKey, "param": "Bearer third-token"]])
        let bounded = AIClient.serviceError(statusCode: 422, data: longData, secret: fakeKey).localizedDescription
        precondition(bounded.count <= 1200 && !bounded.contains(fakeKey) && !bounded.contains("third-token"))
        let html = AIClient.serviceError(statusCode: 400, data: Data(("<html>" + fakeKey + "</html>").utf8), secret: fakeKey).localizedDescription
        precondition(html.contains("参数无效") && !html.contains("<html>"))

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubAIProtocol.self]
        var keyLookups: [(String, String)] = []
        let client = AIClient(configuration: config, keyReader: { account, base in keyLookups.append((account, base)); return fakeKey })
        var observedRequests: [URLRequest] = []
        StubAIProtocol.response = { request in
            observedRequests.append(request)
            precondition(request.httpMethod == "GET")
            precondition(request.url?.absoluteString == "https://api.example.invalid/v1/models")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + fakeKey)
            return (200, Data(#"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro","name":"V4 Pro"},{"id":"deepseek-flash"}]}"#.utf8))
        }
        let models = try wait { done in try client.listModels(accountId: accountA, baseURL: "https://api.example.invalid/v1", completion: done) }.get()
        precondition(models == [["id": "deepseek-flash", "name": "deepseek-flash"], ["id": "deepseek-v4-pro", "name": "V4 Pro"]])
        precondition(keyLookups[0].0 == accountA && keyLookups[0].1 == "https://api.example.invalid/v1")
        StubAIProtocol.response = { request in
            observedRequests.append(request)
            precondition(request.httpMethod == "POST")
            let payload = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
            precondition(payload["model"] as? String == "DeepSeek-V4.1-Flash-1017", "Send must trim only, without silently selecting another model")
            return (400, errorData)
        }
        let failure: Result<String, Error> = try wait { done in try client.send(accountId: accountA, baseURL: "https://api.example.invalid/v1", model: "  DeepSeek-V4.1-Flash-1017 \n", messages: [["role": "user", "content": "Synthetic test"]], completion: done) }
        guard case .failure(let returnedError) = failure else { fatalError("400 became a success") }
        precondition(returnedError.localizedDescription.contains("deepseek-flash") && !returnedError.localizedDescription.contains(fakeKey))
        precondition(observedRequests.count == 2, "Invalid model must never trigger an automatic retry")
        StubAIProtocol.response = { _ in (200, Data(#"{"data":[{"name":"missing id"}]}"#.utf8)) }
        let malformed: Result<[[String: String]], Error> = try wait { done in try client.listModels(accountId: accountA, baseURL: "https://api.example.invalid/v1", completion: done) }
        guard case .failure = malformed else { fatalError("Malformed model list accepted") }
        let dummySession = URLSession(configuration: config)
        let dummyTask = dummySession.dataTask(with: URL(string: "https://api.example.invalid/v1/models")!)
        let redirect = HTTPURLResponse(url: dummyTask.originalRequest!.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": "https://other.invalid/"])!
        var redirectWasRejected = false
        client.urlSession(dummySession, task: dummyTask, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://other.invalid/")!)) { redirectWasRejected = $0 == nil }
        precondition(redirectWasRejected); dummySession.invalidateAndCancel()
        print("PASS: canonical scoped keys and cancellation gate; safe detailed 400 errors/redaction; model GET endpoints/list parsing; simulated HTTP list/send; trimmed unchanged model and no retry; redirects refused")
    }
}
