import SwiftUI
import WebKit

/// 网页视图看哪里：工作区里的静态 HTML，或者本机能直接打开的网址（工作机上的开发服务器，或设备上转发到它的端口）。
enum WebSource: Equatable {
    /// 相对资源从同一工作区读取；version 变了就重新加载。
    case workspaceFile(client: KitedClient, workspace: String, path: String, version: String)
    /// store 是这个目标在本设备的网站数据（Cookie、本地存储），同一目标下次打开仍是登录状态。
    case address(URL, store: UUID)

    fileprivate static let fileScheme = "kite-file"

    fileprivate var url: URL {
        switch self {
        case .workspaceFile(_, _, let path, _):
            var components = URLComponents()
            components.scheme = Self.fileScheme
            components.host = "workspace"
            components.path = "/" + path
            return components.url!
        case .address(let url, _): return url
        }
    }

    /// 主框架只能停在同一个来源上。
    fileprivate func contains(_ url: URL) -> Bool {
        url.scheme == self.url.scheme && url.host == self.url.host && url.port == self.url.port
    }
}

/// 网页类成果共用的视图，文件插件的静态 HTML 与终端的网页视图都用它。页面是不可信内容，与 App 隔离：
/// 没有原生桥，网站数据与 App 的其他网页分开；主框架只停在自己的目标上，去别处的链接交给系统浏览器，下载一律拒绝。
/// 内容只经工作机的文件接口或本机地址取得，页面拿不到组网身份。
struct WebPreview: View {
    let source: WebSource
    /// 加载失败时报给所在窗口的信息区，成功后报 nil。
    var report: (String?) -> Void = { _ in }
    @State private var page: WebPage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let page { WebView(page) } else { Color.clear }
        }
        .task(id: source) {
            let page = makePage()
            self.page = page
            do {
                for try await _ in page.load(source.url) {}
                report(nil)
            } catch is CancellationError {
            } catch {
                report(Self.message(error))
            }
        }
    }

    private func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        switch source {
        case .workspaceFile(let client, let workspace, _, _):
            configuration.websiteDataStore = .nonPersistent()
            configuration.urlSchemeHandlers[URLScheme(WebSource.fileScheme)!] = WorkspaceFileScheme { path in
                try await FileContentCache.shared.file(client: client, workspace: workspace, path: path)
            }
        case .address(_, let store):
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: store)
        }
        return WebPage(configuration: configuration, navigationDecider: WebNavigation(source: source, openURL: { openURL($0) }))
    }

    private static func message(_ error: any Error) -> String {
        if case .failedProvisionalNavigation(let underlying) = error as? WebPage.NavigationError {
            return "网页打不开：\(underlying.localizedDescription)"
        }
        if case .webContentProcessTerminated = error as? WebPage.NavigationError { return "网页进程已退出，请刷新" }
        return "网页打不开：\(error.localizedDescription)"
    }
}

private struct WebNavigation: WebPage.NavigationDeciding {
    let source: WebSource
    let openURL: (URL) -> Void

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, !action.shouldPerformDownload else { return .cancel }
        let web = ["http", "https"].contains(url.scheme?.lowercased())
        guard let target = action.target, target.isMainFrame else {
            // 新窗口打开的链接交给系统浏览器；框架里的内容照常加载
            if action.target == nil {
                if web && !source.contains(url) { openURL(url) }
                return .cancel
            }
            return web || ["about", "data", "blob", WebSource.fileScheme].contains(url.scheme?.lowercased()) ? .allow : .cancel
        }
        if source.contains(url) || url.scheme == "about" { return .allow }
        if web && action.navigationType == .linkActivated { openURL(url) }
        return .cancel
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMimeType ? .allow : .cancel
    }
}

/// 页面里的 kite-file 请求按路径到同一工作区取文件，越出工作区的由工作机拒绝。
nonisolated private struct WorkspaceFileScheme: URLSchemeHandler {
    let fetch: @MainActor @Sendable (String) async throws -> CachedFile

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = request.url else { throw URLError(.badURL) }
                    let file = try await fetch(String(url.path(percentEncoded: false).dropFirst()))
                    let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                   headerFields: ["Content-Type": file.type, "Content-Length": String(data.count)])!
                    continuation.yield(.response(response))
                    continuation.yield(.data(data))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 工作机上某个端口的网页，给终端的网页视图用。本机就是工作机时直接访问 localhost；其他设备在本机回环上开一个转发
/// （PortRelay），经组网连到工作机为这个端口开的转发。store 是这个目标在本设备的网站数据，见 WebSource.address。
struct PortPreview: View {
    let client: KitedClient
    let port: Int
    let store: UUID
    var report: (String?) -> Void = { _ in }
    @State private var url: URL?

    var body: some View {
        Group {
            if let url { WebPreview(source: .address(url, store: store), report: report) } else { Color.clear }
        }
        .task(id: "\(client.identity) \(port)") {
            url = nil
            // kited 自己的端口在本机和组网上都开着，页面开在它上面就和接口同源，能带上请求头调用接口
            guard port != URL(string: client.address)?.port, port != URL(string: KitedClient.local)?.port else {
                report("这是工作机服务自己的端口，不能预览")
                return
            }
            if client.isLocal { url = URL(string: "http://localhost:\(port)"); return }
            guard let host = URL(string: client.address)?.host(percentEncoded: false), let target = UInt16(exactly: port) else {
                report("工作机地址或端口无效")
                return
            }
            let relay: PortRelay
            do { relay = try await PortRelay.start(host: host, port: target) { try await Tailnet.shared.socksProxy() } }
            catch {
                report("本机转发没有打开：\(error.localizedDescription)")
                return
            }
            url = URL(string: "http://localhost:\(relay.port)")
            // 视图在就一直转发，离开或换了目标时关掉
            try? await Task.sleep(for: .seconds(Int.max))
            relay.stop()
        }
    }
}
