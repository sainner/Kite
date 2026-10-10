import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 紧凑布局：会话窗口平时铺满窗口，盖住 App 的底色。从左边缘往右滑或点标题栏左边的按钮，窗口缩到右边，侧边栏贴着窗口左边从左滑入；
/// 从控制区往上拖，窗口从上下两头缩小，露出底色上的 action 栏和它上面一行页签。缩小时四边的边距同时出现，
/// 内容不重新换行，只露边距的那个方向等比缩放：让出侧边栏时右边裁掉；让出 action 栏时内容变矮，浮在底下的控制区跟着窗口底边走，
/// 圆角从屏幕圆角变成屏幕圆角减去边距。
/// 打开时点窗口或往回拖收起。
struct CompactLayout: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.windowChrome) private var chrome
    #endif

    @State private var open: WorkspaceDrawer?
    /// 露出来的一侧：打开着、手指拖着或者正随时间走。
    @State private var shown: WorkspaceDrawer?
    /// 侧边栏打开到几成，CompactWindow 和窗口一起改，侧栏只有平移跟着更新。
    @State private var sidebarProgress = SidebarProgress()
    /// 屏幕圆角，读到之前按 0 算：铺满时窗口的角本来就被屏幕圆角盖住。
    @State private var screenRadius: CGFloat = 0
    /// 页签和 action 栏合起来多高，按实际排出来的量。
    @State private var drawerHeight: CGFloat = 0
    /// Home 条让出的那一截，不含键盘，从 UIKit 读；读到之前按 SwiftUI 的算。
    @State private var homeInset: CGFloat?
    /// 根视图的左右边距，从 UIKit 读，给窗口里的分组表单，见 pageForm。
    @State private var formMargin: CGFloat?

    var body: some View {
        GeometryReader { geo in
            // SwiftUI 的安全区把状态栏、Home 条和键盘合在一起（分区只能用来忽略，读不出各占多少）
            let safe = geo.safeAreaInsets
            #if os(macOS)
            let insets = EdgeInsets(top: max(safe.top, chrome.top), leading: safe.leading,
                                    bottom: safe.bottom, trailing: safe.trailing)
            #else
            let insets = safe
            #endif
            let screen = CGSize(width: geo.size.width + safe.leading + safe.trailing,
                                height: geo.size.height + safe.top + safe.bottom)
            let home = homeInset ?? insets.bottom
            // 侧边栏拉开后，窗口收成竖着的胶囊：宽度等于此时圆角（屏幕圆角减去边距）的直径，其余宽度都给侧边栏。
            // 没有屏幕圆角（Mac、还没读到）或圆角小到点不着时，窗口留 phoneMinWindow 宽，侧边栏不超过 312
            let capsule = 2 * (screenRadius - Metrics.padding)
            let sidebarWidth = capsule >= Metrics.phoneMinCapsule
                ? screen.width - Metrics.padding - capsule
                : DotMetrics.snapDown(min(screen.width - Metrics.padding - Metrics.phoneMinWindow, 312))
            // 窗口底边要升到页签上面，页签在 action 栏上面，action 栏在 Home 条上面
            let actionsHeight = drawerHeight + home + Metrics.padding
            let current = model.current?.id
            ZStack(alignment: .topLeading) {
                #if os(iOS)
                ScreenReader { radius, bottom, margin in
                    screenRadius = radius
                    homeInset = bottom
                    formMargin = margin
                }
                .ignoresSafeArea()
                #endif
                // 侧栏：一级导航选中的那一栏；点一个工作区就切过去并收起。
                // 收起时滑到屏幕外，不跟着 shown 藏：收起侧栏时底栏可能同时钉回来，shown 立刻换成底栏，侧栏还在往外滑
                VStack(alignment: .leading, spacing: 0) {
                    // 顶部是标志栏（只有搜索按钮），下面是一级导航和当前一栏的列表；
                    // 底部是用户栏，与窗口控制区底边对齐
                    SidebarLogoBar { EmptyView() }
                        .padding(.top, logoBarTop(screen: screen, insets: insets))
                        .padding(.bottom, Metrics.sidebarRuleGap)
                    if model.sidebarSection != .settings {
                        SidebarNavigation()
                            .padding(.bottom, Metrics.sidebarRuleGap)
                        Rectangle().fill(Theme.rule).frame(height: 1)
                            .padding(.bottom, Metrics.sidebarRuleGap)
                    }
                    SidebarListHeader()
                    ScrollView(.vertical, showsIndicators: false) {
                        switch model.sidebarSection {
                        case .workspaces:
                            WorkspaceList(onSelect: { open = nil }) { workspace in
                                WorkspaceRow(workspace: workspace, current: current == workspace.id) {
                                    Color.clear.contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selectWorkspace(workspace.id)
                                        open = nil
                                    }
                                }
                            }
                        case .drive, .extensions, .settings:
                            SectionPages { open = nil }
                        }
                    }
                    .fadesScrollEdges()
                    SidebarUserBar()
                }
                .padding(.horizontal, Metrics.sidebarInset)
                .modifier(SidebarScaledMetrics())
                .frame(width: sidebarWidth)
                .modifier(SidebarSlide(progress: sidebarProgress, width: sidebarWidth))
                .accessibilityHidden(!showing(.sidebar))
                // 底栏：折叠的窗口那一行。一次只露出一侧，拉侧边栏时藏起来，免得窗口移开时从边上露出来
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    if model.paneGroup != nil {
                        tabBar.frame(height: Metrics.tabBar)
                            .padding(.horizontal, Metrics.padding)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drawerHeight = $0 }
                .padding(.horizontal, Metrics.padding)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(showing(.actions) ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 窗口铺满整个屏幕，放在 overlay 里，不把上面这层撑出安全区，action 栏才能留在 Home 条上面
            // 没有窗口时窗口里放占位内容，见 CompactWindow
            .overlay(alignment: .topLeading) {
                CompactWindow(open: $open, shown: $shown, sidebarProgress: sidebarProgress, screen: screen, insets: insets, homeInset: home,
                              sidebarWidth: sidebarWidth, actionsHeight: actionsHeight, screenRadius: screenRadius,
                              actionsRule: windowed ? .free : windowless ? .pinned : .none)
                    .environment(\.formMargin, formMargin)
            }
        }
        // 保留 Home 条自动隐藏，不推测系统何时隐藏它。
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        #endif
        .onChange(of: model.paneGroup?.id, initial: true) { _, _ in
            model.paneGroup?.layout.updateViewport(.zero, presentation: .compact)
        }
        // 刚开出第一个窗口（新建，或在侧栏换到有窗口的工作区）：窗口从底栏上方展开铺满
        .onChange(of: model.paneGroup?.layout.focused == nil) { was, now in
            if was, !now { open = nil }
        }
        .appDotBackground()
        // 窄屏侧栏展开时由 App 画静息点阵；收起后只由开启了点阵的窗口画，不回退到 App 背景。
        .environment(\.dotBackgroundPlacement, showing(.sidebar) ? .app : .windows)
    }

    /// 窗口都排在底部，当前窗口垫一块选中底；点别的窗口换过去，点当前窗口收起底栏。
    @ViewBuilder
    private var tabBar: some View {
        if let group = model.paneGroup {
            if let area = group.workspace {
                CompactDockBar(open: $open)
                    .modifier(InstanceSettingsPresentation())
                    .environment(area)
            } else {
                tabs(in: group)
            }
        }
    }

    /// 设备账号的固定窗口：只有窗口，没有实例与停靠分组。
    private func tabs(in group: PaneGroup) -> some View {
        let workspace = group.layout
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.gap) {
                ForEach(workspace.panes, id: \.self) { pane in
                    Button {
                        workspace.focus(pane)
                        open = nil
                    } label: {
                        PaneBubble(appearance: group.appearance(of: pane))
                            .background { if pane == workspace.focused { DockSelection() } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展开\(group.appearance(of: pane).name)窗口")
                }
            }
        }
        .scrollClipDisabled()
    }

    /// 标志栏与侧边栏拉开后窗口标题栏的按钮同高：窗口顶边让出一个边距，内容按高度缩小，标题栏在补足的安全区下面。
    /// 返回相对安全区顶边的距离，见 WindowPlacement 与 PaneWindow。
    private func logoBarTop(screen: CGSize, insets: EdgeInsets) -> CGFloat {
        let pad = Metrics.padding
        let scale = (screen.height - 2 * pad) / screen.height
        let covered = max(insets.top - pad, 0) / scale
        let button = Metrics.paneHeaderButton
        let center = pad + max(Metrics.paneMargin, covered) * scale + button * scale / 2
        return center - button / 2 - insets.top
    }

    private func showing(_ drawer: WorkspaceDrawer) -> Bool {
        shown == drawer
    }

    /// 当前窗口组有可用窗口时，底栏可以展开收起。
    private var windowed: Bool {
        guard let group = model.paneGroup, group.layout.focused != nil else { return false }
        return group.canShowWindows
    }

    /// 工作区内容已载入但没开窗口：底栏钉着，新建窗口的入口在那里。目录状态（添加项目、连接中等）没有可用的底栏，同单页一样铺满。
    private var windowless: Bool {
        guard model.sidebarSection == .workspaces, model.selectedProject == nil, let area = model.current else { return false }
        return area.layout.focused == nil && area.pluginClient != nil
    }
}

#if os(iOS)
/// 用一个铺满屏幕的 UIView 读 SwiftUI 读不到的三样：
/// - 屏幕圆角：圆角和容器同心的 UIView，它的实际圆角就是屏幕圆角（iOS 26 起的公开接口）。
/// - Home 条让出的那一截：UIKit 的安全区不含键盘，键盘另有 keyboardLayoutGuide。
///   SwiftUI 的安全区分成 container 和 keyboard 两区，但只能按区忽略，读出来的是合在一起的。
/// - 根视图的左右边距：系统按屏幕宽度定，分组表单铺满屏幕时继承的就是它。
struct ScreenReader: UIViewRepresentable {
    let onRead: (_ radius: CGFloat, _ bottom: CGFloat, _ margin: CGFloat?) -> Void

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
        var onRead: ((CGFloat, CGFloat, CGFloat?) -> Void)?
        private var last: (radius: CGFloat, bottom: CGFloat, margin: CGFloat?)?

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let radius = effectiveRadius(corner: .topLeft)
            let bottom = safeAreaInsets.bottom
            let margin = window?.rootViewController?.view.directionalLayoutMargins.leading
            guard radius != last?.radius || bottom != last?.bottom || margin != last?.margin, let onRead else { return }
            last = (radius, bottom, margin)
            // 不在布局过程中改 SwiftUI 的状态
            Task { onRead(radius, bottom, margin) }
        }
    }
}

#endif
