import Foundation
import WebKit

/// 原生桥只接受宿主页主 frame；插件运行在独立来源的 sandbox iframe。
@MainActor
final class PluginWebBridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private let hostHTML: String
    private let load: () async throws -> [String: Any]
    private let call: ([String: Any]) async throws -> Any
    private let report: (String?) -> Void
    private let hostURL = URL(string: "kite-plugin://host/index.html")!
    private var closed = false
    private var closing = false
    private var loaded = false
    private var theme = "light"
    private var revision = 0
    private var state: JSON?
    private var connection: UUID?

    init(hostHTML: String, load: @escaping () async throws -> [String: Any],
         call: @escaping ([String: Any]) async throws -> Any, report: @escaping (String?) -> Void) {
        self.hostHTML = hostHTML
        self.load = load
        self.call = call
        self.report = report
    }

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PluginHostPage(html: hostHTML), forURLScheme: "kite-plugin")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "kitePlugin")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        #endif
        return view
    }()

    func start() {
        guard !hostHTML.isEmpty else { Task { report("插件界面组件缺失，请重新安装 App") }; return }
        webView.load(URLRequest(url: hostURL))
    }

    func update(theme: String, state: JSON?, connection: UUID) {
        guard !closing else { return }
        let resourceChanged = self.state != state || self.connection != connection
        let changed = self.theme != theme || resourceChanged
        self.theme = theme
        self.state = state
        self.connection = connection
        if resourceChanged { revision += 1 }
        if loaded && changed { sendContext() }
    }

    private func sendContext() {
        guard !closing else { return }
        webView.callAsyncJavaScript("window.kitePluginHost.update(theme, revision)",
            arguments: ["theme": theme, "revision": revision], in: nil, in: .page, completionHandler: { _ in })
    }

    func close() async {
        guard !closing else { return }
        closing = true
        _ = try? await webView.callAsyncJavaScript("await window.kitePluginHost?.close()", arguments: [:], in: nil, contentWorld: .page)
        closed = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kitePlugin", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.stopLoading()
        // 已提交的 HTTP 操作继续收口；关闭视图不停止共享插件进程。
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard !closed, message.frameInfo.isMainFrame, message.frameInfo.request.url == hostURL else {
            replyHandler(nil, "仅当前插件的可信宿主页可以调用原生桥")
            return
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "无效的插件请求")
            return
        }
        switch kind {
        case "ready":
            report(nil)
            replyHandler([:], nil)
        case "error":
            report(body["message"] as? String ?? "插件界面加载失败")
            replyHandler([:], nil)
        case "load", "call":
            Task {
                do {
                    if kind == "load" {
                        var resource = try await load()
                        resource["theme"] = theme
                        resource["revision"] = revision
                        replyHandler(resource, nil)
                    } else {
                        replyHandler(try await call(body), nil)
                    }
                } catch { replyHandler(nil, error.localizedDescription) }
            }
        default: replyHandler(nil, "不支持的插件请求")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        sendContext()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let allowed = navigationAction.targetFrame?.isMainFrame == true ? url == hostURL
            : url?.absoluteString == "about:srcdoc" || url?.absoluteString == "about:blank"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !closed { report(error.localizedDescription) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !closed { report("插件界面进程已退出，请重新加载") }
    }
}

private final class PluginHostPage: NSObject, WKURLSchemeHandler {
    let html: Data
    init(html: String) { self.html = Data(html.utf8) }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.absoluteString == "kite-plugin://host/index.html" else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: html.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(html)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
