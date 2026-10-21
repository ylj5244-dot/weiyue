import AppKit
import WebKit
import Network

// All content is synthetic and served on loopback. This harness never reads
// application data, opens an external application, or contacts a remote site.
@main final class ContentPreviewResponsiveTests: NSObject, NSApplicationDelegate {
    var checks = 0, failures: [String] = [], results: [[String: Any]] = [], requests: [String] = []
    var finished = false, base = "", window: NSWindow!, previousApp: NSRunningApplication?, listener: NWListener?
    let preview = ContentPreviewController()
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")

    static func main() {
        let app = NSApplication.shared, delegate = ContentPreviewResponsiveTests()
        DispatchQueue.global().asyncAfter(deadline: .now() + 100) { print("FAIL: responsive preview watchdog"); fflush(stdout); exit(1) }
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
    func check(_ condition: Bool, _ label: String) {
        checks += 1; if !condition { failures.append(label); print("FAIL: " + label) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        previousApp = NSWorkspace.shared.frontmostApplication
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "微阅 1.0.11 · 合成网页适配验收"
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 720))
        window.contentView!.addSubview(preview.view); window.appearance = NSAppearance(named: .aqua)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do { try startServer() } catch { finish(error.localizedDescription) }
    }
    func startServer() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters); listener = server
        server.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
                let path = String(request.split(separator: " ").dropFirst().first ?? "/")
                self.requests.append(path)
                let bytes = Data((path == "/pending.svg" ? "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'></svg>" : self.page(path)).utf8)
                let security = path == "/csp" ? "Content-Security-Policy: style-src 'nonce-fixture'; script-src 'nonce-fixture'\r\n" : ""
                let mime = path == "/pending.svg" ? "image/svg+xml" : "text/html; charset=utf-8"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\n\(security)Connection: close\r\n\r\n"
                let send = { connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() }) }
                if path == "/pending.svg" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: send) }
                else if path == "/slow" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: send) } else { send() }
            }
        }
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = server.port {
                self.base = "http://127.0.0.1:\(port.rawValue)"
                Task { @MainActor in do { try await self.run() } catch { self.finish(error.localizedDescription) } }
            } else if case .failed(let error) = state { self.finish(error.localizedDescription) }
        }
        server.start(queue: .main)
    }
    var article: String {
        let prose = "右侧栏应该保留可读字号，让正文在当前宽度重新换行。缩小窗口时，图片和段落都应完整显示；拉宽窗口后，正文继续利用可用空间，不反复缩放。"
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='1100' height='320'><rect width='1100' height='320' fill='%23dbece7'/><text x='44' y='160' font-size='55' fill='%231b6251'>IMAGE MUST FIT THE ARTICLE</text></svg>"
        return "<header>FIXED DESKTOP NAVIGATION</header><div class='shell'><nav>Desktop sidebar<br>Groups<br>Settings</nav><main><article id='story'><h1>READABLE DESKTOP ARTICLE</h1><p id='prose'>\(prose)\(prose)</p><img id='hero' src=\"data:image/svg+xml,\(svg)\"><p>\(prose)</p><a id='next' href='/responsive'>Open responsive page</a><pre>\(String(repeating: "long-code-", count: 60))</pre><div class='late-slot'></div></article></main><aside>RELATED DESKTOP CONTENT</aside></div>"
    }
    func page(_ path: String) -> String {
        let responsive = path.hasPrefix("/responsive")
        let desktopCSS = "body{min-width:1120px;margin:0;font:12px -apple-system;background:#f0f3f7;color:#253344}header{width:1120px;height:60px;background:#dce5ef;padding:20px;box-sizing:border-box}.shell{width:1120px;display:grid;grid-template-columns:220px 680px 220px;margin:auto}nav,aside{padding:22px;background:#e6ebf0}main{width:680px}article{width:680px;padding:28px;box-sizing:border-box;background:white}h1{font-size:26px}p{font-size:12px;line-height:1.7}img{width:1100px;max-width:none}pre{white-space:pre;width:1000px}a{font-size:17px}"
        let responsiveCSS = "body{margin:0;font:18px -apple-system;color:#263849;background:#edf5f3}article{box-sizing:border-box;width:calc(100% - 32px);max-width:760px;margin:16px auto;padding:20px;background:white;border:1px solid #afc8c0;border-radius:14px}h1{font-size:26px}p{font-size:18px;line-height:1.6}img{width:100%;height:auto}"
        let title = responsive ? "RESPONSIVE ORIGINAL PAGE" : (path == "/late" ? "LATE DESKTOP ARTICLE" : (path == "/login" ? "LOGIN STAYS VISIBLE" : "FIXED DESKTOP ARTICLE"))
        let content: String
        if responsive {
            content = "<article id='story'><h1>RESPONSIVE ORIGINAL PAGE</h1><p id='prose'>This page already fits its container. Its 18px text and original layout must remain unchanged.</p><a id='previous' href='/desktop'>Back to desktop article</a></article>"
        } else if path == "/late" {
            let encoded = String(data: try! JSONSerialization.data(withJSONObject: [article]), encoding: .utf8)!
            content = "<div id='mount'>Loading synthetic article…</div><script>setTimeout(()=>document.getElementById('mount').innerHTML=(\(encoded))[0],180)</script>"
        } else if path == "/login" {
            content = article + "<section role='dialog' aria-modal='true' style='position:fixed;left:10px;top:10px;width:280px;padding:12px;background:white;z-index:10'><h2>LOGIN MUST STAY VISIBLE</h2><form><input type='password' aria-label='Password'><button>Sign in</button></form></section>"
        } else if path == "/interactive" {
            content = article
                .replacingOccurrences(of: "<header>FIXED DESKTOP NAVIGATION</header>", with: "<header id='site-header'><div style='width:1120px;min-width:1120px'>SITE NAVIGATION <button id='header-menu' onclick=\"document.body.dataset.menu='opened'\">Menu</button></div></header>")
                .replacingOccurrences(of: "<nav>Desktop sidebar<br>Groups<br>Settings</nav>", with: "<nav id='site-nav'><div style='width:1120px;min-width:1120px;display:flex;justify-content:space-between'><a id='site-home' href='/responsive'>Site home</a><button id='nav-tail' onclick=\"document.body.dataset.more='opened'\">More navigation</button></div><p>Navigation remains usable</p></nav>")
                .replacingOccurrences(of: "</article></main>", with: "</article><section id='site-actions'><button id='open-share' onclick=\"document.getElementById('share-dialog').showModal()\">Share article</button><button id='add-comment' onclick=\"document.getElementById('comment-state').textContent='COMMENT CONTROL WORKS'\">Comment</button><output id='comment-state'></output></section></main>")
                + "<dialog id='share-dialog'><h2>SHARE DIALOG IS VISIBLE</h2><p>Native modal dialog, initially closed.</p><form method='dialog'><button id='close-share'>Close</button></form></dialog><script>window.fixtureSheet=new CSSStyleSheet();fixtureSheet.replaceSync('#site-actions{padding:12px;background:#e1ece8}');document.adoptedStyleSheets=[fixtureSheet]</script>"
        } else { content = article + (path == "/early" ? "<img src='/pending.svg' width='1' height='1'>" : "") }
        return "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>\(title)</title><style nonce='fixture'>\(responsive ? responsiveCSS : desktopCSS)</style></head><body>\(content)</body></html>"
    }
    @MainActor func pause(_ seconds: Double = 0.15) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    @MainActor func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            if Date() > deadline { throw ReaderError.message("Timeout: " + label) }
            try await pause(0.03)
        }
    }
    @MainActor func evaluate(_ script: String, browser: WKWebView? = nil) async throws -> Any {
        let web = browser ?? preview.webView!
        return try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }
    @MainActor func metrics() async throws -> [String: Any] {
        let script = #"JSON.stringify((()=>{const a=document.getElementById('story'),p=document.getElementById('prose'),i=document.getElementById('hero'),r=a?.getBoundingClientRect();return {width:innerWidth,documentWidth:document.documentElement.scrollWidth,articleLeft:r?.left,articleRight:r?.right,articleWidth:r?.width,articleScroll:a?.scrollWidth,paragraphFont:p?parseFloat(getComputedStyle(p).fontSize):0,imageWidth:i?.getBoundingClientRect().width||0,text:document.body.innerText,bridge:typeof window.webkit?.messageHandlers?.app,zoom:visualViewport?.scale||1};})())"#
        let json = try await evaluate(script) as! String
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }
    func number(_ metrics: [String: Any], _ key: String) -> Double { (metrics[key] as? NSNumber)?.doubleValue ?? -1 }
    @MainActor func size(_ width: CGFloat) async throws {
        window.setContentSize(NSSize(width: width, height: 720))
        preview.layout(NSRect(x: 0, y: 0, width: width, height: 720), visible: true)
        preview.view.layoutSubtreeIfNeeded(); try await pause(0.24)
    }
    @MainActor func open(_ path: String, title: String) async throws {
        try preview.open(url: URL(string: base + path)!, name: "Synthetic article")
        preview.layout(window.contentView!.bounds, visible: true)
        try await wait(title) { self.preview.webView?.isLoading == false && self.preview.webView?.title == title }
        try await pause(0.24)
    }
    @MainActor func capture(_ name: String) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            preview.webView!.takeSnapshot(with: nil) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: ReaderError.message("Snapshot missing")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw ReaderError.message("Snapshot conversion failed") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "native snapshot saved: " + name)
    }
    @MainActor func checkReading(_ width: Int, name: String) async throws {
        let m = try await metrics(); results.append(["case":name,"expectedWidth":width,"metrics":m])
        check(abs(number(m,"width") - Double(width)) <= 1, "\(name): actual web viewport is \(width)")
        check(number(m,"documentWidth") <= Double(width) + 1, "\(name): no horizontal document overflow")
        check(number(m,"articleLeft") >= -1 && number(m,"articleRight") <= Double(width) + 1, "\(name): whole article is in the pane")
        check(number(m,"articleWidth") >= Double(width) - 36, "\(name): article uses available pane width")
        check(number(m,"paragraphFont") >= 14, "\(name): text stays at least 14px")
        check(number(m,"imageWidth") <= number(m,"articleWidth") - 16, "\(name): large image fits article")
        check(number(m,"zoom") == 1 && preview.webView!.pageZoom == 1, "\(name): no whole-page shrinking")
        check(m["bridge"] as? String == "undefined", "\(name): no app bridge")
    }
    @MainActor func hittable(_ id: String) async throws -> Bool {
        // Programmatic click alone would also succeed on hidden controls.
        // Require visible geometry and a real hit-test before invoking it.
        let name = String(data: try JSONSerialization.data(withJSONObject:[id]), encoding:.utf8)!
        return try await evaluate("(()=>{const e=document.getElementById((\(name))[0]);e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect(),s=getComputedStyle(e),hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return s.display!=='none'&&s.visibility!=='hidden'&&r.width>0&&r.height>0&&(hit===e||e.contains(hit))})()") as? Bool == true
    }
    @MainActor func testSiteControls() async throws {
        try await size(320); try await open("/interactive", title:"FIXED DESKTOP ARTICLE")
        for width in [320,480,880] {
            try await size(CGFloat(width))
            check(try await hittable("header-menu"), "site header control is visible and hittable at \(width)")
            check(try await hittable("site-home"), "site navigation link is visible and hittable at \(width)")
            check(try await hittable("nav-tail"), "nested fixed-width navigation's trailing control is reachable at \(width)")
            check(try await evaluate("scrollX===0") as? Bool == true, "fixed navigation scrolls locally without shifting the page at \(width)")
            check(try await hittable("open-share"), "article share control is visible and hittable at \(width)")
            check(try await hittable("add-comment"), "article comment control is visible and hittable at \(width)")
            try await checkReading(width, name:"interactive-site-\(width)")
        }
        _ = try await evaluate("document.getElementById('header-menu').click();document.getElementById('add-comment').click();document.getElementById('nav-tail').click()")
        try await pause(0.2)
        check(try await evaluate("document.body.dataset.menu==='opened'&&document.body.dataset.more==='opened'&&document.getElementById('comment-state').textContent==='COMMENT CONTROL WORKS'") as? Bool == true, "original header, trailing navigation and comment handlers still work")
        try await size(320)
        _ = try await evaluate("document.getElementById('site-header').scrollTo(0,0);document.getElementById('site-nav').scrollTo(0,0);scrollTo(0,0)")
        try await pause(0.1)
        check(try await hittable("site-home"), "navigation remains visible after local scroll resets and resize")
        _ = try await evaluate("scrollTo(0,0)")
        try await pause(0.1)
        let navigationJSON = try await evaluate("JSON.stringify((()=>{let n=document.getElementById('site-nav'),a=document.getElementById('site-home');return {scrollLeft:n.scrollLeft,scrollTop:n.scrollTop,scrollWidth:n.scrollWidth,nav:n.getBoundingClientRect().toJSON(),link:a.getBoundingClientRect().toJSON(),display:getComputedStyle(a).display,visibility:getComputedStyle(a).visibility}})())") as! String
        results.append(["case":"navigation-screenshot-geometry","metrics":try JSONSerialization.jsonObject(with:Data(navigationJSON.utf8))])
        try await capture("v111-native-responsive-site-controls-320")
        let screenshot = Process(); screenshot.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        screenshot.arguments = ["-x","-l",String(window.windowNumber),output.appendingPathComponent("v111-native-responsive-site-controls-window-320.png").path]
        try screenshot.run(); screenshot.waitUntilExit()
        check(screenshot.terminationStatus == 0, "synthetic window screenshot saved for navigation painting check")
        check(try await evaluate("!document.getElementById('share-dialog').open&&getComputedStyle(document.getElementById('share-dialog')).display==='none'") as? Bool == true, "initial closed dialog stays closed")
        check(try await hittable("open-share"), "share trigger is hittable before opening modal")
        _ = try await evaluate("document.getElementById('open-share').click()")
        try await pause(0.2)
        check(try await evaluate("document.getElementById('share-dialog').open") as? Bool == true, "page button opens native dialog")
        check(try await hittable("share-dialog"), "later opened modal is visible and hittable")
        check(try await hittable("close-share"), "modal close button is visible and hittable")
        try await capture("v111-native-responsive-open-dialog-320")
        _ = try await evaluate("document.getElementById('close-share').click()")
        try await pause(0.2)
        check(try await evaluate("!document.getElementById('share-dialog').open") as? Bool == true, "page close button closes modal")
        try await checkReading(320, name:"after-modal-close")
        check(try await hittable("site-home"), "page navigation is usable after modal closes")
        _ = try await evaluate("document.getElementById('open-share').click()")
        try await pause(0.15); try preview.navigate("original"); try await pause(0.2)
        check(try await hittable("close-share"), "switching to original page keeps open modal usable")
        check(try await evaluate("document.querySelectorAll('[data-weiyue-preview-layout],[data-weiyue-preview-font]').length===0&&document.adoptedStyleSheets.length===1&&document.adoptedStyleSheets[0]===fixtureSheet") as? Bool == true, "original mode removes all adaptation markers and preserves site's original stylesheet collection")
        _ = try await evaluate("document.getElementById('close-share').click()")
        try await pause(0.2)
        check(try await evaluate("!document.getElementById('share-dialog').open") as? Bool == true, "dialog closes normally in original-page mode")
        try preview.navigate("reading"); try await pause(0.2)
        try await checkReading(320, name:"reading-after-original-modal")
        check(try await hittable("site-home"), "site navigation remains hittable after returning to reading")
        _ = try await evaluate("document.getElementById('site-home').click()")
        try await wait("site's own navigation link") { self.preview.webView?.title == "RESPONSIVE ORIGINAL PAGE" && self.preview.webView?.isLoading == false }
        check(preview.currentURL?.absoluteString == base + "/responsive", "site navigation updates the actual current address")
        try await size(480)
    }
    @MainActor func run() async throws {
        try await size(320); try await open("/desktop", title: "FIXED DESKTOP ARTICLE")
        for width in [320,480,880,320] {
            try await size(CGFloat(width)); try await checkReading(width, name: "desktop-\(width)")
            try await capture("v111-native-responsive-desktop-\(width)")
        }
        // Keep the initial red run focused on the observable crop and tiny text.
        if !failures.isEmpty { finish(nil); return }
        check(preview.snapshot["readingEnabled"] as? Bool == true, "reading adaptation is enabled by default")
        check(preview.snapshot["canToggleReading"] as? Bool == true, "original-page control is available")
        try preview.navigate("original"); try await pause(0.2)
        let original = try await metrics()
        check(number(original,"documentWidth") >= 1120, "original mode restores desktop width")
        check(number(original,"paragraphFont") == 12, "original mode restores original font")
        check(preview.snapshot["readingEnabled"] as? Bool == false, "original mode snapshot")
        try preview.navigate("reading"); try await pause(0.2); try await checkReading(320, name:"restored-reading")
        _ = try await evaluate("document.getElementById('next').click()")
        try await wait("follow article link") { self.preview.webView?.title == "RESPONSIVE ORIGINAL PAGE" && self.preview.webView?.isLoading == false }
        for width in [320,480,880] {
            try await size(CGFloat(width)); let m = try await metrics(); results.append(["case":"responsive-\(width)","metrics":m])
            check(number(m,"documentWidth") <= Double(width), "responsive \(width): no overflow")
            check(number(m,"paragraphFont") == 18, "responsive \(width): original 18px font unchanged")
            check(abs(number(m,"articleWidth") - min(Double(width)-32,760)) <= 1, "responsive \(width): original layout unchanged")
            check(preview.snapshot["url"] as? String == base + "/responsive", "current address follows in-page navigation")
            check(preview.currentURL?.absoluteString == base + "/responsive", "external-open URL follows the actual current page")
        }
        try await capture("v111-native-responsive-original-880")
        check(preview.webView!.canGoBack, "real link creates native browser history")
        try preview.navigate("back")
        try await wait("back to article") { self.preview.webView?.title == "FIXED DESKTOP ARTICLE" && self.preview.webView?.isLoading == false }
        try await size(480); try await checkReading(480, name:"back-navigation")
        check(preview.webView!.canGoForward, "native forward navigation available")
        try preview.navigate("forward")
        try await wait("forward to responsive") { self.preview.webView?.title == "RESPONSIVE ORIGINAL PAGE" && self.preview.webView?.isLoading == false }
        let count = requests.count; try preview.navigate("reload")
        try await wait("reload makes HTTP request") { self.requests.count > count && self.preview.webView?.isLoading == false }
        check(preview.snapshot["url"] as? String == base + "/responsive", "reload retains current address for external open")
        try await open("/late", title:"LATE DESKTOP ARTICLE"); try await pause(0.3)
        try await checkReading(480, name:"async-article")
        _ = try await evaluate("document.querySelector('.late-slot').innerHTML='<p id=late-copy style=\"font-size:11px;width:1000px\">'+'Late content remains readable. '.repeat(12)+'</p>'")
        try await pause(0.2)
        check((try await evaluate("parseFloat(getComputedStyle(document.getElementById('late-copy')).fontSize)") as? NSNumber)?.doubleValue ?? 0 >= 14, "late inserted text remains readable")
        try await checkReading(480, name:"async-paragraph")
        let before = try await evaluate("document.adoptedStyleSheets.length") as! Int
        for width in [320,880,480,320,880,480] { try await size(CGFloat(width)) }
        let after = try await evaluate("document.adoptedStyleSheets.length") as! Int
        check(after == before && after == 1, "repeated resize keeps exactly one reading stylesheet")
        try await checkReading(480, name:"repeated-resize")
        try await open("/csp", title:"FIXED DESKTOP ARTICLE")
        try await checkReading(480, name:"strict-style-policy")
        try preview.open(url: URL(string:base + "/early")!, name:"Pending image")
        preview.layout(window.contentView!.bounds, visible:true)
        try await wait("article parsed before image finishes") { self.preview.webView?.title == "FIXED DESKTOP ARTICLE" }
        try await pause(0.2)
        check(preview.webView?.isLoading == true, "slow image is still loading during early reading check")
        try await checkReading(480, name:"before-images-finish")
        try await testSiteControls()
        try await open("/login", title:"LOGIN STAYS VISIBLE")
        check(try await evaluate("(()=>{let e=document.querySelector('[role=dialog]');return getComputedStyle(e).display!=='none'&&e.getBoundingClientRect().height>0})()") as? Bool == true, "login dialog is not hidden by reading adaptation")
        try preview.open(url: URL(string:base + "/slow")!, name:"Late navigation")
        preview.close()
        try await open("/responsive", title:"RESPONSIVE ORIGINAL PAGE"); try await pause(0.5)
        check(preview.snapshot["url"] as? String == base + "/responsive", "late navigation callback cannot replace reopened page")
        check(preview.snapshot["title"] as? String == "RESPONSIVE ORIGINAL PAGE", "late navigation callback cannot replace title")
        check(preview.snapshot["error"] as? String == "", "late cancelled callback cannot set reopened error")
        var eventCount = 0; preview.onChange = { _ in eventCount += 1 }; preview.close()
        let closedCount = eventCount; try await pause(0.3)
        check(eventCount == closedCount && preview.webView == nil, "close releases native browser without later publication")
        finish(nil)
    }
    func finish(_ error: String?) {
        guard !finished else { return }; finished = true
        if let error { failures.append(error) }
        let result: [String:Any] = ["success":failures.isEmpty,"assertions":checks,"failures":failures,"httpBinding":"127.0.0.1 only","requests":requests,"cases":results]
        if let data = try? JSONSerialization.data(withJSONObject: result, options:[.sortedKeys,.prettyPrinted]) { try? data.write(to: output.appendingPathComponent("v111-native-responsive-results.json")) }
        preview.close(); listener?.cancel(); window?.orderOut(nil); previousApp?.activate(options:[])
        print((failures.isEmpty ? "PASS" : "FAIL") + ": \(checks) responsive native assertions; \(failures.count) failure(s)")
        if let error { print(error) }; fflush(stdout); exit(failures.isEmpty ? 0 : 1)
    }
}
