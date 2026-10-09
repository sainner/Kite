import SwiftUI

/// 内容区：各张卡片、占位、卡片之间的缝按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成停靠形状、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// 拖动报的是窗口坐标，在这里换算成内容区里的坐标再交给窗口组。
struct TilesLayer: View {
    let group: PaneGroup
    private var workspace: WindowLayout { group.layout }
    @Environment(\.openSidebar) private var openSidebar

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let regions = workspace.regions(in: bounds)
            let origin = geo.frame(in: .global).origin
            let local = { (point: CGPoint) in CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
            let layout = workspace.shown?.layout(in: regions.canvas, free: workspace.resizing) ?? TileLayout()
            let docked = workspace.shownDock
            let area = group.workspace
            let onStage = Set(layout.panes.keys)
            let dock = area.map { DockGeometry(model: $0.dockModel(docked: docked, onStage: onStage), regions: regions) }
            let expanded = !(area?.dockExpansion.isEmpty ?? true)
            // 侧栏入口只放在左上角的窗口：先比顶边，再比左边
            let first = layout.panes.min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }?.key
            ZStack(alignment: .topLeading) {
                if let area, let dock {
                    DockRail(geometry: dock)
                        .environment(area)
                }
                if layout.panes.isEmpty && workspace.drag == nil {
                    WindowlessStage(dock: "右侧停靠栏")
                        .placed(regions.canvas)
                        .transition(.opacity.combined(with: .dotsPresence))
                }
                ForEach(workspace.isFixed ? [] : layout.gaps) { gap in
                    LayoutDragArea(cursor: gap.split.axis == .horizontal ? .columnResize : .rowResize) { drag in
                        workspace.resize(gap, to: local(drag.location))
                    } onEnded: {
                        workspace.finishResize()
                    } onCancelled: {
                        workspace.finishResize()
                    }
                    .placed(gap.rect)
                }
                if let rect = layout.placeholder {
                    // 拖动卡片时预览它放下后的位置
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .fill(Color.accentColor.opacity(0.08))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .placed(rect)
                }
                ForEach(workspace.panes, id: \.self) { pane in
                    let dockFrame = dock?.paneFrame(pane) ?? docked.firstIndex(of: pane).map { regions.dockFrame(at: $0) }
                    let family = dock.flatMap { familyID(of: pane, in: $0) }
                    CardSlot(group: group, pane: pane, rect: layout.panes[pane], dockFrame: dockFrame) { point in
                        area?.collapseDock()
                        workspace.drag(pane, to: local(point), in: bounds) { remaining, location in
                            dockIndex(of: pane, among: remaining, at: location, onStage: onStage, regions: regions)
                        }
                    } onDrop: {
                        workspace.drop(in: bounds)
                    } onActivate: {
                        // 家族格里的父代理：点开看子代理，展开后再点父代理才放上台面
                        if let family { area?.toggleDock(family, depth: 0) }
                        else { workspace.restore(pane, in: bounds) }
                    }
                    .environment(\.openSidebar, pane == first ? openSidebar : nil)
                    .modifier(DockDimmed(dimmed: expanded && layout.panes[pane] == nil && workspace.drag?.pane != pane))
                    .zIndex(workspace.drag?.pane == pane ? 1 : 0)
                    // 拖缝调整大小时指针会快速扫过卡片，期间卡片不响应悬停和点击
                    .allowsHitTesting(workspace.resizing == nil)
                    .transition(closing(pane, from: layout.panes[pane] ?? dockFrame, regions: regions))
                }
                if let area, let dock {
                    DockOverlay(geometry: dock, bounds: bounds, regions: regions) { pane in
                        if layout.panes[pane] != nil { workspace.focus(pane) }
                        else { workspace.restore(pane, in: bounds) }
                    }
                    .environment(area)
                    .zIndex(2)
                }
            }
            .coordinateSpace(.named(DockSpace.name))
            .animation(.snappy, value: workspace.panes)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { workspace.updateViewport($0, presentation: .tiled) }
            .onChange(of: Set(onStage.compactMap { area?.dockInstanceID($0) }), initial: true) { _, visible in
                area?.noteVisible(visible)
            }
            .onDisappear { area?.noteVisible([]) }
        }
        .environment(workspace)
        .environment(\.dockCardsDrawPanes, true)
        .disablesWindowDragging()
    }

    /// 最小化的父代理所在的家族格。
    private func familyID(of pane: Pane, in dock: DockGeometry) -> String? {
        for (entry, _) in dock.cells {
            if case .family(let family) = entry, family.pane == pane, !family.onStage { return entry.id }
        }
        return nil
    }

    /// 拖进停靠栏时，窗口只能落在自己那一类里：插在同类第 j 个之前就占这一类的第 j 格，取画出来离指针最近的那一格。
    private func dockIndex(of pane: Pane, among remaining: [Pane], at location: CGPoint, onStage: Set<Pane>, regions: WindowRegions) -> Int {
        guard let area = group.workspace else { return regions.dockIndex(at: location, count: remaining.count) }
        // 放在最后排一次停靠栏：同类的窗口按停靠的顺序连成一段，它在这一段的末尾，各格大小相同
        let cells = DockGeometry(model: area.dockModel(docked: remaining + [pane], onStage: onStage.subtracting([pane])), regions: regions).cells
        func docked(_ entry: DockEntry) -> (pane: Pane, family: Bool)? {
            switch entry {
            case .pane(let value): (value, false)
            case .family(let family) where !family.onStage: family.pane.map { ($0, true) }
            default: nil
            }
        }
        guard let last = cells.lastIndex(where: { docked($0.entry)?.pane == pane }), let kind = docked(cells[last].entry) else {
            return remaining.count
        }
        let agent = area.isAgentPane(pane)
        var first = last
        while first > cells.startIndex, let other = docked(cells[first - 1].entry), other.family == kind.family,
              area.isAgentPane(other.pane) == agent {
            first -= 1
        }
        // 家族格里的父代理缩在左下角
        func frame(_ cell: Int) -> CGRect { kind.family ? DockGeometry.parentFrame(in: cells[cell].frame) : cells[cell].frame }
        let best = (first...last).min { abs(frame($0).midY - location.y) < abs(frame($1).midY - location.y) } ?? last
        // 紧跟在前一个同类窗口后面
        guard best > first else { return 0 }
        guard let previous = docked(cells[best - 1].entry), let index = remaining.firstIndex(of: previous.pane) else { return remaining.count }
        return index + 1
    }

    /// 关掉独立存续的代理：卡片缩进它要去的那一格（文件夹或父代理的家族格）；随窗口回收的实例原地淡出。
    private func closing(_ pane: Pane, from source: CGRect?, regions: WindowRegions) -> AnyTransition {
        let fade = AnyTransition.scale(scale: 0.92).combined(with: .paneFade)
        guard let area = group.workspace, let source, let instance = area.instance(of: pane), area.isAgent(instance),
              area.definition(of: instance)?.lifetime == .persistent else { return fade }
        return .asymmetric(insertion: fade, removal: AnyTransition(DockLanding(area: area, layout: workspace, pane: pane, instance: instance.id,
                                                                               source: source, regions: regions)))
    }
}

/// 卡片缩进停靠栏里要去的那一格。去哪一格要把停靠栏整个排一遍，只在真正离场时算，台面平时刷新不算。
private struct DockLanding: Transition {
    let area: WorkArea
    let layout: WindowLayout
    let pane: Pane
    let instance: String
    let source: CGRect
    let regions: WindowRegions

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(phase == .didDisappear ? landing() : DockFlight(offset: .zero, scale: 1, opacity: 1))
    }

    private func landing() -> DockFlight {
        let remaining = layout.shownDock.filter { $0 != pane }
        let model = area.dockModel(docked: remaining, onStage: Set(layout.shown?.panes ?? []).subtracting([pane]), closing: instance)
        guard let target = DockGeometry(model: model, regions: regions).frame(containing: instance) else {
            return DockFlight(offset: .zero, scale: 0.92, opacity: 0)
        }
        let scale = min(target.width / max(source.width, 1), target.height / max(source.height, 1))
        return DockFlight(offset: CGSize(width: target.midX - source.midX, height: target.midY - source.midY), scale: scale, opacity: 0)
    }
}

private struct DockFlight: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.scaleEffect(scale).offset(offset).opacity(opacity)
    }
}

/// 宽屏停靠栏：添加入口固定在最上面，然后是代理组（有子代理的在前，没有窗口的收进文件夹）、分隔线、工具组。
/// 最小化的窗口由卡片自己画在格子上；格子上的外圈、角标和家族格装饰画在卡片上面，见 DockOverlay。
private struct DockRail: View {
    let geometry: DockGeometry
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
                        .modifier(DockDimmed(dimmed: dimmed))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            if let divider = geometry.divider {
                Rectangle().fill(Theme.rule)
                    .frame(width: Metrics.dragBubble * 0.6, height: 1)
                    .position(x: geometry.add.midX, y: divider)
                    .modifier(DockDimmed(dimmed: dimmed))
            }
            if case .dock = workspace.drag?.spot, let pane = workspace.drag?.pane, let frame = geometry.paneFrame(pane) {
                RoundedRectangle(cornerRadius: area.isAgentPane(pane) ? frame.width / 2 : Metrics.dockRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .placed(frame)
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: geometry.cells.map(\.entry.id))
        .task(id: model.revision(for: area)) {
            try? await model.ensureRoles(in: area)
        }
    }

    private func isPane(_ entry: DockEntry) -> Bool {
        if case .pane = entry { true } else { false }
    }
}

/// 画在卡片上面的一层：最小化窗口的运行外圈与角标、家族格的描边与角上的子代理、悬停标签和展开的面板。
private struct DockOverlay: View {
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
                marks(cell.entry, frame: cell.frame)
                    .modifier(DockDimmed(dimmed: expanded))
                    .allowsHitTesting(false)
            }
            if let root = area.dockExpansion.first, let cell = geometry.cells.first(where: { $0.entry.id == root }) {
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
            if let hover = area.dockHover, let entry = hoverEntry(hover.id) {
                DockHoverLabel(text: area.dockLabel(entry), frame: hover.frame)
            }
        }
        .animation(.easeOut(duration: 0.12), value: area.dockHover)
    }

    /// 家族格里的父代理是窗口卡片报上来的，按窗口找。
    private func hoverEntry(_ id: String) -> DockEntry? {
        if let entry = DockModel(agents: geometry.cells.map(\.entry)).entry(id) { return entry }
        guard id.hasPrefix("pane:") else { return nil }
        return .pane(Pane(String(id.dropFirst("pane:".count))))
    }

    @ViewBuilder
    private func marks(_ entry: DockEntry, frame: CGRect) -> some View {
        switch entry {
        case .pane(let pane) where workspace.drag?.pane != pane:
            DockStatusMarks(instance: area.dockInstanceID(pane)).placed(frame)
        case .family(let family) where family.pane != nil && !family.onStage && workspace.drag?.pane != family.pane:
            let parent = DockGeometry.parentFrame(in: CGRect(origin: .zero, size: frame.size))
            ZStack(alignment: .topLeading) {
                DockStatusMarks(instance: family.parent.id)
                    .frame(width: parent.width, height: parent.height)
                    .offset(x: parent.minX, y: parent.minY)
                DockFamilyDecoration(family: family, size: frame.width)
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .placed(frame)
        default:
            EmptyView()
        }
    }

    /// 展开的面板从格子原地拉长：先往下，放不下再往上，最高到停靠栏全高，再多就在里面滚动。
    private func panel(_ entry: DockEntry, from cell: CGRect) -> some View {
        let path = area.dockExpansion.dropFirst()
        let extent = DockPanel.extent(entry, path: path), breadth = DockPanel.breadth(entry, path: path)
        let height = min(extent, regions.dock.height)
        let top = max(min(cell.minY - DockPanel.padding, regions.dock.maxY - height), regions.dock.minY)
        let frame = CGRect(x: cell.midX - breadth / 2, y: top, width: breadth, height: height)
        return ScrollView(.vertical, showsIndicators: false) {
            DockPanel(entry: entry, depth: 0, axis: .vertical, showPane: showPane)
        }
        .scrollDisabled(extent <= height)
        .scrollClipDisabled(extent <= height)
        .placed(frame)
        .transition(.scale(scale: 0.7, anchor: .top).combined(with: .opacity))
    }
}

/// 一张卡片摆在哪。进入布局拖动后缩成停靠形状跟着指针，松手后展开到落点。
/// 只有它读指针位置，指针一动只重画这一张，不重算整个排布。
private struct CardSlot: View {
    let group: PaneGroup
    let pane: Pane
    /// 在排布里的位置，不在排布里为 nil。
    let rect: CGRect?
    let dockFrame: CGRect?
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    var onActivate: () -> Void
    @Environment(WindowLayout.self) private var workspace

    var body: some View {
        if let (frame, minimized) = place {
            PaneCard(group: group, pane: pane, minimized: minimized, width: frame.width,
                     onDrag: onDrag, onDrop: onDrop, onActivate: onActivate) { hovering in
                // 家族格里的父代理按整格浮出标签
                group.workspace?.setDockHover(DockEntry.pane(pane).id, frame: dockFrame ?? frame, hovering: hovering && minimized)
            }
            .placed(frame)
        }
    }

    private var place: (CGRect, Bool)? {
        guard let drag = workspace.drag, drag.pane == pane else {
            return rect.map { ($0, false) } ?? dockFrame.map { ($0, true) }
        }
        let size = Metrics.dragBubble
        return (CGRect(x: workspace.pointer.x - size / 2, y: workspace.pointer.y - size / 2, width: size, height: size), true)
    }
}

private extension View {
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

/// 宽屏布局中的一张卡片，里面是窗口（PaneWindow）。按住标题栏拖够一段距离后缩成停靠形状，内容淡出，出现图标。
struct PaneCard: View {
    let group: PaneGroup
    let pane: Pane
    let minimized: Bool
    let width: CGFloat
    @Environment(WindowLayout.self) private var workspace
    @Environment(AppModel.self) private var model
    @State private var cardHovered = false
    @State private var menuWidth: CGFloat = 0
    @State private var controlsSize: CGSize = .zero
    @State private var headerHeight: CGFloat = 0
    @State private var headerInteractiveRects: [CGRect] = []
    private var appearance: WindowAppearance { group.appearance(of: pane) }
    /// 拖动中的指针位置，窗口坐标。
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    var onActivate: () -> Void
    /// 缩成停靠形状时报给停靠栏，用来浮出名字。
    var onHover: (Bool) -> Void = { _ in }

    private var actionsShown: Bool { !workspace.isFixed && !controlsInMenu && InputMode.current.revealsControls(hovered: cardHovered) && !minimized && workspace.drag == nil && workspace.resizing == nil }
    private var canExpand: Bool { (workspace.shown?.panes.count ?? 0) > 1 }

    private var controlsInMenu: Bool {
        guard !minimized, group.workspace?.thread(in: pane) != nil, menuWidth > 0 else { return false }
        // 按完整控制组计算，不能随悬停显隐改变判断；圆环占一个按钮宽，标题至少保留两个按钮宽。
        let required = 2 * Metrics.paneMargin + menuWidth + controlsSize.width
            + 3 * Metrics.paneButtonGap + 3 * Metrics.paneHeaderButton
        return width < required
    }

    private var windowActions: PaneWindowActions? {
        guard let area = group.workspace else { return nil }
        let expand: (@MainActor () -> Void)?
        if canExpand { expand = { workspace.expand(pane) } }
        else { expand = nil }
        return PaneWindowActions(minimize: { workspace.minimize(pane) }, expand: expand,
                                 close: { model.closeWindow(pane, in: area) },
                                 canClose: !area.isDraft && !area.changingWindows)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: minimized ? appearance.minimizedCornerRadius(width: width) : Metrics.cardRadius)
        // 底下的形状定大小，内容放在 overlay 里：缩小时内容比停靠形状大，不能把它撑开
        // 卡片是不透明的面，盖住背景上的点阵；代理缩小后仍是卡片的底色，上面是签名头像，像一扇缩小的空白窗口
        shape
            .fill(minimized && !appearance.isAgent ? appearance.tint : Theme.card)
            .overlay(alignment: .topLeading) {
                PaneBody(group: group, pane: pane)
                    .paneFocus(pane, in: workspace, enabled: !minimized)
                    .environment(\.paneOverflowActions, controlsInMenu ? windowActions : nil)
                    .environment(\.paneHeaderControlsInset, actionsShown ? controlsSize.width + Metrics.paneButtonGap : 0)
                    .environment(\.paneHeaderMinHeight, controlsSize.height)
                    // 卡片的形状，里面同心的圆角（控制区输入框）跟着它
                    .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    .modifier(PaneFade(visible: !minimized))
                    .allowsHitTesting(!minimized)
                    .accessibilityHidden(minimized)
            }
            // 图标画在拖动层下面：盖在 AppKit 视图上的 SwiftUI 内容会挡住点到它的鼠标。
            // 只在缩小后才建，以缩小后的尺寸淡入，台面上的卡片不解析头像、不跟着代理状态重算。
            .overlay {
                if minimized {
                    Group {
                        if appearance.isAgent, let area = group.workspace {
                            let id = area.dockInstanceID(pane)
                            let size = min(width, Metrics.dragBubble)
                            AgentAvatar(design: model.emblem(for: id, in: area), instance: id, animating: area.isRunning(id))
                                .padding(1)
                                .frame(width: size, height: size)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: appearance.icon)
                                .font(Theme.title)
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                ZStack(alignment: .trailing) {
                    // 展开窗口移动一个标题栏高度后进入布局；按钮所在的位置不接拖动。
                    if !workspace.isFixed { dragArea }

                    if !minimized, !workspace.isFixed {
                        headerActions
                            .padding(.trailing, Metrics.paneMargin + (menuWidth > 0 ? menuWidth + Metrics.paneButtonGap : 0))
                            .opacity(actionsShown ? 1 : 0)
                            .allowsHitTesting(actionsShown)
                            .accessibilityHidden(!actionsShown)
                    }
                }
                // 缩成停靠图标时整块都接点击和拖动
                .frame(height: minimized ? nil : headerHeight)
            }
            .clipShape(shape)
            // clipShape 只裁画面不裁命中；标题栏可交互玻璃的命中范围会伸出卡片，盖住旁边停靠栏的按钮。
            .contentShape(shape)
            // 在整张卡片上跟踪悬停，指针经过标题栏、正文或控制区时都显示窗口操作。
            .onHover { cardHovered = $0; onHover($0) }
            .onPreferenceChange(PaneHeaderActionsWidth.self) { menuWidth = $0 }
            .onPreferenceChange(PaneHeaderHeight.self) { headerHeight = $0 }
            .onPreferenceChange(PaneHeaderInteractiveRects.self) { headerInteractiveRects = $0 }
            .accessibilityActions {
                if minimized {
                    Button("展开窗口", action: onActivate)
                } else if let area = group.workspace {
                    Button("缩小窗口") { workspace.minimize(pane) }
                    if canExpand { Button("展开窗口") { workspace.expand(pane) } }
                    Button("关闭窗口") { model.closeWindow(pane, in: area) }
                }
            }
    }

    private var dragArea: some View {
        let excluded = minimized ? [] : headerInteractiveRects
        return LayoutDragArea(cursor: minimized ? .pointingHand : .openHand, activeCursor: .closedHand,
                      minimumDistance: minimized ? Metrics.dragThreshold : headerHeight, excluded: excluded) { drag in
            onDrag(drag.location)
        } onEnded: {
            onDrop()
        } onCancelled: {
            workspace.cancelDrag()
        } onClick: {
            if minimized { onActivate() }
            else { workspace.focus(pane) }
        }
        .contextMenu {
            if let area = group.workspace,
               let target = area.windows.first(where: { $0.id == pane.id })?.target,
               let instance = area.instances.first(where: { $0.id == target.instanceId }) {
                if minimized { Text(area.dockLabel(.pane(pane))) }
                InstanceActions(instance: instance)
                Button("关闭窗口") { model.closeWindow(pane, in: area) }
            }
        }
        .padding(.trailing, minimized ? 0 : menuWidth + (actionsShown ? controlsSize.width + Metrics.paneButtonGap : 0) + Metrics.paneMargin)
    }

    @ViewBuilder
    private var headerActions: some View {
        if let actions = windowActions {
            PaneHeaderButtonGroup {
                headerButton("缩小", icon: "minus", action: actions.minimize)
                if let expand = actions.expand {
                    headerButton("展开", icon: "arrow.up.left.and.arrow.down.right", action: expand)
                }
                headerButton("关闭", icon: "xmark", action: actions.close)
                    .disabled(!actions.canClose)
            }
            // 按系统控件的实际尺寸安排标题栏并避让拖动，避免固定标签尺寸再次撑大按钮。
            .onGeometryChange(for: CGSize.self) { $0.size } action: { controlsSize = $0 }
        }
    }

    private func headerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PaneHeaderButtonLabel(title, systemImage: icon)
        }
        .help(title)
        .accessibilityLabel(title)
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

/// 最小化窗口：agent 用圆形，其余窗口用圆角矩形。
struct PaneBubble: View {
    let appearance: WindowAppearance

    var body: some View {
        RoundedRectangle(cornerRadius: appearance.minimizedCornerRadius())
            .fill(appearance.tint)
            .overlay {
                Image(systemName: appearance.icon).font(Theme.title).foregroundStyle(Theme.ink)
            }
            .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
    }
}
