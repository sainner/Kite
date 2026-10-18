import SwiftUI
@preconcurrency import SwiftTerm

/// 终端窗口：工作机上一个 PTY 会话的一种呈现，关掉窗口进程照跑。进程状态和连接情况写在副标题，失败在信息区。
struct TerminalPane: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.colorScheme) private var colorScheme
    /// 会话按窗口建一次；视图重算时传进来的新对象不用，所以里面不在 init 里建 SwiftTerm 视图。
    @State private var session: TerminalSession
    @State private var stopping = false
    @State private var stopError: String?

    init(instance: RemotePluginInstance, client: KitedClient, connection: UUID) {
        self.instance = instance
        self.client = client
        self.connection = connection
        _session = State(initialValue: TerminalSession(instanceID: instance.id))
    }

    /// 本次连接收到的状态比工作区推送早一步，先用它。
    private var status: TerminalStatus? { session.status ?? instance.state?.terminal }
    private var running: Bool { status?.running ?? true }

    /// 停止放在标题栏右边，红色。用户开的终端也能在里面 Ctrl+C、exit；agent 转到后台的命令没有输入，只能靠它。
    private var headerActions: PaneHeaderActions {
        guard running else { return PaneHeaderActions() }
        return PaneHeaderActions(groups: [[PaneHeaderAction(title: "停止终端", systemImage: "stop.fill", busy: stopping, disabled: stopping,
                                                            tint: Theme.danger, action: stop)]])
    }

    /// 信息区：失败优先，其次是终端结束了、正在连接。
    private var notice: PaneNotice? {
        if let stopError { return .failure(stopError) }
        if case .failed(let message) = session.link, running { return .failure(message) }
        if let status, !status.running { return .info(status.summary, symbol: "stop.circle") }
        return switch session.link {
        case .waiting, .connecting: .info("正在连接…", symbol: "hourglass")
        case .connected, .failed: nil
        }
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: "终端"), notice: notice, actions: headerActions) {
            TerminalHost(session: session, dark: colorScheme == .dark)
                .padding(.horizontal, Metrics.padding)
        } controls: { _ in
            HStack(spacing: Metrics.paneButtonGap) {
                // 进程树里有监听的端口时，从这里打开同一个终端的网页视图
                if running, instance.state?.terminal?.ports?.isEmpty == false {
                    PaneHeaderButtonGroup {
                        ActionButton("打开网页", icon: "globe") {
                            model.openWindow(.open(.init(instanceId: instance.id, viewId: "web")), in: area)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
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
}

#if os(macOS)
private typealias TerminalRepresentable = NSViewRepresentable
#else
private typealias TerminalRepresentable = UIViewRepresentable
#endif

private struct TerminalHost: TerminalRepresentable {
    let session: TerminalSession
    let dark: Bool

    #if os(macOS)
    func makeNSView(context: Context) -> KiteTerminalView { make() }
    func updateNSView(_ view: KiteTerminalView, context: Context) { session.applyColors(dark: dark) }
    #else
    func makeUIView(context: Context) -> KiteTerminalView { make() }
    func updateUIView(_ view: KiteTerminalView, context: Context) { session.applyColors(dark: dark) }
    #endif

    private func make() -> KiteTerminalView {
        let view = session.makeView()
        session.applyColors(dark: dark)
        return view
    }
}
