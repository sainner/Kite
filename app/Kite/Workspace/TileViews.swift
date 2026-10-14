import SwiftUI

/// 宽屏的台面：各张卡片、空画板、卡片之间的缝和停靠栏按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成停靠形状、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// Mac 是原生的 StageView，iPad 是原生的 PhoneStageView。
struct TilesLayer: View {
    let group: PaneGroup

    var body: some View {
        #if os(macOS)
        StageHost(group: group)
        #else
        PhoneStageHost(group: group)
        #endif
    }
}

/// 宽屏停靠栏：添加入口固定在最上面，然后是代理组（有子代理的在前）、分隔线、工具组；没有窗口的代理和工具排成小头像，贴着底边。
/// 最小化的窗口由卡片自己画在格子上；脉冲画在卡片上面，见 DockOverlay；家族格里叠在父代理后面的子代理画在这一层。
struct DockRail: View {
    let geometry: DockGeometry
    var hiddenInstances: Set<String> = []
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
                if !isPane(cell.entry) {
                    DockCellButton(entry: cell.entry, depth: 0, hoverFrame: cell.frame)
                        .placed(cell.frame)
                        .opacity(cell.entry.leadInstance.map { hiddenInstances.contains($0.id) } == true ? 0 : 1)
                        .modifier(DockDimmed(dimmed: dimmed))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            ForEach(geometry.minis, id: \.entry.id) { mini in
                // 悬停标签从停靠栏左边浮出，不盖住左列的小头像
                let hover = CGRect(x: geometry.add.minX, y: mini.frame.minY, width: mini.frame.maxX - geometry.add.minX, height: mini.frame.height)
                DockCellButton(entry: mini.entry, depth: 0, mini: true, hoverFrame: hover)
                    .placed(mini.frame)
                    .opacity(mini.entry.leadInstance.map { hiddenInstances.contains($0.id) } == true ? 0 : 1)
                    .modifier(DockDimmed(dimmed: dimmed))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if let divider = geometry.divider {
                DockDivider(x: geometry.add.midX, y: divider)
                    .modifier(DockDimmed(dimmed: dimmed))
            }
            if case .dock = workspace.drag?.spot, let pane = workspace.drag?.pane, let frame = geometry.paneFrame(pane) {
                RoundedRectangle(cornerRadius: area.isAgentPane(pane) ? frame.width / 2 : Metrics.dockRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .placed(frame)
                    .allowsHitTesting(false)
            }
        }
        .animation(WindowMotionKind.preview.animation, value: geometry.allCells.map(\.entry.id))
        .task(id: model.revision(for: area)) {
            try? await model.ensureRoles(in: area)
        }
    }

    private func isPane(_ entry: DockEntry) -> Bool {
        if case .pane = entry { true } else { false }
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

/// 画在卡片上面的一层：最小化窗口的脉冲、悬停标签和展开的面板。
struct DockOverlay: View {
    let geometry: DockGeometry
    let bounds: CGRect
    let regions: WindowRegions
    var showPane: (Pane) -> Void
    @Environment(WindowLayout.self) private var workspace
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model

    var body: some View {
        let expanded = !area.dockExpansion.isEmpty
        ZStack(alignment: .topLeading) {
            ForEach(geometry.cells, id: \.entry.id) { cell in
                pulse(cell.entry, frame: cell.frame)
                    .modifier(DockDimmed(dimmed: expanded))
                    .allowsHitTesting(false)
            }
            if let root = area.dockExpansion.first, let cell = geometry.allCells.first(where: { $0.entry.id == root }) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { area.collapseDock() }
                    .placed(bounds)
                panel(cell.entry, from: cell.frame)
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
        .dockHoverSource(hoverTip)
    }

    private var hoverTip: DockHoverTip? {
        guard workspace.drag == nil, workspace.resizing == nil,
              let hover = area.dockHover, let entry = hoverEntry(hover.id) else { return nil }
        return DockHoverTip(text: area.dockLabel(entry), frame: hover.frame)
    }

    /// 家族格里的父代理是窗口卡片报上来的，按窗口找。
    private func hoverEntry(_ id: String) -> DockEntry? {
        if let entry = DockModel(agents: geometry.allCells.map(\.entry)).entry(id) { return entry }
        guard id.hasPrefix("pane:") else { return nil }
        return .pane(Pane(String(id.dropFirst("pane:".count))))
    }

    @ViewBuilder
    private func pulse(_ entry: DockEntry, frame: CGRect) -> some View {
        switch entry {
        case .pane(let pane) where workspace.drag?.pane != pane:
            DockPulse(instance: area.dockInstanceID(pane)).placed(frame)
        case .family(let family) where family.pane != nil && !family.onStage && workspace.drag?.pane != family.pane:
            // 子代理和描边在卡片下面，见 DockCell
            DockPulse(instance: family.parent.id).placed(DockGeometry.parentFrame(in: frame))
        default:
            EmptyView()
        }
    }

    /// 展开的面板从格子原地拉长：先往下，放不下再往上，最高到停靠栏全高，再多就在里面滚动。小头像展开的面板也居中在停靠栏上。
    private func panel(_ entry: DockEntry, from cell: CGRect) -> some View {
        let path = area.dockExpansion.dropFirst()
        let extent = DockPanel.extent(entry, path: path), breadth = DockPanel.breadth(entry, path: path)
        let height = min(extent, regions.dock.height)
        let top = max(min(cell.minY - DockPanel.padding, regions.dock.maxY - height), regions.dock.minY)
        let frame = CGRect(x: regions.dock.midX - breadth / 2, y: top, width: breadth, height: height)
        let anchor = UnitPoint(x: (cell.midX - frame.minX) / frame.width, y: (cell.midY - frame.minY) / frame.height)
        return ScrollView(.vertical, showsIndicators: false) {
            DockPanel(entry: entry, depth: 0, axis: .vertical, showPane: showPane)
        }
        .scrollDisabled(extent <= height)
        .scrollClipDisabled(extent <= height)
        .placed(frame)
        .transition(.scale(scale: 0.7, anchor: anchor).combined(with: .opacity))
    }
}

/// 台面上没有窗口时的画板。它把场景图形摆到整个 App 的点阵上，点阵不参与过渡（见 WindowLayout.transitioning）：
/// 空台面的画板。缩小最后一个窗口时等它落进停靠栏再出现，不然飞行中整窗点阵逐帧长出图形。过渡状态在这一层读，同 PausedInTransition。
/// 打开窗口时画板的实色底和文字随窗口展开淡出，图形不淡、逐格收回；窗口展开完盖住它以后再移除（2026-10-12 用户确定）。
/// 台面变空、打开窗口的那次更新里卡片还没报上自己在动，这时就当作已经停下，画板会提前出场、提前移除
/// （2026-10-12 用户看到图形先退场、停下后再随画板出场）；所以先不动，等这次更新走完再看还在不在过渡中。
struct SettledWindowlessStage: View {
    let layout: WindowLayout
    let canvas: CGRect
    /// 台面上没有窗口，也没在拖窗口。
    let wanted: Bool
    @State private var mounted = false
    @State private var shown = false

    var body: some View {
        let settled = !layout.transitioning
        // 不要了的那次排布更新里直接变成 false，淡出跟着排布的动画走
        let visible = shown && wanted
        ZStack {
            if mounted {
                WindowlessStage(dock: "右侧停靠栏")
                    .environment(\.stageCardOpacity, visible ? 1 : 0)
                    .modifier(DotsPresence(presented: visible))
                    .allowsHitTesting(visible)
            }
        }
        .placed(canvas)
        .task(id: [wanted, settled]) {
            guard settled else {
                if !wanted { shown = false }
                return
            }
            await Task.yield()
            guard !Task.isCancelled, !layout.transitioning else { return }
            if wanted {
                guard !shown else { return }
                if !mounted {
                    mounted = true
                    // 先按透明摆上去，下一拍再淡入
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                }
                withAnimation(.easeOut(duration: 0.25)) { shown = true }
            } else {
                shown = false
                mounted = false
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
    let expand: (@MainActor () -> Void)?
    if (layout.shown?.panes.count ?? 0) > 1 { expand = { layout.expand(pane) } }
    else { expand = nil }
    return PaneWindowActions(minimize: { layout.minimize(pane) }, expand: expand,
                             close: { model.closeWindow(pane, in: area) },
                             canClose: !area.isDraft && !area.changingWindows && area.creatingWindow != pane.id)
}

/// 卡片标题栏的悬停和几项实际尺寸，由外框、按钮组和正文报上来，只有读它们的几层随之更新。
/// 正文标题栏给窗口按钮让位也按它算（PaneHeaderControlsSpace），悬停一变只有标题栏读它的那一层更新。
@Observable final class PaneCardHeader: PaneHeaderControlsSpace {
    var hovered = false
    /// 正文标题栏右侧菜单的宽度。
    var menuWidth: CGFloat = 0
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
        return controls.shown ? controlsSize.width + Metrics.paneButtonGap : 0
    }

    var minHeight: CGFloat { controlsSize.height }
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

    var shown: Bool {
        !layout.isFixed && !inMenu && InputMode.current.revealsControls(hovered: header.hovered) && !minimized
            && layout.drag == nil && layout.resizing == nil
    }
}

/// 正文标题栏按窗口按钮让位（见 PaneHeaderControlsSpace）、收进菜单；在正文的托管视图里读，卡片不跟着重算。
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

/// 创建实例的菜单，由添加入口弹出。
struct CreateInstanceMenu: View {
    @Binding var presented: Bool
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var error: String?

    private var canAdd: Bool { area.canAddWindows(connected: model.isConnected(area)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("创建实例").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if area.isDraft {
                        Button("创建工作区") { presented = false; model.newWorkspace = .session }
                    } else {
                        ForEach(area.definitions) { definition in
                            Button {
                                model.createInstance(definition, in: area)
                                presented = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(definition.title)
                                        Text(definition.views.isEmpty ? "后台实例" : definition.views.map(\.title).joined(separator: "、"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus")
                                }.padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.pointingPlain)
                        }
                    }
                }.disabled(!canAdd)
            }.frame(maxHeight: 340)
            if area.pendingWindowRequest != nil {
                Button("重试创建") { model.retryOpenWindow(in: area); presented = false }.disabled(area.changingWindows)
            }
            if area.pendingInstanceRequest != nil {
                Button("重试创建") { model.retryCreateInstance(in: area); presented = false }.disabled(area.changingWindows)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
        }
        .padding(16).frame(width: 280)
        .toastHost()
        .presentationCompactAdaptation(.popover)
        .task {
            guard !area.isDraft else { return }
            do { try await model.refreshDefinitions(model.activeClient(in: area)); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

extension WorkArea {
    /// 没有窗口请求在路上、工作区在线且未归档时才能再加窗口。
    func canAddWindows(connected: Bool) -> Bool {
        !changingWindows && pendingWindowRequest == nil && pendingInstanceRequest == nil &&
            (isDraft || (connected && remote?.workspace.status == .open))
    }
}

/// 窗口操作失败时的提示，可以重试。
struct WindowErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    func body(content: Content) -> some View {
        content
            .alert("窗口操作失败", isPresented: Binding(get: { area.windowError != nil }, set: { if !$0 { area.windowError = nil } })) {
                if area.pendingWindowRequest != nil { Button("重试添加") { model.retryOpenWindow(in: area) } }
                if area.pendingInstanceRequest != nil { Button("重试添加") { model.retryCreateInstance(in: area) } }
                Button("好", role: .cancel) { area.windowError = nil }
            } message: { Text(area.windowError ?? "") }
    }
}
