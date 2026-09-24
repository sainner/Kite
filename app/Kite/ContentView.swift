import SwiftUI

struct ContentView: View {
    let workspace: Workspace
    @Namespace private var tiles

    var body: some View {
        #if os(macOS)
        // 左边侧边栏，上面是列表，底部是 action 区；右边内容区。都铺在 App 的底色上，四周留内边距
        HStack(spacing: Metrics.gap) {
            VStack(spacing: 0) {
                SidebarList()
                Spacer(minLength: Metrics.gap)
                ActionArea()
            }
            .padding(.top, Metrics.titleBar - Metrics.padding)
            .padding(.leading, Metrics.sidebarLeading)
            .frame(width: Metrics.sidebarWidth)
            TileView(tile: workspace.root)
                .coordinateSpace(.named(Workspace.space))
                .overlay { DropIndicator() }
                .environment(\.tileNamespace, tiles)
        }
        .environment(workspace)
        .padding(Metrics.padding)
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.background)
        .ignoresSafeArea()
        #else
        PhoneLayout()
        #endif
    }
}

#Preview {
    ContentView(workspace: Workspace())
}
