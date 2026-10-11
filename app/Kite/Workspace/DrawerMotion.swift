import SwiftUI

/// 拉出来的是哪一侧。
nonisolated enum WorkspaceDrawer { case sidebar, actions }

/// 底栏跟着窗口怎么动：开着窗口时可以展开收起；工作区载入后没有窗口时一直展开，只在拉开侧边栏时让开；单页和目录状态没有底栏。
nonisolated enum ActionsRule: Sendable { case free, pinned, none }

/// 紧凑布局拉开侧边栏、底栏的状态与手势。CompactLayout 持有一个，经环境交给窗口。
///
/// 打开、收起分两段，照系统可交互转场的做法：
/// - 拖着：窗口跟着手指走，挪多少走多少，拖回去就收回来；越过一半时轻震一下，松手就会去这一头。
///   推过完全打开还能再推出去一截，变形照旧接着走，越推越吃力，最多 Openness.limit；收起的那头不留。
/// - 松手：甩得够快就去甩的那头，不然过半就打开、不到一半收回去；用弹簧带着手指的速度走过去，甩得越快回弹越多，
///   回弹交给系统弹簧。点按钮、点窗口收起也是这一段，没有速度，不回弹、不冲过头。
///   走的途中按住就接着拖，从当时的样子接手；半路改去另一头，带着当时的速度掉头。
/// 照 Apple 的做法（WWDC24「Enhance your UI animations and transitions」）都交给 SwiftUI 的弹簧动画：
/// 拖着时每挪一下用 interactiveSpring 改一次，一个接着一个；松手用 spring，它接着拖动时的速度走，不用自己算初速度。
///
/// 进度（target）只由窗口外壳、侧栏平移和标题栏、控制区的补位读，窗口内容不读：开合时内容不求值、不排版，见 CompactWindow。
/// 放进环境的动作（openSidebar、拉底栏）建好就不再换，开合起止也不会让读它们的视图重算。
@MainActor @Observable
final class DrawerMotion {
    /// 打开着的一侧；停在收起的位置时是 rest。
    private(set) var open: WorkspaceDrawer?
    /// 露出来的一侧：打开着、手指拖着或者正在走。
    private(set) var shown: WorkspaceDrawer?
    /// 每一侧要打开到几成：拖着时是手指处，松手后是 0 或 1。都带着动画改，窗口这一帧实际摆到哪见 presented。
    private(set) var target = Openness()
    /// 拖着越过一半的次数，每变一次轻震一下。
    private(set) var crossings = 0
    /// 底栏规则；第一次配好以前是 nil，窗口按停着的样子摆。
    private(set) var rule: ActionsRule?

    /// 这一帧弹簧走到几成，由窗口的变换逐帧写入，不引起视图更新。手指半路接住时从这里接着拖。
    @ObservationIgnored var presented = Openness()
    /// 侧边栏宽、底栏连同页签与 Home 条高，手指位移按它换算成几成。
    @ObservationIgnored var extents = (sidebar: CGFloat(0), actions: CGFloat(0))
    /// 手指正拖着的一侧。
    @ObservationIgnored private var dragging: WorkspaceDrawer?
    /// 这次拖动里，手指的位移为 0 时对应打开到几成。
    @ObservationIgnored private var anchor: CGFloat = 0
    /// 这次拖的方向不对，不拉抽屉，松手前都不管。
    @ObservationIgnored private var offAxis = false
    /// 拉开侧边栏，给标题栏左边的按钮。
    @ObservationIgnored private(set) var openSidebar: @MainActor () -> Void = {}
    /// 给底栏的打开状态，改它就是 settle。建好就不再换，CompactLayout 重算时底栏不跟着重算。
    @ObservationIgnored private(set) var openBinding: Binding<WorkspaceDrawer?> = .constant(nil)
    /// 从左边缘往右拉侧边栏、从控制区往上拉底栏；打开以后往回拖收起也用它们。
    @ObservationIgnored private(set) var sidebarPull = DrawerPull(changed: { _, _ in }, ended: { _ in })
    @ObservationIgnored private(set) var actionsPull = DrawerPull(changed: { _, _ in }, ended: { _ in })

    /// 松手时甩多快（点每秒）算甩，按甩的方向定去哪头。
    private static let flickSpeed: CGFloat = 300
    /// 松手时甩到多快（点每秒）回弹最多，最多多少。不回弹的弹簧（临界阻尼）冲过头的量也随速度变，
    /// 但要甩到每秒几千点才看得出来，所以按速度加回弹。
    private static let fullBounceSpeed: CGFloat = 3000
    private static let maxBounce = 0.3
    /// 弹簧走完大约多久。
    private static let duration = 0.4
    /// 点按钮、换规则和让开另一侧时用：不回弹、不冲过头。
    private static let settleSpring = Animation.spring(duration: duration, bounce: 0)

    init() {
        openSidebar = { [weak self] in self?.settle(.sidebar) }
        openBinding = Binding(get: { [weak self] in self?.open }, set: { [weak self] in self?.settle($0) })
        sidebarPull = pull(.sidebar)
        actionsPull = pull(.actions)
    }

    /// 收起时停在哪：底栏钉着时是展开的底栏。
    var rest: WorkspaceDrawer? { rule == .pinned ? .actions : nil }

    /// 第一次配好底栏规则以后为 true。
    var configured: Bool { rule != nil }

    /// 窗口铺满、没被拉开也没在走：控制区横滑可以切换窗口。
    var collapsed: Bool { open == nil && shown == nil }

    /// 换了底栏规则：第一次直接停在该在的位置（侧栏开着、底栏钉着），不先铺满再缩；
    /// 之后回到新规则下的收起状态：关掉最后一个窗口时底栏展开，进单页时收起，开出窗口时窗口铺满。
    func setRule(_ rule: ActionsRule) {
        let first = self.rule == nil
        self.rule = rule
        guard !first else {
            if rule == .pinned {
                target.actions = 1
                presented = target
                open = .actions
                shown = .actions
            }
            return
        }
        settle(open == .sidebar ? .sidebar : nil)
    }

    /// 从当时的样子走到 drawer 打开，nil 是收起：点按钮、点窗口收起、点侧边栏里的会话。正在走的带着当时的速度掉头（SwiftUI 的弹簧自己接）。
    func settle(_ drawer: WorkspaceDrawer?) {
        let drawer = drawer ?? rest
        for side in [WorkspaceDrawer.sidebar, .actions] where side != drawer && target[side] != 0 {
            animate(side, to: 0, with: Self.settleSpring)
        }
        if let drawer, target[drawer] != 1 {
            animate(drawer, to: 1, with: Self.settleSpring)
        }
        open = drawer
    }

    /// 带着动画让 drawer 那一侧走到 value。收起的走完了才藏起那一侧。
    private func animate(_ drawer: WorkspaceDrawer, to value: CGFloat, with animation: Animation) {
        shown = drawer
        withAnimation(animation, completionCriteria: .removed) {
            target[drawer] = value
        } completion: { [weak self] in
            guard let self else { return }
            // 中间又拉开、又拖起来的不藏
            if target[drawer] == 0, dragging != drawer, shown == drawer { shown = nil }
        }
    }

    private func extent(_ drawer: WorkspaceDrawer) -> CGFloat {
        drawer == .sidebar ? extents.sidebar : extents.actions
    }

    /// 手指的位移或速度往打开的方向有多少，换算成几成。
    private func along(_ drawer: WorkspaceDrawer, _ size: CGSize) -> CGFloat {
        guard extent(drawer) > 0 else { return 0 }
        return (drawer == .sidebar ? size.width : -size.height) / extent(drawer)
    }

    /// 往 drawer 那一侧拉。一开始往哪个方向拖就定下来：侧边栏要横着拖，action 栏要竖着拖，
    /// 方向不对的留给拖的地方自己的手势（比如控制区里横着滑选 effort）。另一侧没收好时也不接。
    private func pull(_ drawer: WorkspaceDrawer) -> DrawerPull {
        DrawerPull { [weak self] moved, _ in
            self?.drag(drawer, moved: moved)
        } ended: { [weak self] velocity in
            self?.release(drawer, velocity: velocity)
        }
    }

    private func drag(_ drawer: WorkspaceDrawer, moved: CGSize) {
        // 底栏钉着或没有底栏时不能拖
        if drawer == .actions, rule != .free { return }
        let other: WorkspaceDrawer = drawer == .sidebar ? .actions : .sidebar
        let holding = dragging == drawer
        if !holding {
            guard !offAxis else { return }
            // 钉着的底栏不算没收好：拉侧边栏时它让开
            let otherPinned = other == rest
            guard DrawerPull.isHorizontal(moved) == (drawer == .sidebar), otherPinned || presented[other] < 0.001 else {
                offAxis = true
                return
            }
            if otherPinned { animate(other, to: 0, with: Self.settleSpring) }
            // 接手：从这一帧实际摆到的地方（可能正在走）接着拖，窗口不跳
            dragging = drawer
            shown = drawer
            anchor = presented[drawer] - along(drawer, moved)
        }
        let finger = anchor + along(drawer, moved)
        if holding, (target[drawer] > 0.5) != (finger > 0.5) { crossings += 1 }
        // 每挪一下接着上一个弹簧走；接手时正在走的动画也带着当时的速度转过来
        withAnimation(.interactiveSpring) { target[drawer] = finger }
    }

    private func release(_ drawer: WorkspaceDrawer, velocity: CGSize) {
        offAxis = false
        guard dragging == drawer else { return }
        dragging = nil
        let finger = target[drawer]
        let speed = along(drawer, velocity)
        let to: CGFloat = abs(speed) * extent(drawer) > Self.flickSpeed ? (speed > 0 ? 1 : 0) : (finger > 0.5 ? 1 : 0)
        let bounce = min(abs(speed) * extent(drawer) / Self.fullBounceSpeed, 1) * Self.maxBounce
        // 速度由 SwiftUI 从拖动时的 interactiveSpring 接过来
        animate(drawer, to: to, with: .spring(duration: Self.duration, bounce: bounce))
        if to == 0, let rest, rest != drawer {
            animate(rest, to: 1, with: Self.settleSpring)
            open = rest
        } else {
            open = to == 1 ? drawer : nil
        }
    }
}

/// 两侧各打开到几成，0 是铺满，1 是完全打开。按手指算，计算窗口位置时再给越界部分加阻尼。
nonisolated struct Openness: Equatable, Sendable {
    var sidebar: CGFloat = 0
    var actions: CGFloat = 0

    /// 推过完全打开最多再出去多少点。
    static let limit: CGFloat = 32

    subscript(drawer: WorkspaceDrawer) -> CGFloat {
        get { drawer == .sidebar ? sidebar : actions }
        set { if drawer == .sidebar { sidebar = newValue } else { actions = newValue } }
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(sidebar, actions) }
        set { sidebar = newValue.first; actions = newValue.second }
    }

    /// 窗口位置对应的打开进度：推过完全打开的那截加上阻尼，起初跟手，越推越吃力，最多出去 limit 点。
    static func shown(_ x: CGFloat, extent: CGFloat) -> CGFloat {
        guard x > 1, extent > 0 else { return max(x, 0) }
        let over = (x - 1) * extent
        return 1 + limit * over / (over + limit) / extent
    }
}

/// 紧凑布局里窗口的几何。窗口缩小时四边的边距同时出现，拉开的那一侧让出侧边栏，或者让出 action 栏连同上面的页签；
/// 内容贴着窗口左下角等比缩小，宽度照铺满时排，字不重新换行：拉侧边栏时按窗口高度缩，右边裁掉；拉 action 栏时按窗口宽度缩。
/// 圆角从屏幕圆角变成屏幕圆角减去边距。
///
/// 内容只按窗口停着的样子（rest）排一次，打开到别的程度时整块缩放、平移、裁切：
/// 标题栏和控制区再平移补位，停住时与按那个样子排出来的位置一致（标题栏与侧栏标志栏同高、控制区与用户栏底边对齐），
/// 中间的正文不重新排版，露出来的部分贴着底边。
nonisolated struct WindowGeometry: Equatable, Sendable {
    var screen: CGSize
    /// 屏幕四边被盖着的：状态栏、Home 条，键盘升起来时底下是键盘。
    var insets: EdgeInsets
    /// 其中 Home 条那一截，不含键盘。
    var homeInset: CGFloat
    /// 窗口里有输入框，要给键盘让位。
    var avoidsKeyboard: Bool
    var sidebarWidth: CGFloat
    /// 页签和 action 栏合起来连同 Home 条与边距的高度。
    var actionsHeight: CGFloat
    var screenRadius: CGFloat
    var rule: ActionsRule
    /// 窗口与屏幕边缘的边距、窗口内容的边距（Metrics.padding、Metrics.paneMargin），在主线程取好。
    var padding: CGFloat
    var margin: CGFloat

    /// 窗口停着时打开到几成：底栏钉着时 actions 为 1。
    var rest: Openness { Openness(actions: rule == .pinned ? 1 : 0) }

    /// openness 下窗口让出的四边（屏幕坐标）、内容的缩放与窗口的圆角。
    struct Placement {
        var edges: EdgeInsets
        var scale: CGFloat
        var radius: CGFloat
    }

    func placement(_ openness: Openness) -> Placement {
        let s = Openness.shown(openness.sidebar, extent: sidebarWidth)
        let a = Openness.shown(openness.actions, extent: actionsHeight)
        // 推过完全打开时照样接着变
        let margin = (s + a) * padding
        let edges = EdgeInsets(top: margin, leading: s * sidebarWidth + a * padding,
                               bottom: s * padding + a * actionsHeight, trailing: margin)
        guard screen.width > 0, screen.height > 0 else { return Placement(edges: edges, scale: 1, radius: screenRadius) }
        let scale = (screen.height - 2 * s * padding) / screen.height * (screen.width - 2 * a * padding) / screen.width
        return Placement(edges: edges, scale: scale, radius: max(screenRadius - edges.top, 0))
    }

    /// 窗口在屏幕上的范围。
    func windowRect(_ openness: Openness) -> CGRect {
        let edges = placement(openness).edges
        return CGRect(x: edges.leading, y: edges.top, width: max(screen.width - edges.leading - edges.trailing, 0),
                      height: max(screen.height - edges.top - edges.bottom, 0))
    }

    /// openness 下窗口外壳怎么摆：排版框 size 盖住整个屏幕，按 mapping 整块缩小、左上角放到窗口左上角，正好是窗口；radius 是缩放前的圆角。
    struct Shell {
        var size: CGSize
        var mapping: DotCarrier.Mapping
        var radius: CGFloat
    }

    /// 按窗口较窄的那一维缩放：那一维的排版框正好是屏幕，另一维比屏幕长，伸到屏幕外。四边都在屏幕边缘或屏幕外，见 WindowShell。
    func shell(_ openness: Openness) -> Shell {
        let placement = placement(openness)
        let window = windowRect(openness)
        guard screen.width > 0, screen.height > 0, window.width > 0, window.height > 0 else {
            return Shell(size: screen, mapping: DotCarrier.Mapping(origin: window.origin), radius: placement.radius)
        }
        let wide = window.width / screen.width, tall = window.height / screen.height
        // 贴着屏幕的那一维直接取屏幕的量，不经过除法，免得差一点落进屏幕里
        let size = wide <= tall ? CGSize(width: screen.width, height: window.height / wide)
                                : CGSize(width: window.width / tall, height: screen.height)
        let scale = min(wide, tall)
        return Shell(size: size, mapping: DotCarrier.Mapping(origin: window.origin, scale: scale), radius: placement.radius / scale)
    }

    /// openness 下窗口能露出多高的内容（缩放前）。
    private func visibleHeight(_ openness: Openness) -> CGFloat {
        let placement = placement(openness)
        return windowRect(openness).height / placement.scale
    }

    /// 内容按停着的样子排的尺寸。
    var contentSize: CGSize { CGSize(width: screen.width, height: visibleHeight(rest)) }

    /// 内容坐标（卡片坐标）到屏幕坐标：内容贴着窗口左下角缩放。
    func mapping(_ openness: Openness) -> DotCarrier.Mapping {
        let placement = placement(openness)
        return DotCarrier.Mapping(origin: CGPoint(x: placement.edges.leading,
                                                  y: screen.height - placement.edges.bottom - placement.scale * contentSize.height),
                                  scale: placement.scale)
    }

    /// 屏幕上的一点换算到窗口停着时的屏幕位置：openness 下窗口里这一点的内容，停着时在哪。
    func follow(_ openness: Openness) -> DotCarrier.Mapping {
        mapping(rest).after(mapping(openness).inverted)
    }

    /// 停着时状态栏、Home 条和键盘盖住窗口的那一截（缩放前），内容按它让位；home 是其中给 Home 条留的。
    /// 底栏展开时，Home 条安全区随窗口一起保留；侧边栏只让出实际覆盖窗口的高度。不让键盘时底部只算 Home 条。
    func covered(_ openness: Openness) -> (insets: EdgeInsets, home: CGFloat) {
        let placement = placement(openness)
        let edges = placement.edges, scale = placement.scale
        let s = Openness.shown(openness.sidebar, extent: sidebarWidth)
        let home = max(homeInset - s * padding, 0) / scale
        let bottom = avoidsKeyboard ? insets.bottom : min(insets.bottom, homeInset)
        return (EdgeInsets(top: max(insets.top - edges.top, 0) / scale,
                           leading: max(insets.leading - edges.leading, 0) / scale,
                           bottom: max(max(bottom - edges.bottom, 0) / scale, home),
                           trailing: max(insets.trailing - edges.trailing, 0) / scale), home)
    }

    /// 键盘升起来了：SwiftUI 的安全区比 Home 条那一截高。
    var keyboardShown: Bool { insets.bottom > homeInset + 1 }

    /// 标题栏要往下挪多少（缩放前）：按 openness 排时它离窗口顶边多远，减去按停着的样子排的位置。
    func headerShift(_ openness: Openness) -> CGFloat {
        func top(_ openness: Openness) -> CGFloat {
            contentSize.height - visibleHeight(openness) + max(margin, covered(openness).insets.top)
        }
        return top(openness) - top(rest)
    }

    /// 控制区要往下挪多少（缩放前）：控制区底边离窗口底边的距离，按停着的样子排的减去按 openness 排的。见 PaneControlsBottom。
    func controlsShift(_ openness: Openness) -> CGFloat {
        func distance(_ openness: Openness) -> CGFloat {
            let covered = covered(openness)
            let safe = keyboardShown ? 0 : covered.home
            return covered.insets.bottom + max(margin, safe) - safe
        }
        return distance(rest) - distance(openness)
    }
}

extension EnvironmentValues {
    /// 所在窗口的抽屉，紧凑布局的窗口里才有。
    @Entry var drawerMotion: DrawerMotion?
    /// 所在窗口的几何，紧凑布局的窗口里才有。
    @Entry var windowGeometry: WindowGeometry?
}

extension View {
    /// 拉开抽屉时把标题栏（top）或控制区（bottom）补到窗口这一帧该在的位置。只在合成层平移，所在窗口的内容不重新排版。
    func drawerShift(_ edge: VerticalEdge) -> some View {
        modifier(DrawerShift(edge: edge))
    }
}

private struct DrawerShift: ViewModifier {
    let edge: VerticalEdge
    @Environment(\.drawerMotion) private var motion
    @Environment(\.windowGeometry) private var geometry

    func body(content: Content) -> some View {
        content.modifier(ShiftEffect(y: shift).ignoredByLayout())
    }

    private var shift: CGFloat {
        guard let motion, let geometry, motion.configured else { return 0 }
        return edge == .top ? geometry.headerShift(motion.target) : geometry.controlsShift(motion.target)
    }
}

/// 只在渲染时平移：offset 会进排版，挪过的控制区按挪后的位置重算安全区，开合时每帧重排。
private struct ShiftEffect: GeometryEffect {
    var y: CGFloat

    var animatableData: CGFloat {
        get { y }
        set { y = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: y))
    }
}

/// 侧边栏贴着窗口左边从左滑入：按窗口同样的进度（含推过头的阻尼）平移，右边缘始终挨着窗口左边。
/// 平移量和窗口的左边距对进度都是线性的，同一个弹簧插值下逐帧对齐。
struct SidebarSlide: ViewModifier {
    let motion: DrawerMotion
    let width: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: (Openness.shown(motion.target.sidebar, extent: width) - 1) * width)
    }
}
