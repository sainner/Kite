import Foundation
import WebKit
import Darwin
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// 独立手动探针：只验证 WebKit/JS/宿主网关的跨进程交接，不进入产品工程。
final class Probe: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private let hostURL: URL
    private let token: String
    #if os(macOS)
    private var window: NSWindow?
    #elseif os(iOS)
    private(set) var window: UIWindow?
    var windowScene: UIWindowScene?
    #endif
    private var reported = false

    init(hostURL: URL, token: String) {
        self.hostURL = hostURL
        self.token = token
    }

    func start() {
        #if os(macOS)
        NSApp.setActivationPolicy(.prohibited)
        #endif
        let content = WKUserContentController()
        content.addScriptMessageHandler(self, contentWorld: .page, name: "kite")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        #if os(macOS)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Kite 插件边界探针"
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        self.window = window
        #elseif os(iOS)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        let window = UIWindow(windowScene: windowScene!)
        let root = UIViewController()
        root.view = webView
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        #endif
        webView.load(URLRequest(url: hostURL))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.finish(["pass": false, "error": "原生探针超时"], code: 1)
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              origin.protocol == hostURL.scheme,
              origin.host == hostURL.host,
              origin.port == (hostURL.port ?? 80) else {
            replyHandler(["error": "仅可信主 frame 可调用原生桥"], nil)
            return
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(["error": "无效请求"], nil)
            return
        }
        if kind == "report" {
            finish(body, code: (body["pass"] as? Bool) == true ? 0 : 1)
            replyHandler(["ok": true], nil)
            return
        }
        guard kind == "resource" || kind == "call" || kind == "restart" else {
            replyHandler(["error": "不支持的原生请求"], nil)
            return
        }
        let path = kind == "restart" ? "/restart" : "/bridge"
        guard let url = URL(string: path, relativeTo: hostURL)?.absoluteURL else {
            replyHandler(["error": "URL 无效"], nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            replyHandler(["error": "请求不是 JSON"], nil)
            return
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let answer: [String: Any]
            if let error {
                answer = ["error": error.localizedDescription]
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    answer = ["error": json["error"] ?? "HTTP \(status)", "status": status]
                } else {
                    answer = json
                }
            } else {
                answer = ["error": "服务器返回非 JSON"]
            }
            DispatchQueue.main.async { replyHandler(answer, nil) }
        }.resume()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(["pass": false, "error": error.localizedDescription], code: 1)
    }

    private func finish(_ payload: [String: Any], code: Int32) {
        guard !reported else { return }
        reported = true
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("KITE_PLUGIN_PROBE=\(text)")
        } else {
            print("KITE_PLUGIN_PROBE={\"pass\":false,\"error\":\"结果无法序列化\"}")
        }
        fflush(stdout)
        Darwin.exit(code)
    }
}

guard CommandLine.arguments.count == 3,
      let url = URL(string: CommandLine.arguments[1]),
      url.scheme == "http", url.host == "127.0.0.1" else {
    fputs("用法: Probe <http://127.0.0.1:端口/host> <临时令牌>\n", stderr)
    Darwin.exit(2)
}
#if os(macOS)
final class MacDelegate: NSObject, NSApplicationDelegate {
    let probe: Probe
    init(_ probe: Probe) { self.probe = probe }
    func applicationDidFinishLaunching(_ notification: Notification) { probe.start() }
}
let app = NSApplication.shared
let macDelegate = MacDelegate(Probe(hostURL: url, token: CommandLine.arguments[2]))
app.delegate = macDelegate
app.run()
#elseif os(iOS)
@objc(ProbeAppDelegate)
final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Probe Scene", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ProbeSceneDelegate.self
        return configuration
    }
}
@objc(ProbeSceneDelegate)
final class ProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var probe: Probe?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let probe = Probe(hostURL: URL(string: CommandLine.arguments[1])!, token: CommandLine.arguments[2])
        probe.windowScene = scene
        self.probe = probe
        probe.start()
        window = probe.window
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ProbeAppDelegate.self))
#endif
