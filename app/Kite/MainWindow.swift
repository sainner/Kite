#if os(macOS)
import SwiftUI

/// Mac 主窗口：左边侧边栏，右边内容区显示选中会话的窗口组，都铺在 App 的底色上，四周留内边距。
/// 两者之间的缝拖动调侧边栏宽度，拖到很窄就收成一列图标。
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowChrome) private var chrome
    /// 拖侧边栏边缘时，按下那一刻的宽度。
    @State private var resizingFrom: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            MacSidebar()
                .frame(width: sidebarWidth)
            MouseDragArea(cursor: .columnResize) { drag in
                let from = resizingFrom ?? sidebarWidth
                resizingFrom = from
                resizeSidebar(to: from + drag.translation.width)
            } onEnded: {
                resizingFrom = nil
            }
            .frame(width: Metrics.gap)
            .disablesWindowDragging()
            if let session = model.current {
                SessionContent(session: session)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSize = $0 }
            } else {
                // 会话都分离出去了
                Color.clear
            }
        }
        .padding(Metrics.padding)
        // 窗口不能小到放不下当前会话的卡片
        .frame(minWidth: 2 * Metrics.padding + sidebarWidth + Metrics.gap + minimum.width,
               minHeight: 2 * Metrics.padding + minimum.height)
        .background(Theme.background)
        .ignoresSafeArea()
    }

    /// 侧边栏实际占的宽度。收起时是一列图标，宽到放得下红绿灯按钮。
    private var sidebarWidth: CGFloat {
        model.sidebarCollapsed ? chrome.leading - Metrics.padding : model.sidebarWidth
    }

    private var minimum: CGSize {
        model.current?.workspace.root.minimumSize ?? .zero
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
