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
    /// 窗口里的浏览控件经它操作这个页面；不给就只是看。
    var browser: WebBrowser?
    /// 藏起来时页面留着、网页视图摘下：不在窗口里的页面由 WebKit 节流，再显示时接着原来的页面。
    var visible = true
    @State private var page: WebPage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let page, visible {
                #if os(macOS)
                // Mac 窗口底部没有系统安全区，页面直接铺到控制区后面，控制区浮在页面上，不为它让边。
                WebView(page).ignoresSafeArea(.container, edges: .bottom)
                #else
                // WebView 自己把安全区（Home 条、控制区）交给页面：铺到控制区后面，被挡住的那一截让出来，同 Safari。
                WebView(page)
                #endif
            } else { Color.clear }
        }
        .onChange(of: page?.isLoading) { _, loading in
            if loading == false { browser?.refreshIcon() }
        }
        .task(id: source) {
            let page = makePage()
            self.page = page
            browser?.attach(page, report: report)
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

    fileprivate static func message(_ error: any Error) -> String {
        if case .failedProvisionalNavigation(let underlying) = error as? WebPage.NavigationError {
            return "网页打不开：\(underlying.localizedDescription)"
        }
        if case .webContentProcessTerminated = error as? WebPage.NavigationError { return "网页进程已退出，请刷新" }
        return "网页打不开：\(error.localizedDescription)"
    }
}

/// 一个网页视图的浏览操作：窗口控制区的地址栏、前进后退、首页和重新加载经它在同一个页面里跳转，也从它读当前地址和站点图标。
/// 页面由 WebPreview 建好交给它；换了来源（换端口）是新的页面，历史从头开始。跳转失败照样报给窗口的信息区。
@MainActor @Observable final class WebBrowser {
    /// 页面由预览持有；端口消失、预览卸下后，控制区不继续留住它。
    private(set) weak var page: WebPage?
    /// 站点图标，没有或画不出来时是 nil。
    private(set) var icon: Image?
    @ObservationIgnored private var report: (String?) -> Void = { _ in }
    @ObservationIgnored private var navigation: Task<Void, Never>?

    var url: URL? { page?.url }
    var canGoBack: Bool { page?.backForwardList.backList.isEmpty == false }
    var canGoForward: Bool { page?.backForwardList.forwardList.isEmpty == false }

    fileprivate func attach(_ page: WebPage, report: @escaping (String?) -> Void) {
        navigation?.cancel()
        self.page = page
        self.report = report
        icon = nil
    }

    func back() {
        guard let page, let item = page.backForwardList.backList.last else { return }
        follow(page.load(item))
    }

    func forward() {
        guard let page, let item = page.backForwardList.forwardList.first else { return }
        follow(page.load(item))
    }

    func open(_ url: URL) {
        guard let page else { return }
        follow(page.load(url))
    }

    /// 重新加载当前页面。还没打开成功过（首次加载就失败了）时没有可重新加载的，返回 false，由窗口重建网页视图。
    func reload() -> Bool {
        guard let page, page.url != nil else { return false }
        follow(page.reload())
        return true
    }

    private func follow(_ events: some AsyncSequence<WebPage.NavigationEvent, any Error>) {
        navigation?.cancel()
        let report = report
        navigation = Task {
            do {
                for try await _ in events {}
                report(nil)
            } catch {
                // 被下一次跳转顶掉的不算失败
                if !Task.isCancelled { report(WebPreview.message(error)) }
            }
        }
    }

    /// 让页面把图标画成 PNG 交回来：SVG、ICO 都由 WebKit 解码，两端一样。脚本在隔离的环境里跑，页面自己的脚本碰不到；
    /// 图标跨源时画布读不出来，就没有图标。
    fileprivate func refreshIcon() {
        guard let page else { return }
        Task {
            let data = try? await page.callJavaScript(Self.iconScript, contentWorld: .defaultClient) as? String
            guard self.page === page else { return }
            icon = data.flatMap(Self.image)
        }
    }

    private static let iconScript = """
        const links = document.querySelectorAll('link[rel~="icon" i]');
        const image = new Image();
        image.src = links.length ? links[links.length - 1].href : new URL('/favicon.ico', location.href).href;
        await image.decode();
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 64;
        canvas.getContext('2d').drawImage(image, 0, 0, 64, 64);
        return canvas.toDataURL('image/png');
        """

    private static func image(_ dataURL: String) -> Image? {
        guard let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = PlatformImage(data: data) else { return nil }
        #if os(macOS)
        return Image(nsImage: image)
        #else
        return Image(uiImage: image)
        #endif
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
                                                   headerFields: ["Content-Type": file.info.type, "Content-Length": String(data.count)])!
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
    /// 消息里点的链接或地址栏里输入的路径：在页面里打开到它，每次都打开一回；没有时是首页。
    var link: WebLink?
    /// 其他设备上页面的地址是本机转发的地址，端口不是工作机上的端口，只看路径。
    let browser: WebBrowser
    var report: (String?) -> Void = { _ in }
    /// 见 WebPreview.visible。
    var visible = true
    /// 网站根地址：本机的 localhost，或本机转发的地址。
    @State private var url: URL?
    /// 第一次打开到哪里：带上转发好时的链接路径；之后的链接在同一个页面里打开，前进后退接得上。
    @State private var start: URL?

    var body: some View {
        Group {
            if let start {
                WebPreview(source: .address(start, store: store), report: report, browser: browser, visible: visible)
            } else { Color.clear }
        }
        .onChange(of: link) { _, link in
            guard let url, let link, let target = URL(string: url.absoluteString + link.target.path) else { return }
            browser.open(target)
        }
        .task(id: "\(client.identity) \(port)") {
            url = nil
            start = nil
            // kited 自己的端口在本机和组网上都开着，页面开在它上面就和接口同源，能带上请求头调用接口
            guard port != URL(string: client.address)?.port, port != URL(string: KitedClient.local)?.port else {
                report("这是工作机服务自己的端口，不能预览")
                return
            }
            if client.isLocal { show(URL(string: "http://localhost:\(port)")); return }
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
            // 转发只听 IPv4 回环；写 localhost 时 WebKit 先连 ::1，本机正好有服务占着同号端口就会打开错的页面。
            show(URL(string: "http://127.0.0.1:\(relay.port)"))
            // 视图在就一直转发，离开或换了目标时（任务取消）关掉
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            relay.stop()
        }
    }

    private func show(_ root: URL?) {
        guard let root else { return }
        url = root
        start = URL(string: root.absoluteString + (link?.target.path ?? "")) ?? root
    }
}
