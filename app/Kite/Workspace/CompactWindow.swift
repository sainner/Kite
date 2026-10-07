import SwiftUI

/// 拉出来的是哪一侧。
enum WorkspaceDrawer { case sidebar, actions }

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
    @Environment(AppModel.self) private var model
    /// 每一侧要打开到几成：拖着时是手指处，松手后是 0 或 1。都带着动画改，窗口实际摆到哪见 presented。
    @State private var target = Openness()
    /// 这一帧弹簧走到几成，WindowProgress 读回来。手指半路接住时从这里接着拖。
    @State private var presented = Presented()
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

    var body: some View {
        // 外壳的身份不随会话改变，保留边距和缩放的动画状态。
        // Group 会把外面的修饰器分发给成员，成员换掉时各段动画可能从不同进度重新开始。
        ZStack(alignment: .topLeading) {
            if let workspace = model.current {
                Group {
                    if !workspace.isSample, workspace.pluginClient == nil {
                        DirectoryStatus(workspace: workspace)
                    } else if let pane = workspace.layout.focused {
                        PaneBody(pane: pane).id(pane)
                            .transition(.opacity)
                    }
                    else {
                        PaneWindow(header: workspace.header) {
                            Text("从添加按钮打开一个窗口").font(Theme.body).foregroundStyle(.secondary)
                        } controls: { _ in
                            AddWindowButton()
                                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Metrics.dockRadius))
                        }
                    }
                }
                    .animation(.snappy, value: workspace.layout.focused)
                    .environment(workspace)
                    .environment(\.drawerPull, open == nil ? pull(.actions) : nil)
                    // 一直给着：打开时窗口上盖着一层点了收起的，按钮点不到。有无来回切的话，标题栏会被当成换了一个视图
                    .environment(\.openSidebar, { settle(.sidebar) })
                    .environment(\.keyboardShown, insets.bottom > homeInset + 1)
                    .id(workspace.id)
            } else {
                DirectoryStatus().environment(\.openSidebar, { settle(.sidebar) })
            }
        }
        .modifier(WindowPlacement(openness: target, screen: screen, insets: insets, homeInset: homeInset,
                                  sidebarWidth: sidebarWidth, actionsHeight: actionsHeight, screenRadius: screenRadius,
                                  presented: presented, overlay: catcher))
        // 点侧边栏里的会话收起：open 在外面改的，到这里才起动画
        .onChange(of: open) { _, new in
            if new != target.opened { settle(new) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: crossings)
    }

    /// 盖在窗口上接手势的：打开时点了收起、拖了往回收；铺满时左边缘往右拖拉出侧边栏。
    @ViewBuilder
    private var catcher: some View {
        if let drawer = open {
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
        withAnimation(animation, completionCriteria: .removed) {
            target[drawer] = value
        } completion: {
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
        DrawerPull { moved, _ in
            let other: WorkspaceDrawer = drawer == .sidebar ? .actions : .sidebar
            let holding = dragging == drawer
            if !holding {
                guard !offAxis else { return }
                guard DrawerPull.isHorizontal(moved) == (drawer == .sidebar), presented.openness[other] < 0.001 else {
                    offAxis = true
                    return
                }
                // 接手：从这一帧实际摆到的地方（可能正在走）接着拖，窗口不跳
                dragging = drawer
                shown = drawer
                anchor = presented.openness[drawer] - along(drawer, moved)
            }
            let finger = anchor + along(drawer, moved)
            if holding, (target[drawer] > 0.5) != (finger > 0.5) { crossings += 1 }
            // 每挪一下接着上一个弹簧走；接手时正在走的动画也带着当时的速度转过来
            withAnimation(.interactiveSpring) { target[drawer] = finger }
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
            open = to == 1 ? drawer : nil
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

/// 只读取系统弹簧的当前进度供手势接手，不修改绘制位置，也不逐帧重建视图。
private struct WindowProgress: GeometryEffect {
    var openness: Openness
    let presented: Presented

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(openness.sidebar, openness.actions) }
        set { openness = Openness(sidebar: newValue.first, actions: newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        presented.openness = openness
        return ProjectionTransform(.identity)
    }
}

/// 只在目标进度变化时计算布局，帧间插值交给 frame、padding、scaleEffect 和圆角本身。
private struct WindowPlacement<Overlay: View>: ViewModifier {
    let openness: Openness
    let screen: CGSize
    let insets: EdgeInsets
    let homeInset: CGFloat
    let sidebarWidth: CGFloat
    let actionsHeight: CGFloat
    let screenRadius: CGFloat
    let presented: Presented
    let overlay: Overlay

    func body(content: Content) -> some View {
        let s = Openness.shown(openness.sidebar, extent: sidebarWidth)
        let a = Openness.shown(openness.actions, extent: actionsHeight)
        let pad = Metrics.padding
        // 窗口缩进屏幕里，四边的边距随进度出现；拉开的那一侧让出侧边栏，或者让出 action 栏连同上面的页签。
        // 推过完全打开时照样接着变
        let margin = (s + a) * pad
        let windowInsets = EdgeInsets(top: margin, leading: s * sidebarWidth + a * pad,
                                      bottom: s * pad + a * actionsHeight, trailing: margin)
        let radius = max(screenRadius - margin, 0)
        let shape = RoundedRectangle(cornerRadius: radius)
        // 内容贴着窗口左下角等比缩小，宽度照铺满时排，字不重新换行：拉侧边栏时按窗口高度缩，右边裁掉；
        // 拉 action 栏时按窗口宽度缩。内容和缩放都对齐底边，控制区的位置由容器底部 inset 决定。
        let scale = (screen.height - 2 * s * pad) / screen.height * (screen.width - 2 * a * pad) / screen.width
        // 底栏展开时，Home 条安全区随窗口一起保留；侧边栏仍只让出实际覆盖窗口的高度。
        // 换算成缩放前的尺寸，保证缩放后保留的高度不变。
        let coveredByHome = max(homeInset - s * pad, 0) / scale
        // 状态栏、键盘等仍只给覆盖窗口的那一截让位，底部至少保留 Home 条安全区。
        let covered = EdgeInsets(top: max(insets.top - windowInsets.top, 0) / scale,
                                 leading: max(insets.leading - windowInsets.leading, 0) / scale,
                                 bottom: max(max(insets.bottom - windowInsets.bottom, 0) / scale, coveredByHome),
                                 trailing: max(insets.trailing - windowInsets.trailing, 0) / scale)
        return content
            .environment(\.homeIndicatorInset, coveredByHome)
            .environment(\.paneTopSafeInset, covered.top)
            .safeAreaPadding(covered)
            .frame(width: screen.width, height: (screen.height - windowInsets.top - windowInsets.bottom) / scale,
                   alignment: .bottomLeading)
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
            .modifier(WindowProgress(openness: openness, presented: presented))
            .ignoresSafeArea()
    }
}
