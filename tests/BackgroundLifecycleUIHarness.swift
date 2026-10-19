import AppKit
import WebKit

@main final class BackgroundLifecycleUIHarness: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var subject: AppDelegate!
    var window: NSWindow!, local: WKWebView!, official: WKWebView!
    var previousApp: NSRunningApplication?, quitObserver: NSObjectProtocol?
    var loaded = 0, started = false, expectingQuit = false, pendingOperation: UUID!
    var timeout: DispatchWorkItem?

    static func main() {
        let app = NSApplication.shared, harness = BackgroundLifecycleUIHarness()
        app.setActivationPolicy(.accessory); app.delegate = harness
        withExtendedLifetime(harness) { app.run() }
    }
    func step(_ message: String) { print("STEP: " + message); fflush(stdout) }
    func check(_ condition: Bool, _ label: String) { if !condition { fail(label) } }
    func fail(_ message: String) -> Never {
        print("FAIL: " + message); fflush(stdout); previousApp?.activate(options: []); exit(1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        previousApp = NSWorkspace.shared.frontmostApplication
        subject = AppDelegate()
        // Only the isolated host window is constructed here. AppDelegate's real
        // close, reopen and quit callbacks run below; startup/account I/O is not run.
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1120, height: 700), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let localConfig = WKWebViewConfiguration(); localConfig.websiteDataStore = .nonPersistent()
        let officialConfig = WKWebViewConfiguration(); officialConfig.websiteDataStore = .nonPersistent()
        local = WKWebView(frame: window.contentView!.bounds, configuration: localConfig)
        official = WKWebView(frame: .zero, configuration: officialConfig)
        local.navigationDelegate = self; official.navigationDelegate = self
        window.contentView!.addSubview(local); window.contentView!.addSubview(official)
        subject.window = window; subject.localView = local; subject.officialView = official; subject.uiReady = true
        pendingOperation = UUID(); subject.aiBridgeOperation = pendingOperation
        subject.syncConfigurationTask = DispatchWorkItem {}
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            self.check(self.expectingQuit, "close must never terminate the process")
            self.timeout?.cancel()
            print("PASS: native close keeps process and WebViews alive; Dock reopen preserves session; explicit quit pauses, flushes, waits for file operations and terminates")
            fflush(stdout); self.previousApp?.activate(options: [])
        }
        let timeout = DispatchWorkItem { self.fail("background lifecycle timed out: loaded=\(self.loaded), started=\(self.started), quit=\(self.subject?.terminationRequested ?? false), freeze=\(self.subject?.freezeInboundForQuit ?? false), visible=\(self.window?.isVisible ?? false)") }; self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        let fixture = """
        <!doctype html><p>Isolated lifecycle fixture</p><script>
        window.ticks=0;window.flushes=0;window.pauses=0;window.session='same-session';
        setInterval(()=>window.ticks++,30);
        window.flushBeforeQuit=async options=>{if(!options.quitting)throw Error('missing quit intent');window.flushes++;};
        window.__weiboReaderSync={pause:()=>window.pauses++};
        </script>
        """
        local.loadHTMLString(fixture, baseURL: nil); official.loadHTMLString(fixture, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded += 1; step("fixture loaded \(loaded)")
        guard loaded == 2, !started else { return }; started = true
        NSApp.delegate = subject
        check(!subject.applicationShouldTerminateAfterLastWindowClosed(NSApp), "last-window close still requests application termination")
        window.makeKeyAndOrderFront(nil); step("window opened")
        local.evaluateJavaScript("window.ticks") { before, error in
            self.check(error == nil, "local fixture ready")
            self.closeAndCheck(before: before as? Int ?? -1)
        }
    }
    func closeAndCheck(before: Int) {
        step("closing native window")
        window.standardWindowButton(.closeButton)!.performClick(nil)
        check(!window.isVisible, "red close button hides the main window")
        check(!subject.terminationRequested && !subject.freezeInboundForQuit, "close must not enter quit or freeze inbound messages")
        check(subject.aiBridgeOperation == pendingOperation, "close must preserve pending AI operation")
        check(subject.syncConfigurationTask?.isCancelled == false, "close must preserve scheduled sync")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            self.local.evaluateJavaScript("({ticks:window.ticks,flushes:window.flushes,session:window.session})") { value, error in
                let state = value as? [String: Any] ?? [:]
                self.check(error == nil && (state["ticks"] as? Int ?? -1) > before, "local WebView work continues with window closed")
                self.check(state["flushes"] as? Int == 0 && state["session"] as? String == "same-session", "close retains session without running quit-save")
                self.official.evaluateJavaScript("({ticks:window.ticks,pauses:window.pauses})") { value, error in
                    let state = value as? [String: Any] ?? [:]
                    self.check(error == nil && (state["ticks"] as? Int ?? 0) > 0 && state["pauses"] as? Int == 0, "official background work stays active")
                    self.reopenAndQuit()
                }
            }
        }
    }
    func reopenAndQuit() {
        step("background checks passed; reopen")
        _ = (subject as NSApplicationDelegate).applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        check(window.isVisible && subject.window === window && subject.localView === local && subject.officialView === official, "Dock reopen restores the same window and WebViews")
        window.performMiniaturize(nil)
        _ = (subject as NSApplicationDelegate).applicationShouldHandleReopen?(NSApp, hasVisibleWindows: true)
        check(window.isVisible && !window.isMiniaturized, "Dock reopen also restores a minimized main window")
        window.performClose(nil)
        _ = (subject as NSApplicationDelegate).applicationShouldHandleReopen?(NSApp, hasVisibleWindows: true)
        check(window.isVisible && !subject.terminationRequested, "main window can reopen while another window is reported visible")
        window.performClose(nil)
        subject.fileOperations.enter()
        expectingQuit = true; step("request explicit quit")
        // AppKit may keep terminate() on a nested event loop until reply.
        // Schedule the observer before requesting quit so its file gate can open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.check(self.subject.terminationRequested && self.subject.freezeInboundForQuit, "explicit quit enters quit-save path")
            self.check(self.subject.aiGeneration == 1 && self.subject.contentGeneration == 1 && self.subject.syncConfigurationTask?.isCancelled == true, "explicit quit stops active operations and scheduled sync")
            self.local.evaluateJavaScript("window.flushes") { flushes, error in
                self.check(error == nil && flushes as? Int == 1, "explicit quit flushes once")
                self.official.evaluateJavaScript("window.pauses") { pauses, error in
                    self.check(error == nil && pauses as? Int == 1, "explicit quit pauses sync once")
                    print("PASS: quit save completed while file operation gate still held"); fflush(stdout)
                    self.subject.fileOperations.leave()
                }
            }
        }
        NSApp.terminate(nil)
    }
}
