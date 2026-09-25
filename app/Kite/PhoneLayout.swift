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
    /// 在动的一侧：手指拖着，或者正随时间走。动的进度每一帧都变，放在 PhoneWindow 里，只有窗口跟着重画。
    @State private var moving: Drawer?
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
                PhoneWindow(open: $open, moving: $moving, screen: screen, insets: insets, homeInset: home,
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
        open == drawer || moving == drawer
    }
}

/// 会话窗口，和拉出侧边栏、action 栏的手势。
///
/// 打开、收起分两段，照系统可交互转场的做法：
/// - 拖着：窗口跟着手指走，挪多少走多少，拖回去就收回来。推过完全打开还能再推出去一截，越推越吃力，最多 Motion.limit；收起的那头不留。
/// - 松手：甩得够快就去甩的那头，不然过半就打开、不到一半收回去；随时间先快后慢地走过去，不过冲，起步跟上手指的速度。
///   点按钮、点窗口收起也是这一段，只是没有手指的速度。走的途中按住就接着拖，从当时的样子接手。
private struct PhoneWindow: View {
    @Binding var open: Drawer?
    /// 在动的一侧：手指拖着，或者正随时间走。
    @Binding var moving: Drawer?
    let screen: CGSize
    /// 屏幕四边被盖着的：状态栏、Home 条，键盘升起来时底下是键盘。
    let insets: EdgeInsets
    /// 其中 Home 条那一截，不含键盘。
    let homeInset: CGFloat
    let sidebarWidth: CGFloat
    let actionsHeight: CGFloat
    let screenRadius: CGFloat
    @Environment(AppModel.self) private var model
    @State private var motion: Motion?
    /// 这次拖动里，手指的位移为 0 时对应打开到几成（按 Motion.finger 的算法，推过头的不加阻尼）。
    @State private var anchor: CGFloat = 0
    /// 在走，要一帧帧画。
    @State private var playing = false
    /// 这次拖的方向不对，不拉抽屉，松手前都不管。
    @State private var offAxis = false

    /// 从一头走到另一头多久；短的按距离的平方根缩短，不短于 minSweep。
    private static let fullSweep = 0.35
    private static let minSweep = 0.15
    /// 松手时甩多快（点每秒）算甩，按甩的方向定去哪头。
    private static let flickSpeed: CGFloat = 300

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            window(at: context.date)
        }
        .onChange(of: open) { old, new in
            // 别处改的（标题栏的按钮、点窗口收起、点侧边栏里的会话）：从当时的样子随时间走过去。松手时已经定好往哪走的不管
            guard let drawer = new ?? old else { return }
            let to: CGFloat = new == drawer ? 1 : 0
            let now = Date.now
            var from = old == drawer ? 1.0 : 0
            if let motion, motion.drawer == drawer {
                guard motion.finger != nil || motion.to != to else { return }
                from = motion.progress(at: now, extent: extent(drawer))
            }
            motion = sweep(drawer, from: from, to: to, speed: 0, at: now)
        }
        .onChange(of: motion?.drawer) { moving = motion?.drawer }
        // 走完就停下，不再一帧帧画；多等一点，最后一帧落在走完以后。松手后走完就不动了
        .task(id: motion) {
            guard let motion else { return }
            playing = motion.end > .now
            if playing, (try? await Task.sleep(for: .seconds(motion.end.timeIntervalSinceNow + 0.05))) == nil { return }
            playing = false
            if motion.finger == nil { self.motion = nil }
        }
    }

    private func window(at now: Date) -> some View {
        let s = progress(.sidebar, at: now)
        let a = progress(.actions, at: now)
        // 推过完全打开的那一截只往拉开的方向走：侧边栏那边窗口整个往右挪，action 栏那边窗口底边接着往上
        let s1 = min(s, 1), a1 = min(a, 1)
        let pad = Metrics.padding
        // 窗口缩进屏幕里，四边的边距随进度出现；拉开的那一侧让出侧边栏，或者让出 action 栏连同上面的页签
        let beyond = (s - s1) * sidebarWidth
        let left = s1 * sidebarWidth + a1 * pad + beyond
        let top = (s1 + a1) * pad
        let right = screen.width - (s1 + a1) * pad + beyond
        let bottom = screen.height - s1 * pad - a * actionsHeight
        let radius = max(screenRadius - (s1 + a1) * pad, 0)
        let shape = RoundedRectangle(cornerRadius: radius)
        // 内容贴着窗口左上角等比缩小，宽度照铺满时排，字不重新换行：拉侧边栏时按窗口高度缩，右边裁掉；
        // 拉 action 栏时按窗口宽度缩，高度只排到窗口底边，控制区这些浮在底下的跟着窗口底边走
        let scale = (screen.height - 2 * s1 * pad) / screen.height * (screen.width - 2 * a1 * pad) / screen.width
        // 窗口里只给状态栏、Home 条、键盘还盖着窗口的那一截让位：窗口移开多少就少让多少，换算成缩放前的尺寸
        let covered = EdgeInsets(top: max(insets.top - top, 0) / scale,
                                 leading: max(insets.leading - left, 0) / scale,
                                 bottom: max(insets.bottom - (screen.height - bottom), 0) / scale,
                                 trailing: max(insets.trailing - (screen.width - right), 0) / scale)
        let coveredByHome = max(homeInset - (screen.height - bottom), 0) / scale
        return Group {
            if let session = model.current {
                // 聚焦的那个窗口铺满，内容从状态栏、标题栏、控制区和 Home 条后面滚过去
                PaneBody(pane: session.workspace.focused)
                    .environment(session)
                    .environment(\.drawerPull, open == nil ? pull(.actions) : nil)
                    // 一直给着：打开时窗口上盖着一层点了收起的，按钮点不到。有无来回切的话，标题栏会被当成换了一个视图
                    .environment(\.openSidebar, { open = .sidebar })
                    .environment(\.homeIndicatorInset, coveredByHome)
                    .environment(\.keyboardShown, insets.bottom > homeInset + 1)
                    .id(session.id)
            }
        }
        .safeAreaPadding(covered)
        .frame(width: screen.width, height: (bottom - top) / scale, alignment: .topLeading)
        // 窗口的形状，里面同心的圆角（控制区卡片）跟着它；在缩放前，圆角也换算成缩放前的
        .containerShape(RoundedRectangle(cornerRadius: radius / scale))
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: right - left, height: bottom - top, alignment: .topLeading)
        .background(Theme.card)
        .clipShape(shape)
        .contentShape(shape)
        .overlay {
            if let drawer = open {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { open = nil }
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
        .offset(x: left, y: top)
        .ignoresSafeArea()
    }

    private func extent(_ drawer: Drawer) -> CGFloat {
        drawer == .sidebar ? sidebarWidth : actionsHeight
    }

    /// now 这一刻打开到几成，0 是铺满，1 是完全打开，推过完全打开时大于 1。
    private func progress(_ drawer: Drawer, at now: Date) -> CGFloat {
        guard let motion, motion.drawer == drawer, extent(drawer) > 0 else { return open == drawer ? 1 : 0 }
        return motion.progress(at: now, extent: extent(drawer))
    }

    /// 手指的位移或速度往打开的方向有多少，换算成几成。
    private func along(_ drawer: Drawer, _ size: CGSize) -> CGFloat {
        guard extent(drawer) > 0 else { return 0 }
        return (drawer == .sidebar ? size.width : -size.height) / extent(drawer)
    }

    /// 从 now 起由 from 随时间走到 to。speed 是手指往 to 那头的速度（每秒几成）：先快后慢的曲线起步是平均速度的 3 倍，
    /// 手指快的话缩短时间让起步跟上手指。
    private func sweep(_ drawer: Drawer, from: CGFloat, to: CGFloat, speed: CGFloat, at now: Date) -> Motion {
        let distance = Double(abs(to - from))
        var duration = max(Self.fullSweep * distance.squareRoot(), Self.minSweep)
        if speed > 0 { duration = max(min(duration, 3 * distance / Double(speed)), Self.minSweep) }
        return Motion(drawer: drawer, from: from, to: to, start: now, duration: duration)
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
                anchor = Motion.unstretch(progress(drawer, at: .now), extent: extent) - along(drawer, moved)
            }
            motion = Motion(drawer: drawer, finger: anchor + along(drawer, moved))
        } ended: { velocity in
            offAxis = false
            guard let motion, motion.drawer == drawer, motion.finger != nil else { return }
            let now = Date.now
            let current = motion.progress(at: now, extent: extent(drawer))
            let speed = along(drawer, velocity)
            let to: CGFloat = abs(speed) * extent(drawer) > Self.flickSpeed ? (speed > 0 ? 1 : 0) : (current > 0.5 ? 1 : 0)
            // 先定好往哪走再改 open，onChange 看到方向一样就不另起一段
            self.motion = sweep(drawer, from: current, to: to, speed: to == 1 ? speed : -speed, at: now)
            open = to == 1 ? drawer : nil
        }
    }
}

/// 抽屉在动：手指拖着，或者松手后随时间走的一段。
private struct Motion: Equatable {
    let drawer: Drawer
    /// 手指拖着时打开到几成，不截断：大于 1 的是推过头的手指距离，显示时按 stretch 加阻尼。松手后是 nil。
    var finger: CGFloat?
    /// 松手后从 from 走到 to（0 收起，1 打开），走 duration 秒，先快后慢。from 可以大于 1：从推过头的地方走回来。
    var from: CGFloat = 0
    var to: CGFloat = 0
    var start = Date.distantPast
    var duration = 0.0

    /// 推过完全打开最多再出去多少点。
    static let limit: CGFloat = 32

    /// now 这一刻打开到几成。
    func progress(at now: Date, extent: CGFloat) -> CGFloat {
        if let finger {
            return finger <= 1 ? max(finger, 0) : 1 + Self.stretch((finger - 1) * extent) / extent
        }
        let t = now.timeIntervalSince(start) / duration
        return from + (to - from) * UnitCurve.easeOutCubic.value(at: min(max(t, 0), 1))
    }

    /// 走完的那一刻；拖着时不走。
    var end: Date {
        finger == nil ? start + duration : .distantPast
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
