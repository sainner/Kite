import SwiftUI
@preconcurrency import SwiftTerm

/// 终端窗口：工作机上一个 PTY 会话，关掉窗口进程照跑。输出与网页是它的两个视图，在同一个窗口里切换（切换按钮由窗口统一加，
/// 见 PaneWindow 的 viewSwitcher）；各自第一次显示时才接上，之后切走只是藏起来、不再绘制：输出的连接不断，网页里的跳转、滚动不丢。
/// 网页是进程树里监听的端口上的页面，所选端口各设备共用，页面里的跳转、滚动与登录状态按设备各自保存（PortPreview 的 store 按实例分开）。
/// 网页的控制区：左边后退、前进、首页，中间地址栏（站点图标、localhost:端口/路径），右边重新加载，Mac 上还有开发者工具、在浏览器中打开。端口点了从监听的端口里选，
/// 路径跟着页面显示，改了回车打开；都在同一个页面里跳转（WebBrowser），前进后退接得上。
/// 宽屏卡片里控制区随悬停显隐，同窗口按钮（见 WebControls）。紧凑布局里左边只有后退，有下一页时才出现前进，首页挪到地址栏最右边；
/// 键盘升起时收起键盘顶替左边这组，在地址栏里打字时清除输入顶替重新加载，点了路径回到打字前的样子、接着打字。
/// 进程状态、端口写在副标题，失败在信息区。
struct TerminalPane: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    /// 当前视图，terminal 或 web。
    let view: String
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspacePresentation) private var presentation
    /// 会话按窗口建一次；视图重算时传进来的新对象不用，所以里面不在 init 里建 SwiftTerm 视图。
    @State private var session: TerminalSession
    @State private var browser = WebBrowser()
    @State private var stopping = false
    @State private var stopError: String?
    /// 显示过的视图一直留着，切走时只是藏起来。输出没显示过就不排版，连接等排好版才连（见 TerminalSession.run）。
    @State private var outputKept = false
    @State private var webKept = false
    @State private var webFailure: String?
    @State private var selectError: String?
    @State private var reload = UUID()
    /// 清除输入：每点一次，地址栏的路径回到打字前的样子。
    @State private var pathReset = 0

    init(instance: RemotePluginInstance, client: KitedClient, connection: UUID, view: String) {
        self.instance = instance
        self.client = client
        self.connection = connection
        self.view = view
        _session = State(initialValue: TerminalSession(instanceID: instance.id))
    }

    private var showsWeb: Bool { view == "web" }
    private var compact: Bool { presentation == .compact }
    /// 工作区推送的状态。端口与所选端口以它为准：选端口改的是实例状态。
    private var pushed: TerminalStatus? { instance.state?.terminal }
    /// 本次连接收到的状态比工作区推送早一步，先用它。
    private var status: TerminalStatus? { session.status ?? pushed }
    private var running: Bool { status?.running ?? true }
    private var ports: [TerminalStatus.Port] { pushed?.ports ?? [] }
    private var port: Int? { running ? pushed?.webPort : nil }
    /// 本工作区运行中终端监听的端口：其他设备上网页视图为它们都开转发，页面里连向别的端口也打得开（见 PortPreview）。
    private var workspacePorts: [Int] {
        Set(area.instances.filter { $0.status == .open && $0.state?.terminal?.running == true }
            .flatMap { $0.state?.terminal?.ports ?? [] }.map(\.port)).sorted()
    }
    /// 消息里点的链接，端口对得上才打开到它的路径（见 AppModel.openLocalPort）。
    private var link: WebLink? { area.webLinks[instance.id].flatMap { $0.target.port == port ? $0 : nil } }
    /// 页面当前的路径、查询和锚点，首页是 /。
    private var webPath: String {
        guard let path = browser.url.flatMap(LocalPort.init)?.path, !path.isEmpty else { return "/" }
        return path.removingPercentEncoding ?? path
    }

    /// 停止放在标题栏右边，红色。用户开的终端也能在里面 Ctrl+C、exit；agent 转到后台的命令没有输入，只能靠它。
    private var headerActions: PaneHeaderActions {
        guard running else { return PaneHeaderActions() }
        return PaneHeaderActions(groups: [[PaneHeaderAction(title: "停止终端", systemImage: "stop.fill", busy: stopping, disabled: stopping,
                                                            tint: Theme.danger, action: stop)]])
    }

    /// 信息区：失败优先（网页是选端口、加载失败，输出是连接失败），其次是终端结束了，再按当前视图说明为什么还没有东西可看。
    private var notice: PaneNotice? {
        if let stopError { return .failure(stopError) }
        if showsWeb, let error = selectError ?? (port == nil ? nil : webFailure) { return .failure(error) }
        if !showsWeb, running, case .failed(let message) = session.link { return .failure(message) }
        if let status, !status.running { return .info(status.summary, symbol: "stop.circle") }
        if showsWeb { return port == nil ? .info(ports.isEmpty ? "还没有监听的端口" : "没有能用 HTTP 打开的端口") : nil }
        return switch session.link {
        case .waiting, .connecting: .info("正在连接…", symbol: "hourglass")
        case .connected, .failed: nil
        }
    }

    private var subtitle: String {
        guard showsWeb else { return "终端" }
        return port.map { "localhost:\($0)" } ?? "网页预览"
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: subtitle), notice: notice, actions: headerActions) {
            ZStack {
                if outputKept || !showsWeb {
                    TerminalHost(session: session, dark: colorScheme == .dark, visible: !showsWeb)
                        .padding(.horizontal, Metrics.padding)
                        .shown(!showsWeb)
                }
                if webKept || showsWeb, let port, let store = UUID(uuidString: instance.id) {
                    PortPreview(client: client, port: port, workspacePorts: workspacePorts, store: store, link: link, browser: browser,
                                report: { webFailure = $0 }, visible: showsWeb)
                        .id("\(port) \(reload)")
                        .shown(showsWeb)
                }
            }
        } controls: { typing in
            // 网页端口一定在监听的端口里，没有端口就没有可选也没有可浏览的。
            if showsWeb, !ports.isEmpty {
                WebControls(typing: typing.wrappedValue) {
                    HStack(spacing: Metrics.paneButtonGap) {
                        if let port {
                            KeyboardSwap {
                                PaneHeaderButtonGroup {
                                    ActionButton("后退", icon: "chevron.left", action: browser.back)
                                        .disabled(!browser.canGoBack)
                                    if !compact || browser.canGoForward {
                                        ActionButton("前进", icon: "chevron.right", action: browser.forward)
                                            .disabled(!browser.canGoForward)
                                    }
                                    if !compact {
                                        ActionButton("首页", icon: "house") { open("/", on: port) }
                                    }
                                }
                            } shown: {
                                KeyboardDismissButton()
                            }
                            address(port: port, typing: typing)
                            KeyboardSwap(active: typing.wrappedValue) {
                                PaneHeaderButtonGroup {
                                    ActionButton("重新加载", icon: "arrow.clockwise") {
                                        webFailure = nil
                                        if !browser.reload() { reload = UUID() }
                                    }
                                    #if os(macOS)
                                    // iPhone、iPad 没有自带的检查器，只能接上 Mac 从 Safari 打开（见 WebPreview）。
                                    ActionButton("开发者工具", icon: "wrench.and.screwdriver", action: browser.inspect)
                                    // 只在 Mac 上：其他设备上页面开在本机转发上（PortRelay），转发随这个窗口的网页视图开着；
                                    // iPhone、iPad 切到浏览器后 App 进后台，转发停下，打不开。
                                    // 不走环境里的 openURL：本机地址会被它接回这个网页视图（见 ReferenceNavigation）。
                                    ActionButton("在浏览器中打开", icon: "arrow.up.right.square") {
                                        if let url = browser.url { NSWorkspace.shared.open(url) }
                                    }
                                    .disabled(browser.url == nil)
                                    #endif
                                }
                            } shown: {
                                PaneHeaderButtonGroup {
                                    ActionButton("清除输入", icon: "xmark") { pathReset += 1 }
                                }
                            }
                        } else {
                            Spacer(minLength: 0)
                            address(port: nil, typing: typing)
                            Spacer(minLength: 0)
                        }
                    }
                    // 没选端口时只有地址栏，收起键盘仍在最左边
                    .containerValue(\.placesKeyboardButton, port != nil)
                }
            }
        }
        .onChange(of: view, initial: true) {
            if showsWeb {
                webKept = true
                session.resignFocus()
            } else {
                outputKept = true
            }
        }
        .onChange(of: port) {
            webFailure = nil
            // 换到别的端口（比如自己选的）就从首页看起，回到原来的端口也不再停在之前点的链接上
            if area.webLinks[instance.id]?.target.port != port { area.webLinks[instance.id] = nil }
        }
        .task(id: connection) { await session.run(client: client) }
    }

    /// 地址栏：站点图标、localhost:、端口菜单、路径，端口和路径之间不留空。还没选端口时只有选端口。
    /// 紧凑布局里宽度不够，省掉 localhost:，首页放在地址栏最右边。
    private func address(port: Int?, typing: FocusState<Bool>.Binding) -> some View {
        PaneHeaderButtonGroup(expands: port != nil) {
            HStack(spacing: Metrics.paneHeaderLogoGap) {
                Group {
                    if let icon = browser.icon, port != nil {
                        icon.resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: Metrics.paneHeaderLogo, height: Metrics.paneHeaderLogo)
                .accessibilityHidden(true)
                if !compact {
                    Text("localhost:")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, Metrics.paneHeaderButtonGap / 2)
            Menu {
                ForEach(ports, id: \.port) { item in
                    Button { select(item.port) } label: {
                        let title = item.http ? "\(item.port)" : "\(item.port)（不是网页）"
                        if item.port == port { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            } label: { PaneHeaderButtonLabel(port.map(String.init) ?? "选端口") }
                .foregroundStyle(Color.primary)
                .help("选要打开的端口")
            if let port {
                WebPathField(path: webPath, typing: typing, reset: pathReset) { open($0, on: port) }
                    // 路径框压住端口按钮右边那半个按钮间距，端口的悬停高亮仍按整个按钮画
                    .padding(.leading, -Metrics.paneHeaderButtonGap / 2)
                if compact {
                    ActionButton("首页", icon: "house") { open("/", on: port) }
                }
            }
        }
    }

    private func stop() {
        stopping = true
        stopError = nil
        Task {
            defer { stopping = false }
            do { try await model.stopTerminal(instance.id, in: area) }
            catch { stopError = error.localizedDescription }
        }
    }

    private func select(_ value: Int) {
        selectError = nil
        Task {
            do { try await model.selectTerminalPort(value, of: instance.id, in: area) }
            catch { selectError = error.localizedDescription }
        }
    }

    /// 地址栏里输入的路径、首页，和消息里点的链接一样在页面里打开到它（见 WorkArea.webLinks）。
    private func open(_ path: String, on port: Int) {
        let path = path.trimmingCharacters(in: .whitespaces)
        let rooted = ["/", "?", "#"].contains(where: path.hasPrefix) ? path : "/" + path
        guard let url = URL(string: "http://localhost:\(port)" + rooted), let target = LocalPort(url) else { return }
        webFailure = nil
        area.webLinks[instance.id] = WebLink(target: target)
    }
}

/// 宽屏卡片里的网页控制区：指针在卡片上、或正在地址栏里打字时才有，同窗口按钮（见 PaneHeaderControls）；触屏一直有。
/// 藏起来时控制区是空的，不接点击，后面的页面照常可点（见 PaneControlsBar）。不在卡片里（紧凑布局）时一直有。
/// 悬停只在这一层读，窗口不跟着重算。
private struct WebControls<Content: View>: View {
    let typing: Bool
    @ViewBuilder let content: Content
    @Environment(\.paneHeaderControlsSpace) private var card

    var body: some View {
        if typing || card.map({ InputMode.current.revealsControls(hovered: $0.hovered) }) ?? true {
            content
        }
    }
}

/// 地址栏里的路径：平时跟着页面显示当前路径，打字时不被页面的跳转改掉；回车打开，没打开就离开（Mac 上按 Esc 也是）回到当前路径。
/// reset 变了（清除输入）也回到当前路径，接着打字。
private struct WebPathField: View {
    let path: String
    let typing: FocusState<Bool>.Binding
    let reset: Int
    let open: (String) -> Void
    @State private var text = ""
    /// 刚按回车打开：留着输入的路径等页面跳过去，不先退回旧路径。
    @State private var submitted = false

    var body: some View {
        TextField("网页路径", text: $text, prompt: Text("/"))
            .textFieldStyle(.plain)
            .font(Theme.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
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
                if editing { submitted = false } else if !submitted { text = path }
            }
    }
}

private extension View {
    /// 藏起来的视图留在原处，不显示、不接点击、读屏跳过。
    func shown(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
    }
}

#if os(macOS)
private typealias TerminalRepresentable = NSViewRepresentable
#else
private typealias TerminalRepresentable = UIViewRepresentable
#endif

private struct TerminalHost: TerminalRepresentable {
    let session: TerminalSession
    let dark: Bool
    /// 藏起来时照收输出、不再绘制：透明度为 0 的视图系统照样画。
    let visible: Bool

    #if os(macOS)
    func makeNSView(context: Context) -> KiteTerminalView { make() }
    func updateNSView(_ view: KiteTerminalView, context: Context) { update(view) }
    #else
    func makeUIView(context: Context) -> KiteTerminalView { make() }
    func updateUIView(_ view: KiteTerminalView, context: Context) { update(view) }
    #endif

    private func make() -> KiteTerminalView {
        let view = session.makeView()
        update(view)
        return view
    }

    private func update(_ view: KiteTerminalView) {
        session.applyColors(dark: dark)
        view.isHidden = !visible
    }
}
