import SwiftUI

struct ContentView: View {
    let workspace: Workspace

    var body: some View {
        #if os(macOS)
        // 左边侧边栏，上面是列表，底部是 action 区；右边内容区。都铺在 App 的底色上，四周留内边距。
        // 两者之间的缝拖动调侧边栏宽度，拖到很窄就收起
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SidebarList()
                Spacer(minLength: Metrics.gap)
                ActionArea()
            }
            .padding(.top, Metrics.titleBar - Metrics.padding)
            .padding(.leading, Metrics.sidebarLeading)
            .frame(width: workspace.sidebarCollapsed ? 0 : workspace.sidebarWidth, alignment: .leading)
            .opacity(workspace.sidebarCollapsed ? 0 : 1)
            MouseDragArea(cursor: .columnResize) { point in
                resizeSidebar(to: point.x - Metrics.padding - Metrics.gap / 2)
            }
            .frame(width: Metrics.gap)
            TilesLayer()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { workspace.area = $0 }
            // 侧边栏收起后红绿灯按钮落在内容区左上角，卡片从它下面开始
            .padding(.top, workspace.sidebarCollapsed ? Metrics.titleBar - Metrics.padding : 0)
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

    #if os(macOS)
    private func resizeSidebar(to width: CGFloat) {
        let collapse = width < Metrics.sidebarCollapse
        if collapse != workspace.sidebarCollapsed {
            withAnimation(.snappy) { workspace.sidebarCollapsed = collapse }
        }
        if !collapse {
            workspace.sidebarWidth = min(max(width, Metrics.sidebarMin), Metrics.sidebarMax)
        }
    }
    #endif
}

#Preview {
    ContentView(workspace: Workspace())
}
