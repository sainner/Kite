import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        #if os(macOS)
        // 左边侧边栏，右边内容区显示选中会话的窗口组，都铺在 App 的底色上，四周留内边距。
        // 两者之间的缝拖动调侧边栏宽度，拖到很窄就收成一列图标
        HStack(spacing: 0) {
            MacSidebar()
                .frame(width: model.sidebarCollapsed ? Metrics.rail : model.sidebarWidth)
            MouseDragArea(cursor: .columnResize) { point in
                resizeSidebar(to: point.x - Metrics.padding - Metrics.gap / 2)
            }
            .frame(width: Metrics.gap)
            if let session = model.current {
                SessionContent(session: session)
            } else {
                // 会话都分离出去了
                Color.clear
            }
        }
        .environment(model)
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
        if collapse != model.sidebarCollapsed {
            withAnimation(.snappy) { model.sidebarCollapsed = collapse }
        }
        if !collapse {
            model.sidebarWidth = min(max(width, Metrics.sidebarMin), Metrics.sidebarMax)
        }
    }
    #endif
}

#Preview {
    ContentView(model: AppModel())
}
