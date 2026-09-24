#if os(macOS)
import SwiftUI

/// Mac 主窗口：左边侧边栏，右边内容区显示选中会话的窗口组，都铺在 App 的底色上，四周留内边距。
/// 两者之间的缝拖动调侧边栏宽度，拖到很窄就收成一列图标。
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            MacSidebar()
                .frame(width: model.sidebarCollapsed ? Metrics.rail : model.sidebarWidth)
            MouseDragArea(cursor: .columnResize) { point in
                resizeSidebar(to: point.x - Metrics.padding - Metrics.gap / 2)
            }
            .frame(width: Metrics.gap)
            .disablesWindowDragging()
            if let session = model.current {
                SessionContent(session: session)
            } else {
                // 会话都分离出去了
                Color.clear
            }
        }
        .padding(Metrics.padding)
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.background)
        .ignoresSafeArea()
    }

    private func resizeSidebar(to width: CGFloat) {
        let collapse = width < Metrics.sidebarCollapse
        if collapse != model.sidebarCollapsed {
            withAnimation(.snappy) { model.sidebarCollapsed = collapse }
        }
        if !collapse {
            model.sidebarWidth = min(max(width, Metrics.sidebarMin), Metrics.sidebarMax)
        }
    }
}

#Preview {
    MainWindow().environment(AppModel())
}
#endif
