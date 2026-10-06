#if os(macOS)
import SwiftUI

/// Mac 主窗口：左边侧边栏，右边内容区显示选中工作区的窗口组；左右侧栏共用底部内边距。
/// 两者之间的缝拖动调侧边栏宽度，拖到很窄就收成一列图标。
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowChrome) private var chrome
    /// 拖侧边栏边缘时，按下那一刻的宽度。
    @State private var resizingFrom: CGFloat?
    @State private var stage = DotStage()

    var body: some View {
        HStack(spacing: 0) {
            MacSidebar()
                .frame(width: sidebarWidth)
                // 拖动调宽时指针会扫过两边，期间不响应悬停和点击
                .allowsHitTesting(resizingFrom == nil)
            MouseDragArea(cursor: .columnResize) { drag in
                let from = resizingFrom ?? sidebarWidth
                resizingFrom = from
                resizeSidebar(to: from + drag.translation.width)
            } onEnded: {
                // 跟手拖完再吸附到模块
                withAnimation(.snappy) {
                    resizingFrom = nil
                    model.sidebarWidth = DotMetrics.snap(model.sidebarWidth)
                }
            }
            .frame(width: Metrics.gap)
            .disablesWindowDragging()
            if let workspace = model.current {
                WorkspaceContent(workspace: workspace)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSize = $0 }
                    .padding(.top, Metrics.padding)
                    .allowsHitTesting(resizingFrom == nil)
            } else {
                // 已有工作区都分离到了独立窗口。
                Color.clear
            }
        }
        .padding([.horizontal, .bottom], Metrics.padding)
        // 窗口不能小到放不下当前工作区的卡片
        .frame(minWidth: 2 * Metrics.padding + sidebarWidth + Metrics.gap + minimum.width,
               minHeight: 2 * Metrics.padding + minimum.height)
        .background {
            // 点阵铺满窗口背景，卡片盖在上面
            ZStack {
                Theme.background
                DotCanvas()
            }
        }
        .ignoresSafeArea()
        .environment(\.dotStage, stage)
        .resizesByModule()
    }

    /// 侧边栏实际占的宽度，取模块的整数倍。收起时是一列图标，宽到放得下红绿灯按钮；拖动时跟手。
    private var sidebarWidth: CGFloat {
        if model.sidebarCollapsed { return DotMetrics.snapUp(chrome.leading - Metrics.padding) }
        return resizingFrom == nil ? DotMetrics.snap(model.sidebarWidth) : model.sidebarWidth
    }

    private var minimum: CGSize {
        model.current?.minimumSize ?? .zero
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
