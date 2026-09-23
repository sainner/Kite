import SwiftUI

struct ContentView: View {
    let workspace: Workspace

    var body: some View {
        #if os(macOS)
        // 左边侧边栏，右边内容区，都铺在 App 的底色上，四周留内边距
        HStack(spacing: Metrics.gap) {
            Sidebar()
                .padding(.top, Metrics.titleBar - Metrics.padding)
                .padding(.leading, Metrics.sidebarLeading)
                .frame(width: Metrics.sidebarWidth)
            TileView(tile: workspace.root)
        }
        .padding(Metrics.padding)
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.background)
        .ignoresSafeArea()
        #else
        Text("Kite")
            .padding()
        #endif
    }
}

#Preview {
    ContentView(workspace: Workspace())
}
