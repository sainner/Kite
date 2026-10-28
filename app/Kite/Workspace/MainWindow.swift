import SwiftUI

/// 宽屏工作台：左侧项目栏、中间卡片、右侧停靠栏。输入方式只改变控件与手势。
struct MainWindow: View {
    var availableWidth: CGFloat = 1272
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    /// 侧栏字号的缩放，同 SidebarScaledMetrics：收起的宽是侧栏的图标列，跟着一起缩放。
    @ScaledMetric(relativeTo: .headline) private var sidebarScale: CGFloat = 100
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
                .modifier(SidebarLiveWidth(drag: model.sidebarDrag, width: expandedSidebarWidth,
                                           column: model.sidebarCollapsed ? sidebarColumn : nil, slot: sidebarSlot))
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
        model.sidebarCollapsed ? sidebarColumn + 2 * SidebarMetrics.railMargin : expandedSidebarWidth
    }

    /// 收起的侧栏露出的图标列，两侧另留 railMargin。
    private var sidebarColumn: CGFloat { SidebarMetrics().scaled(by: sidebarScale / 100).column }

    /// 展开时的宽；收起时侧栏仍按它排。
    private var expandedSidebarWidth: CGFloat {
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

/// 侧栏按 width 排，露出整个 width，收着时只露出图标列 column、两侧各多留 railMargin，在排版上占 slot。
/// 收起、展开不改排法，只是右边缘收到图标列、盖住其余部分（见 WorkspaceSidebar），名字不会跟着边缘逐帧重排。iPad 拖侧栏改宽时（SidebarDrag）slot 是最窄的宽，
/// 侧栏按实时的宽画、伸进内容区底下，台面把排窗口的那块让到它右边。实时的宽只在这里读，每步只有侧栏这一棵重算。
private struct SidebarLiveWidth: ViewModifier {
    let drag: SidebarDrag
    let width: CGFloat
    let column: CGFloat?
    let slot: CGFloat

    func body(content: Content) -> some View {
        let width = drag.width ?? width
        let margin = SidebarMetrics.railMargin
        content
            .frame(width: width, alignment: .leading)
            .environment(\.sidebarTuck, column.map { max(width - $0, 0) } ?? 0)
            // 收着时图标列挪到露出部分的正中
            .offset(x: column == nil ? 0 : margin)
            .frame(width: column.map { $0 + 2 * margin } ?? width, alignment: .leading)
            // 裁掉露出的部分以外的；往外留一圈，贴着边的玻璃按钮不被裁
            .padding(Metrics.sidebarInset)
            .clipped()
            .padding(-Metrics.sidebarInset)
            .frame(width: slot, alignment: .leading)
    }
}

#Preview {
    MainWindow().environment(AppModel())
}
