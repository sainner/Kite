import SwiftUI

/// 宽屏的台面：各张卡片、空画板、卡片之间的缝和停靠栏按排布算好的位置摆在同一层。卡片始终是同一个视图，
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

/// 宽屏停靠栏：添加入口固定在最上面，然后是代理组、分隔线、工具组，每个实例一格。
/// 有视图的实例由它的卡片自己画在格子上，没有视图的由这里画；脉冲画在卡片上面，见 DockOverlay；家族格各占一层，见 DockUnfold。
struct DockRail: View {
    let geometry: DockGeometry
    var hiddenInstances: Set<String> = []
    /// 点了有视图的实例：同 DockUnfold.showPane。
    var showPane: (Pane) -> Void = { _ in }
    @Environment(WindowLayout.self) private var workspace
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model

    var body: some View {
        let dimmed = !area.dockExpansion.isEmpty
        ZStack(alignment: .topLeading) {
            AddWindowButton()
                .placed(geometry.add)
                .modifier(DockDimmed(dimmed: dimmed))
            ForEach(geometry.cells, id: \.entry.id) { cell in
                if !isPane(cell.entry) && !cell.entry.expands {
                    DockCellButton(entry: cell.entry, depth: 0, hoverFrame: cell.frame, showPane: showPane)
                        .placed(cell.frame)
                        .opacity(hidden(cell.entry) ? 0 : 1)
                        .modifier(DockDimmed(dimmed: dimmed))
                        .transition(.scale(0.6, placedIn: cell.frame).combined(with: .opacity))
                }
            }
            if let divider = geometry.divider {
                DockDivider(x: geometry.add.midX, y: divider)
                    .modifier(DockDimmed(dimmed: dimmed))
            }
            if case .dock = workspace.drag?.spot, let pane = workspace.drag?.pane, let frame = dropFrame(pane) {
                RoundedRectangle(cornerRadius: area.isAgentPane(pane) ? frame.width / 2 : Metrics.dockRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .placed(frame)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.dockOnStage, geometry.onStage)
        .animation(WindowMotionKind.preview.animation, value: geometry.allCells.map(\.entry.id))
        .task(id: model.revision(for: area)) {
            try? await model.ensureRoles(in: area)
        }
    }

    private func isPane(_ entry: DockEntry) -> Bool {
        if case .pane = entry { true } else { false }
    }

    /// 关闭途中、卡片还没落下的那一格。
    private func hidden(_ entry: DockEntry) -> Bool {
        entry.leadInstance.map { hiddenInstances.contains($0.id) } == true
    }

    /// 拖进停靠栏时放下的位置：子代理落在父代理那一格里自己的头像上。
    private func dropFrame(_ pane: Pane) -> CGRect? {
        let instance = area.dockInstanceID(pane)
        return geometry.grouped.contains(instance) ? geometry.face(of: instance) : geometry.paneFrame(pane)
    }
}

/// 代理组和工具组之间的分隔线，(x, y) 是它的中点。
struct DockDivider: View {
    let x: CGFloat
    let y: CGFloat

    var body: some View {
        Rectangle().fill(Theme.rule)
            .frame(width: Metrics.dragBubble * 0.6, height: 1)
            .position(x: x, y: y)
    }
}

/// 画在卡片上面的一层：不在台面上的实例的脉冲，展开时点空白处收起。悬停标签由台面算好往上报（见 StageView.hoverTips）。
struct DockOverlay: View {
    let geometry: DockGeometry
    let bounds: CGRect
    /// 抬到这一层上面的格子，脉冲由它们自己画，见 DockUnfold。
    var lifted: Set<String> = []
    @Environment(WindowLayout.self) private var workspace
    @Environment(WorkArea.self) private var area

    var body: some View {
        let expanded = !area.dockExpansion.isEmpty
        ZStack(alignment: .topLeading) {
            ForEach(geometry.cells, id: \.entry.id) { cell in
                pulse(cell.entry, frame: cell.frame)
                    .opacity(lifted.contains(cell.entry.id) ? 0 : 1)
                    // 和抬起、放下那一格同时换手，不淡入淡出
                    .animation(nil, value: lifted)
                    .modifier(DockDimmed(dimmed: expanded))
                    .allowsHitTesting(false)
            }
            if let root = area.dockExpansion.first, geometry.allCells.contains(where: { $0.entry.id == root }) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { area.collapseDock() }
                    .placed(bounds)
            }
            if expanded {
                // Esc 收起
                Button("收起") { area.collapseDock() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
        }
        // 原生台面拖侧栏改宽时 bounds 左边让出一段（见 StageView.stageRect），格子按台面坐标摆，这一层从台面原点铺到右下角
        .frame(width: bounds.maxX, height: bounds.maxY, alignment: .topLeading)
    }

    @ViewBuilder
    private func pulse(_ entry: DockEntry, frame: CGRect) -> some View {
        switch entry {
        case .pane(let pane) where workspace.drag?.pane != pane:
            DockPulse(instance: area.dockInstanceID(pane)).placed(frame)
        case .family(let family) where family.pane != nil && !family.onStage && workspace.drag?.pane != family.pane:
            // 子代理和描边在卡片下面，见 DockUnfold
            DockPulse(instance: family.parent.id).placed(DockGeometry.parentFrame(in: frame))
        default:
            EmptyView()
        }
    }
}

/// 宽屏停靠栏里能展开的一格（家族格）：收着和展开是同一个 DockGroup，openness 从 0 到 1 逐帧插值，
/// 从格子原地拉长成面板，收起时原路叠回。台面给每个这样的格子单独一层（见 StageView.unfolds）：收着时同停靠栏压在卡片下面，
/// 最小化的父代理由卡片画在胶囊最上面；展开到收回之前这一层抬到卡片和停靠栏上面那一层的上面（lift），父代理的头像连同脉冲
/// 由它自己画、盖住底下的卡片，停靠栏上面那一层不画这一格的脉冲。抬起在已经画出父代理以后，放下在不画以前，底下的卡片不会露出来。
struct DockUnfold: View {
    let geometry: DockGeometry
    let regions: WindowRegions
    let id: String
    let hiddenInstances: Set<String>
    let lift: (Bool) -> Void
    /// 点了家族里开着窗口的代理：宽屏放上台面。
    let showPane: (Pane) -> Void
    @Environment(WorkArea.self) private var area
    @State private var openness: CGFloat = 0
    @State private var lifted = false
    /// 台面排好以后才有的格子先不露，同停靠栏的格子缩放淡入。
    @State private var shown: Bool

    init(geometry: DockGeometry, regions: WindowRegions, id: String, hiddenInstances: Set<String>, appearing: Bool,
         lift: @escaping (Bool) -> Void, showPane: @escaping (Pane) -> Void) {
        self.geometry = geometry
        self.regions = regions
        self.id = id
        self.hiddenInstances = hiddenInstances
        self.lift = lift
        self.showPane = showPane
        _shown = State(initialValue: !appearing)
    }

    var body: some View {
        let expanded = area.dockExpansion.first == id
        ZStack(alignment: .topLeading) {
            if shown, let cell = geometry.allCells.first(where: { $0.entry.id == id }) {
                DockUnfolding(entry: cell.entry, cell: cell.frame, regions: regions, expanded: expanded, openness: openness,
                              drawsParent: expanded || lifted || drawsParent(cell.entry),
                              hoverFrame: geometry.hoverFrame(of: cell.entry, cell: cell.frame), showPane: showPane)
                .transition(.scale(0.6, placedIn: cell.frame).combined(with: .opacity))
            }
        }
        .environment(\.dockOnStage, geometry.onStage)
        .animation(WindowMotionKind.preview.animation, value: geometry.allCells.map(\.entry.id))
        .onAppear {
            guard !shown else { return }
            withAnimation(WindowMotionKind.preview.animation) { shown = true }
        }
        .onChange(of: expanded, initial: true) { _, expanded in
            if expanded {
                // 这一次已经按展开画出了父代理，再抬起来
                if !lifted {
                    lifted = true
                    lift(true)
                }
                withAnimation(.snappy) { openness = 1 }
            } else if lifted {
                withAnimation(.snappy, completionCriteria: .removed) { openness = 0 } completion: {
                    // 收回途中又展开了：留在上面
                    guard openness == 0, lifted else { return }
                    // 先放下，再交还父代理的头像
                    lift(false)
                    lifted = false
                }
            }
        }
    }

    /// 收着时家族格里的父代理：不在台面上时它的卡片画在胶囊最上面（脉冲见 DockOverlay），关掉的新建页正飞回来时也先不画。
    private func drawsParent(_ entry: DockEntry) -> Bool {
        guard case .family(let family) = entry else { return true }
        return !(family.pane != nil && !family.onStage) && !hiddenInstances.contains(family.parent.id)
    }
}

/// 能展开的一格这一刻画在哪：面板（见 DockGeometry.panel）不随进度变，家族格在里面从格子挪到面板上。
/// 面板始终套着滚动区，排不下时才能滚：排得下、排不下是同一个家族格的两种状态，里面再展开一层、子代理多了越过上限时不换视图。
/// 滚动区只借它的手势、惯性和滚动范围，同紧凑布局的底栏：里面是一条和排开一样长的空轨道，家族格钉在可视区里，
/// 按滚了多远自己堆叠（见 DockGroup.viewport）。家族格若跟着滚动内容走，收起时还带着滚过的那一段，落到格子上面。
private struct DockUnfolding: View, Animatable {
    let entry: DockEntry
    let cell: CGRect
    let regions: WindowRegions
    let expanded: Bool
    /// 展开到哪，逐帧走。
    var openness: CGFloat
    let drawsParent: Bool
    let hoverFrame: CGRect
    var showPane: (Pane) -> Void
    @Environment(WorkArea.self) private var area
    @State private var position = ScrollPosition(edge: .top)
    /// 从开头滚了多远。
    @State private var offset: CGFloat = 0

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    var body: some View {
        let panel = DockGeometry.panel(entry, from: cell, path: area.dockExpansion.dropFirst(), regions: regions)
        let frame = panel.frame, scrolls = panel.extent > frame.height
        // 收起时边叠回去边滚回开头：开头滚出去的从上面回到原来的间距再叠起来，不从面板外面飞进来
        let viewport = DockViewport(length: frame.height, offset: offset * min(max(openness, 0), 1))
        ScrollView(.vertical, showsIndicators: false) {
            Color.clear
                .frame(width: frame.width, height: panel.extent)
                .overlay(alignment: .top) {
                    DockGroup(entry: entry, depth: 0, expanded: expanded, openness: openness, mini: cell.width < Metrics.dragBubble,
                              drawsParent: drawsParent, hoverFrame: hoverFrame, viewport: viewport, showPane: showPane)
                        .offset(CGSize(width: (cell.minX - frame.minX) * (1 - openness), height: (cell.minY - frame.minY) * (1 - openness)))
                        // 别的格子展开着：模糊淡出
                        .modifier(DockDimmed(dimmed: !area.dockExpansion.isEmpty && !expanded))
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        // 钉在可视区：滚动挪了多少，反着挪回来
                        .visualEffect { content, proxy in
                            content.offset(y: -proxy.frame(in: .scrollView(axis: .vertical)).minY)
                        }
                }
        }
        .scrollDisabled(!expanded || !scrolls)
        // 钉住的家族格不出可视区，开头滚出去的由它自己渐隐；收着时脉冲伸出格子，不截
        .scrollClipDisabled()
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            withTransaction(Transaction(animation: nil)) { offset = new }
        }
        .placed(frame)
        // 收好了、或排得下不用滚了，回到开头：下次展开从父代理排起
        .onChange(of: openness <= 0 || !scrolls) { _, rewind in
            guard rewind else { return }
            withTransaction(Transaction(animation: nil)) {
                position.scrollTo(edge: .top)
                offset = 0
            }
        }
    }
}

/// 过渡中（见 WindowLayout.transitioning）停靠栏、缝不接点击和悬停。
/// 过渡状态在这一层读：开始、结束过渡只更新这一层，摆卡片的整层不跟着重算。
struct PausedInTransition: ViewModifier {
    let layout: WindowLayout
    /// 拖缝调整大小也算。正拖着的缝自己不算，照常接。
    var whileResizing = true

    func body(content: Content) -> some View {
        content.allowsHitTesting(!(whileResizing ? layout.transitioning : layout.blocksInput))
    }
}

extension View {
    /// 按 rect 定大小和位置，坐标是所在容器的。
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

extension AnyTransition {
    /// placed(rect) 摆的视图进出时以 rect 的中心缩放。placed 的视图铺满整个容器，.scale 的 anchor 按容器算，
    /// 不是按 rect：锚在中心就成了容器中心，格子会从台面中间斜着飞过来。所以以容器原点为锚缩放，再挪回 rect 的中心。
    static func scale(_ scale: CGFloat, placedIn rect: CGRect) -> AnyTransition {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        return .modifier(active: PlacedScale(scale: scale, point: point), identity: PlacedScale(scale: 1, point: point))
    }
}

private struct PlacedScale: ViewModifier {
    let scale: CGFloat
    let point: CGPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: (1 - scale) * point.x, y: (1 - scale) * point.y)
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
