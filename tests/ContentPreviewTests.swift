import AppKit
import WebKit
import Quartz
import PDFKit
import Network
import Vision

// All data is synthetic. HTTP listens only on 127.0.0.1; no remote URLs,
// application state, keychain, or external application launches are used.
@main final class ContentPreviewTests: NSObject, NSApplicationDelegate {
    var checks = 0, finished = false
    let first = ContentPreviewController(), second = ContentPreviewController()
    var root: URL!, output: URL!, allowed: URL!, pdf: URL!, word: URL!
    var window: NSWindow!, previousApp: NSRunningApplication?
    var listener: NWListener?, base = "", requests: [String] = [], snapshots: [[String: Any]] = []
    static func main() {
        let app = NSApplication.shared, delegate = ContentPreviewTests()
        DispatchQueue.global().asyncAfter(deadline: .now() + 100) { print("FAIL: content preview process watchdog"); fflush(stdout); exit(1) }
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
    func check(_ value: Bool, _ label: String) throws {
        checks += 1; if !value { throw ReaderError.message(label) }
    }
    func rejects(_ label: String, _ work: () throws -> Void) throws {
        do { try work() } catch { checks += 1; return }
        throw ReaderError.message("Expected rejection: " + label)
    }
    func guarded(_ work: () throws -> Void) { do { try work() } catch { finish(false, error.localizedDescription) } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guarded {
            previousApp = NSWorkspace.shared.frontmostApplication
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
            for raw in ["https://example.invalid/page?q=1", "http://example.invalid/", "HTTPS://example.invalid/path"] {
                try check(try ContentPreviewPolicy.webURL(raw).host == "example.invalid", "HTTP(S) URL accepted")
            }
            for raw in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "weiyue-media://cache/file", "mailto:test@example.invalid", "https://user:pass@example.invalid/", "https:///", "/relative/path"] {
                try rejects(raw) { _ = try ContentPreviewPolicy.webURL(raw) }
            }
            let fm = FileManager.default
            root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("weiyue-content-preview-tests-" + UUID().uuidString)
            allowed = root.appendingPathComponent("allowed")
            let outside = root.appendingPathComponent("outside.txt")
            try fm.createDirectory(at: allowed, withIntermediateDirectories: true)
            try Data("offline synthetic text".utf8).write(to: outside)
            let good = allowed.appendingPathComponent("safe.txt")
            try Data("offline synthetic document".utf8).write(to: good)
            let link = allowed.appendingPathComponent("link.txt"), linkedRoot = root.appendingPathComponent("linked-root")
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: allowed)
            try rejects("outside allowed directory") { try first.open(file: outside, name: "outside", allowedDirectory: allowed) }
            try rejects("file symbolic link") { try first.open(file: link, name: "link", allowedDirectory: allowed) }
            try rejects("symbolic-link allowed root") { try first.open(file: linkedRoot.appendingPathComponent("safe.txt"), name: "link root", allowedDirectory: linkedRoot) }
            try rejects("directory is not regular file") { try first.open(file: allowed, name: "directory", allowedDirectory: root) }
            try rejects("missing file") { try first.open(file: allowed.appendingPathComponent("missing.txt"), name: "missing", allowedDirectory: allowed) }
            try makeDocuments()
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "微阅 1.0.10 · 合成原生预览验收"
            window.contentView = first.view; window.appearance = NSAppearance(named: .aqua)
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            first.layout(NSRect(x: 0, y: 0, width: 900, height: 700), visible: true)
            try startHTTPFixture()
        }
    }
    func makeDocuments() throws {
        pdf = allowed.appendingPathComponent("synthetic-preview.pdf")
        let page = SyntheticPDFPage(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        try page.dataWithPDF(inside: page.bounds).write(to: pdf)
        try check(PDFDocument(url: pdf)?.string?.contains("NATIVE PDF PREVIEW V110") == true, "synthetic PDF contains real readable page text")
        word = allowed.appendingPathComponent("synthetic-preview.docx")
        let package = root.appendingPathComponent("word-package"), fm = FileManager.default
        try fm.createDirectory(at: package.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: package.appendingPathComponent("word"), withIntermediateDirectories: true)
        let types = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#
        let relationships = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#
        let document = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:rPr><w:b/><w:color w:val="205DA1"/><w:sz w:val="36"/></w:rPr><w:t>NATIVE DOCX PREVIEW V110</w:t></w:r></w:p><w:p><w:r><w:rPr><w:sz w:val="26"/></w:rPr><w:t>This is an actual temporary Word document.</w:t></w:r></w:p><w:p><w:r><w:t>Only synthetic content. No account data or remote resource.</w:t></w:r></w:p><w:p><w:r><w:t>Quick Look must render this text inside the native preview.</w:t></w:r></w:p><w:p><w:r><w:rPr><w:b/><w:color w:val="26836C"/></w:rPr><w:t>DOCUMENT CONTENT CHECK: 123456789</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1000" w:bottom="1440" w:left="1000"/></w:sectPr></w:body></w:document>"#
        for (name, content) in [("[Content_Types].xml", types), ("_rels/.rels", relationships), ("word/document.xml", document)] { try Data(content.utf8).write(to: package.appendingPathComponent(name)) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = package
        zip.arguments = ["-q", "-r", word.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run(); zip.waitUntilExit(); try check(zip.terminationStatus == 0, "synthetic DOCX package created")
    }
    func startHTTPFixture() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters); listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
                let path = String(request.split(separator: " ").dropFirst().first ?? "/")
                self.requests.append(path)
                let secondPage = path.hasPrefix("/two"), title = secondPage ? "NATIVE WEB PAGE TWO" : "NATIVE WEB PAGE ONE"
                let html = "<!doctype html><html><head><meta charset='utf-8'><meta name='referrer' content='no-referrer'><title>\(title)</title><style>body{font:20px -apple-system;background:#f2f6fa;color:#203040;margin:40px}h1{font-size:34px;color:#205da1}article{background:white;border:2px solid #c3d5e7;border-radius:15px;padding:30px}a{display:inline-block;margin-top:20px;color:#165da0}</style></head><body><article><h1>\(title)</h1><p>Actual native WKWebView content, served only on loopback.</p><p>Navigation and isolation test for Weiyue 1.0.10.</p><a id='next' href='\(secondPage ? "/one" : "/two")'>\(secondPage ? "Return to page one" : "Open page two")</a><p>HTTP fixture request \(self.requests.count)</p></article></body></html>"
                let bytes = Data(html.utf8), header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = server.port { self.base = "http://127.0.0.1:\(port.rawValue)"; self.startBrowserTests() }
            else if case .failed(let error) = state { self.finish(false, error.localizedDescription) }
        }
        server.start(queue: .main)
    }
    func wait(_ label: String, timeout: TimeInterval = 8, until condition: @escaping () -> Bool, then next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if self.finished { return }
            if condition() { next(); return }
            if Date() >= deadline { self.finish(false, "Timeout: " + label); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }
    func loaded(_ title: String) -> Bool { first.webView?.title == title && first.webView?.isLoading == false }
    func startBrowserTests() {
        guarded {
            for controller in [first, second] {
                try controller.open(url: URL(string: base + "/one")!, name: "Loopback fixture")
                let browser = controller.webView!
                try check(!browser.configuration.websiteDataStore.isPersistent, "content browser is nonpersistent")
                let scripts = browser.configuration.userContentController.userScripts
                try check(scripts.count == 1 && scripts[0].isForMainFrameOnly && scripts[0].injectionTime == .atDocumentEnd && !scripts[0].source.contains("messageHandlers"), "only the main-frame reading layout script is injected; no app bridge")
            }
            first.layout(window.contentView!.bounds, visible: true)
            try check(first.webView !== second.webView, "previews do not share browser instances")
            try check(first.webView!.configuration.userContentController !== second.webView!.configuration.userContentController, "independent content controllers")
            try check(first.webView!.configuration.websiteDataStore !== second.webView!.configuration.websiteDataStore, "independent ephemeral stores")
            wait("first native loopback page", until: { self.loaded("NATIVE WEB PAGE ONE") }) { self.inspectBrowser() }
        }
    }
    func inspectBrowser() {
        first.webView!.evaluateJavaScript("JSON.stringify({bridge:typeof window.webkit?.messageHandlers?.app,reading:typeof globalThis.__weiyueReading,text:document.body.innerText,origin:location.origin})") { result, error in
            self.guarded {
                if let error { throw error }
                let object = try JSONSerialization.jsonObject(with: Data((result as! String).utf8)) as! [String: Any]
                try self.check(object["bridge"] as? String == "undefined", "actual web document has no app bridge")
                try self.check(object["reading"] as? String == "undefined", "page scripts cannot access the isolated reading controller")
                try self.check((object["text"] as? String)?.contains("NATIVE WEB PAGE ONE") == true, "native page one renders real HTTP content")
                try self.check(object["origin"] as? String == self.base, "HTTP fixture stays on loopback")
                self.first.layout(NSRect(x: 0, y: 0, width: 900, height: 700), visible: false)
                try self.check(self.first.view.isHidden, "modal layout hides native preview")
                self.first.layout(NSRect(x: 0, y: 0, width: 39, height: 700), visible: true)
                try self.check(self.first.view.isHidden, "collapsed preview is hidden")
                self.first.layout(NSRect(x: 0, y: 0, width: 900, height: 700), visible: true)
                try self.check(!self.first.view.isHidden, "normal preview layout is visible")
                try self.rejects("unknown navigation command") { try self.first.navigate("delete-files") }
                self.webSnapshot("v110-native-browser-one") {
                    self.first.webView!.evaluateJavaScript("document.getElementById('next').click()") { _, error in
                        if let error { self.finish(false, error.localizedDescription); return }
                        self.wait("native link navigation", until: { self.loaded("NATIVE WEB PAGE TWO") }) { self.testHistory() }
                    }
                }
            }
        }
    }
    func testHistory() {
        guarded {
            try check(first.webView!.canGoBack, "native link navigation creates history")
            try first.navigate("back")
            wait("native back", until: { self.loaded("NATIVE WEB PAGE ONE") }) {
                self.guarded {
                    try self.check(self.first.webView!.canGoForward, "back exposes forward navigation")
                    try self.first.navigate("forward")
                    self.wait("native forward", until: { self.loaded("NATIVE WEB PAGE TWO") }) {
                        self.guarded {
                            let before = self.requests.count
                            try self.first.navigate("reload")
                            self.wait("native reload issues actual HTTP request", until: { self.loaded("NATIVE WEB PAGE TWO") && self.requests.count > before }) {
                                self.guarded {
                                    try self.check(self.first.snapshot["url"] as? String == self.base + "/two", "snapshot tracks navigated URL")
                                    try self.check(self.first.snapshot["title"] as? String == "NATIVE WEB PAGE TWO", "snapshot tracks actual page title")
                                    self.webSnapshot("v110-native-browser-two") { self.testCookies() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func testCookies() {
        let cookie = HTTPCookie(properties: [.name: "synthetic-isolation", .value: "not-a-credential", .domain: "127.0.0.1", .path: "/"])!
        first.webView!.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            self.second.webView!.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                self.guarded {
                    try self.check(!cookies.contains { $0.name == "synthetic-isolation" }, "ephemeral browsers do not share cookies")
                    self.first.close(); self.second.close()
                    try self.check(self.first.webView == nil && self.first.fileURL == nil && self.first.view.isHidden, "close releases browser and hides native view")
                    self.openDocument(self.pdf, name: "PDF", expected: "NATIVE PDF PREVIEW V110") {
                        self.openDocument(self.word, name: "DOCX", expected: "NATIVE DOCX PREVIEW V110") {
                            self.finish(true, "\(self.checks) native assertions; real loopback HTTP load/link/back/forward/reload and PDF/DOCX Quick Look screenshots verified")
                        }
                    }
                }
            }
        }
    }
    func webSnapshot(_ name: String, attempt: Int = 0, then next: @escaping () -> Void) {
        first.view.layoutSubtreeIfNeeded(); first.view.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.first.webView!.takeSnapshot(with: nil) { image, error in
            self.guarded {
                if let error { throw error }
                guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { throw ReaderError.message("Native WebKit screenshot unavailable") }
                try self.save(bitmap, name: name)
                let recognized = try self.recognize(bitmap)
                if !recognized.contains("NATIVE WEB PAGE"), attempt < 3 { self.webSnapshot(name, attempt: attempt + 1, then: next); return }
                try self.check(recognized.contains("NATIVE WEB PAGE"), "native WebKit snapshot contains real rendered page text")
                self.snapshots.append(["name":name + ".png","method":"WKWebView.takeSnapshot","ocr":recognized])
                next()
            }
        } }
    }
    func openDocument(_ file: URL, name: String, expected: String, then next: @escaping () -> Void) {
        guarded {
            try first.open(file: file, name: "Synthetic " + name, allowedDirectory: allowed)
            first.layout(NSRect(x: 0, y: 0, width: 900, height: 700), visible: true)
            try check(first.fileURL == file && first.webView == nil, name + " opens actual native document view")
            guard let quickLook = first.view.subviews.first(where: { $0 is QLPreviewView }) as? QLPreviewView else { throw ReaderError.message(name + " QLPreviewView missing") }
            try check(quickLook.previewItem?.previewItemURL == file, name + " Quick Look item references verified local file")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.documentSnapshot(name.lowercased(), expected: expected, attempt: 0, then: next) }
        }
    }
    func recognize(_ bitmap: NSBitmapImageRep) throws -> String {
        guard let image = bitmap.cgImage else { throw ReaderError.message("Screenshot has no CGImage") }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").uppercased()
    }
    func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0, let data = bitmap.representation(using: .png, properties: [:]) else { throw ReaderError.message("Native screenshot conversion failed") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
    func documentSnapshot(_ kind: String, expected: String, attempt: Int, then next: @escaping () -> Void) {
        guarded {
            first.view.layoutSubtreeIfNeeded(); first.view.displayIfNeeded()
            guard let bitmap = first.view.bitmapImageRepForCachingDisplay(in: first.view.bounds) else { throw ReaderError.message(kind + " bitmap allocation failed") }
            first.view.cacheDisplay(in: first.view.bounds, to: bitmap)
            let name = "v110-native-" + kind
            try save(bitmap, name: name + "-bitmap")
            let recognized = try recognize(bitmap)
            if recognized.contains(expected) {
                try save(bitmap, name: name); try check(true, kind + " native bitmap contains rendered document text")
                snapshots.append(["name":name + ".png","method":"NSView.cacheDisplay/NSBitmapImageRep","ocr":recognized]); next(); return
            }
            if attempt < 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.documentSnapshot(kind, expected: expected, attempt: attempt + 1, then: next) }; return
            }
            // Quick Look may use a remote view that cannot draw into NSBitmap.
            // Capture only this synthetic test window, then require real OCR.
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let target = output.appendingPathComponent(name + ".png")
            process.arguments = ["-x", "-l", String(window.windowNumber), target.path]
            try process.run(); process.waitUntilExit()
            try check(process.terminationStatus == 0, kind + " native-window capture succeeds")
            guard let image = NSBitmapImageRep(data: try Data(contentsOf: target)) else { throw ReaderError.message(kind + " native-window screenshot cannot decode") }
            let windowText = try recognize(image)
            try check(windowText.contains(expected), kind + " native-window screenshot does not contain rendered document text: " + windowText)
            snapshots.append(["name":name + ".png","method":"screencapture synthetic window only; NSBitmap remote surface unavailable","ocr":windowText]); next()
        }
    }
    func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }; finished = true
        first.close(); second.close(); listener?.cancel(); window?.orderOut(nil); previousApp?.activate(options: [])
        if let output {
            let result: [String: Any] = ["success":success,"assertions":checks,"message":message,"httpBinding":"127.0.0.1 only","httpRequests":requests,"screenshots":snapshots]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys,.prettyPrinted]) { try? data.write(to: output.appendingPathComponent("v110-native-results.json")) }
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        print((success ? "PASS: " : "FAIL: ") + message); fflush(stdout); exit(success ? 0 : 1)
    }
}

final class SyntheticPDFPage: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.65, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 40, y: 660, width: 532, height: 8)).fill()
        ("NATIVE PDF PREVIEW V110" as NSString).draw(at: NSPoint(x: 40, y: 700), withAttributes: [.font:NSFont.boldSystemFont(ofSize:28),.foregroundColor:NSColor.black])
        for (index, line) in ["Actual local PDF rendered by Quick Look.","Only synthetic data; no account or external resource.","Native document content must remain visible.","PDF CONTENT CHECK: 123456789"].enumerated() {
            (line as NSString).draw(at: NSPoint(x: 40, y: 610 - index * 50), withAttributes: [.font:NSFont.systemFont(ofSize:17),.foregroundColor:NSColor.darkGray])
        }
        NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 250, width: 532, height: 150), xRadius: 12, yRadius: 12).fill()
        ("OFFLINE NATIVE PREVIEW" as NSString).draw(at: NSPoint(x: 70, y: 310), withAttributes: [.font:NSFont.boldSystemFont(ofSize:24),.foregroundColor:NSColor(calibratedRed:0.1,green:0.4,blue:0.3,alpha:1)])
    }
}
