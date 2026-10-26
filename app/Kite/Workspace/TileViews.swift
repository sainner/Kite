import SwiftUI

/// 宽屏的台面：各张卡片、卡片之间的缝和停靠栏按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成停靠形状、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// Mac 是原生的 StageView，iPad 是原生的 PhoneStageView。
/// 台面的大小、位置不跟 SwiftUI 的动画逐帧变：侧栏收起、展开时它一下子换到终点，窗口由台面按终点排一次、交给 Core Animation 飞过去
/// （见 StageView.layout）。逐帧改的话每一帧台面上的窗口都要改大小，正文跟着重排（2026-10-20 Mac 实测，收起、展开一次 0.8 秒里
/// 主线程约 660 毫秒、掉 30 多帧）。
struct TilesLayer: View {
    let group: PaneGroup

    var body: some View {
        Group {
            #if os(macOS)
            StageHost(group: group)
            #else
            PhoneStageHost(group: group)
            #endif
        }
        .transaction { $0.animation = nil }
    }
}

/// 过渡中（见 WindowLayout.transitioning）停靠栏、缝不接点击和悬停。
/// 过渡状态在这一层读：开始、结束过渡只更新这一层，摆卡片的整层不跟着重算。
struct PausedInTransition: ViewModifier {
    let layout: WindowLayout
    /// 拖缝调整大小也算。正拖着的缝自己不算，照常接。
    var whileResizing = true
    /// 拖动也算。停靠栏不算：从它拖出一格时拖动本身也是过渡，那一格的手势照常走完。
    var whileDragging = true

    func body(content: Content) -> some View {
        let paused = whileResizing ? layout.transitioning : layout.blocksInput
        content.allowsHitTesting(!paused || (!whileDragging && layout.drag != nil))
    }
}

extension View {
    /// 按 rect 定大小和位置，坐标是所在容器的。
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

/// 正文只收内容身份和共享状态；卡片每次改尺寸时，不把包含整张卡片的偏好回调重新交给托管视图。
struct PaneCardBody: View {
    let group: PaneGroup
    let pane: Pane
    let minimized: Bool
    let header: PaneCardHeader
    let headerRegions: HeaderRegions
    let presence: PanePresence
    let motion: WindowMotion
    let reports: PaneCardBodyReports
    /// 标题栏在这里面：标题栏报的几项从这里接。Mac 宽屏的原生会话窗口（ThreadWindowView）的标题栏在它自己的托管视图里，从那边接。
    var reportsHeader = true

    var body: some View {
        PaneBody(group: group, pane: pane, retainForExit: true)
            .coordinateSpace(.named(DotCarrier.space))
            .paneFocus(pane, in: group.layout, enabled: !minimized)
            .modifier(PaneHeaderEnvironment(header: header, group: group, pane: pane))
            .environment(\.panePresence, presence)
            .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .modifier(WhileSettled(motion: motion, shown: !minimized, fades: false))
            .accessibilityHidden(minimized)
            // 托管正文报出的偏好在这里接；点阵两项再由外框转交给 App 背景和 DotsPresence。
            .onPreferenceChange(WindowDotsActive.self) { reports.usesDots = $0 }
            .onPreferenceChange(DotSlots.self) { reports.dotSlots = $0 }
            .modifier(PaneHeaderReports(header: header, regions: headerRegions, motion: motion, enabled: reportsHeader))
    }
}

/// 标题栏报上来的菜单宽、高度和可点控件的范围，交给卡片：拖动区按它们让位、挖空。
struct PaneHeaderReports: ViewModifier {
    let header: PaneCardHeader
    let regions: HeaderRegions
    let motion: WindowMotion
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content
                .onPreferenceChange(PaneHeaderActionsWidth.self) { width in
                    if header.menuWidth != width { header.menuWidth = width }
                }
                .onPreferenceChange(PaneHeaderHeight.self) { height in
                    if header.height != height { header.height = height }
                }
                .onPreferenceChange(PaneHeaderInteractiveRects.self) { rects in
                    regions.rects = rects
                    if !motion.moving { regions.settled = rects }
                }
        } else {
            content
        }
    }
}

@Observable final class PaneCardBodyReports {
    var usesDots = false
    var dotSlots: Set<String> = []
    /// Mac 原生会话窗口外框里铺满窗口的那个托管视图报的（空会话的签名、录音的那一带），见 ThreadWindowView。
    var threadSlots: Set<String> = []
}

@MainActor func paneWindowActions(group: PaneGroup, pane: Pane, model: AppModel) -> PaneWindowActions? {
    guard let area = group.workspace else { return nil }
    let layout = group.layout
    var close: (@MainActor () -> Void)?
    if area.hasClose(pane) { close = { model.close(pane, in: area) } }
    return PaneWindowActions(minimize: { layout.minimize(pane) }, expansion: layout.expansion(of: pane),
                             expand: { layout.expand(pane) }, collapse: { layout.collapse(pane) },
                             close: close, canClose: area.canClose(pane))
}

/// 卡片标题栏的悬停和几项实际尺寸，由外框、按钮组和正文报上来，只有读它们的几层随之更新。
/// 正文标题栏给窗口按钮让位也按它算（PaneHeaderControlsSpace），悬停一变只有标题栏读它的那一层更新。
@Observable final class PaneCardHeader: PaneHeaderControlsSpace {
    var hovered = false
    /// 正文标题栏右侧菜单的宽度。改了宽，右组正在伸缩，见 actionsResizing。
    var menuWidth: CGFloat = 0 {
        didSet { if oldValue > 0, menuWidth != oldValue { resizeActions() } }
    }
    /// 右组正在伸缩（浏览的侧栏开关伸成搜索框）：报上来的已是终点宽度，窗口按钮这时露出来会先跳过去。
    /// 藏到右组按 Animation.paneHeaderActions 伸缩完，同窗口在动时不接悬停；给它们留的地方照留，标题不跟着来回让。
    private(set) var actionsResizing = false
    @ObservationIgnored private var actionsSettle: Task<Void, Never>?
    /// 窗口按钮组（缩小、展开、关闭）的实际尺寸。
    var controlsSize = CGSize.zero
    /// 正文标题栏的实际高度。
    var height: CGFloat = 0
    /// 卡片报来的几项，正文标题栏按它们算让出多少（见 PaneHeaderControlsSpace）。
    var placement = HeaderPlacement()
    @ObservationIgnored weak var layout: WindowLayout?

    var inset: CGFloat {
        guard let layout else { return 0 }
        let controls = PaneHeaderControls(header: self, layout: layout, minimized: placement.minimized, width: placement.width,
                                          hasThread: placement.hasThread)
        return controls.revealed ? controlsSize.width + Metrics.paneButtonGap : 0
    }

    var minHeight: CGFloat { controlsSize.height }

    private func resizeActions() {
        actionsResizing = true
        actionsSettle?.cancel()
        actionsSettle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Animation.paneHeaderActionsDuration))
            guard !Task.isCancelled else { return }
            self?.actionsResizing = false
        }
    }
}

/// 窗口按钮放不放得下、该不该露出来要看的卡片状态。
struct HeaderPlacement: Equatable {
    var minimized = false
    var width: CGFloat = 0
    var hasThread = false
}

/// 窗口按钮放在哪：标题栏上露出来、藏着，还是收进正文的更多菜单。读 PaneCardHeader 的几层各自用它算。
struct PaneHeaderControls {
    let header: PaneCardHeader
    let layout: WindowLayout
    let minimized: Bool
    let width: CGFloat
    let hasThread: Bool

    /// 按完整控制组计算，不能随悬停显隐改变判断；圆环占一个按钮宽，标题至少保留两个按钮宽。
    var inMenu: Bool {
        guard !minimized, hasThread, header.menuWidth > 0 else { return false }
        let required = 2 * Metrics.paneMargin + header.menuWidth + header.controlsSize.width
            + 3 * Metrics.paneButtonGap + 3 * Metrics.paneHeaderButton
        return width < required
    }

    /// 按悬停该露出来；标题栏按它给窗口按钮留地方。右组正在伸缩时先藏着（shown），见 PaneCardHeader.actionsResizing。
    var revealed: Bool {
        !layout.isFixed && !inMenu && InputMode.current.revealsControls(hovered: header.hovered) && !minimized
            && layout.drag == nil && layout.resizing == nil
    }

    var shown: Bool { revealed && !header.actionsResizing }
}

/// 正文标题栏按窗口按钮让位（见 PaneHeaderControlsSpace）、收进菜单；在正文的托管视图里读，卡片不跟着重算。
/// 卡片窄于 narrowPaneWidth 时正文按窄排（narrowTile）；缩在停靠栏里不算，免得缩小时正文跟着换排法。
struct PaneHeaderEnvironment: ViewModifier {
    let header: PaneCardHeader
    let group: PaneGroup
    let pane: Pane
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let placement = header.placement
        let controls = PaneHeaderControls(header: header, layout: group.layout, minimized: placement.minimized,
                                          width: placement.width, hasThread: placement.hasThread)
        content
            .environment(\.paneOverflowActions, controls.inMenu ? paneWindowActions(group: group, pane: pane, model: model) : nil)
            .environment(\.paneHeaderControlsSpace, header)
            .environment(\.narrowTile, !placement.minimized && placement.width > 0 && placement.width < WorkspacePresentation.narrowPaneWidth)
    }
}

/// 命中区域在动画完成时交给原生拖动层，避免标题逐帧补位引起整段正文重算。
@Observable final class HeaderRegions {
    /// 正文最新报上来的。
    @ObservationIgnored var rects: [CGRect] = []
    /// 拖动区挖掉的：停着时跟着 rects，动画中保持动画开始前的，停下再换。
    var settled: [CGRect] = []
}

/// 窗口在动时看不见、不接输入（shown 为 false 时一直这样）。动画开始、结束只更新这一层。
struct WhileSettled: ViewModifier {
    let motion: WindowMotion
    let shown: Bool
    var fades = true

    func body(content: Content) -> some View {
        let active = shown && !motion.moving
        content
            .opacity(fades && !active ? 0 : 1)
            .allowsHitTesting(active)
    }
}

/// 网格固定在屏幕上，静息的网点不随卡片走。窗口在动时整层收起（见 CardView），卡片上的图形也不逐帧跟随。
struct WindowSurfaceDots: View {
    let enabled: Bool

    var body: some View {
        if enabled { DotCanvas() }
    }
}

/// 实例操作失败时的提示，可以重试。
struct WindowErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    func body(content: Content) -> some View {
        content
            .alert("窗口操作失败", isPresented: Binding(get: { area.windowError != nil }, set: { if !$0 { area.windowError = nil } })) {
                if !area.failedInstanceRequests.isEmpty {
                    Button("重试添加") { model.retryRequests(in: area) }
                }
                Button("好", role: .cancel) { area.windowError = nil }
            } message: { Text(area.windowError ?? "") }
    }
}
