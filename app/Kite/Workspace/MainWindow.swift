import SwiftUI

/// 宽屏工作台：左侧项目栏、中间卡片、右侧停靠栏。输入方式只改变控件与手势。
struct MainWindow: View {
    var availableWidth: CGFloat = 1272
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.windowChrome) private var chrome
    #endif
    @State private var resizingFrom: CGFloat?
    @State private var stage = DotStage()

    var body: some View {
        GeometryReader { proxy in
            let top = proxy.frame(in: .global).minY
            // 安全区高度不一定是模块的整数倍；只补到窗口网格线，不移动背景点阵的原点。
            content.padding(.top, DotMetrics.snapUp(top) - top)
        }
        .background {
            ZStack {
                Theme.background
                DotCanvas()
            }
            .ignoresSafeArea()
        }
        .environment(\.dotStage, stage)
        #if os(macOS)
        .ignoresSafeArea()
        .resizesByModule()
        #endif
    }

    private var content: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar()
                .frame(width: sidebarWidth)
                .allowsHitTesting(resizingFrom == nil)
            LayoutDragArea(cursor: .columnResize) { drag in
                let from = resizingFrom ?? sidebarWidth
                resizingFrom = from
                resizeSidebar(to: from + drag.translation.width)
            } onEnded: {
                finishResize()
            } onCancelled: {
                finishResize()
            }
            .frame(width: Metrics.sidebarInset)
            .disablesWindowDragging()
            Group {
                if model.sidebarSection != .workspaces {
                    // 工作区以外的栏是单页，自带半透明卡片
                    SectionContent()
                        .padding(.top, Metrics.padding)
                } else if let workspace = model.current {
                    WorkspaceContent(workspace: workspace)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSize = $0 }
                        .padding(.top, Metrics.padding)
                        .allowsHitTesting(resizingFrom == nil)
                } else if model.workspaces.isEmpty {
                    DirectoryStatus().padding(.top, Metrics.padding)
                } else {
                    EmptyStage(scene: .idle, title: "选择一个工作区", details: ["从左侧列表打开一个工作区。"])
                        .padding(.top, Metrics.padding)
                }
            }
            // 侧栏收起后，展开按钮移到内容区第一个窗口的标题栏
            .environment(\.openSidebar, expandSidebar)
        }
        .padding(.leading, Metrics.sidebarInset)
        .padding([.trailing, .bottom], Metrics.padding)
    }

    private var expandSidebar: (@MainActor () -> Void)? {
        guard model.sidebarCollapsed else { return nil }
        return { withAnimation(.snappy) { model.sidebarCollapsed = false } }
    }

    private var sidebarWidth: CGFloat {
        if model.sidebarCollapsed {
            #if os(macOS)
            // 图标栏只放一列圆点，四个模块；标题栏在红绿灯下方，不必让开它的宽度
            return 4 * DotMetrics.module
            #else
            return Metrics.dragBubble
            #endif
        }
        let requested = resizingFrom == nil ? DotMetrics.snap(model.sidebarWidth) : model.sidebarWidth
        let remaining = availableWidth - 2 * Metrics.sidebarInset - Metrics.padding - Metrics.gap - Metrics.dockWidth - Metrics.minPane
        return min(requested, max(Metrics.sidebarMin, remaining))
    }

    private func finishResize() {
        withAnimation(.snappy) {
            resizingFrom = nil
            model.sidebarWidth = DotMetrics.snap(model.sidebarWidth)
        }
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
