import SwiftUI

#if os(macOS)
/// 内容区：各张卡片、占位、卡片之间的缝按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成圆、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// 拖动报的是窗口坐标，在这里换算成内容区里的坐标再交给窗口组。
struct TilesLayer: View {
    @Environment(WindowLayout.self) private var workspace

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let regions = WindowRegions(in: bounds)
            let origin = geo.frame(in: .global).origin
            let local = { (point: CGPoint) in CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
            let layout = workspace.shown?.layout(in: regions.canvas) ?? TileLayout()
            ZStack(alignment: .topLeading) {
                DockRail(regions: regions)
                ForEach(layout.gaps) { gap in
                    MouseDragArea(cursor: gap.split.axis == .horizontal ? .columnResize : .rowResize) { drag in
                        workspace.resize(gap, to: local(drag.location))
                    } onEnded: {
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
                    let dockFrame = workspace.shownDock.firstIndex(of: pane).map { regions.dockFrame(at: $0) }
                    CardSlot(pane: pane, rect: layout.panes[pane], dockFrame: dockFrame) { point in
                        workspace.drag(pane, to: local(point), in: bounds)
                    } onDrop: {
                        workspace.drop(in: bounds)
                    } onActivate: {
                        workspace.restore(pane, in: bounds)
                    }
                    .zIndex(workspace.drag?.pane == pane ? 1 : 0)
                }
            }
        }
        .disablesWindowDragging()
    }
}

/// 停靠栏沿用工作区底色，只放添加入口和拖动落点；圆形窗口仍由原来的 CardSlot 呈现。
private struct DockRail: View {
    let regions: WindowRegions
    @Environment(WindowLayout.self) private var workspace

    private var dropIndex: Int? {
        if case .dock(let index) = workspace.drag?.spot { index } else { nil }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AddWindowButton()
                .placed(regions.dockFrame(at: workspace.shownDock.count))
            if let index = dropIndex {
                Circle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .placed(regions.dockFrame(at: index))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// 一张卡片摆在哪。进入布局拖动后缩成圆跟着指针，松手后展开到落点。
/// 只有它读指针位置，指针一动只重画这一张，不重算整个排布。
private struct CardSlot: View {
    let pane: Pane
    /// 在排布里的位置，不在排布里为 nil。
    let rect: CGRect?
    let dockFrame: CGRect?
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    var onActivate: () -> Void
    @Environment(WindowLayout.self) private var workspace

    var body: some View {
        if let (frame, circle) = place {
            PaneCard(pane: pane, circle: circle, onDrag: onDrag, onDrop: onDrop, onActivate: onActivate)
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

/// Mac 上的一张卡片，里面是窗口（PaneWindow）。按住标题栏拖够一段距离后缩成圆，内容淡出，出现图标。
struct PaneCard: View {
    let pane: Pane
    let circle: Bool
    @Environment(WindowLayout.self) private var workspace
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model
    @State private var headerHovered = false
    private var appearance: WindowAppearance { area.appearance(of: pane) }
    /// 拖动中的指针位置，窗口坐标。
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    var onActivate: () -> Void

    private var actionsShown: Bool { headerHovered && !circle && workspace.drag == nil }
    private var canExpand: Bool { (workspace.root?.panes.count ?? 0) > 1 }
    private var headerActionsWidth: CGFloat {
        let count: CGFloat = canExpand ? 3 : 2
        return count * Metrics.headerAction + (count - 1) * Metrics.headerActionSpacing
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? Metrics.dragBubble / 2 : Metrics.cardRadius)
        // 底下的形状定大小，内容放在 overlay 里：缩成圆时内容比圆大，不能把它撑开
        shape
            .fill(circle ? appearance.tint : Theme.card)
            .overlay(alignment: .topLeading) {
                PaneBody(pane: pane)
                    .environment(\.paneHeaderTrailingInset, actionsShown ? headerActionsWidth + Metrics.gap : 0)
                    // 卡片的形状，里面同心的圆角（控制区卡片）跟着它
                    .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    .opacity(circle ? 0 : 1)
                    .allowsHitTesting(!circle)
                    .accessibilityHidden(circle)
            }
            .overlay(alignment: .top) {
                ZStack(alignment: .trailing) {
                    // 展开窗口移动一个标题栏高度后进入布局；按钮所在的位置不接拖动。
                    dragArea

                    if !circle {
                        headerActions
                            .padding(.trailing, 14)
                            .opacity(actionsShown ? 1 : 0)
                            .allowsHitTesting(actionsShown)
                            .accessibilityHidden(!actionsShown)
                    }
                }
                .frame(height: Metrics.header)
                .contentShape(Rectangle())
                .onHover { headerHovered = $0 }
            }
            .overlay {
                Image(systemName: appearance.icon)
                    .font(Theme.title)
                    .foregroundStyle(.white)
                    .opacity(circle ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .help(circle ? "展开\(appearance.name)窗口；拖动可调整位置" : "拖动标题栏调整窗口位置")
            .accessibilityActions {
                if circle {
                    Button("展开窗口", action: onActivate)
                } else {
                    Button("缩小窗口") { workspace.minimize(pane) }
                    if canExpand { Button("展开窗口") { workspace.expand(pane) } }
                    Button("关闭窗口") { model.closeWindow(pane, in: area) }
                }
            }
    }

    private var dragArea: some View {
        MouseDragArea(cursor: circle ? .pointingHand : .openHand, activeCursor: .closedHand,
                      minimumDistance: circle ? Metrics.dragThreshold : Metrics.header) { drag in
            onDrag(drag.location)
        } onEnded: {
            onDrop()
        } onClick: {
            if circle { onActivate() }
        }
        .padding(.trailing, actionsShown ? headerActionsWidth + 14 : 0)
    }

    private var headerActions: some View {
        HStack(spacing: Metrics.headerActionSpacing) {
            headerButton("缩小", icon: "minus") { workspace.minimize(pane) }
            if canExpand {
                headerButton("展开", icon: "arrow.up.left.and.arrow.down.right") { workspace.expand(pane) }
            }
            headerButton("关闭", icon: "xmark") { model.closeWindow(pane, in: area) }
                .disabled(area.isDraft || area.changingWindows)
        }
    }

    private func headerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.headerAction, height: Metrics.headerAction)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .help(title)
        .accessibilityLabel(title)
    }
}

#endif

/// 同一个添加菜单用于 Mac 停靠栏和 iPhone 折叠窗口栏。
struct AddWindowButton: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    private var canAdd: Bool {
        !area.changingWindows && area.pendingWindowRequest == nil &&
            (area.isDraft || area.isSample || (model.connected && area.remote?.workspace.status == .open))
    }

    var body: some View {
        @Bindable var area = area
        Menu {
            if area.pendingWindowRequest != nil {
                Button("重试添加") { model.retryOpenWindow(in: area) }
                    .disabled(area.changingWindows)
            }
            Group {
                Button("新会话") { model.openWindow(.create("kite.agent.coding"), in: area) }
                Menu("插件窗口") {
                    ForEach(area.definitions.filter { $0.agent == nil }) { definition in
                        Button(definition.title) { model.openWindow(.create(definition.id), in: area) }
                    }
                }
                .disabled(area.isDraft)
                if !area.instances.isEmpty {
                    Menu("打开已有") {
                        ForEach(area.instances.filter { $0.status == .open }) { instance in
                            Menu(instance.title) {
                                ForEach(area.definition(of: instance)?.views ?? []) { view in
                                    Button(view.title) {
                                        model.openWindow(.open(WindowTarget(instanceId: instance.id, viewId: view.id)), in: area)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .disabled(!canAdd)
        } label: {
            Image(systemName: "plus")
                .font(Theme.title)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .clickPointer()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加会话窗口或插件窗口")
        .accessibilityLabel("添加")
        .alert("窗口操作失败", isPresented: Binding(get: { area.windowError != nil }, set: { if !$0 { area.windowError = nil } })) {
            if area.pendingWindowRequest != nil { Button("重试添加") { model.retryOpenWindow(in: area) } }
            Button("好", role: .cancel) { area.windowError = nil }
        } message: { Text(area.windowError ?? "") }
    }
}

/// iPhone 底部的折叠窗口，沿用 Mac 卡片拖动时的圆形、颜色和图标。
struct PaneBubble: View {
    let pane: Pane
    @Environment(WorkArea.self) private var area

    var body: some View {
        let appearance = area.appearance(of: pane)
        Circle()
            .fill(appearance.tint)
            .overlay {
                Image(systemName: appearance.icon).font(Theme.title).foregroundStyle(.white)
            }
            .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
    }
}
