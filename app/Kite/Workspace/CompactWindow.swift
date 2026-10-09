import SwiftUI

/// 拉出来的是哪一侧。
enum WorkspaceDrawer { case sidebar, actions }

/// 底栏跟着窗口怎么动：开着窗口时可以展开收起；工作区载入后没有窗口时一直展开，只在拉开侧边栏时让开；单页和目录状态没有底栏。
enum ActionsRule { case free, pinned, none }

/// 会话窗口，和拉出侧边栏、action 栏的手势。
///
/// 打开、收起分两段，照系统可交互转场的做法：
/// - 拖着：窗口跟着手指走，挪多少走多少，拖回去就收回来；越过一半时轻震一下，松手就会去这一头。
///   推过完全打开还能再推出去一截，变形照旧接着走，越推越吃力，最多 Openness.limit；收起的那头不留。
/// - 松手：甩得够快就去甩的那头，不然过半就打开、不到一半收回去；用弹簧带着手指的速度走过去，甩得越快回弹越多，
///   回弹交给系统弹簧。点按钮、点窗口收起也是这一段，没有速度，不回弹、不冲过头。
///   走的途中按住就接着拖，从当时的样子接手；半路改去另一头，带着当时的速度掉头。
/// 照 Apple 的做法（WWDC24「Enhance your UI animations and transitions」）都交给 SwiftUI 的弹簧动画：
/// 拖着时每挪一下用 interactiveSpring 改一次，一个接着一个；松手用 spring，它接着拖动时的速度走，不用自己算初速度。
/// WindowPlacement 只计算目标布局；窗口固定在全屏容器内，只动画四边 inset，位置和宽高由同一次布局确定。
/// WindowProgress 只读取系统弹簧的进度供续拖，不再单独平移窗口。
/// 不把整套布局做成 Animatable，否则每一帧都会重新计算视图、写入安全区和容器形状。
/// 没有窗口时（单页、工作区里没开窗口、目录未载入）窗口里放占位内容，行为与普通窗口相同，只有底栏按 ActionsRule 走。
struct CompactWindow: View {
    @Binding var open: WorkspaceDrawer?
    /// 露出来的一侧：打开着、手指拖着或者正在走。
    @Binding var shown: WorkspaceDrawer?
    let screen: CGSize
    /// 屏幕四边被盖着的：状态栏、Home 条，键盘升起来时底下是键盘。
    let insets: EdgeInsets
    /// 其中 Home 条那一截，不含键盘。
    let homeInset: CGFloat
    let sidebarWidth: CGFloat
    let actionsHeight: CGFloat
    let screenRadius: CGFloat
    let actionsRule: ActionsRule
    /// 工作区开着窗口；否则放占位内容。
    private var windowed: Bool { actionsRule == .free }
    @Environment(AppModel.self) private var model
    /// 每一侧要打开到几成：拖着时是手指处，松手后是 0 或 1。都带着动画改，窗口实际摆到哪见 presented。
    @State private var target = Openness()
    /// 这一帧弹簧走到几成，WindowProgress 读回来。手指半路接住时从这里接着拖。
    @State private var presented = Presented()
    /// 窗口这一帧实际在哪，报给窗口里摆在点阵上的图形，见 DotCarrier。
    @State private var carrier = DotCarrier()
    /// 手指正拖着的一侧。
    @State private var dragging: WorkspaceDrawer?
    /// 这次拖动里，手指的位移为 0 时对应打开到几成。
    @State private var anchor: CGFloat = 0
    /// 这次拖的方向不对，不拉抽屉，松手前都不管。
    @State private var offAxis = false
    /// 拖着越过一半的次数，每变一次轻震一下。
    @State private var crossings = 0

    /// 松手时甩多快（点每秒）算甩，按甩的方向定去哪头。
    private static let flickSpeed: CGFloat = 300
    /// 松手时甩到多快（点每秒）回弹最多，最多多少。不回弹的弹簧（临界阻尼）冲过头的量也随速度变，
    /// 但要甩到每秒几千点才看得出来，所以按速度加回弹。
    private static let fullBounceSpeed: CGFloat = 3000
    private static let maxBounce = 0.3
    /// 弹簧走完大约多久。
    private static let duration = 0.4

    /// 一出现就停在该在的位置（侧栏开着、底栏钉着），不先铺满再缩。
    init(open: Binding<WorkspaceDrawer?>, shown: Binding<WorkspaceDrawer?>, screen: CGSize, insets: EdgeInsets, homeInset: CGFloat,
         sidebarWidth: CGFloat, actionsHeight: CGFloat, screenRadius: CGFloat, actionsRule: ActionsRule) {
        _open = open
        _shown = shown
        self.screen = screen
        self.insets = insets
        self.homeInset = homeInset
        self.sidebarWidth = sidebarWidth
        self.actionsHeight = actionsHeight
        self.screenRadius = screenRadius
        self.actionsRule = actionsRule
        var start = Openness()
        if open.wrappedValue == .sidebar { start.sidebar = 1 }
        else if actionsRule == .pinned { start.actions = 1 }
        _target = State(initialValue: start)
        let presented = Presented()
        presented.openness = start
        _presented = State(initialValue: presented)
    }

    var body: some View {
        // 外壳的身份不随会话改变，保留边距和缩放的动画状态。
        // Group 会把外面的修饰器分发给成员，成员换掉时各段动画可能从不同进度重新开始。
        ZStack(alignment: .topLeading) {
            if windowed, let group = model.paneGroup {
                CompactPaneStack(group: group, width: screen.width, canSwitch: open == nil && shown == nil)
                    .modifier(CompactPaneHeaderHost(focused: group.layout.focused))
                    .environment(group.layout)
                    .environment(\.drawerPull, open == nil && actionsRule == .free ? pull(.actions) : nil)
                    // 一直给着：打开时窗口上盖着一层点了收起的，按钮点不到。有无来回切的话，标题栏会被当成换了一个视图
                    .environment(\.openSidebar, { settle(.sidebar) })
                    .environment(\.keyboardShown, insets.bottom > homeInset + 1)
                    .transition(.opacity.combined(with: .dotsPresence))
                    // 换一组窗口（侧栏切栏目、切工作区）直接替换：交叉淡化时新旧两组的点阵同时半透明，整片会暗一下
                    .transaction(value: group.id) { $0.animation = nil }
                    .id(group.id)
            } else {
                placeholder
                    .environment(\.openSidebar, { settle(.sidebar) })
                    .environment(\.keyboardShown, insets.bottom > homeInset + 1)
                    .transition(.opacity.combined(with: .dotsPresence))
            }
        }
        .animation(.snappy, value: windowed)
        // 拉开侧边栏或底栏就是焦点到了它们那边，窗口不画静息的点；钉着的底栏不算
        .environment(\.windowDotsFocused, shown == nil || (shown == .actions && actionsRule == .pinned))
        .environment(\.dotCarrier, carrier)
        .modifier(WindowPlacement(openness: target, screen: screen, insets: insets, homeInset: homeInset,
                                  avoidsKeyboard: avoidsKeyboard, sidebarWidth: sidebarWidth, actionsHeight: actionsHeight, screenRadius: screenRadius,
                                  presented: presented, carrier: carrier, overlay: catcher))
        // 点侧边栏里的会话收起：open 在外面改的，到这里才起动画
        .onChange(of: open) { _, new in
            if new != target.opened { settle(new) }
        }
        // 规则变了就回到新规则下的收起状态：关掉最后一个窗口时底栏展开，进单页时收起，开出窗口时窗口铺满
        .onChange(of: actionsRule) { _, _ in
            settle(open == .sidebar ? .sidebar : nil)
        }
        .onAppear {
            if actionsRule == .pinned, open == nil {
                open = .actions
                shown = .actions
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: crossings)
    }

    /// 收起时停在哪：底栏钉着时是展开的底栏。
    private var rest: WorkspaceDrawer? { actionsRule == .pinned ? .actions : nil }

    /// 窗口和单页里有输入框，要给键盘让位；目录状态和空画板只展示信息，弹窗里打字时不跟着键盘变形。
    private var avoidsKeyboard: Bool {
        windowed || model.sidebarSection != .workspaces || model.selectedProject != nil
    }

    /// 没有窗口时放的占位内容：单页、目录状态，或工作区没有窗口时的画板。
    @ViewBuilder
    private var placeholder: some View {
        if model.sidebarSection != .workspaces {
            SectionContent()
        } else if let project = model.selectedProject {
            ProjectSettingsPage(project: project).id(project.id)
        } else if let area = model.current {
            Group {
                if area.pluginClient == nil {
                    DirectoryStatus(workspace: area)
                } else {
                    WindowlessStage(dock: "底栏")
                }
            }
            .environment(area)
            .id(area.id)
        } else {
            DirectoryStatus()
        }
    }

    /// 盖在窗口上接手势的：打开时点了收起、拖了往回收；铺满（或底栏钉着）时左边缘往右拖拉出侧边栏。
    @ViewBuilder
    private var catcher: some View {
        if let drawer = open, drawer != rest {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { settle(nil) }
                .gesture(pull(drawer).gesture)
        } else {
            Color.clear
                .frame(width: Metrics.edgeZone)
                .contentShape(Rectangle())
                .gesture(pull(.sidebar).gesture)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 从当时的样子走到 drawer 打开，nil 是收起：点按钮、点窗口收起、点侧边栏里的会话。正在走的带着当时的速度掉头（SwiftUI 的弹簧自己接）。
    private func settle(_ drawer: WorkspaceDrawer?) {
        let drawer = drawer ?? rest
        let spring = Animation.spring(duration: Self.duration, bounce: 0)
        for side in [WorkspaceDrawer.sidebar, .actions] where side != drawer && target[side] != 0 {
            animate(side, to: 0, with: spring)
        }
        if let drawer, target[drawer] != 1 {
            animate(drawer, to: 1, with: spring)
        }
        open = drawer
    }

    /// 带着动画让 drawer 那一侧走到 value。收起的走完了才藏起那一侧。
    private func animate(_ drawer: WorkspaceDrawer, to value: CGFloat, with animation: Animation) {
        shown = drawer
        carrier.began()
        withAnimation(animation, completionCriteria: .removed) {
            target[drawer] = value
        } completion: {
            carrier.ended()
            // 中间又拉开、又拖起来的不藏
            if target[drawer] == 0, dragging != drawer, shown == drawer { shown = nil }
        }
    }

    private func extent(_ drawer: WorkspaceDrawer) -> CGFloat {
        drawer == .sidebar ? sidebarWidth : actionsHeight
    }

    /// 手指的位移或速度往打开的方向有多少，换算成几成。
    private func along(_ drawer: WorkspaceDrawer, _ size: CGSize) -> CGFloat {
        guard extent(drawer) > 0 else { return 0 }
        return (drawer == .sidebar ? size.width : -size.height) / extent(drawer)
    }

    /// 往 drawer 那一侧拉。一开始往哪个方向拖就定下来：侧边栏要横着拖，action 栏要竖着拖，
    /// 方向不对的留给拖的地方自己的手势（比如控制区里横着滑选 effort）。另一侧没收好时也不接。
    private func pull(_ drawer: WorkspaceDrawer) -> DrawerPull {
        // 底栏钉着或没有底栏时不能拖
        if drawer == .actions, actionsRule != .free { return DrawerPull { _, _ in } ended: { _ in } }
        return DrawerPull { moved, _ in
            let other: WorkspaceDrawer = drawer == .sidebar ? .actions : .sidebar
            let holding = dragging == drawer
            if !holding {
                guard !offAxis else { return }
                // 钉着的底栏不算没收好：拉侧边栏时它让开
                let otherPinned = other == rest
                guard DrawerPull.isHorizontal(moved) == (drawer == .sidebar), otherPinned || presented.openness[other] < 0.001 else {
                    offAxis = true
                    return
                }
                if otherPinned { animate(other, to: 0, with: .spring(duration: Self.duration, bounce: 0)) }
                // 接手：从这一帧实际摆到的地方（可能正在走）接着拖，窗口不跳
                dragging = drawer
                shown = drawer
                anchor = presented.openness[drawer] - along(drawer, moved)
            }
            let finger = anchor + along(drawer, moved)
            if holding, (target[drawer] > 0.5) != (finger > 0.5) { crossings += 1 }
            // 每挪一下接着上一个弹簧走；接手时正在走的动画也带着当时的速度转过来
            carrier.began()
            withAnimation(.interactiveSpring, completionCriteria: .removed) {
                target[drawer] = finger
            } completion: {
                carrier.ended()
            }
        } ended: { velocity in
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
                animate(rest, to: 1, with: .spring(duration: Self.duration, bounce: 0))
                open = rest
            } else {
                open = to == 1 ? drawer : nil
            }
        }
    }
}

/// 两侧各打开到几成，0 是铺满，1 是完全打开。按手指算，计算目标边距时再给越界部分加阻尼。
private struct Openness: Equatable {
    var sidebar: CGFloat = 0
    var actions: CGFloat = 0

    /// 推过完全打开最多再出去多少点。
    static let limit: CGFloat = 32

    subscript(drawer: WorkspaceDrawer) -> CGFloat {
        get { drawer == .sidebar ? sidebar : actions }
        set { if drawer == .sidebar { sidebar = newValue } else { actions = newValue } }
    }

    /// 完全打开着的一侧。
    var opened: WorkspaceDrawer? {
        sidebar == 1 ? .sidebar : actions == 1 ? .actions : nil
    }

    /// 目标边距对应的打开进度：推过完全打开的那截加上阻尼，起初跟手，越推越吃力，最多出去 limit 点。
    static func shown(_ x: CGFloat, extent: CGFloat) -> CGFloat {
        guard x > 1, extent > 0 else { return max(x, 0) }
        let over = (x - 1) * extent
        return 1 + limit * over / (over + limit) / extent
    }
}

/// 这一帧窗口实际摆到几成。只供手势接手时读取，不引起视图更新。
private final class Presented {
    var openness = Openness()
}

/// 只读取系统弹簧的当前进度供手势接手，并把窗口这一帧相对停下时的位置报给 carrier；不修改绘制位置，也不逐帧重建视图。
private struct WindowProgress: GeometryEffect {
    var openness: Openness
    /// 弹簧要去的进度，布局按它排。
    let target: Openness
    let presented: Presented
    let carrier: DotCarrier
    /// 某个进度下卡片坐标到窗口坐标的换算。
    let card: (Openness) -> DotCarrier.Mapping

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(openness.sidebar, openness.actions) }
        set { openness = Openness(sidebar: newValue.first, actions: newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        presented.openness = openness
        carrier.update(current: card(openness), final: card(target))
        return ProjectionTransform(.identity)
    }
}

/// 只在目标进度变化时计算布局，帧间插值交给 frame、padding、scaleEffect 和圆角本身。
private struct WindowPlacement<Overlay: View>: ViewModifier {
    let openness: Openness
    let screen: CGSize
    let insets: EdgeInsets
    let homeInset: CGFloat
    let avoidsKeyboard: Bool
    let sidebarWidth: CGFloat
    let actionsHeight: CGFloat
    let screenRadius: CGFloat
    let presented: Presented
    let carrier: DotCarrier
    let overlay: Overlay

    /// openness 下窗口让出的四边与内容的缩放。
    private static func layout(_ openness: Openness, screen: CGSize, sidebarWidth: CGFloat,
                               actionsHeight: CGFloat) -> (insets: EdgeInsets, scale: CGFloat) {
        let s = Openness.shown(openness.sidebar, extent: sidebarWidth)
        let a = Openness.shown(openness.actions, extent: actionsHeight)
        let pad = Metrics.padding
        // 窗口缩进屏幕里，四边的边距随进度出现；拉开的那一侧让出侧边栏，或者让出 action 栏连同上面的页签。
        // 推过完全打开时照样接着变
        let margin = (s + a) * pad
        let insets = EdgeInsets(top: margin, leading: s * sidebarWidth + a * pad,
                                bottom: s * pad + a * actionsHeight, trailing: margin)
        // 内容贴着窗口左下角等比缩小，宽度照铺满时排，字不重新换行：拉侧边栏时按窗口高度缩，右边裁掉；
        // 拉 action 栏时按窗口宽度缩。内容和缩放都对齐底边，控制区的位置由容器底部 inset 决定。
        let scale = (screen.height - 2 * s * pad) / screen.height * (screen.width - 2 * a * pad) / screen.width
        return (insets, scale)
    }

    func body(content: Content) -> some View {
        let s = Openness.shown(openness.sidebar, extent: sidebarWidth)
        let pad = Metrics.padding
        let (windowInsets, scale) = Self.layout(openness, screen: screen, sidebarWidth: sidebarWidth,
                                                actionsHeight: actionsHeight)
        let radius = max(screenRadius - windowInsets.top, 0)
        let shape = RoundedRectangle(cornerRadius: radius)
        // 底栏展开时，Home 条安全区随窗口一起保留；侧边栏仍只让出实际覆盖窗口的高度。
        // 换算成缩放前的尺寸，保证缩放后保留的高度不变。
        let coveredByHome = max(homeInset - s * pad, 0) / scale
        // 状态栏、键盘等仍只给覆盖窗口的那一截让位，底部至少保留 Home 条安全区；不让键盘时底部只算 Home 条。
        let bottom = avoidsKeyboard ? insets.bottom : min(insets.bottom, homeInset)
        let covered = EdgeInsets(top: max(insets.top - windowInsets.top, 0) / scale,
                                 leading: max(insets.leading - windowInsets.leading, 0) / scale,
                                 bottom: max(max(bottom - windowInsets.bottom, 0) / scale, coveredByHome),
                                 trailing: max(insets.trailing - windowInsets.trailing, 0) / scale)
        return content
            .environment(\.homeIndicatorInset, coveredByHome)
            .environment(\.paneTopSafeInset, covered.top)
            .safeAreaPadding(covered)
            .frame(width: screen.width, height: (screen.height - windowInsets.top - windowInsets.bottom) / scale,
                   alignment: .bottomLeading)
            // 卡片坐标：缩放前的内容，摆在卡片上的点阵图形按它换算到窗口，见 DotCarrier
            .coordinateSpace(.named(DotCarrier.space))
            // 窗口的形状，里面同心的圆角（控制区输入框）跟着它；在缩放前，圆角也换算成缩放前的
            .containerShape(RoundedRectangle(cornerRadius: radius / scale))
            .scaleEffect(scale, anchor: .bottomLeading)
            // 接受 inset 后容器给出的尺寸，内容贴着底边；正文保持原宽度，多出来的部分由窗口裁掉。
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)
            .background(Theme.card)
            .clipShape(shape)
            .contentShape(shape)
            .overlay { overlay }
            // 位置和尺寸来自同一组边距，右边、底边贴着容器，不再分别动画尺寸和 offset。
            .padding(windowInsets)
            .frame(width: screen.width, height: screen.height, alignment: .bottomTrailing)
            .modifier(WindowProgress(openness: openness, target: openness, presented: presented, carrier: carrier) {
                [screen, sidebarWidth, actionsHeight] openness in
                let layout = Self.layout(openness, screen: screen, sidebarWidth: sidebarWidth, actionsHeight: actionsHeight)
                // 窗口铺满屏幕的容器从窗口坐标原点排起；内容贴着窗口左下角缩放，卡片坐标原点落在窗口左上角
                return DotCarrier.Mapping(origin: CGPoint(x: layout.insets.leading, y: layout.insets.top), scale: layout.scale)
            })
            .ignoresSafeArea()
    }
}
