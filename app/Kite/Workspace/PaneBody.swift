import SwiftUI

/// 窗口按所属工作机取得连接提示：工作区窗口属于工作区的工作机，账号窗口属于正在查看的工作机。
struct PaneBody: View {
    let group: PaneGroup
    let pane: Pane
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch group {
            case .workspace(let area):
                WorkspacePaneBody(pane: pane).environment(area)
                    .environment(\.paneConnectionNotice, model.connectionNotice(model.connection(for: area)))
            case .accounts:
                ModelAccountPane(pane: pane)
                    .environment(\.paneConnectionNotice, model.connectionNotice(model.accountWorker))
            }
        }
        .environment(\.headerPane, pane)
    }
}

/// 每个工作区窗口按目标引用取得自己的线程或插件实例，不共享“当前线程”槽位。
private struct WorkspacePaneBody: View {
    let pane: Pane
    @Environment(WorkArea.self) private var area

    var body: some View {
        let renderer = area.view(in: pane)?.renderer
        Group {
            if let thread = area.thread(in: pane) {
                // 不按线程 id 区分身份：草稿发出后同一个会话对象变成真实代理，id 随之改变，窗口内容不能跟着重建
                ThreadPane().environment(thread)
            } else if let browser = area.files(in: pane), renderer == "files" {
                FilePane(browser: browser).id(pane.id)
            } else if renderer == "web", let target = area.windows.first(where: { $0.id == pane.id })?.target,
                      let instance = area.instances.first(where: { $0.id == target.instanceId }),
                      let client = area.pluginClient {
                PluginPane(target: target, title: area.appearance(of: pane).name, client: client,
                           state: instance.state?.plugin, connection: area.pluginConnection)
                    .id(pane.id)
            } else {
                PlaceholderPane(appearance: area.appearance(of: pane), kind: WindowAppearance.renderer(renderer ?? "").name)
            }
        }
        .environment(\.paneInstance, area.windows.first(where: { $0.id == pane.id }).flatMap { window in
            area.instances.first { $0.id == window.target.instanceId }
        })
        .modifier(ReferenceNavigation())
    }
}

/// 插件内容接入之前仍使用原来的窗口占位。
private struct PlaceholderPane: View {
    let appearance: WindowAppearance
    let kind: String

    var body: some View {
        PaneWindow(header: PaneHeader(title: appearance.name, subtitle: kind)) {
            RoundedRectangle(cornerRadius: 8).fill(appearance.tint.opacity(0.12))
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
}
