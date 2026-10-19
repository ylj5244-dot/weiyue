import Foundation

private final class StreamStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var mime = "text/event-stream"
        var chunks: [Data]
        var interval = 0.002
        var error: Error? = nil
    }
    static var reply: (URLRequest) throws -> Reply = { _ in throw URLError(.badServerResponse) }
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.mime])!, cacheStoragePolicy: .notAllowed)
            deliver(reply, index: 0)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func deliver(_ reply: Reply, index: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.interval) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock(); guard !stopped else { return }
            if index < reply.chunks.count {
                self.client?.urlProtocol(self, didLoad: reply.chunks[index]); self.deliver(reply, index: index + 1)
            } else if let error = reply.error { self.client?.urlProtocol(self, didFailWithError: error) }
            else { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

@main struct AIStreamingTests {
    static var assertions = 0
    static func check(_ yes: Bool, _ note: String) { assertions += 1; precondition(yes, note) }
    static func wait<T>(_ start: (@escaping (Result<T, Error>) -> Void) throws -> Void) throws -> Result<T, Error> {
        var result: Result<T, Error>?
        try start { check(Thread.isMainThread, "Completion must run on main thread"); result = $0 }
        let deadline = Date().addingTimeInterval(7)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        guard let result else { throw ReaderError.message("Simulated stream timed out") }; return result
    }
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(bytes, count: count) }
        }
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func event(_ dictionary: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: dictionary)
        return Data("data: ".utf8) + json + Data("\r\n\r\n".utf8)
    }
    static func delta(_ value: [String: Any]) -> Data { event(["choices": [["index": 0, "delta": value, "finish_reason": NSNull()]]]) }
    static let finish = event(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]])
    static let done = Data("data: [DONE]\n\n".utf8)
    static func main() throws {
        // The parser must accept CRLF, comments, multi-line JSON, and UTF-8 split at every byte.
        let jsonText = "{\"choices\":[{\"delta\":{\"content\":\"你好🌙\"}}]}"
        let input = Data((": keepalive\r\ndata: " + jsonText + "\r\n\r\ndata: {\n" + "data: \"a\":1}\n\n").utf8)
        var parser = AIEventStreamParser(), outputs: [String] = []
        for byte in input { outputs += try parser.append(Data([byte])) }
        check(outputs == [jsonText, "{\n\"a\":1}"], "SSE line framing and UTF8 must survive all byte boundaries")
        outputs += try parser.append(Data("data: [DONE]".utf8), final: true)
        check(outputs.last == "[DONE]", "Final unterminated SSE event must flush")
        do { var invalid = AIEventStreamParser(); _ = try invalid.append(Data(repeating: 65, count: 1_000_001)); fatalError("Unbounded SSE accepted") } catch { assertions += 1 }

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamStubProtocol.self]
        let client = AIClient(configuration: config, keyReader: { _, _ in "test-key-never-real" })
        let messages: [[String: Any]] = [["role": "user", "content": "Synthetic sample"]]
        var events: [[String: Any]] = []
        let stream = delta(["reasoning_content": "先阅读材料。 "]) + delta(["content": "你好，"]) + delta(["content": "世界🌙"])
            + event(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]], "usage": ["prompt_tokens": 10, "completion_tokens": 6, "total_tokens": 16]]) + done
        StreamStubProtocol.reply = { request in
            let payload = body(request)
            check(payload["stream"] as? Bool == true, "Actual request must enable streaming")
            check((payload["thinking"] as? [String: String])?["type"] == "disabled", "DeepSeek thinking off must be sent explicitly")
            check((payload["stream_options"] as? [String: Bool])?["include_usage"] == true, "Official supported usage parameter must be sent")
            return .init(chunks: stride(from: 0, to: stream.count, by: 7).map { Data(stream[$0..<min(stream.count, $0 + 7)]) })
        }
        let answer = try wait { done in
            try client.send(accountId: "test", baseURL: "https://api.deepseek.com", model: "deepseek-flash", messages: messages, thinking: "disabled", onProgress: { event in
                check(Thread.isMainThread, "Progress must run on main thread"); events.append(event)
            }, completion: done)
        }.get()
        check(answer == "你好，世界🌙", "Stream must concatenate the exact content only")
        check(events.compactMap { $0["contentDelta"] as? String }.joined() == answer, "Deltas and final output must agree")
        check(events.compactMap { $0["reasoningDelta"] as? String }.joined() == "先阅读材料。 ", "Only actual reasoning_content is surfaced")
        check(events.contains { ($0["usage"] as? [String: Any])?["total_tokens"] as? Int == 16 }, "Usage is actual server output")
        check(events.first?["phase"] as? String == "preparing" && events.contains { $0["phase"] as? String == "connecting" } && events.last?["phase"] as? String == "completed", "Phases begin and end predictably")
        check(events.allSatisfy { ($0["elapsed"] as? Double ?? -1) >= 0 }, "Elapsed time present on all progress")

        StreamStubProtocol.reply = { _ in .init(chunks: [delta(["content": "partial"])]) }
        let truncated: Result<String, Error> = try wait { done in try client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages, completion: done) }
        guard case .failure(let incomplete) = truncated else { fatalError("Premature EOF incorrectly succeeded") }
        check(incomplete.localizedDescription.contains("中断"), "Truncated stream is distinguishable")
        StreamStubProtocol.reply = { _ in .init(chunks: [event(["error": ["message": "bad request test-key-never-real", "code": "stream_error"]])]) }
        let streamError: Result<String, Error> = try wait { done in try client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages, completion: done) }
        guard case .failure(let error) = streamError else { fatalError("Stream error incorrectly succeeded") }
        check(error.localizedDescription.contains("stream_error") && !error.localizedDescription.contains("test-key-never-real"), "Stream errors are actionable and redacted")
        StreamStubProtocol.reply = { _ in .init(status: 429, mime: "application/json", chunks: [Data("{\"error\":{\"message\":\"quota exceeded\"}}".utf8)]) }
        let rejected: Result<String, Error> = try wait { done in try client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages, completion: done) }
        guard case .failure(let rejectedError) = rejected else { fatalError("HTTP error incorrectly succeeded") }; check(rejectedError.localizedDescription.contains("quota exceeded"), "Original HTTP diagnostics preserved")
        StreamStubProtocol.reply = { _ in .init(mime: "application/json", chunks: [Data("{\"choices\":[{\"message\":{\"content\":\"Buffered answer\"}}]}".utf8)]) }
        events = []
        let buffered = try wait { done in try client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages, onProgress: { events.append($0) }, completion: done) }.get()
        check(buffered == "Buffered answer" && events.contains { $0["buffered"] as? Bool == true }, "Nonstreaming compatible servers remain usable and disclosed")
        // Buffered compatible responses must disclose partial output just as
        // SSE does. The batch runner observes these warnings before deciding
        // that all records have been summarized; the partial text stays usable.
        let finishWarnings = [
            "length": "模型达到本次输出上限，回答可能尚未结束；可继续追问。",
            "content_filter": "服务的内容过滤器终止了输出。"
        ]
        for reason in ["length", "content_filter", "stop"] {
            for streaming in [false, true] {
                events = []
                StreamStubProtocol.reply = { _ in
                    if streaming { return .init(chunks: [delta(["content": "Preserved partial"]), event(["choices": [["index":0,"delta":[:],"finish_reason":reason]]]), Self.done]) }
                    let json: [String: Any] = ["choices": [
                        ["index":1,"message":["content":"Wrong choice"],"finish_reason":"stop"],
                        ["index":0,"message":["content":"Preserved partial"],"finish_reason":reason]
                    ]]
                    return .init(mime:"application/json",chunks:[try JSONSerialization.data(withJSONObject:json)])
                }
                let output = try wait { done in
                    try client.send(accountId:"test",baseURL:"https://example.invalid/v1",model:"custom",messages:messages,onProgress:{events.append($0)},completion:done)
                }.get()
                check(output == "Preserved partial", "Both transports preserve choice zero output without inventing missing text")
                let warnings = events.compactMap { $0["warning"] as? String }
                if let warning = finishWarnings[reason] {
                    check(warnings == [warning], "Buffered and SSE truncated output must surface the same truthful warning")
                    check(events.contains { $0["finishReason"] as? String == reason }, "The actual finish reason must accompany the warning")
                    let warningIndex = events.firstIndex { $0["warning"] as? String == warning }!
                    let completedIndex = events.firstIndex { $0["phase"] as? String == "completed" }!
                    check(warningIndex < completedIndex, "Truncation warning is delivered before completion, so summary completeness can be rejected")
                } else { check(warnings.isEmpty, "Normal completed output does not invent a truncation warning") }
                check(streaming || events.contains { $0["buffered"] as? Bool == true }, "Buffered output remains disclosed")
            }
        }
        StreamStubProtocol.reply = { _ in .init(mime: "application/octet-stream", chunks: [delta(["content": "No MIME"]), finish, done]) }
        let noMIME = try wait { done in try client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages, completion: done) }.get()
        check(noMIME == "No MIME", "Clearly framed SSE with absent content type is supported")

        // Cancel midway, immediately start another generation, and prove late bytes
        // from the previous generation cannot reach either result or progress UI.
        var cancelled: Result<String, Error>?, replacement: Result<String, Error>?, staleEvents = 0, didCancel = false
        StreamStubProtocol.reply = { _ in .init(chunks: [delta(["content": "first"]), delta(["content": "late"]), finish, done], interval: 0.03) }
        try client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages, onProgress: { event in
            if didCancel { staleEvents += 1 }
            if event["contentDelta"] != nil && !didCancel {
                didCancel = true; client.cancel()
                StreamStubProtocol.reply = { _ in .init(chunks: [delta(["content": "replacement"]), finish, done]) }
                try! client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages) { replacement = $0 }
            }
        }) { cancelled = $0 }
        let deadline = Date().addingTimeInterval(4)
        while (cancelled == nil || replacement == nil) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard case .failure(let cancelError) = cancelled else { fatalError("Cancelled request did not settle") }
        check((cancelError as? URLError)?.code == .cancelled, "Cancelled generation receives cancellation")
        check(try replacement?.get() == "replacement", "New request succeeds independently")
        check(staleEvents == 0, "Cancelled generation cannot emit stale progress")

        var cancelledBeforeDispatchCalls = 0
        StreamStubProtocol.reply = { _ in cancelledBeforeDispatchCalls += 1; return .init(chunks: [delta(["content": "must not send"]), finish, done]) }
        let earlyCancel: Result<String, Error> = try wait { done in
            try client.send(accountId: "test", baseURL: "https://example.invalid/v1", model: "custom", messages: messages, completion: done)
            client.cancel()
        }
        guard case .failure(let earlyError) = earlyCancel else { fatalError("Cancelled preparation sent a request") }
        check((earlyError as? URLError)?.code == .cancelled && cancelledBeforeDispatchCalls == 0, "Cancel during background payload preparation prevents network dispatch")

        // Refresh must hit /models on each click and retain novel IDs returned by the server.
        var listCalls = 0
        StreamStubProtocol.reply = { request in
            listCalls += 1
            check(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData, "Model refresh bypasses URL caches")
            check(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache, no-store", "Model refresh sends cache control")
            let data = listCalls == 1 ? "{\"data\":[{\"id\":\"deepseek-flash\"}]}" : "{\"data\":[{\"id\":\"new-server-model\",\"name\":\"New\"},{\"id\":\"deepseek-flash\"},{\"id\":\"new-server-model\"}]}"
            return .init(mime: "application/json", chunks: [Data(data.utf8)])
        }
        _ = try wait { done in try client.listModels(accountId: "test", baseURL: "https://api.deepseek.com", completion: done) }.get()
        let refreshed = try wait { done in try client.listModels(accountId: "test", baseURL: "https://api.deepseek.com", completion: done) }.get()
        check(listCalls == 2 && refreshed.map { $0["id"]! } == ["new-server-model", "deepseek-flash"], "Latest server models retained without invented version IDs")

        let deepseek = try AIClient.endpoint("https://api.deepseek.com"), openai = try AIClient.endpoint("https://api.openai.com/v1"), compatible = try AIClient.endpoint("https://custom.invalid/v1")
        let image: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": "Translate"], ["type": "image_url", "image_url": ["url": "data:image/png;base64,aGVsbG8="]]]]]
        let pdf: [[String: Any]] = [["role": "user", "content": [["type": "file", "file": ["filename": "sample.pdf", "file_data": "data:application/pdf;base64,JVBERi0xLjQ="]]]]]
        func payload(_ endpoint: URL, _ model: String, _ materials: [[String: Any]], _ thinking: String = "auto", _ images: Bool = false, _ pdf: Bool = false) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: AIModelPolicy.requestBody(endpoint: endpoint, model: model, messages: materials, thinking: thinking, allowImages: images, allowPDF: pdf)) as! [String: Any]
        }
        check((try payload(deepseek, "deepseek-flash", image))["messages"] != nil, "DeepSeek Flash supports raw image content")
        check((try payload(openai, "gpt-4.1", pdf))["messages"] != nil, "Known OpenAI vision model supports inline PDF")
        check((try payload(compatible, "my-model", image, "auto", true))["messages"] != nil, "Explicit compatible-image capability is honored")
        check((try payload(openai, "gpt-6-sol", messages, "disabled"))["reasoning_effort"] as? String == "none", "Supported OpenAI thinking-off mapping")
        for operation in [
            { try payload(deepseek, "deepseek-v4-pro", image) },
            { try payload(deepseek, "deepseek-flash", pdf) },
            { try payload(compatible, "deepseek-flash", image) },
            { try payload(compatible, "my-model", messages, "enabled") },
            { try payload(openai, "gpt-6-astra", messages, "disabled") },
            { try payload(deepseek, "deepseek-flash", [["role": "assistant", "content": image[0]["content"]!]]) }
        ] { do { _ = try operation(); fatalError("Unsupported capability was sent") } catch { assertions += 1 } }
        check((try AIClient.capabilities(baseURL: "https://api.deepseek.com", model: "deepseek-flash"))["images"] as? Bool == true, "Current official Flash vision capability exposed")
        let attachment: [String: Any] = ["url": "https://weibo.invalid/test.png", "type": "image", "name": "test.png"]
        let nativeState: [String: Any] = ["accountId": "A", "messages": [["accountId": "A", "groupId": "group", "id": "message", "attachments": [attachment]]]]
        let source: [String: Any] = ["groupId": "group", "messageId": "message", "attachmentIndex": 0, "expectedAttachment": attachment]
        check(try AIInputPolicy.sourceAttachment(source, state: nativeState, accountId: "A")["url"] as? String == attachment["url"] as? String, "Valid native source resolves exactly")
        var staleSource = source; staleSource["expectedAttachment"] = ["url": "https://weibo.invalid/changed.png", "type": "image", "name": "test.png"]
        var badIndex = source; badIndex["attachmentIndex"] = -1
        for operation in [
            { try AIInputPolicy.sourceAttachment(source, state: nativeState, accountId: "B") },
            { try AIInputPolicy.sourceAttachment(staleSource, state: nativeState, accountId: "A") },
            { try AIInputPolicy.sourceAttachment(badIndex, state: nativeState, accountId: "A") }
        ] { do { _ = try operation(); fatalError("Unsafe source accepted") } catch { assertions += 1 } }
        let conversation: [[String: Any]] = [["role": "system", "content": "Keep system text"], ["role": "user", "content": "Earlier question"], ["role": "assistant", "content": "Earlier answer"], ["role": "user", "content": "Current question"]]
        let appended = try AIInputPolicy.messages(conversation, appending: [["type": "text", "text": "native attachment marker"]])
        check(appended[0]["content"] as? String == "Keep system text" && appended[1]["content"] as? String == "Earlier question", "File insertion preserves system and previous turns")
        check((appended[3]["content"] as? [[String: String]])?.first?["text"] == "Current question", "Current user question precedes native file parts")
        do { _ = try AIInputPolicy.messages(image, appending: []); fatalError("JS-provided multimodal bytes bypassed native source validation") } catch { assertions += 1 }
        print("PASS: \(assertions) streaming/real-time progress/UTF8/SSE/error/cancellation/models refresh/multimodal/thinking assertions (synthetic URLProtocol only)")
    }
}
