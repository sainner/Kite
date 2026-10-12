import SwiftUI

/// 内容区：各张卡片、占位、卡片之间的缝按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成停靠形状、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// 拖动报的是窗口坐标，在这里换算成内容区里的坐标再交给窗口组。
struct TilesLayer: View {
    let group: PaneGroup
    private var workspace: WindowLayout { group.layout }
    @Environment(\.openSidebar) private var openSidebar
    @State private var retained: [Pane] = []
    @State private var paneInstances: [Pane: String] = [:]

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
            let instances = area.map { Dictionary(uniqueKeysWithValues: $0.windows.map { (Pane($0.id), $0.target.instanceId) }) } ?? [:]
            let retiring = Set(retained.filter { !workspace.panes.contains($0) }.compactMap { paneInstances[$0] })
            let opening = area?.openingInstance
            let dock = area.map { DockGeometry(model: $0.dockModel(docked: docked, onStage: onStage, windowless: opening), regions: regions) }
            let expanded = !(area?.dockExpansion.isEmpty ?? true)
            // 侧栏入口只放在左上角的窗口：先比顶边，再比左边
            let first = layout.panes.min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }?.key
            ZStack(alignment: .topLeading) {
                if let area, let dock {
                    DockRail(geometry: dock, hiddenInstances: retiring)
                        .environment(area)
                        .modifier(PausedInTransition(layout: workspace))
                }
                SettledWindowlessStage(layout: workspace, canvas: regions.canvas, wanted: layout.panes.isEmpty && workspace.drag == nil)
                ForEach(workspace.isFixed ? [] : layout.gaps) { gap in
                    LayoutDragArea(cursor: gap.split.axis == .horizontal ? .columnResize : .rowResize) { drag in
                        workspace.resize(gap, to: local(drag.location))
                    } onEnded: {
                        workspace.finishResize()
                    } onCancelled: {
                        workspace.finishResize()
                    }
                    .placed(gap.rect)
                    // 拖缝本身不算在内：正拖着的缝照常接，iPad 上它是 SwiftUI 手势
                    .modifier(PausedInTransition(layout: workspace, whileResizing: false))
                }
                if let rect = layout.placeholder {
                    // 拖动卡片时预览它放下后的位置
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .fill(Color.accentColor.opacity(0.08))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .placed(rect)
                }
                ForEach(retained, id: \.self) { pane in
                    // 正从停靠栏打开的窗口先待在它原来那一格
                    let dockFrame = dock?.paneFrame(pane)
                        ?? opening.flatMap { area?.dockInstanceID(pane) == $0 ? dock?.frame(containing: $0) : nil }
                        ?? docked.firstIndex(of: pane).map { regions.dockFrame(at: $0) }
                    let closing = !workspace.panes.contains(pane)
                    let family = dock.flatMap { familyID(of: pane, in: $0) }
                    CardSlot(group: group, pane: pane, rect: layout.panes[pane], dockFrame: dockFrame, fallbackSize: regions.canvas.size, viewport: geo.size, regions: regions, closing: closing) { point in
                        area?.collapseDock()
                        area?.dockHover = nil
                        workspace.drag(pane, to: local(point), in: bounds) { remaining, location in
                            dockIndex(of: pane, among: remaining, at: location, onStage: onStage, regions: regions)
                        }
                    } onDrop: {
                        workspace.drop(in: bounds)
                    } onActivate: {
                        // 家族格里的父代理：点开看子代理，展开后再点父代理才放上台面
                        if let family { area?.toggleDock(family, depth: 0) }
                        else { workspace.restore(pane, in: bounds) }
                    } onRetired: {
                        retained.removeAll { $0 == pane }
                        paneInstances[pane] = nil
                    }
                    .environment(\.openSidebar, pane == first ? openSidebar : nil)
                    .modifier(DockDimmed(dimmed: expanded && layout.panes[pane] == nil && workspace.drag?.pane != pane))
                    // 拖缝调整大小时指针会快速扫过卡片，期间卡片不响应悬停和点击
                    .allowsHitTesting(workspace.resizing == nil && !closing)
                    .transition(.identity)
                }
                if let area, let dock {
                    DockOverlay(geometry: dock, bounds: bounds, regions: regions) { pane in
                        if layout.panes[pane] != nil { workspace.focus(pane) }
                        else { workspace.restore(pane, in: bounds) }
                    }
                    .environment(area)
                    .modifier(PausedInTransition(layout: workspace))
                    .zIndex(2)
                }
            }
            .coordinateSpace(.named(DockSpace.name))
            .onChange(of: workspace.panes, initial: true) { _, panes in
                retained += panes.filter { !retained.contains($0) }
            }
            .onChange(of: instances, initial: true) { _, instances in
                paneInstances.merge(instances) { _, new in new }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { workspace.updateViewport($0, presentation: .tiled) }
            .onChange(of: Set(onStage.compactMap { area?.dockInstanceID($0) }), initial: true) { _, visible in
                area?.noteVisible(visible)
            }
            .onDisappear { area?.noteVisible([]) }
        }
        .environment(workspace)
        .environment(\.dockCardsDrawPanes, true)
        .disablesWindowDragging()
        .modifier(CursorFrozenInTransition(layout: workspace))
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

}

/// 宽屏停靠栏：添加入口固定在最上面，然后是代理组（有子代理的在前）、分隔线、工具组；没有窗口的代理和工具排成小头像，贴着底边。
/// 最小化的窗口由卡片自己画在格子上；脉冲画在卡片上面，见 DockOverlay；家族格里叠在父代理后面的子代理画在这一层。
private struct DockRail: View {
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
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
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

/// 一张卡片摆在哪。进入布局拖动后缩成停靠形状跟着指针，松手后展开到落点。
/// 只有它读指针位置，指针一动只重画这一张，不重算整个排布。
private struct CardSlot: View {
    let group: PaneGroup
    let pane: Pane
    let rect: CGRect?
    let dockFrame: CGRect?
    let fallbackSize: CGSize
    let viewport: CGSize
    let regions: WindowRegions
    let closing: Bool
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    var onActivate: () -> Void
    var onRetired: () -> Void
    @Environment(WindowLayout.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var saved = CardPresentation()

    var body: some View {
        let contentSize = rect?.size ?? saved.size ?? fallbackSize
        let appearance = closing ? saved.appearance ?? group.appearance(of: pane) : group.appearance(of: pane)
        let returnTarget = closing || saved.motion == nil ? returnFrame : nil
        // 不读 motion 的终点：读了的话，交给它新终点时这张卡片和里面的窗口要再算一轮
        let previous = saved.frame ?? CGRect(origin: .zero, size: contentSize)
        let frame = closing ? returnTarget ?? previous : destination ?? previous
        let minimized = closing ? returnTarget != nil : rect == nil || workspace.drag?.pane == pane
        let target = WindowPose(frame: frame,
                                scale: minimized ? max(frame.width / max(contentSize.width, 1), frame.height / max(contentSize.height, 1)) : 1,
                                radius: minimized ? appearance.minimizedCornerRadius(width: frame.width) : Metrics.cardRadius,
                                contentOpacity: minimized || closing ? 0 : 1,
                                iconOpacity: minimized ? 1 : 0)
        let motion = saved.prepare(target: target, start: saved.motion == nil ? dockFrame ?? returnTarget : nil, size: rect?.size, contentSize: contentSize, appearance: appearance,
                                   instance: closing ? nil : group.workspace?.instance(of: pane))
        PaneCard(group: group, pane: pane, minimized: minimized, target: target, contentSize: contentSize,
                 motion: motion, viewport: viewport, appearance: appearance, instance: saved.instance,
                 onDrag: onDrag, onDrop: onDrop, onActivate: onActivate) { hovering in
            group.workspace?.setDockHover(DockEntry.pane(pane).id, frame: dockFrame ?? frame,
                hovering: hovering && minimized && !motion.moving && workspace.drag == nil && workspace.resizing == nil)
        }
        .onChange(of: target, initial: true) { _, target in
            let kind: WindowMotionKind = reduceMotion ? .immediate : workspace.drag?.pane == pane ? .tracking
                : workspace.resizing != nil ? .immediate : workspace.drag != nil ? .preview : workspace.motionKind
            motion.move(to: target, kind: kind)
        }
        .modifier(CardMotionState(motion: motion, layout: workspace, pane: pane, closing: closing))
        .onDisappear { workspace.noteSettling(pane, false) }
        .task(id: closing) {
            guard closing else { return }
            // 退出只负责回收视图；新的手势和布局更新仍可改变目标。
            repeat {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            } while motion.moving
            onRetired()
        }
    }

    private var returnFrame: CGRect? {
        guard let area = group.workspace, let instance = saved.instance ?? area.instance(of: pane),
              area.definition(of: instance)?.lifetime == .persistent else { return nil }
        let model = area.dockModel(docked: workspace.shownDock.filter { $0 != pane },
                                   onStage: Set(workspace.shown?.panes ?? []).subtracting([pane]), windowless: instance.id)
        return DockGeometry(model: model, regions: regions).frame(containing: instance.id)
    }

    private var destination: CGRect? {
        if workspace.drag?.pane == pane {
            let size = Metrics.dragBubble
            return CGRect(x: workspace.pointer.x - size / 2, y: workspace.pointer.y - size / 2, width: size, height: size)
        }
        return rect ?? dockFrame
    }
}

/// 卡片随自己的动画变的几项：报给窗口组是否在走排布动画、叠放次序、过渡中接不接输入。
/// 这些在这一层读，动画开始、结束和别的窗口开始、停下时只更新这一层，不让卡片和正文跟着重算。
private struct CardMotionState: ViewModifier {
    let motion: WindowMotion
    let layout: WindowLayout
    let pane: Pane
    let closing: Bool

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(acceptsInput)
            .onChange(of: motion.settling, initial: true) { _, settling in layout.noteSettling(pane, settling) }
            // 拖着、关闭、在停靠栏和台面之间飞的卡片压在别的窗口上面。不然按加入的先后排，缩小时从后面那个窗口底下穿过，
            // 快到停靠栏才从它的直边露出来，头像和卡片都被切掉一截（2026-10-12 Mac 实测）
            .zIndex(layout.drag?.pane == pane || closing || motion.changingForm ? 1 : 0)
    }

    /// 见 WindowLayout.blocksInput。iPad 上跟手拖动是挂在卡片上的 SwiftUI 手势，中途设成不可命中可能把拖动取消，
    /// 没在真机上验证之前，被拖的卡片照常接。
    private var acceptsInput: Bool {
        guard layout.blocksInput else { return true }
        #if os(iOS)
        return layout.drag?.pane == pane
        #else
        return false
        #endif
    }
}

/// 台面上没有窗口时的画板。它把场景图形摆到整个 App 的点阵上，点阵不参与过渡（见 WindowLayout.transitioning）：
/// 空台面的画板。缩小最后一个窗口时等它落进停靠栏再出现，不然飞行中整窗点阵逐帧长出图形。过渡状态在这一层读，同 PausedInTransition。
/// 打开窗口时画板的实色底和文字随窗口展开淡出，图形不淡、逐格收回；窗口展开完盖住它以后再移除（2026-10-12 用户确定）。
/// 台面变空、打开窗口的那次更新里卡片还没报上自己在动，这时就当作已经停下，画板会提前出场、提前移除
/// （2026-10-12 用户看到图形先退场、停下后再随画板出场）；所以先不动，等这次更新走完再看还在不在过渡中。
private struct SettledWindowlessStage: View {
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
private struct PausedInTransition: ViewModifier {
    let layout: WindowLayout
    /// 拖缝调整大小也算。正拖着的缝自己不算，照常接。
    var whileResizing = true

    func body(content: Content) -> some View {
        content.allowsHitTesting(!(whileResizing ? layout.transitioning : layout.blocksInput))
    }
}

/// 过渡中 Mac 上整个内容区不换光标，同 PausedInTransition 只在这一层读过渡状态。
private struct CursorFrozenInTransition: ViewModifier {
    let layout: WindowLayout

    func body(content: Content) -> some View {
        content.freezesCursor(layout.transitioning)
    }
}

/// 退出期间保留内容的排版和实例身份；服务端移除窗口不能让飞行中的卡片换成占位。
private final class CardPresentation {
    var size: CGSize?
    /// 上一次排布给的外框。
    var frame: CGRect?
    var appearance: WindowAppearance?
    var instance: RemotePluginInstance?
    var motion: WindowMotion?

    func prepare(target: WindowPose, start: CGRect?, size: CGSize?, contentSize: CGSize, appearance: WindowAppearance,
                 instance: RemotePluginInstance?) -> WindowMotion {
        if let size { self.size = size }
        frame = target.frame
        self.appearance = appearance
        if let instance { self.instance = instance }
        if let motion { return motion }
        var initial = target
        if let start {
            initial.frame = start
            initial.radius = appearance.minimizedCornerRadius(width: start.width)
            initial.scale = max(start.width / max(contentSize.width, 1), start.height / max(contentSize.height, 1))
            initial.contentOpacity = 0
            initial.iconOpacity = 1
        }
        let motion = WindowMotion(initial)
        self.motion = motion
        return motion
    }
}

extension View {
    /// 按 rect 定大小和位置，坐标是所在容器的。
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

/// 宽屏布局中的一张卡片，里面是窗口（PaneWindow）。按住标题栏拖够一段距离后缩成停靠形状，内容淡出，出现图标。
struct PaneCard: View {
    let group: PaneGroup
    let pane: Pane
    let minimized: Bool
    /// 这次排布给的终点，见 WindowSurface.target。
    let target: WindowPose
    /// 内容按台面上的尺寸排。缩成停靠形状、拖动和从停靠栏展开时只整体缩放，不跟着卡片逐帧重排。
    let contentSize: CGSize
    @Environment(WindowLayout.self) private var workspace
    @Environment(AppModel.self) private var model
    @State private var header = PaneCardHeader()
    @State private var headerRegions = HeaderRegions()
    @State private var carrier = DotCarrier()
    @State private var scope = DotScope()
    @State private var usesDots = false
    /// 正文里摆在点阵上的图形，转交给外面的 DotsPresence，见 body。
    @State private var dotSlots: Set<String> = []
    @State private var screenOrigin = CGPoint.zero
    /// 头像的描边颜色，由头像报上来，画在外框上。
    @State private var ringColor: Color?
    /// 缩进停靠栏时不在屏上，写进这个盒子交给内容：只有读它的逐帧动画随它停、起，窗口本身不跟着重算。
    @State private var presence = PanePresence()
    let motion: WindowMotion
    let viewport: CGSize
    let appearance: WindowAppearance
    let instance: RemotePluginInstance?
    /// 拖动中的指针位置，窗口坐标。
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    var onActivate: () -> Void
    /// 缩成停靠形状时报给停靠栏，用来浮出名字。
    var onHover: (Bool) -> Void = { _ in }

    private var width: CGFloat { target.frame.width }

    private var canExpand: Bool { (workspace.shown?.panes.count ?? 0) > 1 }

    private var controls: PaneHeaderControls {
        PaneHeaderControls(header: header, layout: workspace, minimized: minimized, width: width,
                           hasThread: group.workspace?.thread(in: pane) != nil)
    }

    private var windowActions: PaneWindowActions? {
        guard let area = group.workspace else { return nil }
        let expand: (@MainActor () -> Void)?
        if canExpand { expand = { workspace.expand(pane) } }
        else { expand = nil }
        return PaneWindowActions(minimize: { workspace.minimize(pane) }, expand: expand,
                                 close: { model.closeWindow(pane, in: area) },
                                 canClose: !area.isDraft && !area.changingWindows && area.creatingWindow != pane.id)
    }

    var body: some View {
        WindowSurface(motion: motion, target: target, contentSize: contentSize, viewport: viewport,
                      iconSize: min(width, Metrics.dragBubble), color: Theme.card,
                      minimizedColor: appearance.isAgent ? Theme.card : appearance.tint,
                      ring: ringColor.map { ($0, DockFace.ringWidth) },
                      background: AnyView(WindowSurfaceDots(enabled: usesDots)),
                      // 点阵不参与过渡（见 WindowLayout.transitioning）：窗口自己在动时 WindowSurface 收起，拖缝调整大小时也收起
                      backgroundHidden: workspace.resizing != nil,
                      headerHeight: minimized ? nil : header.height,
                      onHover: { hovered in
                          if header.hovered != hovered { header.hovered = hovered }
                          onHover(hovered)
                      }) {
            PaneBody(group: group, pane: pane, retainForExit: true)
                .coordinateSpace(.named(DotCarrier.space))
                .paneFocus(pane, in: workspace, enabled: !minimized)
                .modifier(PaneHeaderEnvironment(controls: controls, actions: windowActions))
                .environment(\.panePresence, presence)
                .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .modifier(WhileSettled(motion: motion, shown: !minimized, fades: false))
                .accessibilityHidden(minimized)
                // Mac 上正文托管在自己的视图里（见 WindowSurface），它报的偏好值传不出卡片，在这里接；
                // 点阵的两项外面也要用（App 背景让出静息点、整页淡出时收回图形），由卡片接着往上报
                .onPreferenceChange(WindowDotsActive.self) { usesDots = $0 }
                .onPreferenceChange(DotSlots.self) { dotSlots = $0 }
                .onPreferenceChange(PaneHeaderActionsWidth.self) { width in
                    if header.menuWidth != width { header.menuWidth = width }
                }
                .onPreferenceChange(PaneHeaderHeight.self) { height in
                    if header.height != height { header.height = height }
                }
                .onPreferenceChange(PaneHeaderInteractiveRects.self) { rects in
                    headerRegions.rects = rects
                    if !motion.moving { headerRegions.settled = rects }
                }
        } icon: {
            if appearance.isAgent, let area = group.workspace {
                DockEntryFace(subject: instance.map { .instance($0) } ?? .pane(pane), pulse: false, ring: false)
                    .environment(area)
            } else {
                Image(systemName: appearance.icon).font(Theme.title).foregroundStyle(Theme.ink)
            }
        } header: {
            ZStack(alignment: .trailing) {
                if !workspace.isFixed { dragArea }
                if !minimized, !workspace.isFixed {
                    headerActions.modifier(HeaderActionsPlacement(controls: controls, motion: motion))
                }
            }
        }
        .environment(\.dotCarrier, carrier)
        .environment(\.dotScope, scope)
        .preference(key: WindowDotsActive.self, value: usesDots)
        .preference(key: DotSlots.self, value: dotSlots)
        .onPreferenceChange(DockRingColor.self) { ringColor = $0 }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { screenOrigin = $0; updateDots() }
        .onChange(of: target, initial: true) { updateDots() }
        .onChange(of: contentSize) { updateDots() }
        .onChange(of: minimized, initial: true) { _, minimized in
            let onScreen = !minimized
            if presence.onScreen != onScreen { presence.onScreen = onScreen }
        }
        // 正文标题栏按这几项算给窗口按钮让出多少，交给 PaneCardHeader，见 PaneHeaderControlsSpace
        .onChange(of: HeaderPlacement(minimized: minimized, width: width, hasThread: group.workspace?.thread(in: pane) != nil), initial: true) { _, placement in
            header.layout = workspace
            if header.placement != placement { header.placement = placement }
        }
        .modifier(DragStarted(layout: workspace) {
            if header.hovered { header.hovered = false }
            onHover(false)
        })
        .modifier(MotionFlip(motion: motion) { moving in
            if moving { onHover(false) }
            else { headerRegions.settled = headerRegions.rects }
        })
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

    private func updateDots() {
        let offset = target.contentOrigin(size: contentSize)
        carrier.rest = DotCarrier.Mapping(origin: CGPoint(x: screenOrigin.x + offset.x, y: screenOrigin.y + offset.y),
                                          scale: target.scale)
        scope.frame = target.frame.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
    }

    /// 挖掉的按钮范围在动画停下时才换（见 HeaderRegions），按钮和菜单让出的宽度跟着悬停变（见 PaneCardHeader），都只更新拖动区这一层。
    private var dragArea: some View {
        SettledRegions(regions: headerRegions) { settled in
            dragArea(excluded: minimized ? [] : settled)
        }
    }

    private func dragArea(excluded: [CGRect]) -> some View {
        LayoutDragArea(cursor: minimized ? .pointingHand : .openHand, activeCursor: .closedHand,
                       minimumDistance: minimized ? Metrics.dragThreshold : header.height, excluded: excluded) { drag in
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
        .padding(.trailing, minimized ? 0 : header.menuWidth + (controls.shown ? header.controlsSize.width + Metrics.paneButtonGap : 0)
                 + Metrics.paneMargin)
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if header.controlsSize != size { header.controlsSize = size }
            }
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

/// 卡片标题栏的悬停和几项实际尺寸，由外框、按钮组和正文报上来，只有读它们的几层随之更新：卡片每重算一次，
/// 正文的托管视图就整个更新一遍。缩小、恢复时悬停跟着结束、剩一个窗口时按钮组少了展开，以前首帧、结束时卡片都要多算一两轮。
/// 正文标题栏给窗口按钮让位也按它算（PaneHeaderControlsSpace），悬停一变只有标题栏读它的那一层更新。
@Observable private final class PaneCardHeader: PaneHeaderControlsSpace {
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
private struct HeaderPlacement: Equatable {
    var minimized = false
    var width: CGFloat = 0
    var hasThread = false
}

/// 窗口按钮放在哪：标题栏上露出来、藏着，还是收进正文的更多菜单。读 PaneCardHeader 的几层各自用它算。
private struct PaneHeaderControls {
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
private struct PaneHeaderEnvironment: ViewModifier {
    let controls: PaneHeaderControls
    let actions: PaneWindowActions?

    func body(content: Content) -> some View {
        content
            .environment(\.paneOverflowActions, controls.inMenu ? actions : nil)
            .environment(\.paneHeaderControlsSpace, controls.header)
    }
}

/// 窗口按钮组让开正文的菜单，悬停时露出来。
private struct HeaderActionsPlacement: ViewModifier {
    let controls: PaneHeaderControls
    let motion: WindowMotion

    func body(content: Content) -> some View {
        let menuWidth = controls.header.menuWidth, shown = controls.shown
        content
            .padding(.trailing, Metrics.paneMargin + (menuWidth > 0 ? menuWidth + Metrics.paneButtonGap : 0))
            .modifier(WhileSettled(motion: motion, shown: shown))
            .accessibilityHidden(!shown)
    }
}

/// 开始拖哪个窗口时做的事，在这一层读 drag，卡片本身不跟着重算。
private struct DragStarted: ViewModifier {
    let layout: WindowLayout
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: layout.drag?.pane) { _, _ in action() }
    }
}

/// 命中区域在动画完成时交给原生拖动层，避免标题逐帧补位引起整段正文重算。
@Observable private final class HeaderRegions {
    /// 正文最新报上来的。
    @ObservationIgnored var rects: [CGRect] = []
    /// 拖动区挖掉的：停着时跟着 rects，动画中保持动画开始前的，停下再换。
    var settled: [CGRect] = []
}

/// 只在这一层读 HeaderRegions.settled。
private struct SettledRegions<Content: View>: View {
    let regions: HeaderRegions
    @ViewBuilder let content: ([CGRect]) -> Content

    var body: some View { content(regions.settled) }
}

/// 窗口在动时看不见、不接输入（shown 为 false 时一直这样）。动画开始、结束只更新这一层。
private struct WhileSettled: ViewModifier {
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

/// 动画开始、结束时做的事，在这一层读 moving，卡片本身不跟着重算。
private struct MotionFlip: ViewModifier {
    let motion: WindowMotion
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: motion.moving) { _, moving in action(moving) }
    }
}

/// 网格固定在屏幕上，静息的网点不随卡片走。窗口在动时整层收起（见 WindowSurface），卡片上的图形也不逐帧跟随。
private struct WindowSurfaceDots: View {
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
