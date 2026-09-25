#if os(iOS)
import SwiftUI
import UIKit

/// 拉出来的是哪一侧。
private enum Drawer { case sidebar, actions }

/// iPhone：会话窗口平时铺满屏幕，盖住 App 的底色。从左边缘往右滑或点标题栏左边的按钮，窗口缩到右边，露出底色上的侧边栏；
/// 从控制区往上拖，窗口从上下两头缩小，露出底色上的 action 栏和它上面一行页签。缩小时四边的边距同时出现，
/// 内容不重新换行，只露边距的那个方向等比缩放：让出侧边栏时右边裁掉；让出 action 栏时底下裁掉，内容和浮在底下的控制区往上挪，跟着窗口底边走，
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
///   推过完全打开还能再推出去一截，变形照旧接着走，越推越吃力，最多 Motion.limit；收起的那头不留。
/// - 松手：甩得够快就去甩的那头，不然过半就打开、不到一半收回去；用弹簧带着手指的速度走过去，甩得越快回弹越多，
///   冲过头再回来，冲出去的那截和手指推过头一样吃力。点按钮、点窗口收起也是这一段，没有速度，不回弹、不冲过头。
///   走的途中按住就接着拖，从当时的样子接手；半路改去另一头，带着当时的速度掉头。
private struct PhoneWindow: View {
    @Binding var open: Drawer?
    /// 露出来的一侧：打开着、手指拖着或者正随时间走。
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
    @State private var drive = Drive()
    /// 这次拖动里，手指的位移为 0 时对应打开到几成（按 Motion.finger 的算法，推过头的不加阻尼）。
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

    private var motion: Motion? {
        get { drive.motion }
        nonmutating set { drive.motion = newValue }
    }

    private var rest: Drawer? {
        get { drive.rest }
        nonmutating set { drive.rest = newValue }
    }

    var body: some View {
        // 窗口里的内容在这里建好，逐帧画时不重建。这里不读 drive，它变了这一层不重画
        let pane = pane
        Frames(drive: drive, shown: $shown) { now in
            window(pane, at: now)
        }
        // 点侧边栏里的会话收起：open 在外面改的，到这里才起动画
        .onChange(of: open) { _, new in
            let target = motion.map { $0.to == 1 && $0.finger == nil ? $0.drawer : nil } ?? rest
            if new != target { settle(new) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: crossings)
    }

    /// 从当时的样子走到 drawer 打开，nil 是收起。正在走的带着当时的速度掉头。
    /// 先定好怎么走再改 open，同一次更新里窗口就从原地起步。
    private func settle(_ drawer: Drawer?) {
        let now = Date.now
        if let side = motion?.drawer ?? rest {
            if side != drawer || motion != nil {
                motion = Motion(drawer: side, from: finger(side, at: now), to: side == drawer ? 1 : 0,
                                velocity: motion?.velocity(at: now) ?? 0, start: now)
            }
        } else if let drawer {
            motion = Motion(drawer: drawer, from: 0, to: 1, start: now)
        }
        open = drawer
    }

    /// 聚焦的那个窗口，照铺满屏幕排：抽屉动的时候窗口里不重新排，只整体缩放、挪、裁，见 window。
    @ViewBuilder
    private var pane: some View {
        if let session = model.current {
            // 内容从状态栏、标题栏、控制区和 Home 条后面滚过去
            PaneBody(pane: session.workspace.focused)
                .environment(session)
                .environment(\.drawerPull, open == nil ? pull(.actions) : nil)
                // 一直给着：打开时窗口上盖着一层点了收起的，按钮点不到。有无来回切的话，标题栏会被当成换了一个视图
                .environment(\.openSidebar, { settle(.sidebar) })
                .environment(\.homeIndicatorInset, homeInset)
                .environment(\.keyboardShown, insets.bottom > homeInset + 1)
                .id(session.id)
        }
    }

    /// now 这一刻的窗口。窗口里一直照铺满屏幕、让着状态栏和 Home 条排，抽屉动的时候只变缩放、位置、裁掉多少，
    /// 和控制区、内容往上挪多少（WindowLift）：这些都不重新排版。让出的安全区、窗口的高度要是跟着逐帧变，
    /// 对话每一帧都得重排、重算留白，会掉帧（实测每开关一次可见区高度变三四十次）。
    private func window(_ pane: some View, at now: Date) -> some View {
        let s = progress(.sidebar, at: now)
        let a = progress(.actions, at: now)
        let pad = Metrics.padding
        // 窗口缩进屏幕里，四边的边距随进度出现；拉开的那一侧让出侧边栏，或者让出 action 栏连同上面的页签。
        // 推过完全打开时照样接着变
        let left = s * sidebarWidth + a * pad
        let top = (s + a) * pad
        let right = screen.width - (s + a) * pad
        let bottom = screen.height - s * pad - a * actionsHeight
        let radius = max(screenRadius - (s + a) * pad, 0)
        // 内容贴着窗口左上角等比缩小，字不重新换行：拉侧边栏时按窗口高度缩，右边裁掉；
        // 拉 action 栏时按窗口宽度缩，底下裁掉，控制区和内容往上挪，跟着窗口底边走
        let scale = (screen.height - 2 * s * pad) / screen.height * (screen.width - 2 * a * pad) / screen.width
        // 窗口露出来多大，换算成缩放前的尺寸
        let size = CGSize(width: (right - left) / scale, height: (bottom - top) / scale)
        let shape = WindowShape(size: size, radius: radius / scale)
        // 控制区平时停在 Home 条上面；窗口底边升上来以后，停在 Home 条还盖着的那一截上面，盖得不到 controlMargin 就离底边 controlMargin
        let rise = screen.height - size.height
        let coveredByHome = max(homeInset - (screen.height - bottom), 0) / scale
        let lift = WindowLift(content: rise, controls: rise - homeInset + max(coveredByHome, Metrics.controlMargin),
                              hidesStatus: coveredByHome < Metrics.statusMinHeight)
        return pane
            .environment(\.windowLift, lift)
            .safeAreaPadding(insets)
            .frame(width: screen.width, height: screen.height)
            // 窗口的形状，里面同心的圆角（控制区卡片）跟着它；在缩放前，圆角也换算成缩放前的
            .containerShape(RoundedRectangle(cornerRadius: radius / scale))
            .background(Theme.card)
            .overlay(alignment: .topLeading) {
                if let drawer = open {
                    Color.clear
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { settle(nil) }
                        .gesture(pull(drawer).gesture)
                }
            }
            .overlay(alignment: .leading) {
                if open == nil {
                    Color.clear
                        .frame(width: Metrics.edgeZone)
                        .contentShape(Rectangle())
                        .gesture(pull(.sidebar).gesture)
                }
            }
            // 露出来的那块以外既不画也不接点按：action 栏在它下面
            .clipShape(shape)
            .contentShape(shape)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: left, y: top)
            .ignoresSafeArea()
    }

    private func extent(_ drawer: Drawer) -> CGFloat {
        drawer == .sidebar ? sidebarWidth : actionsHeight
    }

    /// now 这一刻打开到几成，0 是铺满，1 是完全打开，推过完全打开时大于 1。
    private func progress(_ drawer: Drawer, at now: Date) -> CGFloat {
        guard let motion, motion.drawer == drawer, extent(drawer) > 0 else { return rest == drawer ? 1 : 0 }
        return motion.progress(at: now, extent: extent(drawer))
    }

    /// now 这一刻按手指算打开到几成：推过头的那截不加阻尼。
    private func finger(_ drawer: Drawer, at now: Date) -> CGFloat {
        Motion.unstretch(progress(drawer, at: now), extent: extent(drawer))
    }

    /// 手指的位移或速度往打开的方向有多少，换算成几成。
    private func along(_ drawer: Drawer, _ size: CGSize) -> CGFloat {
        guard extent(drawer) > 0 else { return 0 }
        return (drawer == .sidebar ? size.width : -size.height) / extent(drawer)
    }

    /// 往 drawer 那一侧拉。一开始往哪个方向拖就定下来：侧边栏要横着拖，action 栏要竖着拖，
    /// 方向不对的留给拖的地方自己的手势（比如控制区里横着滑选 effort）。另一侧还在走时也不接。
    private func pull(_ drawer: Drawer) -> DrawerPull {
        DrawerPull { moved, _ in
            let extent = extent(drawer)
            if motion?.finger == nil || motion?.drawer != drawer {
                guard !offAxis else { return }
                guard DrawerPull.isHorizontal(moved) == (drawer == .sidebar), motion == nil || motion?.drawer == drawer else {
                    offAxis = true
                    return
                }
                // 接手：从当时的样子（可能正在走）接着拖，窗口不跳
                anchor = finger(drawer, at: .now) - along(drawer, moved)
            }
            let finger = anchor + along(drawer, moved)
            if let last = motion?.finger, (last > 0.5) != (finger > 0.5) { crossings += 1 }
            motion = Motion(drawer: drawer, finger: finger)
        } ended: { velocity in
            offAxis = false
            guard let finger = motion?.finger, motion?.drawer == drawer else { return }
            let speed = along(drawer, velocity)
            let to: CGFloat = abs(speed) * extent(drawer) > Self.flickSpeed ? (speed > 0 ? 1 : 0) : (finger > 0.5 ? 1 : 0)
            // 先定好往哪走再改 open，onChange 看到方向一样就不另起一段
            let bounce = min(abs(speed) * extent(drawer) / Self.fullBounceSpeed, 1) * Self.maxBounce
            motion = Motion(drawer: drawer, from: finger, to: to, velocity: speed, bounce: bounce, start: .now)
            open = to == 1 ? drawer : nil
        }
    }
}

/// 抽屉停在哪、怎么动。放在引用里：只有逐帧画的那一层（Frames）读它，它变了窗口里的内容不跟着重建。
@Observable
private final class Drive {
    var motion: Motion?
    /// 没在动时停在哪一侧打开着。窗口画在哪只看它和 motion，不看 open：open 是要去哪，
    /// 别处改了 open 以后要到 onChange 里才起动画，按 open 画的话中间会先按走完的样子排一遍。
    var rest: Drawer?

    /// 露出来的一侧：打开着、手指拖着或者正在走。
    var side: Drawer? {
        motion?.drawer ?? rest
    }
}

/// 逐帧画窗口的那一层：随时间走时一帧帧画，拖着时跟着手指的位移画。drive 只在这一层读。
private struct Frames<Content: View>: View {
    let drive: Drive
    @Binding var shown: Drawer?
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.animation(paused: drive.motion == nil || drive.motion?.finger != nil)) { context in
            content(context.date)
        }
        .onChange(of: drive.side) { _, side in shown = side }
        // 走完就停下；多等一点，最后一帧落在走完以后
        .task(id: drive.motion) {
            guard let motion = drive.motion, motion.finger == nil else { return }
            guard (try? await Task.sleep(for: .seconds(motion.end.timeIntervalSinceNow + 0.05))) != nil else { return }
            drive.rest = motion.to == 1 ? motion.drawer : nil
            drive.motion = nil
        }
    }
}

/// 窗口露出来的那块：从左上角起 size 那么大的圆角矩形，缩放前的坐标。
nonisolated private struct WindowShape: Shape {
    let size: CGSize
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: CGRect(origin: rect.origin, size: size), cornerRadius: radius, style: .continuous)
    }
}

/// 抽屉在动：手指拖着，或者松手后弹簧走的一段。打开到几成都先按手指算（推过头的那截不加阻尼），显示时再加阻尼。
private struct Motion: Equatable {
    let drawer: Drawer
    /// 手指拖着时打开到几成。松手后是 nil。
    var finger: CGFloat?
    /// 松手后从 from 起、带着速度 velocity（每秒几成，往打开的方向为正）走到 to（0 收起，1 打开）。
    var from: CGFloat = 0
    var to: CGFloat = 0
    var velocity: CGFloat = 0
    /// 弹簧的回弹，0 是临界阻尼：没有速度时直接停在终点，不来回晃。
    var bounce = 0.0
    var start = Date.distantPast

    /// 推过完全打开最多再出去多少点。
    static let limit: CGFloat = 32
    private var spring: Spring {
        Spring(duration: 0.4, bounce: bounce)
    }

    /// now 这一刻按手指算打开到几成。
    private func raw(at now: Date) -> CGFloat {
        if let finger { return finger }
        return from + spring.value(target: to - from, initialVelocity: velocity, time: now.timeIntervalSince(start))
    }

    /// now 这一刻打开到几成：推过完全打开的那截加上阻尼；收起的那头不过去。
    func progress(at now: Date, extent: CGFloat) -> CGFloat {
        let x = raw(at: now)
        return x <= 1 ? max(x, 0) : 1 + Self.stretch((x - 1) * extent) / extent
    }

    /// now 这一刻的速度，每秒几成；拖着时按 0 算。
    func velocity(at now: Date) -> CGFloat {
        guard finger == nil else { return 0 }
        return spring.velocity(target: to - from, initialVelocity: velocity, time: now.timeIntervalSince(start))
    }

    /// 走完的那一刻，差不到千分之一算停下；拖着时不走。
    var end: Date {
        guard finger == nil else { return .distantPast }
        return start + spring.settlingDuration(target: to - from, initialVelocity: velocity, epsilon: 0.001)
    }

    /// 打开到 progress 时手指该在几成：progress 反过来。
    static func unstretch(_ progress: CGFloat, extent: CGFloat) -> CGFloat {
        guard progress > 1 else { return progress }
        let y = min((progress - 1) * extent, limit * 0.99)
        return 1 + limit * y / (limit - y) / extent
    }

    /// 手指推过头 x 点，窗口多走多少：起初跟手，越推越吃力，不超过 limit。
    private static func stretch(_ x: CGFloat) -> CGFloat {
        limit * x / (x + limit)
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
