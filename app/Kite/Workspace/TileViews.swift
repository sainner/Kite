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
            // 侧栏入口只放在左上角的窗口：先比顶边，再比左边
            let first = layout.panes.min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }?.key
            ZStack(alignment: .topLeading) {
                if let area = group.workspace {
                    DockRail(regions: regions, paneCount: docked.count)
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
                    let dockFrame = docked.firstIndex(of: pane).map { regions.dockFrame(at: $0) }
                    CardSlot(group: group, pane: pane, rect: layout.panes[pane], dockFrame: dockFrame) { point in
                        workspace.drag(pane, to: local(point), in: bounds)
                    } onDrop: {
                        workspace.drop(in: bounds)
                    } onActivate: {
                        workspace.restore(pane, in: bounds)
                    }
                    .environment(\.openSidebar, pane == first ? openSidebar : nil)
                    .zIndex(workspace.drag?.pane == pane ? 1 : 0)
                    // 拖缝调整大小时指针会快速扫过卡片，期间卡片不响应悬停和点击
                    .allowsHitTesting(workspace.resizing == nil)
                    .transition(.scale(scale: 0.92).combined(with: .paneFade))
                }
            }
            .animation(.snappy, value: workspace.panes)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { workspace.updateViewport($0, presentation: .tiled) }
        }
        .environment(workspace)
        .disablesWindowDragging()
    }
}

/// 最小化窗口和添加入口在上方，无窗口实例在底部；停靠栏沿用工作区底色。
private struct DockRail: View {
    let regions: WindowRegions
    let paneCount: Int
    @Environment(WindowLayout.self) private var workspace
    @Environment(WorkArea.self) private var area

    private var dropIndex: Int? {
        if case .dock(let index) = workspace.drag?.spot { index } else { nil }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AddWindowButton()
                .placed(regions.dockFrame(at: paneCount))
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
                     onDrag: onDrag, onDrop: onDrop, onActivate: onActivate)
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

    private var actionsShown: Bool { !workspace.isFixed && !controlsInMenu && InputMode.current.revealsControls(hovered: cardHovered) && !minimized && workspace.drag == nil && workspace.resizing == nil }
    private var canExpand: Bool { (workspace.shown?.panes.count ?? 0) > 1 }

    private var controlsInMenu: Bool {
        #if os(macOS)
        guard !minimized, group.workspace?.thread(in: pane) != nil, menuWidth > 0 else { return false }
        // 按完整控制组计算，不能随悬停显隐改变判断；圆环占一个按钮宽，标题至少保留两个按钮宽。
        let required = 2 * Metrics.paneMargin + menuWidth + controlsSize.width
            + 3 * Metrics.paneButtonGap + 3 * Metrics.paneHeaderButton
        return width < required
        #else
        return false
        #endif
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
        let shape = RoundedRectangle(cornerRadius: minimized ? appearance.minimizedCornerRadius : Metrics.cardRadius)
        // 底下的形状定大小，内容放在 overlay 里：缩小时内容比停靠形状大，不能把它撑开
        // 卡片是不透明的面，盖住背景上的点阵
        shape
            .fill(minimized ? appearance.tint : Theme.card)
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
            .onHover { cardHovered = $0 }
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

/// 宽屏停靠栏与紧凑布局的窗口栏共用添加入口。
struct AddWindowButton: View {
    @Environment(WorkArea.self) private var area
    @State private var presented = false

    var body: some View {
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
        .popover(isPresented: $presented) { CreateInstanceMenu(presented: $presented) }
        .modifier(WindowErrorAlert())
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
        RoundedRectangle(cornerRadius: appearance.minimizedCornerRadius)
            .fill(appearance.tint)
            .overlay {
                Image(systemName: appearance.icon).font(Theme.title).foregroundStyle(Theme.ink)
            }
            .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
    }
}
