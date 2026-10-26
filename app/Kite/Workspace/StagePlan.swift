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
        let regions = regions
        dock = area.map { Self.geometry(area: $0, regions: regions) }
        expanded = !(area?.dockExpansion.isEmpty ?? true)
    }

    /// 只算停靠栏，不排台面：不读拖缝改的比例，拖缝时读它的停靠栏不跟着每步重算。
    static func dock(layout: WindowLayout, area: WorkArea, bounds: CGRect) -> (regions: WindowRegions, dock: DockGeometry) {
        let regions = layout.regions(in: bounds)
        return (regions, geometry(area: area, regions: regions))
    }

    /// 停靠栏这一刻的样子：滚到哪、展开的家族格里滚到哪不观察（见 WorkArea.dockScrollDistance）。
    fileprivate static func geometry(area: WorkArea, regions: WindowRegions) -> DockGeometry {
        DockGeometry(model: area.dockModel(), region: regions.dock, expansion: area.dockExpansion,
                     distance: area.dockScrollDistance, familyOffset: area.dockFamilyOffset, familyLimit: area.dockFamilyLimit)
    }

    /// 侧栏入口只放在左上角的窗口：先比顶边，再比左边。
    var first: Pane? {
        tiles.panes.min { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }?.key
    }

    /// 卡片缩在停靠栏时停在哪一格、多透明；instance 是卡片对应的实例。子代理收进父代理那一格里自己的头像位置。
    /// 停靠栏里没有它的格子时为 nil（只在本机的新建页垫着底时）。
    func dockSlot(of pane: Pane, instance: String?) -> DockGeometry.Slot? {
        if let instance, let face = dock?.face(of: instance) { return face }
        return dock?.slot(of: pane)
    }

    /// 是收在家族胶囊里只露一截的子代理：卡片落进去时外框缩到它的头像上淡没，出来时从那里透明地长出来（见 CardPresentation.place）。
    func tucked(_ instance: String?) -> Bool {
        instance.map { dock?.tucked.contains($0) == true } ?? false
    }

    /// 停靠栏里点了一格：在台面上就聚焦，否则放上台面。
    static func show(_ pane: Pane, layout: WindowLayout, in bounds: CGRect) {
        if layout.shown?.panes.contains(pane) == true { layout.focus(pane) }
        else { layout.restore(pane, in: bounds) }
    }
}

/// 一张卡片这次排布的终点。退出期间保留内容的排版和实例身份；服务端移除窗口不能让飞行中的卡片换成占位。
/// 两端的台面各给每张卡片建一个，建好不换。
///
/// 停靠栏里的头像同一时刻只有一份。卡片停在停靠栏的格子里时整张透明（parked），头像由格子画，跟着格子堆叠、渐隐、滚动，
/// 卡片只在格子挪了时当场跟过去；要出来（放上台面、拖出来）时先当场摆到格子这一刻的位置、画上和格子一样的头像（snap），格子同时不画，
/// 再飞出去，停到台面上以后格子画「看得到」的样子。缩小时飞到格子上，停稳的那一轮先让格子画上（landing，卡片还在上面画着同样的头像），
/// 下一轮卡片才透明，中间不空一帧。
final class CardPresentation {
    var size: CGSize?
    /// 上一次排布给的外框。
    var frame: CGRect?
    var appearance: WindowAppearance?
    var instance: RemotePluginInstance?
    var motion: WindowMotion?
    /// 是新建页（见 WorkArea.chooserPane）：没选插件就关掉的，收回添加入口。
    private var chooser = false
    /// 停靠形状落进格子到了哪一步，见上。
    private var docking = Docking.away
    /// 上一轮是不是停靠形状，认出从停靠栏飞出去的那一轮。
    private var wasMinimized = false
    /// 正从停靠栏（或添加入口）飞往台面、还没停下。
    private var fromDock = false

    private enum Docking { case away, landing, parked }

    /// 停靠栏里那一格这一刻由谁画头像，台面汇总给停靠栏（见 StageGeometry）。
    enum Facing {
        /// 卡片停在格子里、整张透明，格子画头像。
        case cell
        /// 卡片自己画着头像（缩成停靠形状在飞、拖着，刚从停靠栏飞出去，关掉的新建页飞进交给的实例那一格），格子不画。
        case card
        /// 卡片停在台面上，格子画「看得到」的样子。
        case stage
    }

    /// 这次排布算出来的：正文按哪个尺寸排、外观、是不是缩成停靠形状、终点和驱动它的 motion。
    struct Placement {
        let contentSize: CGSize
        let appearance: WindowAppearance
        let minimized: Bool
        /// 整张透明、不接输入、读屏跳过：停在格子里，或收在家族胶囊里的子代理缩成了停靠形状（头像由家族格画）。
        var hidden = false
        let target: WindowPose
        let motion: WindowMotion
        /// 先当场摆到这里再走向 target：停在格子里的卡片要出来时，从格子这一刻的位置、画着头像起。
        var snap: WindowPose?
        /// 当场到 target、不走动画：停在格子里时跟着格子挪，停稳后转成透明。
        var immediate = false
        var facing = Facing.card
        /// 还差一步：落进格子的那一轮（下一轮转成透明），或停靠形状、从停靠栏飞出去的卡片没有动画就到了（下一轮才认得出停稳），
        /// 台面在没有动画停下来提醒的时候自己再排一轮（见 StageView.settle）。
        var unsettled = false
        /// 等着停下：卡片停下时台面再排一轮，把它收进格子或让格子画上「看得到」（见 CardView.motionChanged）。
        var awaitsRest = false
    }

    /// rect 是台面上给它的位置（缩在停靠栏时为 nil），slot 是停靠栏里那一格（家族里的是它的头像）这一刻的位置和透明度，
    /// closing 是这个 pane 已经不在了（实例关闭、归档，草稿、新建页关掉）、正飞走。
    /// 拖着的卡片缩成停靠形状跟着指针；关闭时交给了后台实例的新建页飞进那个实例的格子（见 WorkArea.handedOff），否则原地淡出。
    /// appearing 是台面排好以后才打开的窗口，和让位的窗口一起动：已有的实例从它在停靠栏的那一格展开，新建的（新建页、草稿、本机先建的实例）
    /// 从停靠栏的添加入口 addButton 展开（自己已有一格的从那一格），没有停靠栏时、清空上下文接在原处的草稿原地淡入；台面头一次排的窗口直接摆好。
    /// 没选插件就关掉的新建页收回添加入口。添加入口没有底色，在那一头卡片整个透明：从它那里长出来、底色跟着淡入，收回去时淡没，露出的就是底下的加号。
    /// addStart 是添加入口上一轮画在哪：新建页的格子插在它前面，添加入口正往后挪，新建的窗口从它挪动前的地方长出来。
    /// tucked 是收在家族胶囊里只露一截的子代理：缩小时外框缩到自己的头像上淡没，露出家族格画的头像，恢复时从那里透明地长出来。
    func place(group: PaneGroup, pane: Pane, rect: CGRect?, dock slot: DockGeometry.Slot?, fallbackSize: CGSize, regions: WindowRegions,
               closing: Bool, appearing: Bool = false, addButton: CGRect? = nil, addStart: CGRect? = nil, tucked: Bool = false) -> Placement {
        let layout = group.layout
        let dragged = layout.drag?.pane == pane
        let contentSize = rect?.size ?? size ?? fallbackSize
        let appearance = closing ? self.appearance ?? group.appearance(of: pane) : group.appearance(of: pane)
        if !closing { chooser = group.workspace?.isChooser(pane) == true }
        let instanceReturn = closing || motion == nil ? returnFrame(group: group, pane: pane, regions: regions) : nil
        let intoAdd = closing && instanceReturn == nil && chooser && addButton != nil
        let returnTarget = intoAdd ? addButton : instanceReturn
        let dockFrame = slot?.frame
        // 不读 motion 的终点：读了的话，交给它新终点时这张卡片和里面的窗口要再算一轮（停没停用 quietState 看，不登记观察）
        let previous = frame ?? CGRect(origin: .zero, size: contentSize)
        let frame = closing ? returnTarget ?? previous : destination(layout: layout, pane: pane, rect: rect, dockFrame: dockFrame) ?? previous
        let minimized = closing ? returnTarget != nil : rect == nil || dragged
        // 卡片画着的头像同格子一样透明（堆叠渐隐）；收在家族胶囊里的子代理落进去时淡没
        let iconOpacity = intoAdd || tucked && !dragged ? 0 : slot?.opacity ?? 1
        let resting = motion?.quietState
        let inCell = minimized && !dragged && !closing && dockFrame != nil
        var snap: WindowPose?
        if inCell {
            if motion == nil {
                docking = .parked
            } else if docking != .parked {
                let arrived = resting.map { !$0.moving && $0.target.frame.isClose(to: dockFrame!) } ?? false
                docking = arrived ? (docking == .landing ? .parked : .landing) : .away
            }
        } else {
            if docking == .parked, !closing, let slot {
                snap = WindowPose(frame: slot.frame, scale: Self.scale(slot.frame, contentSize), radius: slot.frame.width / 2,
                                  contentOpacity: 0, iconOpacity: tucked ? 0 : slot.opacity)
            }
            docking = .away
        }
        let parked = docking == .parked
        let target = WindowPose(frame: frame,
                                scale: minimized ? Self.scale(frame, contentSize) : 1,
                                radius: minimized ? frame.width / 2 : Metrics.cardRadius,
                                contentOpacity: minimized || closing ? 0 : 1,
                                iconOpacity: minimized && !parked ? iconOpacity : 0)
        let created = appearing && (group.workspace.map { area in area.instance(of: pane).map { area.isOpening(instance: $0.id) } ?? true } ?? false)
        // 清空上下文时接在原处的草稿原地淡入，和原地淡出的旧代理交叠
        let inPlace = appearing && group.workspace?.takeReplacement(pane) == true
        let fromAdd = !inPlace && created && addButton != nil && (dockFrame == nil || chooser)
        let start = inPlace ? nil : fromAdd ? addStart ?? addButton : dockFrame ?? returnTarget
        let fresh = motion == nil
        let motion = prepare(target: target, start: fresh ? start : nil, startOpacity: iconOpacity, fromAdd: fromAdd, fadesIn: appearing,
                             startsHidden: tucked, size: rect?.size, contentSize: contentSize, appearance: appearance,
                             instance: closing ? nil : group.workspace?.instance(of: pane))
        if minimized || closing { fromDock = false }
        else if wasMinimized || fresh && start != nil { fromDock = true }
        else if let resting, !resting.moving, resting.target == target { fromDock = false }
        wasMinimized = minimized
        let facing: Facing = closing ? .card : minimized ? (docking == .away ? .card : .cell) : fromDock ? .card : .stage
        return Placement(contentSize: contentSize, appearance: appearance, minimized: minimized,
                         hidden: parked || tucked && minimized && !dragged, target: target, motion: motion, snap: snap, immediate: parked,
                         facing: facing, unsettled: docking == .landing, awaitsRest: inCell && docking == .away || fromDock)
    }

    /// 缩成停靠形状时整张缩放多少：盖住那一格。
    private static func scale(_ frame: CGRect, _ contentSize: CGSize) -> CGFloat {
        max(frame.width / max(contentSize.width, 1), frame.height / max(contentSize.height, 1))
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
        guard let area = group.workspace, let instance = area.handedOff[pane.id] else { return nil }
        return StagePlan.geometry(area: area, regions: regions).face(of: instance)?.frame
    }

    private func destination(layout: WindowLayout, pane: Pane, rect: CGRect?, dockFrame: CGRect?) -> CGRect? {
        if layout.drag?.pane == pane {
            let size = Metrics.dragBubble
            return CGRect(x: layout.pointer.x - size / 2, y: layout.pointer.y - size / 2, width: size, height: size)
        }
        return rect ?? dockFrame
    }

    private func prepare(target: WindowPose, start: CGRect?, startOpacity: Double, fromAdd: Bool, fadesIn: Bool, startsHidden: Bool,
                         size: CGSize?, contentSize: CGSize, appearance: WindowAppearance, instance: RemotePluginInstance?) -> WindowMotion {
        if let size { self.size = size }
        frame = target.frame
        self.appearance = appearance
        if let instance { self.instance = instance }
        if let motion { return motion }
        var initial = target
        if let start {
            initial.frame = start
            initial.radius = start.width / 2
            initial.scale = Self.scale(start, contentSize)
            initial.contentOpacity = 0
            // 子代理从父代理那一格里自己的头像上透明地长出来，头像由家族格画；从添加入口长出来的也透明，露出底下的加号
            initial.iconOpacity = startsHidden || fromAdd ? 0 : startOpacity
        } else if fadesIn {
            initial.contentOpacity = 0
            initial.iconOpacity = 0
        }
        let motion = WindowMotion(initial)
        self.motion = motion
        return motion
    }
}

private extension CGRect {
    /// 差不到半点：格子的位置按排版取整前后可能差一点。
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.5 && abs(minY - other.minY) < 0.5 && abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }
}
