import SwiftUI
@preconcurrency import SwiftTerm

/// 终端窗口：工作机上一个 PTY 会话，关掉窗口进程照跑。输出与网页是它的两个视图，在同一个窗口里切换（切换按钮由窗口统一加，
/// 见 PaneWindow 的 viewSwitcher）；各自第一次显示时才接上，之后切走只是藏起来、不再绘制：输出的连接不断，网页里的跳转、滚动不丢。
/// 网页是进程树里监听的端口上的页面，所选端口各设备共用，页面里的跳转、滚动与登录状态按设备各自保存（PortPreview 的 store 按实例分开）。
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
    /// 会话按窗口建一次；视图重算时传进来的新对象不用，所以里面不在 init 里建 SwiftTerm 视图。
    @State private var session: TerminalSession
    @State private var stopping = false
    @State private var stopError: String?
    /// 显示过的视图一直留着，切走时只是藏起来。输出没显示过就不排版，连接等排好版才连（见 TerminalSession.run）。
    @State private var outputKept = false
    @State private var webKept = false
    @State private var webFailure: String?
    @State private var selectError: String?
    @State private var reload = UUID()

    init(instance: RemotePluginInstance, client: KitedClient, connection: UUID, view: String) {
        self.instance = instance
        self.client = client
        self.connection = connection
        self.view = view
        _session = State(initialValue: TerminalSession(instanceID: instance.id))
    }

    private var showsWeb: Bool { view == "web" }
    /// 工作区推送的状态。端口与所选端口以它为准：选端口改的是实例状态。
    private var pushed: TerminalStatus? { instance.state?.terminal }
    /// 本次连接收到的状态比工作区推送早一步，先用它。
    private var status: TerminalStatus? { session.status ?? pushed }
    private var running: Bool { status?.running ?? true }
    private var ports: [TerminalStatus.Port] { pushed?.ports ?? [] }
    private var port: Int? { running ? pushed?.webPort : nil }
    /// 消息里点的链接，端口对得上才打开到它的路径（见 AppModel.openLocalPort）。
    private var link: WebLink? { area.webLinks[instance.id].flatMap { $0.target.port == port ? $0 : nil } }

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
                    PortPreview(client: client, port: port, store: store, link: link, report: { webFailure = $0 }, visible: showsWeb)
                        .id("\(port) \(reload)")
                        .shown(showsWeb)
                }
            }
        } controls: { _ in
            // 网页端口一定在监听的端口里，没有端口就没有可选也没有可重新加载的。
            if showsWeb, !ports.isEmpty {
                HStack(spacing: Metrics.paneButtonGap) {
                    Spacer(minLength: 0)
                    PaneHeaderButtonGroup {
                        Menu {
                            ForEach(ports, id: \.port) { item in
                                Button { select(item.port) } label: {
                                    let title = item.http ? "\(item.port)" : "\(item.port)（不是网页）"
                                    if item.port == port { Label(title, systemImage: "checkmark") } else { Text(title) }
                                }
                            }
                        } label: { PaneHeaderButtonLabel(port.map { "端口 \($0)" } ?? "选端口") }
                            .foregroundStyle(Color.primary)
                            .help("选要打开的端口")
                        if port != nil {
                            ActionButton("重新加载", icon: "arrow.clockwise") { webFailure = nil; reload = UUID() }
                        }
                    }
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
