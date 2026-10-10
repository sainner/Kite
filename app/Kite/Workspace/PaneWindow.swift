import SwiftUI

/// 窗口的共有布局：浮在上面的标题栏、内容、浮在下面的控制区。内容从标题栏和控制区后面滚过去，
/// 标题栏后面垫系统滚动软边，iPhone 的软边是渐进模糊，再叠一层渐变。Mac 上是一张卡片的内容，iPhone 上铺满窗口；各个窗口只给标题栏的信息、内容、控制区里的东西，
/// 标题前的信息区由窗口给出（会话是状态圆环），两端相同。信息区同时只展示一项：所属工作机的连接提示优先于
/// 窗口自己的提示，提示出现时盖住圆环，见 PaneNotice。
/// 控制区是液态玻璃容器，各个窗口给内部控件提供玻璃形状；左右留边，底部总边距统一取固定留白与安全区高度的较大值。
/// 控制区始终存在；内容为空时窄屏触控下仍保留交互范围，鼠标或宽屏下不接点击，后面的内容照常可点。
/// 安全区已由窗口容器让出，控制区补足差额；打字时在键盘上方保留固定留白。
/// 控制区里的输入框拿 typing 绑定焦点。iPhone 上打字时点控制区以外的地方收起键盘；不打字时从控制区往上拖拉出 action 栏。
/// 窄屏控制区左右滑动切换窗口，键盘显示或控制区已聚焦时禁用。
/// 标题栏左侧负责打开侧栏；紧凑触屏布局由会话状态圆环承接，其他情况显示侧栏按钮。
struct PaneWindow<Content: View, Controls: View, HeaderStatus: View, HeaderActions: View>: View {
    let header: PaneHeader
    let usesDots: Bool
    let notice: PaneNotice?
    let content: Content
    let controls: (FocusState<Bool>.Binding) -> Controls
    let headerStatus: HeaderStatus
    let headerActions: HeaderActions
    @FocusState private var typing: Bool
    @Environment(\.headerPane) private var headerPane
    @Environment(\.sharedPaneHeaderHeight) private var sharedHeaderHeight
    @Environment(\.workspacePresentation) private var presentation
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.paneConnectionNotice) private var connectionNotice
    /// 整个窗口（连同标题栏与控制区）的范围，交给内容里要铺满整个窗口的点阵图案；不铺点阵的窗口不量。
    @State private var frame: CGRect?

    init(header: PaneHeader, usesDots: Bool = false, notice: PaneNotice? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder controls: @escaping (_ typing: FocusState<Bool>.Binding) -> Controls,
         @ViewBuilder headerStatus: () -> HeaderStatus = { EmptyView() },
         @ViewBuilder headerActions: () -> HeaderActions = { EmptyView() }) {
        self.header = header
        self.usesDots = usesDots
        self.notice = notice
        self.content = content()
        self.controls = controls
        self.headerStatus = headerStatus()
        self.headerActions = headerActions()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.paneWindowFrame, frame)
            // 加在控制区外面这一层，点控制区不算
            .endsTyping(typing) { typing = false }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                Group(subviews: controls($typing)) { controlViews in
                    GlassEffectContainer(spacing: Metrics.paneButtonGap) {
                        // 空控制区仍保留命中范围，继续承接上拉与横滑手势。
                        // 什么都没画的底栏不被系统当作控制区，contentShape 也不管用，触摸落到下面的滚动视图
                        // （iOS 27 模拟器 hitTest 实测）；挂一个不显示的 identity 玻璃，系统就会接管这一条。
                        if controlViews.isEmpty {
                            Color.clear.frame(height: Metrics.paneToolbarHeight).glassEffect(.identity)
                        } else {
                            ForEach(controlViews) { $0 }
                        }
                    }
                        .padding(.horizontal, Metrics.paneMargin)
                        .modifier(PaneControlsBottom())
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        // 打字时在输入框里上下拖是选字、滚动，不拉 action 栏
                        .modifier(DrawerPullModifier(enabled: !typing && presentation.isCompactTouch))
                        .modifier(PaneControlSwipe(typing: typing))
                        // 空控制区只在窄屏触控下接上拉与横滑；其他情况只是一段透明的留白，点击和悬停落到后面的内容上。
                        .allowsHitTesting(!controlViews.isEmpty || presentation.isCompactTouch)
                }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                if let sharedHeaderHeight, headerPane != nil {
                    Color.clear.frame(height: sharedHeaderHeight).allowsHitTesting(false)
                } else {
                    PaneHeaderBar(header: header, status: status, actions: headerActions, openSidebar: sidebarAction)
                        .modifier(PaneHeaderPlacement(endTyping: { typing = false }))
                }
            }
            .background {
                Group(subviews: status) { statusViews in
                    CompactPaneHeaderReport(header: header, status: statusViews.isEmpty ? nil : AnyView(status),
                                            actions: AnyView(headerActions), openSidebar: sidebarAction, endTyping: { typing = false })
                }
            }
            // 窗口内容里的滚动区要用 separateScrollPocket，Mac 上贴着窗口顶边的卡片才不会互相串色
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 控制区后面的内容保持完整显示。
            .scrollEdgeEffectHidden(true, for: .bottom)
            .windowDots(usesDots)
            // 窗口移动、缩放时范围每帧都变，写一次状态整个窗口跟着重算，只有铺点阵的窗口才量。
            .onGeometryChange(for: CGRect?.self) {
                usesDots ? $0.frame(in: DotCarrier.coordinateSpace(carrier)) : nil
            } action: { frame = $0 }
    }

    /// 信息区：窗口给的圆环，提示出现时虚化盖住；没有圆环时只放提示图标。
    private var status: some View {
        let shown = connectionNotice ?? notice
        return Group(subviews: headerStatus) { statusViews in
            if !statusViews.isEmpty {
                ForEach(statusViews) { $0 }
            } else if let shown {
                PaneNoticeIcon(notice: shown)
            }
        }
        .environment(\.paneNotice, shown)
    }

    /// 标题栏左边按钮的动作：先收起键盘，再拉开侧边栏。
    private var sidebarAction: (@MainActor () -> Void)? {
        guard let openSidebar else { return nil }
        return {
            typing = false
            openSidebar()
        }
    }

}

/// 含有窗口的视图淡入淡出时用蒙版，不用 opacity，也不留给动画里插入视图时默认的 opacity 转场。
/// 标题栏登记给滚动软边时，SwiftUI 按当时祖先的透明度报一次，之后只有标题栏自身变化才重报；
/// 从 opacity 0 渐入的窗口，Mac 的标题栏软边会一直按“元素不可见”隐藏（macOS 26 实测）。
struct PaneFade: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content.mask { Rectangle().opacity(visible ? 1 : 0) }
            .modifier(DotsPresence(presented: visible))
    }
}

extension AnyTransition {
    static var paneFade: AnyTransition {
        .modifier(active: PaneFade(visible: false), identity: PaneFade(visible: true))
    }
}

extension EnvironmentValues {
    /// 窗口底部为 Home 条保留的高度，不含键盘；底栏展开时仍保留。SwiftUI 的安全区读出来是合在一起的，分不出键盘，
    /// CompactLayout 从 UIKit 读了给出；Mac 上是 0。
    @Entry var homeIndicatorInset: CGFloat = 0
    /// 所在窗口连同标题栏与控制区的范围：窗口坐标，在会移动的卡片里是卡片坐标。由 PaneWindow 给内容。
    @Entry var paneWindowFrame: CGRect?
    /// 窗口容器已让出的顶部安全区，标题栏只补足固定边距；Mac 为 0。
    @Entry var paneTopSafeInset: CGFloat = 0
    /// iPhone 根视图的左右边距，CompactLayout 从 UIKit 读了给窗口，单页的分组表单按它固定，见 pageForm；其他情况为 nil。
    @Entry var formMargin: CGFloat?
    /// iPhone 上键盘升起来了。CompactLayout 在屏幕这一层比出来：SwiftUI 的安全区比 Home 条那一截高。
    /// 不能在窗口里比：拉开、收起抽屉时窗口里读到的安全区跟着动画逐帧变，还会冲过 Home 条那一截，会被当成键盘。Mac 上总是 false。
    @Entry var keyboardShown = false

    /// 拉开侧边栏，标题栏左边的按钮调它。紧凑布局由 CompactLayout 给出；宽屏侧栏收起时由主窗口给出，
    /// 只交给排在左上角的窗口。没有就不显示按钮。
    @Entry var openSidebar: (@MainActor () -> Void)?
    /// iPhone 上从控制区往上拖拉出 action 栏：窗口给出拖动的处理，控制区接手势。没有就不接。
    @Entry var drawerPull: DrawerPull?
}

/// 拉抽屉的处理：拖动中手指的位移和速度、松手时的速度，屏幕坐标。窗口拖着缩小时拖的地方自己也在动，不能按它自己的坐标算。
struct DrawerPull {
    let changed: @MainActor (_ translation: CGSize, _ velocity: CGSize) -> Void
    let ended: @MainActor (_ velocity: CGSize) -> Void

    /// 一次拖动往哪个方向：挪过 dragThreshold 时看横着挪得多还是竖着挪得多，定了就不改。
    /// 抽屉和控制区里要横着拖的控件（比如选 effort）都按它定，同一次拖动两边不会都接或都不接。
    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    var gesture: some Gesture {
        DragGesture(minimumDistance: Metrics.dragThreshold, coordinateSpace: .global)
            .onChanged { changed($0.translation, $0.velocity) }
            .onEnded { ended($0.velocity) }
    }
}

/// 在这里往上拖拉出 action 栏，只在窄屏触控下。和控制区里的点按、输入同时生效，不抢它们。
private struct DrawerPullModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.drawerPull) private var pull

    // 有没有 pull 都是同一个结构，没有时只停掉手势。分成两支的话，拉开、收起抽屉时 pull 在有无之间切换，
    // 控制区会被当成换了一个视图，淡出再淡入
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture((pull ?? DrawerPull(changed: { _, _ in }, ended: { _ in })).gesture,
                                 isEnabled: enabled && pull != nil)
    }
}

/// 控制区的底边距：总底边距取 max(固定留白, 安全区)，容器已经让出的安全区只计算一次。
/// 键盘显示时容器已让出键盘，在它上方补固定留白；和键盘自己的动画同步。
/// Home 条高度在这一层读：拖抽屉时它随手指逐次变化，只重算边距，不带着整个窗口重算。
private struct PaneControlsBottom: ViewModifier {
    /// 窗口底部为 Home 条保留的高度，不含键盘；底栏展开时仍保留。
    @Environment(\.homeIndicatorInset) private var homeInset
    @Environment(\.keyboardShown) private var keyboardShown

    func body(content: Content) -> some View {
        let safeArea = keyboardShown ? 0 : homeInset
        content.padding(.bottom, max(Metrics.paneMargin, safeArea) - safeArea)
    }
}

/// 紧凑布局里几个窗口共用一条标题栏，各窗口把自己的标题栏连同所处环境报上去。读整个环境放在这一小块里，
/// 环境一变只重算它，不带着整个窗口重算。
private struct CompactPaneHeaderReport: View {
    let header: PaneHeader
    let status: AnyView?
    let actions: AnyView
    let openSidebar: (@MainActor () -> Void)?
    let endTyping: () -> Void
    @Environment(\.headerPane) private var headerPane
    @Environment(\.sharedPaneHeaderHeight) private var sharedHeaderHeight
    @Environment(\.self) private var environment

    var body: some View {
        Color.clear.preference(key: CompactPaneHeaders.self, value: headers)
    }

    private var headers: [CompactPaneHeader] {
        guard sharedHeaderHeight != nil, let pane = headerPane else { return [] }
        return [CompactPaneHeader(pane: pane, header: header, status: status, actions: actions, environment: environment,
                                  openSidebar: openSidebar, endTyping: endTyping)]
    }
}
