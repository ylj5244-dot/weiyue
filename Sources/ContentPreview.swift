import AppKit
import WebKit
import Quartz

enum ContentPreviewPolicy {
    static func webURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw ReaderError.message("这个链接不能在内置浏览器打开，请到微博查看原消息。")
        }
        return url
    }
}

// This browser has no app message handlers, no file scheme handler and no
// shared cookies with the signed-in Weibo view. Only native-verified files reach QL.
final class ContentPreviewController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view = NSView(frame: .zero)
    private(set) var webView: WKWebView?
    private(set) var fileURL: URL?
    private var documentView: QLPreviewView?
    private var observations: [NSKeyValueObservation] = []
    private var initialURL: URL?
    private var title = "", kind = "link", error = ""
    var onChange: (([String: Any]) -> Void)?

    override init() { super.init(); view.isHidden = true }
    var snapshot: [String: Any] {
        ["type": "contentPreview", "kind": kind, "title": webView?.title?.isEmpty == false ? webView!.title! : title,
         "url": webView?.url?.absoluteString ?? initialURL?.absoluteString ?? "", "loading": webView?.isLoading ?? false,
         "canGoBack": webView?.canGoBack ?? false, "canGoForward": webView?.canGoForward ?? false, "error": error]
    }
    func close() {
        observations.removeAll(); webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
        documentView?.close(); documentView?.removeFromSuperview(); documentView = nil
        fileURL = nil; initialURL = nil; view.isHidden = true; error = ""
    }
    func open(url: URL, name: String) throws {
        let safe = try ContentPreviewPolicy.webURL(url.absoluteString)
        close(); kind = "link"; title = name; initialURL = safe
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: view.bounds, configuration: configuration)
        browser.autoresizingMask = [.width, .height]; browser.navigationDelegate = self; browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        webView = browser; view.addSubview(browser)
        observations = [browser.observe(\.url, options: [.new]) { [weak self] _, _ in self?.publish() },
                        browser.observe(\.title, options: [.new]) { [weak self] _, _ in self?.publish() },
                        browser.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.publish() }]
        browser.load(URLRequest(url: safe)); publish()
    }
    func open(file: URL, name: String, allowedDirectory: URL) throws {
        let safe = file.standardizedFileURL, root = allowedDirectory.standardizedFileURL
        guard safe.isFileURL, safe.path.hasPrefix(root.path + "/"), safe.resolvingSymlinksInPath().path == safe.path,
              root.resolvingSymlinksInPath().path == root.path,
              try safe.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ReaderError.message("本地文档路径无效，请从原消息重新打开。")
        }
        close(); kind = "document"; title = name; fileURL = safe
        guard let preview = QLPreviewView(frame: view.bounds, style: .normal) else { throw ReaderError.message("系统文档预览暂不可用，可用默认应用打开。") }
        preview.autoresizingMask = [.width, .height]; preview.previewItem = safe as NSURL
        documentView = preview; view.addSubview(preview); publish()
    }
    func layout(_ rect: NSRect, visible: Bool) { view.frame = rect; view.isHidden = !visible || rect.width < 40 || rect.height < 40 }
    func navigate(_ action: String) throws {
        error = ""
        switch action {
        case "back": webView?.goBack()
        case "forward": webView?.goForward()
        case "reload": if let webView { webView.reload() } else { documentView?.refreshPreviewItem() }
        case "external":
            if let fileURL { NSWorkspace.shared.open(fileURL) }
            else if let url = webView?.url ?? initialURL { NSWorkspace.shared.open(try ContentPreviewPolicy.webURL(url.absoluteString)) }
        default: throw ReaderError.message("预览操作无效。")
        }
        publish()
    }
    private func publish() { onChange?(snapshot) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let url = navigationAction.request.url,
              (try? ContentPreviewPolicy.webURL(url.absoluteString)) != nil else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if webView === self.webView { error = ""; publish() } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { failed(webView, failure) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { failed(webView, failure) }
    private func failed(_ browser: WKWebView, _ failure: Error) {
        guard browser === webView, (failure as NSError).code != NSURLErrorCancelled else { return }
        error = "页面暂时无法加载，可在右上角用默认浏览器打开。"; publish()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === self.webView { error = "页面已停止，点击刷新可重新打开。"; publish() } }
}
