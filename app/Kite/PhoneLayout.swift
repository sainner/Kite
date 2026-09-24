#if os(iOS)
import SwiftUI
import UIKit

/// iPhone：会话窗口平时铺满屏幕，盖住 App 的底色。从左边缘往右滑或点标题栏左边的按钮，窗口缩到右边，露出底色上的侧边栏；
/// 从控制区往上拖，窗口从上下两头缩小，露出底色上的 action 栏和它上面一行页签。缩小时四边的边距同时出现，
/// 内容不重新换行，只露边距的那个方向等比缩放：让出侧边栏时右边裁掉；让出 action 栏时内容变矮，浮在底下的控制区跟着窗口底边走，
/// 圆角从屏幕圆角变成屏幕圆角减去边距。
/// 打开时点窗口或往回拖收起。
/// 拉出来的是哪一侧。
private enum Drawer { case sidebar, actions }

struct PhoneLayout: View {
    @Environment(AppModel.self) private var model

    @State private var open: Drawer?
    /// 手指正在拖的一侧。拖动的距离每一帧都变，放在 PhoneWindow 里，只有窗口跟着重画。
    @State private var dragging: Drawer?
    /// 屏幕圆角，读到之前按 0 算：铺满时窗口的角本来就被屏幕圆角盖住。
    @State private var screenRadius: CGFloat = 0
    /// 页签和 action 栏合起来多高，按实际排出来的量。
    @State private var drawerHeight: CGFloat = 0
    @State private var indicatorHidden = false
    /// 状态栏、Home 条让出的安全区，不含键盘，从 UIKit 读；读到之前按 SwiftUI 的算。
    @State private var systemInsets: EdgeInsets?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            // SwiftUI 的安全区把状态栏、Home 条和键盘合在一起（分区只能用来忽略，读不出各占多少）
            let insets = geo.safeAreaInsets
            let screen = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                                height: geo.size.height + insets.top + insets.bottom)
            let system = systemInsets ?? insets
            // 侧边栏拉开后，窗口至少留下 phoneMinWindow 宽
            let sidebarWidth = min(screen.width - Metrics.padding - Metrics.phoneMinWindow, 320)
            // 窗口底边要升到页签上面，页签在 action 栏上面，action 栏在 Home 条上面
            let actionsHeight = drawerHeight + system.bottom + Metrics.padding
            let current = model.current?.id
            ZStack(alignment: .topLeading) {
                Theme.background.ignoresSafeArea()
                ScreenReader { radius, insets in
                    screenRadius = radius
                    systemInsets = insets
                }
                .ignoresSafeArea()
                // 会话列表，点一个就切过去并收起。一次只露出一侧，另一侧藏起来，免得窗口移开时从边上露出来
                VStack(spacing: 4) {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session, current: current == session.id, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selected = session.id
                                withAnimation(.snappy) { open = nil }
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
                PhoneWindow(open: $open, dragging: $dragging, screen: screen, insets: insets, homeInset: system.bottom,
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
        open == drawer || dragging == drawer
    }
}

/// 会话窗口，和拉出侧边栏、action 栏的手势。
private struct PhoneWindow: View {
    @Binding var open: Drawer?
    @Binding var dragging: Drawer?
    let screen: CGSize
    /// 屏幕四边被盖着的：状态栏、Home 条，键盘升起来时底下是键盘。
    let insets: EdgeInsets
    /// 其中 Home 条那一截，不含键盘。
    let homeInset: CGFloat
    let sidebarWidth: CGFloat
    let actionsHeight: CGFloat
    let screenRadius: CGFloat
    @Environment(AppModel.self) private var model
    @State private var translation: CGSize = .zero
    /// 这次拖的方向不对，不拉抽屉，松手前都不管。
    @State private var offAxis = false

    var body: some View {
        let s = progress(.sidebar, extent: sidebarWidth)
        let a = progress(.actions, extent: actionsHeight)
        let pad = Metrics.padding
        // 窗口缩进屏幕里，四边的边距随进度出现；拉开的那一侧让出侧边栏，或者让出 action 栏连同上面的页签
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
        Group {
            if let session = model.current {
                // 聚焦的那个窗口铺满，内容从状态栏、标题栏、控制区和 Home 条后面滚过去
                PaneBody(pane: session.workspace.focused)
                    .environment(session)
                    .environment(\.drawerPull, open == nil ? pull(.actions, extent: actionsHeight) : nil)
                    // 一直给着：打开时窗口上盖着一层点了收起的，按钮点不到。有无来回切的话，标题栏会被当成换了一个视图
                    .environment(\.openSidebar, { settle(.sidebar) })
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
                    .onTapGesture { settle(nil) }
                    .gesture(pull(drawer, extent: drawer == .sidebar ? sidebarWidth : actionsHeight).gesture)
            }
        }
        .overlay(alignment: .leading) {
            if open == nil {
                Color.clear
                    .frame(width: Metrics.edgeZone)
                    .contentShape(Rectangle())
                    .gesture(pull(.sidebar, extent: sidebarWidth).gesture)
            }
        }
        .offset(x: left, y: top)
        .ignoresSafeArea()
    }

    /// 打开到几成，0 是铺满，1 是完全打开。
    private func progress(_ drawer: Drawer, extent: CGFloat) -> CGFloat {
        guard dragging == drawer, extent > 0 else { return open == drawer ? 1 : 0 }
        return min(max(fraction(drawer, moved: translation, extent: extent), 0), 1)
    }

    /// 从拖动前的状态往打开方向挪了 moved，换算成打开到几成，不截断。
    private func fraction(_ drawer: Drawer, moved: CGSize, extent: CGFloat) -> CGFloat {
        (open == drawer ? 1 : 0) + (drawer == .sidebar ? moved.width : -moved.height) / extent
    }

    /// 往 drawer 那一侧拉。一开始往哪个方向拖就定下来：侧边栏要横着拖，action 栏要竖着拖，
    /// 方向不对的留给拖的地方自己的手势（比如控制区里横着滑选 effort）。松手时按预计停下的位置，过半就打开，否则收回去。
    private func pull(_ drawer: Drawer, extent: CGFloat) -> DrawerPull {
        DrawerPull { moved in
            if dragging != drawer {
                guard !offAxis else { return }
                guard (abs(moved.width) > abs(moved.height)) == (drawer == .sidebar) else {
                    offAxis = true
                    return
                }
                dragging = drawer
            }
            translation = moved
        } ended: { predicted in
            offAxis = false
            guard dragging == drawer else { return }
            settle(fraction(drawer, moved: predicted, extent: extent) > 0.5 ? drawer : nil)
        }
    }

    private func settle(_ drawer: Drawer?) {
        withAnimation(.snappy) {
            open = drawer
            dragging = nil
            translation = .zero
        }
    }
}

/// 用一个铺满屏幕的 UIView 读 SwiftUI 读不到的两样：
/// - 屏幕圆角：圆角和容器同心的 UIView，它的实际圆角就是屏幕圆角（iOS 26 起的公开接口）。
/// - 状态栏、Home 条让出的安全区：UIKit 的安全区不含键盘，键盘另有 keyboardLayoutGuide。
///   SwiftUI 的安全区分成 container 和 keyboard 两区，但只能按区忽略，读出来的是合在一起的。
private struct ScreenReader: UIViewRepresentable {
    let onRead: (_ radius: CGFloat, _ insets: EdgeInsets) -> Void

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
        var onRead: ((CGFloat, EdgeInsets) -> Void)?
        private var last: (radius: CGFloat, insets: UIEdgeInsets)?

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let radius = effectiveRadius(corner: .topLeft)
            let insets = safeAreaInsets
            guard radius != last?.radius || insets != last?.insets, let onRead else { return }
            last = (radius, insets)
            let edges = EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
            // 不在布局过程中改 SwiftUI 的状态
            Task { onRead(radius, edges) }
        }
    }
}

#endif
