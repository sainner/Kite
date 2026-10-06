import SwiftUI

#if os(macOS)
/// 内容区：各张卡片、占位、卡片之间的缝按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成停靠形状、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// 拖动报的是窗口坐标，在这里换算成内容区里的坐标再交给窗口组。
struct TilesLayer: View {
    @Environment(WindowLayout.self) private var workspace

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let regions = WindowRegions(in: bounds)
            let origin = geo.frame(in: .global).origin
            let local = { (point: CGPoint) in CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
            let layout = workspace.shown?.layout(in: regions.canvas, free: workspace.resizing) ?? TileLayout()
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
                    // 拖缝调整大小时指针会快速扫过卡片，期间卡片不响应悬停和点击
                    .allowsHitTesting(workspace.resizing == nil)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: workspace.panes)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { workspace.availableSize = $0 }
        }
        .disablesWindowDragging()
        .modifier(InstanceSettingsPresentation())
    }
}

/// 最小化窗口和添加入口在上方，无窗口实例在底部；停靠栏沿用工作区底色。
private struct DockRail: View {
    let regions: WindowRegions
    @Environment(WindowLayout.self) private var workspace
    @Environment(WorkArea.self) private var area

    private var dropIndex: Int? {
        if case .dock(let index) = workspace.drag?.spot { index } else { nil }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AddWindowButton()
                .placed(regions.dockFrame(at: workspace.shownDock.count))
            VStack(spacing: Metrics.gap) {
                ForEach(area.windowlessInstances) { instance in
                    InstanceDockButton(instance: instance)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .placed(regions.dock)
            if let index = dropIndex, let pane = workspace.drag?.pane {
                RoundedRectangle(cornerRadius: area.appearance(of: pane).minimizedCornerRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .placed(regions.dockFrame(at: index))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// 一张卡片摆在哪。进入布局拖动后缩成停靠形状跟着指针，松手后展开到落点。
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
        if let (frame, minimized) = place {
            PaneCard(pane: pane, minimized: minimized, onDrag: onDrag, onDrop: onDrop, onActivate: onActivate)
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

/// Mac 上的一张卡片，里面是窗口（PaneWindow）。按住标题栏拖够一段距离后缩成停靠形状，内容淡出，出现图标。
struct PaneCard: View {
    let pane: Pane
    let minimized: Bool
    @Environment(WindowLayout.self) private var workspace
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model
    @State private var cardHovered = false
    @State private var menuWidth: CGFloat = 0
    @State private var controlsSize: CGSize = .zero
    @State private var headerHeight: CGFloat = 0
    @State private var headerInteractiveRects: [CGRect] = []
    private var appearance: WindowAppearance { area.appearance(of: pane) }
    /// 拖动中的指针位置，窗口坐标。
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    var onActivate: () -> Void

    private var actionsShown: Bool { cardHovered && !minimized && workspace.drag == nil && workspace.resizing == nil }
    private var canExpand: Bool { (workspace.root?.panes.count ?? 0) > 1 }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: minimized ? appearance.minimizedCornerRadius : Metrics.cardRadius)
        // 底下的形状定大小，内容放在 overlay 里：缩小时内容比停靠形状大，不能把它撑开
        // 卡片是不透明的面，盖住背景上的点阵
        shape
            .fill(minimized ? appearance.tint : Theme.card)
            .overlay(alignment: .topLeading) {
                PaneBody(pane: pane)
                    .environment(\.paneHeaderControlsInset, actionsShown ? controlsSize.width + Metrics.paneButtonGap : 0)
                    .environment(\.paneHeaderMinHeight, controlsSize.height)
                    // 卡片的形状，里面同心的圆角（控制区输入框）跟着它
                    .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    .opacity(minimized ? 0 : 1)
                    .allowsHitTesting(!minimized)
                    .accessibilityHidden(minimized)
            }
            // 图标画在拖动层下面：盖在 AppKit 视图上的 SwiftUI 内容会挡住点到它的鼠标
            .overlay {
                Image(systemName: appearance.icon)
                    .font(Theme.title)
                    .foregroundStyle(Theme.ink)
                    .opacity(minimized ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                ZStack(alignment: .trailing) {
                    // 展开窗口移动一个标题栏高度后进入布局；按钮所在的位置不接拖动。
                    dragArea

                    if !minimized {
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
            // 在整张卡片上跟踪悬停，指针经过标题栏、正文或控制区时都显示窗口操作。
            .onHover { cardHovered = $0 }
            .onPreferenceChange(PaneHeaderActionsWidth.self) { menuWidth = $0 }
            .onPreferenceChange(PaneHeaderHeight.self) { headerHeight = $0 }
            .onPreferenceChange(PaneHeaderInteractiveRects.self) { headerInteractiveRects = $0 }
            .help(minimized ? "展开\(appearance.name)窗口；拖动可调整位置" : "拖动标题栏调整窗口位置")
            .accessibilityActions {
                if minimized {
                    Button("展开窗口", action: onActivate)
                } else {
                    Button("缩小窗口") { workspace.minimize(pane) }
                    if canExpand { Button("展开窗口") { workspace.expand(pane) } }
                    Button("关闭窗口") { model.closeWindow(pane, in: area) }
                }
            }
    }

    private var dragArea: some View {
        let excluded = minimized ? [] : headerInteractiveRects
        return MouseDragArea(cursor: minimized ? .pointingHand : .openHand, activeCursor: .closedHand,
                      minimumDistance: minimized ? Metrics.dragThreshold : headerHeight, excluded: excluded) { drag in
            onDrag(drag.location)
        } onEnded: {
            onDrop()
        } onClick: {
            if minimized { onActivate() }
        }
        // SwiftUI 的命中也在可点控件上挖空，与 AppKit 视图的 hitTest 一致
        .contentShape(HeaderDragShape(holes: excluded), eoFill: true)
        .contextMenu {
            if let target = area.windows.first(where: { $0.id == pane.id })?.target,
               let instance = area.instances.first(where: { $0.id == target.instanceId }) {
                InstanceActions(instance: instance)
                Button("关闭窗口") { model.closeWindow(pane, in: area) }
            }
        }
        .padding(.trailing, minimized ? 0 : menuWidth + (actionsShown ? controlsSize.width + Metrics.paneButtonGap : 0) + Metrics.paneMargin)
    }

    private var headerActions: some View {
        PaneHeaderButtonGroup {
            headerButton("缩小", icon: "minus") { workspace.minimize(pane) }
            if canExpand {
                headerButton("展开", icon: "arrow.up.left.and.arrow.down.right") { workspace.expand(pane) }
            }
            headerButton("关闭", icon: "xmark") { model.closeWindow(pane, in: area) }
                .disabled(area.isDraft || area.changingWindows)
        }
        // 按系统控件的实际尺寸安排标题栏并避让拖动，避免固定标签尺寸再次撑大按钮。
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controlsSize = $0 }
    }

    private func headerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PaneHeaderButtonLabel(title, systemImage: icon)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 标题栏拖动层的形状：整块减去可点控件，按奇偶规则填充。
nonisolated private struct HeaderDragShape: Shape {
    let holes: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        holes.forEach { path.addRect($0) }
        return path
    }
}

#endif

/// 同一个添加菜单用于 Mac 停靠栏和 iPhone 折叠窗口栏。
struct AddWindowButton: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var presented = false
    @State private var error: String?

    private var canAdd: Bool {
        !area.changingWindows && area.pendingWindowRequest == nil && area.pendingInstanceRequest == nil &&
            (area.isDraft || area.isSample || (model.connected && area.remote?.workspace.status == .open))
    }

    var body: some View {
        @Bindable var area = area
        Button { presented = true } label: {
            Image(systemName: "plus")
                .font(Theme.title)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .overlay { RoundedRectangle(cornerRadius: Metrics.dockRadius).strokeBorder(.secondary.opacity(0.4), lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: Metrics.dockRadius))
        }
        .buttonStyle(.pointingPlain)
        .fixedSize()
        .help("创建实例")
        .accessibilityLabel("添加")
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("创建实例").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if area.isDraft {
                            Button("创建工作区") { presented = false; model.showNewWorkspace = true }
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
                guard !area.isSample, !area.isDraft else { return }
                do { try await model.refreshDefinitions(model.activeClient()); error = nil }
                catch { self.error = error.localizedDescription }
            }
        }
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
        RoundedRectangle(cornerRadius: appearance.minimizedCornerRadius)
            .fill(appearance.tint)
            .overlay {
                Image(systemName: appearance.icon).font(Theme.title).foregroundStyle(Theme.ink)
            }
            .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
    }
}
