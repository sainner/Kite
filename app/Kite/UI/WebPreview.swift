import SwiftUI
import WebKit

/// 网页视图看哪里：工作区里的静态 HTML，或者本机能直接打开的网址（工作机上的开发服务器、设备上转发到它的端口，浏览里还有互联网）。
enum WebSource: Equatable {
    /// 相对资源从同一工作区读取；version（内容的版本）变了就重新加载。snapshot 是看历史版本时那枚快照的提交号，
    /// 页面和它引用的资源都读那一枚里的，nil 是现在的。
    case workspaceFile(client: KitedClient, workspace: String, path: String, version: String, snapshot: String? = nil)
    /// store 是这个目标在本设备的网站数据（Cookie、本地存储），同一目标下次打开仍是登录状态。
    /// 有 roaming 时主框架可以去任何网址（浏览）；没有时只停在自己的来源上（预览的网页画面）。
    case address(URL, store: UUID, roaming: WebRoaming? = nil)

    fileprivate static let fileScheme = "kite-file"

    fileprivate var url: URL {
        switch self {
        case .workspaceFile(_, _, let path, _, _):
            var components = URLComponents()
            components.scheme = Self.fileScheme
            components.host = "workspace"
            components.path = "/" + path
            return components.url!
        case .address(let url, _, _): return url
        }
    }

    fileprivate var roaming: WebRoaming? {
        if case .address(_, _, let roaming) = self { return roaming }
        return nil
    }

    /// 主框架只能停在同一个来源上。
    fileprivate func contains(_ url: URL) -> Bool {
        url.scheme == self.url.scheme && url.host == self.url.host && url.port == self.url.port
    }
}

/// 网页类成果共用的视图，浏览里的静态 HTML、网页与预览的网页画面都用它。页面是不可信内容，与 App 隔离：
/// 没有原生桥，网站数据与 App 的其他网页分开；下载一律拒绝。静态 HTML 和预览的主框架只停在自己的目标上，去别处的链接交给 openURL（工作区里在浏览里打开）；
/// 浏览里的网页可以去任何网址，只是进不了工作机服务自己的地址（见 WebRoaming）。页面不经组网，拿不到组网身份。
struct WebPreview: View {
    let source: WebSource
    /// 加载失败时报给所在窗口的信息区，成功后报 nil。
    var report: (String?) -> Void = { _ in }
    /// 窗口里的浏览控件经它操作这个页面；不给就只是看。
    var browser: WebBrowser?
    @State private var page: WebPage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let page {
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
            let events = page.load(source.url)
            #if os(macOS)
            page.enableDeveloperTools()
            #endif
            do {
                for try await _ in events {}
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
        case .workspaceFile(let client, let workspace, _, _, let snapshot):
            configuration.websiteDataStore = .nonPersistent()
            configuration.urlSchemeHandlers[URLScheme(WebSource.fileScheme)!] = WorkspaceFileScheme { path in
                try await FileContentCache.shared.file(client: client, workspace: workspace, path: path, version: snapshot)
            }
        case .address(_, let store, _):
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: store)
        }
        // 浏览里新窗口打开的链接在同一个页面里打开
        let follow: @MainActor (URL) -> Void = { [browser] url in browser?.open(url) }
        let page = WebPage(configuration: configuration, navigationDecider: WebNavigation(source: source, openURL: { openURL($0) }, follow: follow))
        // Safari 的网页检查器连得上：iPhone、iPad 没有自带的检查器，接上 Mac 后从 Safari 的「开发」菜单里选设备名下的这个页面；
        // Mac 上在 Kite 里直接打开（见 WebBrowser.inspect）。检查器由用户打开，页面碰不到它，隔离不变。
        page.isInspectable = true
        return page
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
    var currentItem: WebPage.BackForwardList.Item? { page?.backForwardList.currentItem }
    /// 这个网页视图里去过的页面，旧的在前，含正在看的一页。
    var history: [WebPage.BackForwardList.Item] {
        guard let list = page?.backForwardList else { return [] }
        return list.backList + [list.currentItem].compactMap(\.self) + list.forwardList
    }

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

    func go(to item: WebPage.BackForwardList.Item) {
        guard let page else { return }
        follow(page.load(item))
    }

    /// 重新加载当前页面。还没打开成功过（首次加载就失败了）时没有可重新加载的，返回 false，由窗口重建网页视图。
    func reload() -> Bool {
        guard let page, page.url != nil else { return false }
        follow(page.reload())
        return true
    }

    #if os(macOS)
    /// 开发者工具：在 Kite 里打开 WebKit 自带的检查器，单独一个窗口。
    func inspect() {
        let inspector = NSSelectorFromString("_inspector"), show = NSSelectorFromString("show")
        guard let page, page.enableDeveloperTools(), let view = page.backingWebView, view.responds(to: inspector),
              let object = view.perform(inspector)?.takeUnretainedValue() as? NSObject, object.responds(to: show) else {
            report("开发者工具打不开，可以从 Safari 的「开发」菜单里打开")
            return
        }
        object.perform(show)
    }

    /// 在浏览器中打开当前地址。不走环境里的 openURL：本机地址会被它接回 Kite 的窗口（见 ReferenceNavigation）。
    func openExternally() {
        if let url { NSWorkspace.shared.open(url) }
    }
    #endif

    /// 指认：页面上这一点（视图里的点）是哪个元素，用和工作机共用的指认脚本（shared/preview-point.js，随 App 带着）。
    /// 在页面自己的环境里跑：框架开发模式挂在元素上的信息只有页面的脚本看得见；只是 App 去问、页面回答，页面仍然碰不到 App。
    func element(at point: CGPoint) async -> PointedElement? {
        guard let page, let script = Self.pointScript else { return nil }
        // 交回 JSON 字符串，直接解码，不经字典再转一遍
        let json = try? await page.callJavaScript("return JSON.stringify((\(script))(x, y));", arguments: ["x": point.x, "y": point.y], contentWorld: .page)
        return PointedElement.decode(json as? String)
    }

    /// 视图此刻的样子，size 是视图的大小（点）。
    func snapshot(size: CGSize) async -> CGImage? {
        guard let page, size.width > 0, size.height > 0,
              let data = try? await page.exported(as: .image(region: .rect(CGRect(origin: .zero, size: size)))) else { return nil }
        return await PreviewSession.decode(data)
    }

    private static let pointScript: String? = Bundle.main.url(forResource: "preview-point", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

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

/// 浏览里的网页可以去任何网址，只是不进工作机服务（kited）自己的地址：页面开在那里就与接口同源，能调用接口
/// （docs/成果查看与位置.md「运行中的网页」）。地址按本机回环和工作机的主机名，配 kited 在本机和组网上的端口。
struct WebRoaming: Equatable {
    let service: Set<String>

    func allows(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return true }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return !service.contains("\(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))):\(port)")
    }
}

private struct WebNavigation: WebPage.NavigationDeciding {
    let source: WebSource
    let openURL: (URL) -> Void
    /// 浏览里新窗口打开的链接：在同一个页面里打开。
    let follow: @MainActor (URL) -> Void

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, !action.shouldPerformDownload else { return .cancel }
        let web = ["http", "https"].contains(url.scheme?.lowercased())
        if let roaming = source.roaming {
            if web, !roaming.allows(url) { return .cancel }
            if action.target == nil {
                if web { follow(url) } else { openURL(url) }
                return .cancel
            }
            if web || ["about", "data", "blob"].contains(url.scheme?.lowercased()) { return .allow }
            // mailto、tel 这类交给系统
            if action.target?.isMainFrame == true, action.navigationType == .linkActivated { openURL(url) }
            return .cancel
        }
        guard let target = action.target, target.isMainFrame else {
            // 新窗口打开的链接交给 openURL；框架里的内容照常加载
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

#if os(macOS)
/// 开发者工具用的是 WebKit 的私有接口：开发者选项（右键菜单里的「检查元素」）和检查器（_inspector）。Mac 版用 Developer ID 发布、不经商店审核；
/// 系统更新后接口没了就只剩 Safari 的「开发」菜单，所以调用前先确认还在。检查器默认嵌在网页视图下方，而网页视图的大小归 SwiftUI 管，
/// 嵌进去会被挤乱，所以登记成单独开窗口：WebKit 把这个选择记在用户默认值里，用户在检查器里改成嵌入也照记。
extension WebPage {
    /// WebPage 没有公开底下的 WKWebView，按反射取它惰性建好的那个，开始加载后才有。
    fileprivate var backingWebView: WKWebView? {
        Mirror(reflecting: self).children.lazy.compactMap { $0.value as? WKWebView }.first
    }

    /// 打开开发者选项，返回是否打开了。
    @discardableResult
    fileprivate func enableDeveloperTools() -> Bool {
        guard let preferences = backingWebView?.configuration.preferences,
              preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) else { return false }
        UserDefaults.standard.register(defaults: ["__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached": false])
        preferences.setValue(true, forKey: "developerExtrasEnabled")
        return true
    }
}

extension NSView {
    /// 指针下是不是这个视图里面的网页。网页的光标由 WebKit 按页面的 cursor 样式在指针移动时自己设；WebKit 自己的跟踪区域收到的
    /// cursorUpdate 网页视图不接，往外传到窗口就设回箭头。窗口里别的跟踪区域一变（SwiftUI 刷新悬停区域、别的窗口在动），AppKit 就再发一次，
    /// 指针停在页面的按钮上时手形和箭头来回闪（2026-10-21 光标探针记到）。托管网页的视图按它不往外传，见 HostedContentView。
    /// Mac 窄窗口里网页外面全是 SwiftUI 自己的视图，没有能拦的一层。
    func webViewUnderPointer() -> Bool {
        guard let window, let root = window.contentView?.superview else { return false }
        var view = root.hitTest(window.mouseLocationOutsideOfEventStream)
        while let current = view, current !== self {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}
#endif

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

/// 互联网上的一个网址，给浏览的网页画面用：页面从开起时的网址开，之后换网址在同一个页面里跳过去，前进后退接得上；
/// 换了 id 重建时从那时的网址开起。store、roaming 同 PortPreview。
struct AddressPreview: View {
    let url: URL
    let store: UUID
    var roaming: WebRoaming?
    let browser: WebBrowser
    var report: (String?) -> Void = { _ in }
    @State private var start: URL

    init(url: URL, store: UUID, roaming: WebRoaming?, browser: WebBrowser, report: @escaping (String?) -> Void = { _ in }) {
        self.url = url
        self.store = store
        self.roaming = roaming
        self.browser = browser
        self.report = report
        _start = State(initialValue: url)
    }

    var body: some View {
        WebPreview(source: .address(start, store: store, roaming: roaming), report: report, browser: browser)
            .onChange(of: url) { _, url in browser.open(url) }
    }
}

/// 工作机上某个端口的网页，给浏览和预览的网页画面用。本机就是工作机时直接访问 localhost；其他设备在本机回环上开转发
/// （PortRelays），经组网连到工作机为这个端口开的转发。本工作区其他运行中终端与预览的端口也开着同号转发（见 PortForwarding），页面里嵌着或调用的
/// 另一个端口上的服务照工作机上的地址打开。store 是这个目标在本设备的网站数据，roaming 见 WebSource.address。
struct PortPreview: View {
    let client: KitedClient
    let port: Int
    let store: UUID
    var roaming: WebRoaming?
    /// 消息里点的链接或地址栏里输入的路径：在页面里打开到它，每次都打开一回；没有时是首页。
    var link: WebLink?
    /// 其他设备上页面的地址是本机转发的地址，端口不是工作机上的端口，只看路径。
    let browser: WebBrowser
    var report: (String?) -> Void = { _ in }
    /// 网站根地址：本机的 localhost，或本机转发的地址。
    @State private var url: URL?
    /// 第一次打开到哪里：带上转发好时的链接路径；之后的链接在同一个页面里打开，前进后退接得上。
    @State private var start: URL?

    var body: some View {
        Group {
            if let start {
                WebPreview(source: .address(start, store: store, roaming: roaming), report: report, browser: browser)
            } else { Color.clear }
        }
        .onChange(of: link) { _, link in
            guard let url, let link, let target = URL(string: url.absoluteString + link.target.path) else { return }
            browser.open(target)
        }
        .task(id: "\(client.identity) \(port)") {
            url = nil
            start = nil
            guard client.servable(port) else {
                report("这是工作机服务自己的端口，不能预览")
                return
            }
            if client.isLocal { show(URL(string: "http://localhost:\(port)")); return }
            guard let host = client.workerHost, let target = UInt16(exactly: port) else {
                report("工作机地址或端口无效")
                return
            }
            // 视图在就一直转发，离开或换了目标时（任务取消）放开
            do {
                try await PortRelays.shared.hold(host: host, port: target) { relay in
                    // 首页开在 IPv4 回环上：写 localhost 时 WebKit 先连 ::1，同号端口在 ::1 上被本机别的服务占着时会打开错的页面。
                    show(URL(string: "http://127.0.0.1:\(relay.port)"))
                }
            } catch {
                report("本机转发没有打开：\(error.localizedDescription)")
            }
        }
    }

    private func show(_ root: URL?) {
        guard let root else { return }
        url = root
        start = URL(string: root.absoluteString + (link?.target.path ?? "")) ?? root
    }
}

/// 设备打开着工作区期间（主窗口里的那个和分离出去的），为本工作区运行中终端与预览监听的端口在本机回环上开同号转发
/// （docs/成果查看与位置.md「运行中的网页」），不要求开着任何窗口：Mac 上直接用自己的浏览器打开 localhost:端口就行。
/// 本机就是工作机时不用转发；kited 自己的端口不开（见 PortPreview.servable）。
struct PortForwarding: ViewModifier {
    @Environment(AppModel.self) private var model

    private struct Target: Hashable {
        let host: String
        let ports: [UInt16]
    }

    private var targets: [Target] {
        let shown = [model.current].compactMap(\.self) + model.workspaces.filter { model.detached.contains($0.id) }
        return shown.compactMap { area in
            guard let client = area.pluginClient, !client.isLocal, let host = client.workerHost else { return nil }
            let ports = area.workspacePorts.filter(client.servable).compactMap { UInt16(exactly: $0) }
            return ports.isEmpty ? nil : Target(host: host, ports: ports)
        }
    }

    func body(content: Content) -> some View {
        content.task(id: targets) {
            let targets = targets
            await withDiscardingTaskGroup { group in
                for target in targets { group.addTask { await PortRelays.shared.hold(host: target.host, ports: target.ports) } }
            }
        }
    }
}

extension KitedClient {
    /// 工作机在组网上的主机名，本机转发连向它。
    var workerHost: String? { URL(string: address)?.host(percentEncoded: false) }
    /// kited 自己的端口在本机和组网上都开着，页面开在它上面就和接口同源，能带上请求头调用接口：不为它开网页视图、不转发。
    func servable(_ port: Int) -> Bool { !servicePorts.contains(port) }
    /// 浏览里的网页不能进的地址：kited 在本机地址和工作机主机名上的端口。
    var roaming: WebRoaming {
        let hosts = LocalPort.hosts.union([workerHost?.lowercased()].compactMap(\.self))
        return WebRoaming(service: Set(hosts.flatMap { host in servicePorts.map { "\(host):\($0)" } }))
    }
    private var servicePorts: [Int] { [address, KitedClient.local].compactMap { URL(string: $0)?.port } }
}

/// 宽屏卡片里的网页控制区：指针在卡片上、或正在地址栏里打字时才有，同窗口按钮（见 PaneHeaderControls）；触屏一直有。
/// 藏起来时控制区是空的，不接点击，后面的页面照常可点（见 PaneControlsBar）。不在卡片里（紧凑布局）时一直有。
/// 悬停只在这一层读，窗口不跟着重算。
struct WebControls<Content: View>: View {
    let typing: Bool
    @ViewBuilder let content: Content
    @Environment(\.paneHeaderControlsSpace) private var card

    var body: some View {
        if typing || card.map({ InputMode.current.revealsControls(hovered: $0.hovered) }) ?? true {
            content
        }
    }
}

/// 地址栏里的路径（浏览里是整个地址）：平时跟着页面显示当前路径，打字时不被页面的跳转改掉；回车打开，没打开就离开（Mac 上按 Esc 也是）回到当前路径。
/// reset 变了（清除输入）也回到当前路径，接着打字。centered（浏览）时不打字的时候是居中的一行字，太长截掉中间，点了才变成输入框并全选地址。
struct WebPathField: View {
    let path: String
    let typing: FocusState<Bool>.Binding
    var reset = 0
    var prompt = "/"
    var centered = false
    let open: (String) -> Void
    @State private var text = ""
    @State private var selection: TextSelection?
    /// 刚按回车打开：留着输入的路径等页面跳过去，不先退回旧路径。
    @State private var submitted = false

    var body: some View {
        let label = centered && !typing.wrappedValue
        TextField("网页地址", text: $text, selection: $selection, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .font(Theme.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .opacity(label ? 0 : 1)
            .accessibilityHidden(label)
            .overlay {
                if label {
                    Button { typing.wrappedValue = true } label: {
                        // 换了网页，地址同标题一样模糊替换
                        Text(text.isEmpty ? prompt : text)
                            .font(Theme.body)
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(.rect)
                            .id(text)
                            .transition(.blurReplace)
                    }
                    .buttonStyle(.pointingPlain)
                    .animation(.snappy, value: text)
                    .accessibilityLabel("网页地址")
                    .accessibilityValue(text)
                }
            }
            .frame(height: Metrics.paneHeaderButton)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .focused(typing)
            .onSubmit {
                submitted = true
                open(text)
                typing.wrappedValue = false
            }
            #if os(macOS)
            .onExitCommand { typing.wrappedValue = false }
            #endif
            .onChange(of: path, initial: true) {
                if !typing.wrappedValue { text = path }
            }
            .onChange(of: reset) { text = path }
            .onChange(of: typing.wrappedValue) { _, editing in
                if editing {
                    submitted = false
                    if centered { selection = TextSelection(range: text.startIndex..<text.endIndex) }
                } else if !submitted { text = path }
            }
    }
}

/// 预览的网页画面的控制区（设备自己的网页视图）：左边后退、前进，中间地址栏（由窗口给，首页、重新加载这些在它最右边的菜单里，见 WebPageMenu），右边是窗口给的开关（指认）。
/// 窄排（narrowPane）时左边只有后退，有下一页时才出现前进。键盘升起时收起键盘顶替左边这组。
struct WebPageControls<Address: View, Trailing: View>: View {
    let browser: WebBrowser
    @ViewBuilder let address: Address
    @ViewBuilder let trailing: Trailing
    @Environment(\.narrowPane) private var narrow

    var body: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            KeyboardSwap {
                PaneHeaderButtonGroup {
                    ActionButton("后退", icon: "chevron.left", action: browser.back)
                        .disabled(!browser.canGoBack)
                    if !narrow || browser.canGoForward {
                        ActionButton("前进", icon: "chevron.right", action: browser.forward)
                            .disabled(!browser.canGoForward)
                    }
                }
            } shown: {
                KeyboardDismissButton()
            }
            address
            trailing
        }
        .containerValue(\.placesKeyboardButton, true)
    }
}

/// 地址栏最右边的菜单：首页、重新加载；页面在设备自己的网页视图里（给了 browser）时，Mac 上还有开发者工具、在浏览器中打开。浏览和预览的网页画面都用它，和最前面的站点图标对称。
/// 在地址栏里打字、键盘升起时换成清除输入，点了地址回到打字前的样子、接着打字。
struct WebPageMenu: View {
    let browser: WebBrowser?
    let typing: Bool
    let home: () -> Void
    let reload: () -> Void
    let clear: () -> Void

    var body: some View {
        KeyboardSwap(active: typing) {
            Menu {
                MenuButton("首页", systemImage: "house", action: home)
                MenuButton("重新加载", systemImage: "arrow.clockwise", action: reload)
                #if os(macOS)
                // iPhone、iPad 没有自带的检查器，只能接上 Mac 从 Safari 打开（见 WebPreview）。
                if let browser {
                    MenuButton("开发者工具", systemImage: "wrench.and.screwdriver", action: browser.inspect)
                    MenuButton("在浏览器中打开", systemImage: "arrow.up.right.square") { browser.openExternally() }
                        .disabled(browser.url == nil)
                }
                #endif
            } label: {
                PaneHeaderButtonLabel("网页操作", systemImage: "ellipsis")
            }
            .foregroundStyle(Color.primary)
            .help("网页操作")
        } shown: {
            ActionButton("清除输入", icon: "xmark", action: clear)
        }
    }
}

/// 站点图标，没有时是地球。
struct WebSiteIcon: View {
    let icon: Image?

    var body: some View {
        Group {
            if let icon {
                icon.resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: Metrics.paneHeaderLogo, height: Metrics.paneHeaderLogo)
        .accessibilityHidden(true)
    }
}
