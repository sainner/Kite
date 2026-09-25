#if os(iOS)
import SwiftUI
import UIKit

/// 拉出来的是哪一侧。
private enum Drawer { case sidebar, actions }

/// iPhone：会话窗口平时铺满屏幕，盖住 App 的底色。从左边缘往右滑或点标题栏左边的按钮，窗口缩到右边，露出底色上的侧边栏；
/// 从控制区往上拖，窗口从上下两头缩小，露出底色上的 action 栏和它上面一行页签。缩小时四边的边距同时出现，
/// 内容不重新换行，只露边距的那个方向等比缩放：让出侧边栏时右边裁掉；让出 action 栏时内容变矮，浮在底下的控制区跟着窗口底边走，
/// 圆角从屏幕圆角变成屏幕圆角减去边距。
/// 打开时点窗口或往回拖收起。
struct PhoneLayout: View {
    @Environment(AppModel.self) private var model

    @State private var open: Drawer?
    /// 露出来的一侧：打开着、手指拖着或者正随时间走。动的进度每一帧都变，放在 PhoneWindow 里，只有窗口跟着重画。
    @State private var shown: Drawer?
    /// 屏幕圆角，读到之前按 0 算：铺满时窗口的角本来就被屏幕圆角盖住。
    @State private var screenRadius: CGFloat = 0
    /// 页签和 action 栏合起来多高，按实际排出来的量。
    @State private var drawerHeight: CGFloat = 0
    @State private var indicatorHidden = false
    /// Home 条让出的那一截，不含键盘，从 UIKit 读；读到之前按 SwiftUI 的算。
    @State private var homeInset: CGFloat?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            // SwiftUI 的安全区把状态栏、Home 条和键盘合在一起（分区只能用来忽略，读不出各占多少）
            let insets = geo.safeAreaInsets
            let screen = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                                height: geo.size.height + insets.top + insets.bottom)
            let home = homeInset ?? insets.bottom
            // 侧边栏拉开后，窗口至少留下 phoneMinWindow 宽
            let sidebarWidth = min(screen.width - Metrics.padding - Metrics.phoneMinWindow, 320)
            // 窗口底边要升到页签上面，页签在 action 栏上面，action 栏在 Home 条上面
            let actionsHeight = drawerHeight + home + Metrics.padding
            let current = model.current?.id
            ZStack(alignment: .topLeading) {
                Theme.background.ignoresSafeArea()
                ScreenReader { radius, bottom in
                    screenRadius = radius
                    homeInset = bottom
                }
                .ignoresSafeArea()
                // 会话列表，点一个就切过去并收起。一次只露出一侧，另一侧藏起来，免得窗口移开时从边上露出来
                VStack(spacing: 4) {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session, current: current == session.id, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selected = session.id
                                open = nil
                            }
                    }
                }
                .padding(.top, Metrics.padding * 2)
                .padding(.leading, Metrics.padding + Metrics.sidebarLeading)
                .padding(.trailing, Metrics.gap)
                .frame(width: sidebarWidth)
                .opacity(showing(.sidebar) ? 1 : 0)
                // 拉出 action 栏时，它上面同时露出页签那一行
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    tabBar.frame(height: Metrics.tabBar)
                    ActionArea()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drawerHeight = $0 }
                .padding(.horizontal, Metrics.padding * 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(showing(.actions) ? 1 : 0)
            }
            // 窗口铺满整个屏幕，放在 overlay 里，不把上面这层撑出安全区，action 栏才能留在 Home 条上面
            .overlay(alignment: .topLeading) {
                PhoneWindow(open: $open, shown: $shown, screen: screen, insets: insets, homeInset: home,
                            sidebarWidth: sidebarWidth, actionsHeight: actionsHeight, screenRadius: screenRadius)
            }
        }
        // 让小横条藏起来，空出来的地方放控制区底下的状态信息。它只在进 App 时（打开、从后台回来）出来一下，
        // 碰屏幕、滚动都不再出来。系统不告诉 App 它藏没藏：实测 App 画出第一帧时它已经藏了，这里进来后等 1 秒算它藏了
        .persistentSystemOverlays(.hidden)
        .environment(\.homeIndicatorHidden, indicatorHidden)
        .task(id: scenePhase) {
            indicatorHidden = false
            guard scenePhase == .active, (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            indicatorHidden = true
        }
    }

    /// 页签：当前会话窗口组里的各个窗口，点了切过去。iPhone 上一次只显示一个窗口，不做换位置。以后这一行还会放别的功能。
    @ViewBuilder
    private var tabBar: some View {
        if let workspace = model.current?.workspace {
            HStack(spacing: 8) {
                ForEach(workspace.root.panes, id: \.self) { pane in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(pane.tint.opacity(pane == workspace.focused ? 1 : 0.25))
                        .frame(width: 56, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.focused = pane }
                }
            }
        }
    }

    private func showing(_ drawer: Drawer) -> Bool {
        shown == drawer
    }
}

/// 会话窗口，和拉出侧边栏、action 栏的手势。
///
/// 打开、收起分两段，照系统可交互转场的做法：
/// - 拖着：窗口跟着手指走，挪多少走多少，拖回去就收回来；越过一半时轻震一下，松手就会去这一头。
///   推过完全打开还能再推出去一截，变形照旧接着走，越推越吃力，最多 Openness.limit；收起的那头不留。
/// - 松手：甩得够快就去甩的那头，不然过半就打开、不到一半收回去；用弹簧带着手指的速度走过去，甩得越快回弹越多，
///   冲过头再回来，冲出去的那截和手指推过头一样吃力。点按钮、点窗口收起也是这一段，没有速度，不回弹、不冲过头。
///   走的途中按住就接着拖，从当时的样子接手；半路改去另一头，带着当时的速度掉头。
/// 照 Apple 的做法（WWDC24「Enhance your UI animations and transitions」）都交给 SwiftUI 的弹簧动画，由它逐帧插值（WindowPlacement）：
/// 拖着时每挪一下用 interactiveSpring 改一次，一个接着一个；松手用 spring，它接着拖动时的速度走，不用自己算初速度。
/// 自己按时间逐帧算的话，松手后掉帧，拖着时不掉。
private struct PhoneWindow: View {
    @Binding var open: Drawer?
    /// 露出来的一侧：打开着、手指拖着或者正在走。
    @Binding var shown: Drawer?
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
    /// 这一帧窗口实际摆到几成，WindowPlacement 每一帧写进来。手指半路接住时从这里接着拖。
    @State private var presented = Presented()
    /// 手指正拖着的一侧。
    @State private var dragging: Drawer?
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
        Group {
            if let session = model.current {
                // 聚焦的那个窗口铺满，内容从状态栏、标题栏、控制区和 Home 条后面滚过去
                PaneBody(pane: session.workspace.focused)
                    .environment(session)
                    .environment(\.drawerPull, open == nil ? pull(.actions) : nil)
                    // 一直给着：打开时窗口上盖着一层点了收起的，按钮点不到。有无来回切的话，标题栏会被当成换了一个视图
                    .environment(\.openSidebar, { settle(.sidebar) })
                    .environment(\.keyboardShown, insets.bottom > homeInset + 1)
                    .id(session.id)
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
    private func settle(_ drawer: Drawer?) {
        let spring = Animation.spring(duration: Self.duration, bounce: 0)
        for side in [Drawer.sidebar, .actions] where side != drawer && target[side] != 0 {
            animate(side, to: 0, with: spring)
        }
        if let drawer, target[drawer] != 1 {
            animate(drawer, to: 1, with: spring)
        }
        open = drawer
    }

    /// 带着动画让 drawer 那一侧走到 value。收起的走完了才藏起那一侧。
    private func animate(_ drawer: Drawer, to value: CGFloat, with animation: Animation) {
        shown = drawer
        withAnimation(animation, completionCriteria: .removed) {
            target[drawer] = value
        } completion: {
            // 中间又拉开、又拖起来的不藏
            if target[drawer] == 0, dragging != drawer, shown == drawer { shown = nil }
        }
    }

    private func extent(_ drawer: Drawer) -> CGFloat {
        drawer == .sidebar ? sidebarWidth : actionsHeight
    }

    /// 手指的位移或速度往打开的方向有多少，换算成几成。
    private func along(_ drawer: Drawer, _ size: CGSize) -> CGFloat {
        guard extent(drawer) > 0 else { return 0 }
        return (drawer == .sidebar ? size.width : -size.height) / extent(drawer)
    }

    /// 往 drawer 那一侧拉。一开始往哪个方向拖就定下来：侧边栏要横着拖，action 栏要竖着拖，
    /// 方向不对的留给拖的地方自己的手势（比如控制区里横着滑选 effort）。另一侧没收好时也不接。
    private func pull(_ drawer: Drawer) -> DrawerPull {
        DrawerPull { moved, _ in
            let other: Drawer = drawer == .sidebar ? .actions : .sidebar
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

/// 两侧各打开到几成，0 是铺满，1 是完全打开。按手指算：推过完全打开的那截不加阻尼，摆的时候再加（shown(_:extent:)）。
private struct Openness: Equatable {
    var sidebar: CGFloat = 0
    var actions: CGFloat = 0

    /// 推过完全打开最多再出去多少点。
    static let limit: CGFloat = 32

    subscript(drawer: Drawer) -> CGFloat {
        get { drawer == .sidebar ? sidebar : actions }
        set { if drawer == .sidebar { sidebar = newValue } else { actions = newValue } }
    }

    /// 完全打开着的一侧。
    var opened: Drawer? {
        sidebar == 1 ? .sidebar : actions == 1 ? .actions : nil
    }

    /// 摆出来打开到几成：推过完全打开的那截加上阻尼，起初跟手，越推越吃力，最多出去 limit 点；收起的那头不过去。
    static func shown(_ x: CGFloat, extent: CGFloat) -> CGFloat {
        guard x > 1, extent > 0 else { return max(x, 0) }
        let over = (x - 1) * extent
        return 1 + limit * over / (over + limit) / extent
    }
}

/// 这一帧窗口实际摆到几成。放在引用里，WindowPlacement 每一帧写，不引起重画。
private final class Presented {
    var openness = Openness()
}

/// 按两侧打开到几成摆窗口。动画途中 SwiftUI 每一帧插值 openness 再调一次 body。
private struct WindowPlacement<Overlay: View>: ViewModifier, Animatable {
    var openness: Openness
    let screen: CGSize
    let insets: EdgeInsets
    let homeInset: CGFloat
    let sidebarWidth: CGFloat
    let actionsHeight: CGFloat
    let screenRadius: CGFloat
    let presented: Presented
    let overlay: Overlay

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(openness.sidebar, openness.actions) }
        set { openness = Openness(sidebar: newValue.first, actions: newValue.second) }
    }

    func body(content: Content) -> some View {
        presented.openness = openness
        let s = Openness.shown(openness.sidebar, extent: sidebarWidth)
        let a = Openness.shown(openness.actions, extent: actionsHeight)
        let pad = Metrics.padding
        // 窗口缩进屏幕里，四边的边距随进度出现；拉开的那一侧让出侧边栏，或者让出 action 栏连同上面的页签。
        // 推过完全打开时照样接着变
        let left = s * sidebarWidth + a * pad
        let top = (s + a) * pad
        let right = screen.width - (s + a) * pad
        let bottom = screen.height - s * pad - a * actionsHeight
        let radius = max(screenRadius - (s + a) * pad, 0)
        let shape = RoundedRectangle(cornerRadius: radius)
        // 内容贴着窗口左上角等比缩小，宽度照铺满时排，字不重新换行：拉侧边栏时按窗口高度缩，右边裁掉；
        // 拉 action 栏时按窗口宽度缩，高度只排到窗口底边，控制区这些浮在底下的跟着窗口底边走
        let scale = (screen.height - 2 * s * pad) / screen.height * (screen.width - 2 * a * pad) / screen.width
        // 窗口里只给状态栏、Home 条、键盘还盖着窗口的那一截让位：窗口移开多少就少让多少，换算成缩放前的尺寸
        let covered = EdgeInsets(top: max(insets.top - top, 0) / scale,
                                 leading: max(insets.leading - left, 0) / scale,
                                 bottom: max(insets.bottom - (screen.height - bottom), 0) / scale,
                                 trailing: max(insets.trailing - (screen.width - right), 0) / scale)
        let coveredByHome = max(homeInset - (screen.height - bottom), 0) / scale
        return content
            .environment(\.homeIndicatorInset, coveredByHome)
            .safeAreaPadding(covered)
            .frame(width: screen.width, height: (bottom - top) / scale, alignment: .topLeading)
            // 窗口的形状，里面同心的圆角（控制区卡片）跟着它；在缩放前，圆角也换算成缩放前的
            .containerShape(RoundedRectangle(cornerRadius: radius / scale))
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: right - left, height: bottom - top, alignment: .topLeading)
            .background(Theme.card)
            .clipShape(shape)
            .contentShape(shape)
            .overlay { overlay }
            .offset(x: left, y: top)
            .ignoresSafeArea()
    }
}

/// 用一个铺满屏幕的 UIView 读 SwiftUI 读不到的两样：
/// - 屏幕圆角：圆角和容器同心的 UIView，它的实际圆角就是屏幕圆角（iOS 26 起的公开接口）。
/// - Home 条让出的那一截：UIKit 的安全区不含键盘，键盘另有 keyboardLayoutGuide。
///   SwiftUI 的安全区分成 container 和 keyboard 两区，但只能按区忽略，读出来的是合在一起的。
private struct ScreenReader: UIViewRepresentable {
    let onRead: (_ radius: CGFloat, _ bottom: CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.cornerConfiguration = .corners(radius: .containerConcentric())
        view.onRead = onRead
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.onRead = onRead
    }

    final class Probe: UIView {
        var onRead: ((CGFloat, CGFloat) -> Void)?
        private var last: (radius: CGFloat, bottom: CGFloat)?

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let radius = effectiveRadius(corner: .topLeft)
            let bottom = safeAreaInsets.bottom
            guard radius != last?.radius || bottom != last?.bottom, let onRead else { return }
            last = (radius, bottom)
            // 不在布局过程中改 SwiftUI 的状态
            Task { onRead(radius, bottom) }
        }
    }
}

#endif
