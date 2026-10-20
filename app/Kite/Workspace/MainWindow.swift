import SwiftUI

/// 宽屏工作台：左侧项目栏、中间卡片、右侧停靠栏。输入方式只改变控件与手势。
struct MainWindow: View {
    var availableWidth: CGFloat = 1272
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var resizingFrom: CGFloat?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 空白处按住拖窗口、双击缩放
            .windowDragArea()
            .appDotBackground()
            #if os(macOS)
            .ignoresSafeArea()
            #endif
            .dockHoverHost()
    }

    private var content: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar()
                .modifier(SidebarLiveWidth(drag: model.sidebarDrag, width: sidebarWidth, slot: sidebarSlot))
                .allowsHitTesting(resizingFrom == nil)
            LayoutDragArea(cursor: .columnResize) { drag in
                let from = resizingFrom ?? sidebarWidth
                resizingFrom = from
                if !model.sidebarResizing { model.sidebarResizing = true }
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
                    // 设备、资源库和设置页各自负责内容分区与底色。
                    SectionContent()
                        .padding(.top, Metrics.padding)
                } else if let project = model.selectedProject {
                    ProjectSettingsPage(project: project)
                        .id(project.id)
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
            // 右边留的边算在内容区里：PaneFade 的蒙版按内容区裁，台面往右伸进这条边画停靠栏的面板和脉冲（见 StageView.trailingOverflow）
            .padding(.trailing, Metrics.padding)
            // 切换栏目在动画里进行，换页不用默认的 opacity 转场，见 PaneFade
            .transition(.paneFade)
            // 侧栏收起后，展开按钮移到内容区第一个窗口的标题栏
            .environment(\.openSidebar, expandSidebar)
            #if os(macOS)
            // 拖侧栏改宽时原生台面不跟着每步改宽，见 stageInset
            .environment(\.stageLeadingInset, stageInset)
            #endif
        }
        .padding(.leading, Metrics.sidebarInset)
        .padding(.bottom, Metrics.padding)
    }

    /// 拖侧栏改宽时，原生台面按侧栏最窄时的宽度排、往左伸进侧栏底下，被盖住的这一段由台面让出（见 StageHost、StageView.stageRect）：
    /// 台面的视图每步不改尺寸、不挪，只有贴着侧栏的那一列改宽，同拖缝；不然铺满台面的卡片、停靠栏每步都跟着改尺寸重排。
    /// 收起着（拖到收起、展开那一下有动画）照常。只有原生台面读它，别的栏目、独立窗口里不受影响。
    private var stageInset: CGFloat {
        #if os(macOS)
        guard model.sidebarResizing, !model.sidebarCollapsed else { return 0 }
        return max(sidebarWidth - Metrics.sidebarMin, 0)
        #else
        return 0
        #endif
    }

    private var expandSidebar: (@MainActor () -> Void)? {
        guard model.sidebarCollapsed else { return nil }
        return { model.setSidebarCollapsed(false) }
    }

    /// 侧栏在排版上占的宽：平时就是 sidebarWidth；iPad 拖侧栏改宽时只占最窄的宽，内容区（原生台面）往左伸到那里，
    /// 之后每步不用再排，侧栏和台面各自按实时的宽画、让，见 SidebarDrag。
    private var sidebarSlot: CGFloat {
        guard nativeStage, model.sidebarResizing, !model.sidebarCollapsed else { return sidebarWidth }
        return min(Metrics.sidebarMin, sidebarWidth)
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
        let remaining = availableWidth - 2 * Metrics.sidebarInset - Metrics.padding - Metrics.gap - Metrics.dockWidth - Metrics.minPane
        return min(model.sidebarWidth, max(Metrics.sidebarMin, remaining))
    }

    private func finishResize() {
        resizingFrom = nil
        if let width = model.sidebarDrag.end() { model.sidebarWidth = width }
        model.sidebarResizing = false
    }

    /// 内容区是原生台面（工作区的窗口）：iPad 上拖动中侧栏宽不进 SwiftUI，台面自己挪，见 SidebarDrag。
    private var nativeStage: Bool {
        #if os(iOS)
        model.sidebarSection == .workspaces && model.selectedProject == nil && model.current != nil
        #else
        false
        #endif
    }

    private func resizeSidebar(to width: CGFloat) {
        let collapse = width < Metrics.sidebarCollapse
        if collapse != model.sidebarCollapsed {
            // 收起、展开换了排法：先把挪着的宽交回 SwiftUI
            if let width = model.sidebarDrag.end() { model.sidebarWidth = width }
            model.setSidebarCollapsed(collapse)
        }
        guard !collapse else { return }
        // 取到像素：贴着侧栏的那一列跟着侧栏的边走，不落在半像素上
        let width = min(max((width * displayScale).rounded() / displayScale, Metrics.sidebarMin), Metrics.sidebarMax)
        if nativeStage {
            model.sidebarDrag.move(to: min(width, maximumSidebar), from: sidebarWidth, base: sidebarSlot)
        } else {
            model.sidebarWidth = width
        }
    }

    /// 侧栏最宽多少：给内容区至少留一个窗口的最小宽，同 sidebarWidth。
    private var maximumSidebar: CGFloat {
        let remaining = availableWidth - 2 * Metrics.sidebarInset - Metrics.padding - Metrics.gap - Metrics.dockWidth - Metrics.minPane
        return max(Metrics.sidebarMin, remaining)
    }
}

/// 侧栏按 width 画，在排版上占 slot。iPad 拖侧栏改宽时（SidebarDrag）slot 是最窄的宽，侧栏按实时的宽画、伸进内容区底下，
/// 台面把排窗口的那块让到它右边。实时的宽只在这里读，每步只有侧栏这一棵重算。
private struct SidebarLiveWidth: ViewModifier {
    let drag: SidebarDrag
    let width: CGFloat
    let slot: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: drag.width ?? width, alignment: .leading)
            .frame(width: slot, alignment: .leading)
    }
}

#Preview {
    MainWindow().environment(AppModel())
}
