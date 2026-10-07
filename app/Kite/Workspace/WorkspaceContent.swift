import SwiftUI

/// 一个工作区的窗口组，放在主窗口的内容区或独立窗口里。
struct WorkspaceContent: View {
    let workspace: WorkArea

    var body: some View {
        Group {
            if !workspace.isDraft, workspace.pluginClient == nil {
                DirectoryStatus(workspace: workspace)
            } else { TilesLayer() }
        }
            .environment(workspace)
            .environment(workspace.layout)
            .focusedSceneValue(workspace.layout)
            .id(workspace.id)
    }
}
