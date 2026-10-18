import SwiftUI

/// 窗口按所属工作机取得连接提示：工作区窗口属于工作区的工作机，账号窗口属于正在查看的工作机，代理上下文窗口属于当前工作机。
/// 凭据经任一台连着的工作机读写，不属于哪一台，没有连接提示。
struct PaneBody: View {
    let group: PaneGroup
    let pane: Pane
    var retainForExit = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch group {
            case .workspace(let area):
                WorkspacePaneBody(pane: pane, retainForExit: retainForExit).environment(area)
                    .environment(\.paneConnectionNotice, model.connectionNotice(model.connection(for: area)))
            case .accounts:
                ModelAccountPane(pane: pane)
                    .environment(\.paneConnectionNotice, model.connectionNotice(model.accountWorker))
            case .agentContext(let item, _):
                AgentContextPane(item: item, pane: pane)
                    .environment(\.paneConnectionNotice, model.connectionNotice(model.activeConnection))
            case .credentials:
                CredentialPane(pane: pane)
            }
        }
        .environment(\.headerPane, pane)
    }
}

/// 每个工作区窗口按目标引用取得自己的线程或插件实例，不共享“当前线程”槽位。
private struct WorkspacePaneBody: View {
    let pane: Pane
    let retainForExit: Bool
    @State private var retained = PaneExitContent()
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.nativeThreadWindow) private var nativeThreadWindow

    var body: some View {
        if retainForExit {
            retained.content(present: area.windows.contains { $0.id == pane.id }, current: AnyView(resolved))
        } else {
            resolved
        }
    }

    /// 新建窗口原地变成插件窗口时，正文淡过去（见 WorkArea.chooserWindow）。
    @ViewBuilder private var resolved: some View {
        let choosing = pane.id == area.chooserWindow
        Group {
            if choosing { NewWindowChooser().transition(.opacity) }
            else { content.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.2), value: choosing)
    }

    @ViewBuilder private var content: some View {
        let target = area.windows.first(where: { $0.id == pane.id })?.target
        let instance = area.instance(of: pane)
        // 按实例的定义分派，不按窗口当前的视图：窗口在实例的几个视图之间切换，正文由同一个视图接着显示（见 TerminalPane）
        let renderer = instance.flatMap(area.definition(of:))?.defaultRenderer
        // 本机先建、工作机还没建好的实例：正文要读工作机上的实例，先只有标题栏
        let opening = instance.map { area.isOpening(instance: $0.id) } ?? false
        Group {
            if opening {
                PlaceholderPane(appearance: area.appearance(of: pane), kind: WindowAppearance.renderer(renderer ?? "").name, filled: false)
            } else if let thread = area.thread(in: pane) {
                // 不按线程 id 区分身份：草稿发出后同一个会话对象变成真实代理，id 随之改变，窗口内容不能跟着重建。
                // 台面和 iPhone、iPad 的紧凑布局里会话窗口的外框是原生的（ThreadWindowView、PhoneThreadWindowView），
                // 这里只留不占地方的那几样，见 ThreadPaneBridge；Mac 窄窗口是 SwiftUI 的 ThreadPane
                #if os(macOS)
                if let slot = nativeThreadWindow { ThreadPaneBridge(slot: slot).environment(thread) }
                else { ThreadPane().environment(thread) }
                #else
                if let slot = nativeThreadWindow { ThreadPaneBridge(slot: slot).environment(thread) }
                #endif
            } else if let browser = area.files(in: pane), renderer == "files" {
                FilePane(browser: browser).id(pane.id)
            } else if renderer == "monitor", let instance {
                MonitorPane(instance: instance).id(pane.id)
            } else if renderer == "terminal", let target, let instance, let client = area.pluginClient {
                TerminalPane(instance: instance, client: client, connection: area.pluginConnection, view: target.viewId).id(pane.id)
            } else if renderer == "web", let target, let instance, let client = area.pluginClient {
                // 换了视图是另一份插件页面，重新加载
                PluginPane(target: target, title: area.appearance(of: pane).name, client: client,
                           state: instance.state?.plugin, connection: area.pluginConnection)
                    .id("\(pane.id) \(target.viewId)")
            } else {
                PlaceholderPane(appearance: area.appearance(of: pane), kind: WindowAppearance.renderer(renderer ?? "").name)
            }
        }
        .environment(\.paneInstance, opening ? nil : instance)
        .environment(\.paneViewSwitcher, opening ? nil : viewSwitcher(instance, showing: target?.viewId))
        .modifier(ReferenceNavigation())
    }

    /// 实例有几个视图时的切换器：点另一个视图，窗口原地换过去（见 AppModel.openWindow）。
    private func viewSwitcher(_ instance: RemotePluginInstance?, showing current: String?) -> PaneViewSwitcher? {
        guard let instance, let current, let views = area.definition(of: instance)?.views, views.count > 1 else { return nil }
        let items = views.map { PaneViewSwitcher.Item(id: $0.id, title: $0.title, systemImage: WindowAppearance.renderer($0.renderer).icon) }
        return PaneViewSwitcher(items: items, current: current) { view in
            model.openWindow(.open(.init(instanceId: instance.id, viewId: view)), in: area)
        }
    }
}

/// 只延长当前视图的离场寿命，不缓存后续打开的窗口。
private final class PaneExitContent {
    private var last: AnyView?
    func content(present: Bool, current: AnyView) -> AnyView {
        if present || last == nil { last = current }
        return last ?? current
    }
}

/// 插件内容接入之前仍使用原来的窗口占位；filled 为 false 时只有标题栏（实例还没建好）。
private struct PlaceholderPane: View {
    let appearance: WindowAppearance
    let kind: String
    var filled = true

    var body: some View {
        PaneWindow(header: PaneHeader(title: appearance.name, subtitle: kind)) {
            RoundedRectangle(cornerRadius: 8).fill(appearance.tint.opacity(filled ? 0.12 : 0))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        } controls: { _ in
            EmptyView()
        }
    }
}

extension EnvironmentValues {
    /// 供当前窗口标题栏进入实例设置；空白工作区没有实例。
    @Entry var paneInstance: RemotePluginInstance?
    /// 实例几个视图之间的切换器，PaneWindow 放在标题栏右组；只有一个视图时没有。
    @Entry var paneViewSwitcher: PaneViewSwitcher?
}
