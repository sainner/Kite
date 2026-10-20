import SwiftUI

/// 宽屏台面这一次怎么摆：排布切出来的各张卡片、占位和缝，停靠栏各格，侧栏入口给哪张卡片。和视图无关，
/// Mac 的原生台面（StageView）和 iPad 的 SwiftUI 台面（TilesLayer）共用。
struct StagePlan {
    let regions: WindowRegions
    let tiles: TileLayout
    /// 停靠栏里按顺序放的窗口。
    let docked: [Pane]
    let onStage: Set<Pane>
    let dock: DockGeometry?
    /// 停靠栏展开着「更多」或家族格。
    let expanded: Bool

    /// bounds 是台面所在的整块（含停靠栏），台面自己的坐标。
    init(layout: WindowLayout, area: WorkArea?, bounds: CGRect) {
        regions = layout.regions(in: bounds)
        tiles = layout.shown?.layout(in: regions.canvas) ?? TileLayout()
        docked = layout.shownDock
        onStage = Set(tiles.panes.keys)
        let regions = regions, docked = docked, onStage = onStage
        dock = area.map { DockGeometry(model: $0.dockModel(docked: docked, onStage: onStage), regions: regions) }
        expanded = !(area?.dockExpansion.isEmpty ?? true)
    }

    /// 只算停靠栏，不排台面：不读拖缝改的比例，拖缝时读它的停靠栏不跟着每步重算。
    static func dock(layout: WindowLayout, area: WorkArea, bounds: CGRect) -> (regions: WindowRegions, dock: DockGeometry) {
        let regions = layout.regions(in: bounds)
        let model = area.dockModel(docked: layout.shownDock, onStage: Set(layout.shown?.panes ?? []))
        return (regions, DockGeometry(model: model, regions: regions))
    }

    /// 侧栏入口只放在左上角的窗口：先比顶边，再比左边。
    var first: Pane? {
        tiles.panes.min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }?.key
    }

    /// 卡片缩在停靠栏时摆在哪一格；instance 是窗口指向的实例。子代理的窗口收进父代理那一格里自己的头像位置，
    /// 父代理那一格这时不在（拖着父代理的窗口）就没有，卡片留在原处。
    func dockFrame(of pane: Pane, instance: String?) -> CGRect? {
        if let instance, inFamily(instance) { return dock?.face(of: instance) }
        return dock?.paneFrame(pane) ?? docked.firstIndex(of: pane).map { regions.dockFrame(at: $0) }
    }

    /// 是挂在父代理下面的子代理：窗口收着时整张卡片透明，头像由停靠栏的家族格画（见 CardPresentation.Placement.hidden）。
    func inFamily(_ instance: String?) -> Bool {
        instance.map { dock?.grouped.contains($0) == true } ?? false
    }

    /// 停靠栏里点了一个开着窗口的代理：在台面上就聚焦，否则放上台面。
    static func show(_ pane: Pane, layout: WindowLayout, in bounds: CGRect) {
        if layout.shown?.panes.contains(pane) == true { layout.focus(pane) }
        else { layout.restore(pane, in: bounds) }
    }

    /// 拖进停靠栏时，窗口只能落在自己那一类里：插在同类第 j 个之前就占这一类的第 j 格，取画出来离指针最近的那一格。
    static func dockIndex(of pane: Pane, among remaining: [Pane], at location: CGPoint, onStage: Set<Pane>, regions: WindowRegions,
                          area: WorkArea?) -> Int {
        guard let area else { return regions.dockIndex(at: location, count: remaining.count) }
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

/// 一张卡片这次排布的终点。退出期间保留内容的排版和实例身份；服务端移除窗口不能让飞行中的卡片换成占位。
/// 两端的台面各给每张卡片建一个，建好不换。
final class CardPresentation {
    var size: CGSize?
    /// 上一次排布给的外框。
    var frame: CGRect?
    var appearance: WindowAppearance?
    var instance: RemotePluginInstance?
    var motion: WindowMotion?
    /// 是新建窗口（见 WorkArea.chooserWindow）：没选插件就关掉的，收回添加入口。
    private var chooser = false

    /// 这次排布算出来的：正文按哪个尺寸排、外观、是不是缩成停靠形状、终点和驱动它的 motion。
    struct Placement {
        let contentSize: CGSize
        let appearance: WindowAppearance
        let minimized: Bool
        /// 子代理的窗口收进了父代理那一格：整张透明、不接输入，头像由停靠栏的家族格画。
        var hidden = false
        let target: WindowPose
        let motion: WindowMotion
    }

    /// rect 是台面上给它的位置（缩在停靠栏时为 nil），dockFrame 是停靠栏里那一格，closing 是窗口已经不在了、正飞走。
    /// 拖着的卡片缩成停靠形状跟着指针；关闭时持久实例飞回它在停靠栏的格子（家族格里的落到自己的头像上），否则原地淡出。
    /// appearing 是台面排好以后才打开的窗口，和让位的窗口一起动：已有的实例从它在停靠栏的那一格展开，新建的（草稿、新建窗口、本机先建的实例）
    /// 从停靠栏的添加入口 addButton 展开，没有停靠栏时原地淡入；台面头一次排的窗口直接摆好。没选插件就关掉的新建窗口收回添加入口。
    /// 添加入口没有底色，在那一头卡片整个透明：从它那里长出来、底色跟着淡入，收回去时淡没，露出的就是底下的加号。
    /// inFamily 是子代理的窗口：收着时同样整个透明，缩小时外框缩到自己的头像上淡没，露出底下家族格画的头像，恢复时从那里透明地长出来。
    func place(group: PaneGroup, pane: Pane, rect: CGRect?, dockFrame: CGRect?, fallbackSize: CGSize, regions: WindowRegions,
               closing: Bool, appearing: Bool = false, addButton: CGRect? = nil, inFamily: Bool = false) -> Placement {
        let layout = group.layout
        let contentSize = rect?.size ?? size ?? fallbackSize
        let appearance = closing ? self.appearance ?? group.appearance(of: pane) : group.appearance(of: pane)
        if !closing { chooser = group.workspace?.chooserWindow == pane.id }
        let instanceReturn = closing || motion == nil ? returnFrame(group: group, pane: pane, regions: regions) : nil
        let intoAdd = closing && instanceReturn == nil && chooser && addButton != nil
        let returnTarget = intoAdd ? addButton : instanceReturn
        // 不读 motion 的终点：读了的话，交给它新终点时这张卡片和里面的窗口要再算一轮
        let previous = frame ?? CGRect(origin: .zero, size: contentSize)
        let frame = closing ? returnTarget ?? previous : destination(layout: layout, pane: pane, rect: rect, dockFrame: dockFrame) ?? previous
        let minimized = closing ? returnTarget != nil : rect == nil || layout.drag?.pane == pane
        let hidden = inFamily && minimized && layout.drag?.pane != pane
        let target = WindowPose(frame: frame,
                                scale: minimized ? max(frame.width / max(contentSize.width, 1), frame.height / max(contentSize.height, 1)) : 1,
                                radius: intoAdd ? frame.width / 2 : minimized ? appearance.minimizedCornerRadius(width: frame.width) : Metrics.cardRadius,
                                contentOpacity: minimized || closing ? 0 : 1,
                                iconOpacity: minimized && !intoAdd && !hidden ? 1 : 0)
        let created = appearing && (group.workspace.map { area in area.instance(of: pane).map { area.isOpening(instance: $0.id) } ?? true } ?? false)
        let fromAdd = dockFrame == nil && created && addButton != nil
        let start = fromAdd ? addButton : dockFrame ?? returnTarget
        let motion = prepare(target: target, start: motion == nil ? start : nil, fromAdd: fromAdd, fadesIn: appearing, startsHidden: inFamily,
                             size: rect?.size, contentSize: contentSize, appearance: appearance,
                             instance: closing ? nil : group.workspace?.instance(of: pane))
        return Placement(contentSize: contentSize, appearance: appearance, minimized: minimized, hidden: hidden, target: target, motion: motion)
    }

    /// 台面在窗口里挪了：记下的外框和 motion 一起反着平移，窗口里看着不动（见 StageView.layout）。
    func shift(by offset: CGVector) {
        frame = frame?.offsetBy(dx: offset.dx, dy: offset.dy)
        motion?.shift(by: offset)
    }

    /// 交给 motion 新终点时用哪种动画：减少动态效果直接到位；拖着的跟手；拖缝跟手不动画；拖动中别的卡片让位；否则按这次排布改动的种类。
    static func motionKind(layout: WindowLayout, pane: Pane, reduceMotion: Bool) -> WindowMotionKind {
        reduceMotion ? .immediate : layout.drag?.pane == pane ? .tracking
            : layout.resizing != nil ? .immediate : layout.drag != nil ? .preview : layout.motionKind
    }

    /// 关闭时飞回停靠栏的那一格：只有关掉窗口后实例还在的有。家族格里的落到自己的头像上。
    private func returnFrame(group: PaneGroup, pane: Pane, regions: WindowRegions) -> CGRect? {
        let layout = group.layout
        guard let area = group.workspace, let instance = instance ?? area.instance(of: pane),
              area.survivesWindowClose(instance) else { return nil }
        let model = area.dockModel(docked: layout.shownDock.filter { $0 != pane },
                                   onStage: Set(layout.shown?.panes ?? []).subtracting([pane]), windowless: instance.id)
        return DockGeometry(model: model, regions: regions).face(of: instance.id)
    }

    private func destination(layout: WindowLayout, pane: Pane, rect: CGRect?, dockFrame: CGRect?) -> CGRect? {
        if layout.drag?.pane == pane {
            let size = Metrics.dragBubble
            return CGRect(x: layout.pointer.x - size / 2, y: layout.pointer.y - size / 2, width: size, height: size)
        }
        return rect ?? dockFrame
    }

    private func prepare(target: WindowPose, start: CGRect?, fromAdd: Bool, fadesIn: Bool, startsHidden: Bool, size: CGSize?, contentSize: CGSize,
                         appearance: WindowAppearance, instance: RemotePluginInstance?) -> WindowMotion {
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
            // 子代理从父代理那一格里自己的头像上透明地长出来，头像由家族格画
            initial.iconOpacity = startsHidden ? 0 : 1
            if fromAdd {
                initial.radius = start.width / 2
                initial.iconOpacity = 0
            }
        } else if fadesIn {
            initial.contentOpacity = 0
            initial.iconOpacity = 0
        }
        let motion = WindowMotion(initial)
        self.motion = motion
        return motion
    }
}
