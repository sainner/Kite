import SwiftUI
@preconcurrency import SwiftTerm

/// 终端窗口：工作机上一个 PTY 会话，关掉窗口进程照跑。进程树里有能用 HTTP 打开的端口时，标题栏多一个「打开网页」，
/// 打开看这个端口的浏览窗口（见 AppModel.openLocalPort）。进程状态写在副标题，失败在信息区。
/// 预览的输出视图也是它（preview）：同一种 PTY 会话，标题栏换成预览的停止与重新运行。
struct TerminalPane: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    let connection: UUID
    var preview = false
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.colorScheme) private var colorScheme
    /// 会话按窗口建一次；视图重算时传进来的新对象不用，所以里面不在 init 里建 SwiftTerm 视图。
    @State private var session: TerminalSession
    @State private var actionError: String?

    init(instance: RemotePluginInstance, client: KitedClient, connection: UUID, preview: Bool = false) {
        self.instance = instance
        self.client = client
        self.connection = connection
        self.preview = preview
        _session = State(initialValue: TerminalSession(instanceID: instance.id))
    }

    /// 本次连接收到的状态比工作区推送早一步，先用它。
    private var status: TerminalStatus? { session.status ?? instance.state?.terminal }
    private var running: Bool { status?.running ?? true }
    /// 第一个能用 HTTP 打开的端口，「打开网页」打开它。
    private var webPort: Int? { running ? instance.state?.terminal?.ports?.first(where: \.http)?.port : nil }

    /// 停止放在标题栏右边，红色。用户开的终端也能在里面 Ctrl+C、exit；agent 转到后台的命令没有输入，只能靠它。
    private var headerActions: PaneHeaderActions {
        if preview {
            let actions = area.previewActions(instance, model: model) { actionError = $0 }
            return actions.isEmpty ? PaneHeaderActions() : PaneHeaderActions(groups: [actions])
        }
        guard running else { return PaneHeaderActions() }
        var actions: [PaneHeaderAction] = []
        if let webPort {
            actions.append(PaneHeaderAction(title: "打开网页", systemImage: "globe", help: "在浏览窗口里打开 localhost:\(webPort)") { open(webPort) })
        }
        actions.append(PaneHeaderAction(title: "停止终端", systemImage: "stop.fill", tint: Theme.danger) {
            area.stop(instance, model: model) { actionError = $0 }
        })
        return PaneHeaderActions(groups: [actions])
    }

    /// 信息区：失败优先，其次是终端结束了、还在连接。
    private var notice: PaneNotice? {
        if let actionError { return .failure(actionError) }
        if running, case .failed(let message) = session.link { return .failure(message) }
        if let status, !status.running { return .info(status.summary, symbol: "stop.circle") }
        return switch session.link {
        case .waiting, .connecting: .info("正在连接…", symbol: "hourglass")
        case .connected, .failed: nil
        }
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: preview ? "输出" : "终端"), notice: notice, actions: headerActions) {
            TerminalHost(session: session, dark: colorScheme == .dark)
                .padding(.horizontal, Metrics.padding)
        } controls: { _ in
            EmptyView()
        }
        .task(id: connection) { await session.run(client: client) }
    }

    private func open(_ port: Int) {
        actionError = nil
        guard let target = LocalPort(path: "/", port: port) else { return }
        do { try model.openLocalPort(target, in: area) }
        catch { actionError = error.localizedDescription }
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
    }
}
