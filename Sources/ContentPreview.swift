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

    static func prefersMobilePresentation(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "weibo.com" || host.hasSuffix(".weibo.com") || host == "weibo.cn" || host.hasSuffix(".weibo.cn")
    }

    // Request Weibo's mobile presentation without inventing a different post URL.
    // Other sites keep WebKit's normal user agent and responsive layout.
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

// This code runs only in WKContentWorld.defaultClient, never in the app's UI
// world. It has no native message handler. It preserves the original DOM and
// styles; removing its one stylesheet and markers restores the original page.
private enum ContentPreviewReading {
    static func source(enabled: Bool) -> String {
        bootstrap + "\nglobalThis.__weiyueReading.setEnabled(\(enabled ? "true" : "false"));"
    }
    static func userScript(enabled: Bool) -> WKUserScript {
        WKUserScript(source: source(enabled: enabled), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
    }
    static let bootstrap = #"""
    (() => {
      if (globalThis.__weiyueReading) return;
      const layout = 'data-weiyue-preview-layout', font = 'data-weiyue-preview-font';
      let enabled = true, disposed = false, timer = null, sheet = null;
      const marks = new Map();
      function mark(element, name, value) {
        if (!marks.has(element)) marks.set(element, new Map());
        const previous = marks.get(element);
        if (!previous.has(name)) previous.set(name, element.getAttribute(name));
        element.setAttribute(name, value);
      }
      function restore() {
        if (sheet) document.adoptedStyleSheets = document.adoptedStyleSheets.filter(value => value !== sheet);
        sheet = null;
        for (const [element, attributes] of marks) {
          for (const [name, value] of attributes) {
            if (value === null) element.removeAttribute(name); else element.setAttribute(name, value);
          }
        }
        marks.clear();
      }
      function visible(element) {
        const style = getComputedStyle(element), box = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && box.width > 0 && box.height > 0;
      }
      function hasPrompt() {
        // Authentication and blocking dialogs must remain usable, even if the
        // article underneath would otherwise qualify for reading adaptation.
        return [...document.querySelectorAll('dialog[open],[role="dialog"],[role="alertdialog"],[aria-modal="true"],input[type="password"]')].some(visible);
      }
      function candidate() {
        const selectors = ['article', 'main', '[role="main"]', '#js_content', '#article', '.article-content', '.article_content', '.post-content'];
        if (/(^|\.)weibo\.(com|cn)$/i.test(location.hostname)) {
          selectors.push('.WB_feed_detail', '.WB_text', '[class*="Feed_wrap"]', '[class*="Feed_body"]', '[class*="detail_wbtext"]', '.card-main');
        }
        let best = null, score = 0;
        for (const element of [...document.querySelectorAll(selectors.join(','))].slice(0, 80)) {
          if (!visible(element)) continue;
          const text = element.innerText.trim().length;
          if (text < 80) continue;
          const links = [...element.querySelectorAll('a')].reduce((n, link) => n + link.innerText.length, 0);
          if (links > text * .65) continue;
          const value = Math.min(text - links, 24000) * (element.tagName === 'ARTICLE' ? 1.25 : 1);
          if (value > score) { best = element; score = value; }
        }
        return best;
      }
      const css = `
        [${layout}="container"], [${layout}="root"] {
          display:block !important; box-sizing:border-box !important;
          width:100% !important; min-width:0 !important; max-width:100% !important;
          height:auto !important; min-height:0 !important; max-height:none !important;
          margin:0 !important; padding:0 !important; float:none !important;
          position:static !important; inset:auto !important; transform:none !important;
          overflow:visible !important;
        }
        [${layout}="auxiliary"] {
          box-sizing:border-box !important; width:auto !important; min-width:0 !important; max-width:100% !important;
          height:auto !important; min-height:0 !important; max-height:none !important;
          margin-left:0 !important; margin-right:0 !important; float:none !important;
          position:static !important; inset:auto !important; transform:none !important; overflow-wrap:anywhere !important;
          overflow-x:auto !important;
        }
        [${layout}="root"] { padding:16px !important; font-size:17px !important; line-height:1.65 !important; }
        [${layout}="root"] * { box-sizing:border-box !important; min-width:0 !important; max-width:100% !important; overflow-wrap:anywhere !important; }
        [${layout}="root"] :is(p,div,span,a,li,blockquote) { white-space:normal !important; }
        [${layout}="root"] :is(img,video,svg,canvas) { height:auto !important; object-fit:contain !important; }
        [${layout}="root"] :is(iframe,object) { width:100% !important; }
        [${layout}="root"] pre { width:auto !important; white-space:pre-wrap !important; overflow:auto !important; }
        [${layout}="root"] table { display:block !important; overflow:auto !important; }
        [${layout}="wide"] { width:auto !important; margin-left:0 !important; margin-right:0 !important; position:static !important; inset:auto !important; transform:none !important; float:none !important; }
        [${font}="readable"] { font-size:16px !important; line-height:1.65 !important; }
      `;
      function observe() {
        if (!disposed && enabled && document.documentElement) observer.observe(document.documentElement, {
          childList:true, subtree:true, characterData:true, attributes:true,
          attributeFilter:['class','style','src','open','hidden','aria-hidden','aria-modal','role']
        });
      }
      function apply() {
        observer.disconnect(); restore();
        try {
          if (!enabled || disposed || !(document instanceof HTMLDocument) || !document.body || hasPrompt()) return false;
          const width = document.documentElement.clientWidth || innerWidth, root = candidate();
          if (!root || width < 40) return false;
          const box = root.getBoundingClientRect();
          if (document.documentElement.scrollWidth <= width + 2 && box.left >= -1 && box.right <= width + 1 && root.scrollWidth <= box.width + 1) return false;
          mark(root, layout, 'root');
          for (let child = root, parent = root.parentElement; parent; child = parent, parent = parent.parentElement) {
            mark(parent, layout, 'container');
            for (const sibling of parent.children) {
              // Keep site navigation, comment/share controls and surrounding
              // content. Nested fixed-width navigation can scroll within its
              // own region instead of making the whole article overflow.
              // Never change display or expand an initially hidden region.
              // Closed dialogs/popovers must also keep their native behavior
              // so opening them later cannot leave an invisible modal layer.
              if (sibling !== child && visible(sibling) && !['HEAD','SCRIPT','STYLE','LINK','META','TEMPLATE','NOSCRIPT'].includes(sibling.tagName)
                  && !sibling.matches('dialog,[role="dialog"],[role="alertdialog"],[aria-modal="true"],[popover]')) mark(sibling, layout, 'auxiliary');
            }
          }
          // Constructed stylesheets work on the app's macOS 14 baseline and do
          // not depend on a site's permission to insert inline <style> tags.
          sheet = new CSSStyleSheet(); sheet.replaceSync(css);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          const bounds = root.getBoundingClientRect();
          for (const element of [...root.querySelectorAll('*')].slice(0, 4000)) {
            if (!visible(element)) continue;
            const style = getComputedStyle(element), rect = element.getBoundingClientRect();
            if (rect.left < bounds.left || rect.right > bounds.right || ['fixed','absolute'].includes(style.position)) mark(element, layout, 'wide');
            if (parseFloat(style.fontSize) < 14 && [...element.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim())) mark(element, font, 'readable');
          }
          return true;
        } finally { observe(); }
      }
      function cancelTimer() { if (timer !== null) clearTimeout(timer); timer = null; }
      function schedule() {
        if (disposed || !enabled || timer !== null) return;
        timer = setTimeout(() => { timer = null; apply(); }, 80);
      }
      const observer = new MutationObserver(schedule);
      function suspend() { observer.disconnect(); cancelTimer(); }
      function resume() { observe(); schedule(); }
      addEventListener('resize', schedule); addEventListener('pagehide', suspend); addEventListener('pageshow', resume);
      globalThis.__weiyueReading = {
        setEnabled(value) { enabled = value; cancelTimer(); return apply(); },
        dispose() {
          disposed = true; suspend(); restore();
          removeEventListener('resize', schedule); removeEventListener('pagehide', suspend); removeEventListener('pageshow', resume);
        }
      };
    })();
    """#
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
    private var readingEnabled = true, readingAdapted = false
    private var readingRevision = 0
    private var lastReadingWidth: CGFloat?
    var onChange: (([String: Any]) -> Void)?

    override init() { super.init(); view.isHidden = true }
    var currentURL: URL? { webView?.url ?? initialURL }
    var snapshot: [String: Any] {
        ["type": "contentPreview", "kind": kind, "title": webView?.title?.isEmpty == false ? webView!.title! : title,
         "url": currentURL?.absoluteString ?? "", "loading": webView?.isLoading ?? false,
         "canGoBack": webView?.canGoBack ?? false, "canGoForward": webView?.canGoForward ?? false, "error": error,
         "readingEnabled": readingEnabled, "readingAdapted": readingAdapted, "canToggleReading": kind == "link" && webView != nil,
         "originalURL": currentURL?.absoluteString ?? ""]
    }
    func close() {
        readingRevision += 1; lastReadingWidth = nil; readingEnabled = true; readingAdapted = false
        webView?.evaluateJavaScript("globalThis.__weiyueReading?.dispose()", in: nil, in: .defaultClient, completionHandler: nil)
        observations.removeAll(); webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
        documentView?.close(); documentView?.removeFromSuperview(); documentView = nil
        fileURL = nil; initialURL = nil; view.isHidden = true; error = ""
    }
    func open(url: URL, name: String) throws {
        let safe = try ContentPreviewPolicy.webURL(url.absoluteString)
        close(); kind = "link"; title = name; initialURL = safe
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(ContentPreviewReading.userScript(enabled: readingEnabled))
        let browser = WKWebView(frame: view.bounds, configuration: configuration)
        browser.autoresizingMask = [.width, .height]; browser.navigationDelegate = self; browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        browser.customUserAgent = ContentPreviewPolicy.prefersMobilePresentation(safe) ? ContentPreviewPolicy.mobileUserAgent : nil
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
    func layout(_ rect: NSRect, visible: Bool) {
        view.frame = rect; view.isHidden = !visible || rect.width < 40 || rect.height < 40
        guard !view.isHidden, webView?.isLoading == false, lastReadingWidth == nil || abs((lastReadingWidth ?? 0) - rect.width) >= 1 else { return }
        updateReadingPresentation()
    }
    func navigate(_ action: String) throws {
        error = ""
        switch action {
        case "back": webView?.goBack()
        case "forward": webView?.goForward()
        case "reload": if let webView { webView.reload() } else { documentView?.refreshPreviewItem() }
        case "reading", "original":
            guard let webView else { return }
            let enabled = action == "reading", changed = readingEnabled != enabled
            readingEnabled = enabled
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(ContentPreviewReading.userScript(enabled: enabled))
            if changed, let url = webView.url, ContentPreviewPolicy.prefersMobilePresentation(url) {
                webView.customUserAgent = enabled ? ContentPreviewPolicy.mobileUserAgent : nil
                webView.reload()
            } else { updateReadingPresentation() }
        case "external":
            if let fileURL { NSWorkspace.shared.open(fileURL) }
            else if let url = currentURL { NSWorkspace.shared.open(try ContentPreviewPolicy.webURL(url.absoluteString)) }
        default: throw ReaderError.message("预览操作无效。")
        }
        publish()
    }
    private func publish() { onChange?(snapshot) }
    private func updateReadingPresentation() {
        guard let browser = webView, browser.url != nil else { return }
        readingRevision += 1; let revision = readingRevision
        lastReadingWidth = view.bounds.width
        let script = ContentPreviewReading.source(enabled: readingEnabled)
        browser.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak browser] result in
            guard let self, let browser, self.webView === browser, self.readingRevision == revision else { return }
            let adapted: Bool
            if case .success(let value) = result { adapted = value as? Bool ?? false } else { adapted = false }
            if self.readingAdapted != adapted { self.readingAdapted = adapted; self.publish() }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard webView === self.webView, let url = navigationAction.request.url,
              (try? ContentPreviewPolicy.webURL(url.absoluteString)) != nil else { decisionHandler(.cancel, preferences); return }
        if navigationAction.targetFrame?.isMainFrame != false {
            let mobile = readingEnabled && ContentPreviewPolicy.prefersMobilePresentation(url)
            preferences.preferredContentMode = mobile ? .mobile : .recommended
            webView.customUserAgent = mobile ? ContentPreviewPolicy.mobileUserAgent : nil
        }
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel, preferences) }
        else { decisionHandler(.allow, preferences) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { readingRevision += 1; lastReadingWidth = nil; readingAdapted = false; publish() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { error = ""; updateReadingPresentation(); publish() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { failed(webView, failure) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { failed(webView, failure) }
    private func failed(_ browser: WKWebView, _ failure: Error) {
        guard browser === webView, (failure as NSError).code != NSURLErrorCancelled else { return }
        error = "页面暂时无法加载，可在右上角用默认浏览器打开。"; publish()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === self.webView { error = "页面已停止，点击刷新可重新打开。"; publish() } }
}
