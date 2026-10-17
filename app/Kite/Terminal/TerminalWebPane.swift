import SwiftUI

/// 终端的网页视图：进程树里监听的端口上的网页，和输出视图是同一个终端实例的两种呈现。
/// 所选端口各设备共用，页面里的跳转、滚动与登录状态按设备各自保存（PortPreview 的 store 按实例分开）。端口与选择写在副标题，失败在信息区。
struct TerminalWebPane: View {
    let instance: RemotePluginInstance
    let client: KitedClient
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var failure: String?
    @State private var selectError: String?
    @State private var reload = UUID()

    private var status: TerminalStatus? { instance.state?.terminal }
    private var ports: [TerminalStatus.Port] { status?.ports ?? [] }
    private var port: Int? { status?.running == true ? status?.webPort : nil }

    /// 信息区：失败优先，其次是为什么还没有网页可看。
    private var notice: PaneNotice? {
        if let error = selectError ?? (port == nil ? nil : failure) { return .failure(error) }
        guard let status, status.running else {
            return PaneNotice(text: status?.summary ?? "终端已结束", symbol: "stop.circle", tint: .secondary)
        }
        guard port == nil else { return nil }
        return PaneNotice(text: ports.isEmpty ? "还没有监听的端口" : "没有能用 HTTP 打开的端口", symbol: "info.circle", tint: .secondary)
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: instance.title, subtitle: port.map { "localhost:\($0)" } ?? "网页预览"), notice: notice) {
            if let port, let store = UUID(uuidString: instance.id) {
                PortPreview(client: client, port: port, store: store, report: { failure = $0 })
                    .id("\(port) \(reload)")
            } else {
                Color.clear
            }
        } controls: { _ in
            HStack(spacing: Metrics.paneButtonGap) {
                PaneHeaderButtonGroup {
                    ActionButton("终端输出", icon: "terminal") {
                        model.openWindow(.open(.init(instanceId: instance.id, viewId: "terminal")), in: area)
                    }
                }
                Spacer(minLength: 0)
                // 网页端口一定在监听的端口里，没有端口就没有可选也没有可重新加载的。
                if !ports.isEmpty {
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
                            ActionButton("重新加载", icon: "arrow.clockwise") { failure = nil; reload = UUID() }
                        }
                    }
                }
            }
        }
        .onChange(of: port) { failure = nil }
    }

    private func select(_ value: Int) {
        selectError = nil
        Task {
            do { try await model.selectTerminalPort(value, of: instance.id, in: area) }
            catch { selectError = error.localizedDescription }
        }
    }
}
