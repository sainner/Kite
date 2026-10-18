import SwiftUI

/// 窗口的共有布局：浮在上面的标题栏、内容、浮在下面的控制区。内容从标题栏和控制区后面滚过去，
/// 标题栏后面垫系统滚动软边，iPhone 的软边是渐进模糊，再叠一层渐变。Mac 上是一张卡片的内容，iPhone 上铺满窗口；各个窗口只给标题栏的信息、内容、控制区里的东西，
/// 标题前的信息区由窗口给出（会话是状态圆环），两端相同。信息区同时只展示一项：所属工作机的连接提示优先于
/// 窗口自己的提示，提示出现时盖住圆环，见 PaneNotice。
/// 控制区是液态玻璃容器，各个窗口给内部控件提供玻璃形状；左右留边，底部总边距统一取固定留白与安全区高度的较大值。
/// 控制区始终存在；内容为空时窄屏触控下仍保留交互范围，鼠标或宽屏下不接点击，后面的内容照常可点。
/// 安全区已由窗口容器让出，控制区补足差额；打字时在键盘上方保留固定留白。
/// 控制区里的输入框拿 typing 绑定焦点。iPhone 上打字时点控制区以外的地方收起键盘，键盘升起时控制区最左边有收起键盘；不打字时从控制区往上拖拉出 action 栏。
/// 窄屏控制区左右滑动切换窗口，键盘显示或控制区已聚焦时禁用。紧凑布局里标题栏和控制区都由外壳统一显示，只有正文跟着切换平移，
/// 见 CompactPaneHeaderHost（Mac 窄窗口）、CompactRowView（iPhone、iPad）。
/// 标题栏是固定结构：信息区、标题与副标题、右组。信息区只收窗口给的一个组件（会话的状态圆环、账号的额度圆环），可以不给；
/// 侧栏按钮、提示图标由窗口按固定规则加（见 statusArea、PaneHeaderStatus）：紧凑布局里给了组件就由它打开侧栏，没给就是侧栏按钮。
/// 右组按数据给，由窗口统一画（PaneHeaderActions）。各窗口的信息区、右组都是同一种视图，紧凑布局共用一条标题栏时换窗口原地更新。
struct PaneWindow<Content: View, Controls: View>: View {
    let header: PaneHeader
    let usesDots: Bool
    let notice: PaneNotice?
    let content: Content
    let controls: (FocusState<Bool>.Binding) -> Controls
    /// 信息区里窗口自己的组件，不给是 nil。
    let status: AnyView?
    let actions: PaneHeaderActions
    @FocusState private var typing: Bool
    @Environment(\.headerPane) private var headerPane
    @Environment(\.sharedPaneHeaderHeight) private var sharedHeaderHeight
    @Environment(\.sharedPaneControls) private var sharedControls
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.paneConnectionNotice) private var connectionNotice
    @Environment(\.paneViewSwitcher) private var viewSwitcher
    /// 量好的范围写进这个盒子交给内容：只有读它的视图（铺满窗口的签名）随它重算，窗口本身不跟着重算。
    @State private var frame = PaneWindowFrame()

    init(header: PaneHeader, usesDots: Bool = false, notice: PaneNotice? = nil, status: AnyView? = nil,
         actions: PaneHeaderActions = PaneHeaderActions(),
         @ViewBuilder content: () -> Content,
         @ViewBuilder controls: @escaping (_ typing: FocusState<Bool>.Binding) -> Controls) {
        self.header = header
        self.usesDots = usesDots
        self.notice = notice
        self.status = status
        self.actions = actions
        self.content = content()
        self.controls = controls
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.paneWindowFrame, frame)
            // 加在控制区外面这一层，点控制区不算
            .endsTyping(typing) { typing = false }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let sharedControls, let headerPane {
                    Color.clear.frame(height: sharedControls.height(for: headerPane)).allowsHitTesting(false)
                } else {
                    PaneControlsBar(controls: controls($typing), typing: typing)
                }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                if let sharedHeaderHeight, headerPane != nil {
                    Color.clear.frame(height: sharedHeaderHeight).allowsHitTesting(false)
                } else {
                    PaneHeaderBar(header: header, status: statusArea, actions: shownActions, openSidebar: sidebarAction)
                        .modifier(PaneHeaderPlacement(endTyping: { typing = false }))
                }
            }
            .background {
                Group {
                    let shown = controls($typing)
                    CompactPaneHeaderReport(header: header, status: hasStatus ? AnyView(statusArea) : nil,
                                            actions: AnyView(shownActions),
                                            controls: AnyView(PaneControlsBar(controls: shown, typing: typing)),
                                            hasControls: Self.hasControls(shown),
                                            openSidebar: sidebarAction, endTyping: { typing = false })
                }
            }
            // 窗口内容里的滚动区要用 separateScrollPocket，Mac 上贴着窗口顶边的卡片才不会互相串色
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 控制区后面的内容保持完整显示。
            .scrollEdgeEffectHidden(true, for: .bottom)
            .windowDots(usesDots)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: DotCarrier.coordinateSpace(carrier)) } action: { frame.rect = $0 }
    }

    /// 信息区：窗口给的组件，提示出现时虚化盖住；没给时只放提示图标，再没有提示就空着（侧栏按钮由 PaneHeaderStatus 加）。
    private var statusArea: some View {
        let shown = connectionNotice ?? notice
        return Group {
            if let status {
                status
            } else if let shown {
                PaneNoticeIcon(notice: shown)
            }
        }
        .environment(\.paneNotice, shown)
    }

    /// 右组：实例有几个视图时，窗口给的按钮前面加上视图切换器（见 paneViewSwitcher）。
    private var shownActions: PaneHeaderActions {
        guard let viewSwitcher else { return actions }
        var shown = actions
        shown.switcher = viewSwitcher
        return shown
    }

    private var hasStatus: Bool { status != nil || connectionNotice != nil || notice != nil }

    /// 控制区里有没有控件：不给是 EmptyView，按条件给（if）而条件不成立时是 nil。
    private static func hasControls(_ controls: Controls) -> Bool {
        Controls.self != EmptyView.self && (controls as? any OptionalControls)?.isNone != true
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

private protocol OptionalControls {
    var isNone: Bool { get }
}

extension Optional: OptionalControls {
    fileprivate var isNone: Bool { self == nil }
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

/// 窗口连同标题栏与控制区的范围：窗口坐标，在会移动的卡片里是卡片坐标。
@MainActor @Observable final class PaneWindowFrame {
    var rect: CGRect?
}

/// 所在窗口在不在屏上。紧凑布局横滑那一行的窗口都建着，没露出来的只是平移到屏外；宽屏缩进停靠栏的窗口正文看不见。
/// 窗口里的逐帧动画（工具行的扫掠和呼吸：MacToolActivity、PhoneActivityView；iOS 对话列表的逐帧更新；SwiftUI 里的 PaneTimeline）
/// 不在屏上时按它停下。SwiftUI 不会因为看不见就停掉 TimelineView(.animation)：平移出窗口、opacity 0、mask 全透都照常每帧跑 body
/// （2026-10-11 Mac 实测，iPhone 未量）。
/// 放盒子不放 Bool：横滑开始、停稳时相邻窗口露没露出来会翻转，Bool 直接进环境就是一次环境变化，整棵窗口子树都要收（见 CompactPaneStack 文件头）；
/// 盒子建好不再换，只改 onScreen，只有读它的视图跟着变。台面的卡片（CardView、PhoneCardView）和紧凑布局的一行窗口（CompactPaneStack、CompactRowView）给出。
@MainActor @Observable final class PanePresence {
    var onScreen = true
}

/// 窗口里的逐帧动画，每秒 30 帧，窗口不在屏上时停在当时那一帧，见 PanePresence。
struct PaneTimeline<Content: View>: View {
    var paused = false
    @ViewBuilder let content: (TimelineViewDefaultContext) -> Content
    @Environment(\.panePresence) private var presence

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || presence?.onScreen == false), content: content)
    }
}

extension EnvironmentValues {
    /// 窗口底部为 Home 条保留的高度，不含键盘；底栏展开时仍保留。SwiftUI 的安全区读出来是合在一起的，分不出键盘，
    /// 紧凑布局的外壳从 UIKit 读了给出（见 ScreenReader）；Mac 上是 0。
    @Entry var homeIndicatorInset: CGFloat = 0
    /// 所在窗口连同标题栏与控制区的范围，见 PaneWindowFrame。由 PaneWindow 给内容。
    @Entry var paneWindowFrame: PaneWindowFrame?
    /// 窗口容器已让出的顶部安全区，标题栏只补足固定边距；Mac 为 0。
    @Entry var paneTopSafeInset: CGFloat = 0
    /// iPhone 根视图的左右边距，紧凑布局的外壳从 UIKit 读了给窗口，单页的分组表单按它固定，见 pageForm；其他情况为 nil。
    @Entry var formMargin: CGFloat?
    /// iPhone 上键盘升起来了。紧凑布局的外壳在屏幕这一层比出来（WindowGeometry.keyboardShown）：安全区比 Home 条那一截高。
    /// 不能在窗口里比：窗口里的安全区按窗口停着的样子换算过（底栏钉着时缩放），比出来不准。Mac 上总是 false。
    /// 紧凑布局里只给外壳上的控制区和占位内容，不进窗口正文：键盘每次升降、焦点每次换窗口都是一次环境变化，
    /// 进了正文整棵窗口子树都要收，见 CompactPaneStack 文件头。
    @Entry var keyboardShown = false
    /// 所在窗口在不在屏上，见 PanePresence。台面的卡片和紧凑布局的一行窗口给出；别处没有，当作在屏上。
    @Entry var panePresence: PanePresence?

    /// 拉开侧边栏，标题栏左边的按钮调它。紧凑布局由外壳给出；宽屏侧栏收起时由主窗口给出，
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

/// 窗口底部的控制区：液态玻璃容器里放窗口给的控件，键盘升起时最左边是收起键盘。紧凑布局里由外壳统一显示（见 CompactPaneHeaderReport），
/// 窗口只为它让出高度；输入框的焦点仍绑在窗口自己的 typing 上。
struct PaneControlsBar<Controls: View>: View {
    let controls: Controls
    let typing: Bool
    @Environment(\.workspacePresentation) private var presentation

    var body: some View {
        Group(subviews: controls) { controlViews in
            Group {
                HStack(alignment: .bottom, spacing: Metrics.paneButtonGap) {
                    if !controlViews.contains(where: { $0.containerValues.placesKeyboardButton }) {
                        KeyboardDismissButton()
                    }
                    // 空控制区仍保留命中范围，继续承接上拉与横滑手势。
                    // 什么都没画的底栏不被系统当作控制区，contentShape 也不管用，触摸落到下面的滚动视图
                    // （iOS 27 模拟器 hitTest 实测）；挂一个不显示的 identity 玻璃，系统就会接管这一条。
                    // 只在窄屏触控下挂：Mac 上系统会在这块玻璃底下垫一层整条宽的模糊背板，窗口底部的内容跟着变糊，
                    // 而其他情况下空控制区本就不接点击。
                    if controlViews.isEmpty {
                        if presentation.isCompactTouch {
                            Color.clear.frame(height: Metrics.paneToolbarHeight).glassEffect(.identity)
                        } else {
                            Color.clear.frame(height: Metrics.paneToolbarHeight)
                        }
                    } else {
                        ForEach(controlViews) { $0 }
                    }
                }
            }
                .modifier(PaneControlsGlassContainer())
                .padding(.horizontal, Metrics.paneMargin)
                .modifier(PaneControlsBottom())
                .drawerShift(.bottom)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                // 打字时在输入框里上下拖是选字、滚动，不拉 action 栏
                .modifier(DrawerPullModifier(enabled: !typing && presentation.isCompactTouch))
                .modifier(PaneControlSwipe(typing: typing))
                // 空控制区只在窄屏触控下接上拉与横滑；其他情况只是一段透明的留白，点击和悬停落到后面的内容上。
                .allowsHitTesting(!controlViews.isEmpty || presentation.isCompactTouch)
        }
    }
}

private struct PaneControlsGlassContainer: ViewModifier {
    @Environment(\.compactSharedGlass) private var shared

    @ViewBuilder func body(content: Content) -> some View {
        if shared { content }
        else { GlassEffectContainer(spacing: Metrics.paneButtonGap) { content } }
    }
}

/// 在这里往上拖拉出 action 栏，只在窄屏触控下。和控制区里的点按、输入同时生效，不抢它们。
private struct DrawerPullModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.drawerPull) private var pull
    @Environment(\.compactSharedGlass) private var sharedGlass

    private var native: Bool {
        #if os(iOS)
        sharedGlass
        #else
        false
        #endif
    }

    // 有没有 pull 都是同一个结构，没有时只停掉手势；分成两支的话，pull 有无一变控制区就被当成换了一个视图，淡出再淡入。
    // 紧凑布局的窗口一直给着，能不能拉由它自己判断
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture((pull ?? DrawerPull(changed: { _, _ in }, ended: { _ in })).gesture,
                                 isEnabled: enabled && pull != nil && !native)
    }
}

/// 控制区的底边距：总底边距取 max(固定留白, 安全区)，容器已经让出的安全区只计算一次。
/// 键盘显示时容器已让出键盘，在它上方补固定留白；和键盘自己的动画同步。
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
    let controls: AnyView
    let hasControls: Bool
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
        return [CompactPaneHeader(pane: pane, header: header, status: status, actions: actions, controls: controls,
                                  hasControls: hasControls, environment: environment, openSidebar: openSidebar, endTyping: endTyping)]
    }
}
