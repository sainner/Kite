import SwiftUI

/// 宽屏台面这一次怎么摆：排布切出来的各张卡片、占位和缝，停靠栏各格，侧栏入口给哪张卡片。和视图无关，
/// Mac 的原生台面（StageView）和 iPad 的 SwiftUI 台面（TilesLayer）共用。
struct StagePlan {
    let regions: WindowRegions
    let tiles: TileLayout
    let onStage: Set<Pane>
    let dock: DockGeometry?
    /// 停靠栏展开着家族格。
    let expanded: Bool

    /// bounds 是台面所在的整块（含停靠栏），台面自己的坐标。
    init(layout: WindowLayout, area: WorkArea?, bounds: CGRect) {
        regions = layout.regions(in: bounds)
        tiles = layout.shown?.layout(in: regions.canvas) ?? TileLayout()
        onStage = Set(tiles.panes.keys)
        let regions = regions, onStage = onStage
        dock = area.map { DockGeometry(model: $0.dockModel(onStage: Set(onStage.map(\.id))), regions: regions) }
        expanded = !(area?.dockExpansion.isEmpty ?? true)
    }

    /// 只算停靠栏，不排台面：不读拖缝改的比例，拖缝时读它的停靠栏不跟着每步重算。
    static func dock(layout: WindowLayout, area: WorkArea, bounds: CGRect) -> (regions: WindowRegions, dock: DockGeometry) {
        let regions = layout.regions(in: bounds)
        let model = area.dockModel(onStage: Set((layout.shown?.panes ?? []).map(\.id)))
        return (regions, DockGeometry(model: model, regions: regions))
    }

    /// 侧栏入口只放在左上角的窗口：先比顶边，再比左边。
    var first: Pane? {
        tiles.panes.min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }?.key
    }

    /// 卡片缩在停靠栏时摆在哪一格；instance 是卡片对应的实例。子代理收进父代理那一格里自己的头像位置，
    /// 父代理那一格这时不在（拖着父代理的卡片）就没有，卡片留在原处。草稿、新建页这两个只在本机的 pane 不在停靠栏里有格子时为 nil。
    func dockFrame(of pane: Pane, instance: String?) -> CGRect? {
        if let instance, inFamily(instance) { return dock?.face(of: instance) }
        return dock?.paneFrame(pane)
    }

    /// 是挂在父代理下面的子代理：卡片收着时整张透明，头像由停靠栏的家族格画（见 CardPresentation.Placement.hidden）。
    func inFamily(_ instance: String?) -> Bool {
        instance.map { dock?.grouped.contains($0) == true } ?? false
    }

    /// 停靠栏里点了一格：在台面上就聚焦，否则放上台面。
    static func show(_ pane: Pane, layout: WindowLayout, in bounds: CGRect) {
        if layout.shown?.panes.contains(pane) == true { layout.focus(pane) }
        else { layout.restore(pane, in: bounds) }
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
    /// 是新建页（见 WorkArea.chooserPane）：没选插件就关掉的，收回添加入口。
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

    /// rect 是台面上给它的位置（缩在停靠栏时为 nil），dockFrame 是停靠栏里那一格，closing 是这个 pane 已经不在了（实例关闭、归档，草稿、新建页关掉）、正飞走。
    /// 拖着的卡片缩成停靠形状跟着指针；关闭时交给了后台实例的新建页飞进那个实例的格子（见 WorkArea.handedOff），否则原地淡出。
    /// appearing 是台面排好以后才打开的窗口，和让位的窗口一起动：已有的实例从它在停靠栏的那一格展开，新建的（草稿、新建页、本机先建的实例）
    /// 从停靠栏的添加入口 addButton 展开，没有停靠栏时原地淡入；台面头一次排的窗口直接摆好。没选插件就关掉的新建页收回添加入口。
    /// 添加入口没有底色，在那一头卡片整个透明：从它那里长出来、底色跟着淡入，收回去时淡没，露出的就是底下的加号。
    /// inFamily 是子代理的窗口：收着时同样整个透明，缩小时外框缩到自己的头像上淡没，露出底下家族格画的头像，恢复时从那里透明地长出来。
    func place(group: PaneGroup, pane: Pane, rect: CGRect?, dockFrame: CGRect?, fallbackSize: CGSize, regions: WindowRegions,
               closing: Bool, appearing: Bool = false, addButton: CGRect? = nil, inFamily: Bool = false) -> Placement {
        let layout = group.layout
        let contentSize = rect?.size ?? size ?? fallbackSize
        let appearance = closing ? self.appearance ?? group.appearance(of: pane) : group.appearance(of: pane)
        if !closing { chooser = group.workspace?.isChooser(pane) == true }
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

    /// 关闭时飞进停靠栏的那一格：只有交给了后台实例的新建页有（实例本身关闭、归档后格子一起没了，卡片原地淡出）。
    private func returnFrame(group: PaneGroup, pane: Pane, regions: WindowRegions) -> CGRect? {
        let layout = group.layout
        guard let area = group.workspace, let instance = area.handedOff[pane.id] else { return nil }
        let model = area.dockModel(onStage: Set((layout.shown?.panes ?? []).map(\.id)))
        return DockGeometry(model: model, regions: regions).face(of: instance)
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
