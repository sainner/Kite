import Foundation
import WebKit
import Darwin
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// 手动层：真实 WebKit、MCP Apps SDK 与生产原生桥一起运行，只读事件，不做视觉验收。
@MainActor
final class PluginWebProbe: NSObject {
    private let hostHTML: String
    private let fixtureHTML: String
    private let resourceURI = "ui://probe/app.html"
    private var bridge: PluginWebBridge!
    #if os(macOS)
    private var window: NSWindow?
    #elseif os(iOS)
    private(set) var window: UIWindow?
    var windowScene: UIWindowScene?
    #endif
    private var phase = "bootstrap"
    private var handshake = false
    private var fixtureReady = false
    private var lightTheme = false
    private var lightResource = false
    private var teardown = false
    private var resourceEvents = 0
    private var initialResourceEvents = 0
    private var reconnectResource = false
    private var state: JSON? = .object(["count": .number(0)])
    private var connection = UUID()
    private var facts: [String: Any] = [:]
    private var finished = false

    init(hostHTML: String, fixtureHTML: String) {
        self.hostHTML = hostHTML
        self.fixtureHTML = fixtureHTML
    }

    func start() {
        #if os(macOS)
        NSApp.setActivationPolicy(.prohibited)
        #endif
        bridge = PluginWebBridge(
            hostHTML: hostHTML,
            load: { [weak self] in
                guard let self else { throw ProbeFailure("探针已释放") }
                return ["html": self.fixtureHTML, "resourceUri": self.resourceURI]
            },
            call: { [weak self] body in
                guard let self else { throw ProbeFailure("探针已释放") }
                return try self.receive(body)
            },
            report: { [weak self] error in
                guard let self else { return }
                if let error { self.finish(error: error); return }
                self.handshake = true
                self.facts["handshake"] = true
                self.advance()
            }
        )
        #if os(macOS)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = bridge.webView
        self.window = window
        #elseif os(iOS)
        guard let windowScene else { finish(error: "探针没有 UIWindowScene"); return }
        let window = UIWindow(windowScene: windowScene)
        let root = UIViewController()
        root.view = bridge.webView
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        #endif
        bridge.update(theme: "dark", state: state, connection: connection)
        bridge.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.finish(error: "原生探针超时，阶段：\(self.phase)")
        }
    }

    private func receive(_ body: [String: Any]) throws -> Any {
        guard let name = body["name"] as? String,
              let arguments = body["arguments"] as? [String: Any],
              let operationID = body["operationId"] as? String,
              !operationID.isEmpty else {
            throw ProbeFailure("工具调用缺少 name、arguments 或非空 operationId")
        }
        switch name {
        case "__probe_stage":
            let name = arguments["name"] as? String ?? "unknown"
            facts["lastStage"] = name
            var stages = facts["stages"] as? [String] ?? []
            stages.append(name)
            facts["stages"] = stages
        case "__probe_ready":
            let isolation = ["parentReadDenied", "localStorageDenied", "sessionStorageDenied", "cookieDenied",
                             "indexedDBDenied", "fetchDenied", "imageDenied", "socketDenied", "nativeDenied"]
            for key in isolation {
                facts[key] = arguments[key] ?? false
                guard arguments[key] as? Bool == true else {
                    finish(error: "隔离断言失败：\(key)")
                    return toolResult()
                }
            }
            facts["initialTheme"] = arguments["initialTheme"] ?? NSNull()
            guard arguments["initialTheme"] as? String == "dark" else {
                finish(error: "初始 hostContext.theme 不是 dark")
                return toolResult()
            }
            fixtureReady = true
        case "__probe_theme":
            let theme = arguments["theme"] as? String
            var themes = facts["themes"] as? [String] ?? []
            if let theme { themes.append(theme) }
            facts["themes"] = themes
            if phase == "light", theme == "light" { lightTheme = true }
            if phase == "dark", theme == "dark" {
                facts["themeChanged"] = true
                phase = "closing"
                Task { await self.close() }
            }
        case "__probe_resource":
            guard arguments["uri"] as? String == resourceURI else {
                finish(error: "resources/updated 的 uri 与当前资源不同")
                return toolResult()
            }
            resourceEvents += 1
            if phase == "light" { lightResource = true }
            if phase == "reconnect" { reconnectResource = true }
        case "__probe_teardown":
            teardown = true
            facts["teardown"] = true
        case "__probe_failure":
            finish(error: arguments["message"] as? String ?? "MCP App fixture 失败")
        case "__probe_forged_native", "__probe_forged_message", "__probe_after_close":
            finish(error: "不可信或已关闭的页面调用了原生工具：\(name)")
        default:
            finish(error: "意外的原生工具：\(name)")
        }
        advance()
        return toolResult()
    }

    private func toolResult() -> [String: Any] {
        ["content": [["type": "text", "text": "ok"]], "structuredContent": ["ok": true]]
    }

    private func advance() {
        if phase == "bootstrap", handshake, fixtureReady {
            initialResourceEvents = resourceEvents
            phase = "light"
            Task {
                await Task.yield()
                self.state = .object(["count": .number(1)])
                self.bridge.update(theme: "light", state: self.state, connection: self.connection)
            }
        } else if phase == "light", lightTheme, lightResource {
            guard resourceEvents == initialResourceEvents + 1 else {
                finish(error: "一次实例状态变化没有恰好通知一次资源更新")
                return
            }
            facts["resourceUpdated"] = true
            phase = "reconnect"
            Task {
                await Task.yield()
                self.bridge.update(theme: "light", state: self.state, connection: self.connection)
                self.connection = UUID()
                self.bridge.update(theme: "light", state: self.state, connection: self.connection)
            }
        } else if phase == "reconnect", reconnectResource {
            guard resourceEvents == initialResourceEvents + 2 else {
                finish(error: "相同状态的重连没有恰好追加一次资源通知")
                return
            }
            facts["reconnectResourceUpdated"] = true
            phase = "dark"
            Task {
                await Task.yield()
                self.bridge.update(theme: "dark", state: self.state, connection: self.connection)
            }
        }
    }

    private func close() async {
        await bridge.close()
        guard teardown else { finish(error: "close 未等待 SDK teardown"); return }
        guard resourceEvents == initialResourceEvents + 2 else {
            finish(error: "重复 state/connection 或仅主题改变时追加了 resources/updated")
            return
        }
        facts["resourceUpdates"] = resourceEvents - initialResourceEvents
        facts["unchangedStateAndThemeOnlyDoNotRefresh"] = true
        do {
            let denied = try await bridge.webView.callAsyncJavaScript("""
                try {
                    const handler = window.webkit?.messageHandlers?.kitePlugin;
                    if (!handler) return true;
                    const value = await handler.postMessage({kind:'call',name:'__probe_after_close',
                        arguments:{},operationId:'probe-after-close'});
                    return typeof value?.error === 'string';
                } catch { return true; }
                """, arguments: [:], in: nil, contentWorld: .page)
            guard denied as? Bool == true else { finish(error: "close 后原生桥仍接受调用"); return }
            facts["closedBridgeDenied"] = true
            finish(error: nil)
        } catch {
            finish(error: "close 后检查原生桥失败：\(error.localizedDescription)")
        }
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        facts["pass"] = error == nil
        facts["phase"] = phase
        if let error { facts["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("KITE_PLUGIN_WEB_PROBE=\(text)")
        } else {
            print("KITE_PLUGIN_WEB_PROBE={\"pass\":false,\"error\":\"结果无法序列化\"}")
        }
        fflush(stdout)
        Darwin.exit(error == nil ? 0 : 1)
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

#if os(macOS)
@MainActor
private final class PluginWebProbeMacDelegate: NSObject, NSApplicationDelegate {
    let probe: PluginWebProbe
    init(_ probe: PluginWebProbe) { self.probe = probe }
    func applicationDidFinishLaunching(_ notification: Notification) { probe.start() }
}
#elseif os(iOS)
@MainActor
@objc(PluginWebProbeAppDelegate)
final class PluginWebProbeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Probe", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PluginWebProbeSceneDelegate.self
        return configuration
    }
}

@MainActor
@objc(PluginWebProbeSceneDelegate)
final class PluginWebProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var probe: PluginWebProbe?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let hostURL = Bundle.main.url(forResource: "PluginHost", withExtension: "html"),
              let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "html"),
              let host = try? String(contentsOf: hostURL, encoding: .utf8),
              let fixture = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
            fputs("iOS 探针包缺少 PluginHost.html 或 fixture.html\n", stderr)
            Darwin.exit(2)
        }
        let probe = PluginWebProbe(hostHTML: host, fixtureHTML: fixture)
        probe.windowScene = scene
        self.probe = probe
        probe.start()
        window = probe.window
    }
}
#endif

@main
enum PluginWebProbeMain {
    @MainActor
    static func main() {
        #if os(macOS)
        guard CommandLine.arguments.count == 3,
              let host = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
              let fixture = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8) else {
            fputs("用法：PluginWebProbe <PluginHost.html> <fixture.html>\n", stderr)
            Darwin.exit(2)
        }
        let app = NSApplication.shared
        let delegate = PluginWebProbeMacDelegate(PluginWebProbe(hostHTML: host, fixtureHTML: fixture))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        #elseif os(iOS)
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PluginWebProbeAppDelegate.self))
        #endif
    }
}
