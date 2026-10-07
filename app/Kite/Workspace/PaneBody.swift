import SwiftUI

/// 每个窗口按目标引用取得自己的线程或插件实例，不共享“当前线程”槽位。
struct PaneBody: View {
    let pane: Pane
    @Environment(WorkArea.self) private var area

    var body: some View {
        let renderer = area.view(in: pane)?.renderer
        Group {
            if let thread = area.thread(in: pane) {
                ThreadPane().environment(thread).id(thread.id)
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
            Color.clear.frame(height: Metrics.paneToolbarHeight)
        }
    }
}

extension EnvironmentValues {
    /// 供当前窗口标题栏进入实例设置；空白工作区没有实例。
    @Entry var paneInstance: RemotePluginInstance?
}
