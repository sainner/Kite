import SwiftUI

/// 窗口标题栏里的信息。不放图标，靠标题区分是哪个窗口。
struct PaneHeader {
    var title: String
    /// 次要信息，比如会话所在的项目：Mac 上在标题右边，iPhone 上在标题下面。
    var detail: String?
}

/// 窗口的共有布局：浮在上面的标题栏、内容、浮在下面的控制区。内容从标题栏和控制区后面滚过去，
/// 标题栏后面垫系统的滚动边缘效果（软边），再叠一层从窗口顶边起的渐变遮罩；控制区后面垫一层到窗口底边的渐变遮罩。Mac 上是一张卡片的内容，iPhone 上铺满窗口；各个窗口只给标题栏的信息、内容、控制区里的东西，
/// 和控制区底下的状态信息。
/// 控制区是一张液态玻璃卡片，左右留边，底下贴着 Home 条让出的安全区；底下没有安全区时（Mac 的卡片、iPhone 拉开抽屉）离窗口底边留一点，
/// 打字时离键盘也留这么多。
/// 状态信息只看不点，放在控制区底下的安全区里，iPhone 上小横条藏起来以后才显示（它只在进 App 时出来一下），打字时不显示。
/// 控制区里的输入框拿 typing 绑定焦点。iPhone 上打字时点控制区以外的地方收起键盘；不打字时从控制区往上拖拉出 action 栏。
/// iPhone 上标题栏左边有个按钮拉开侧边栏。
struct PaneWindow<Content: View, Controls: View>: View {
    let header: PaneHeader
    let status: Text?
    let content: Content
    let controls: (FocusState<Bool>.Binding) -> Controls
    @FocusState private var typing: Bool
    /// 窗口底下被 Home 条盖着的那一截，不含键盘。
    @Environment(\.homeIndicatorInset) private var homeInset
    @Environment(\.keyboardShown) private var keyboardShown
    @Environment(\.homeIndicatorHidden) private var indicatorHidden
    @Environment(\.openSidebar) private var openSidebar

    init(header: PaneHeader, status: Text? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder controls: @escaping (_ typing: FocusState<Bool>.Binding) -> Controls) {
        self.header = header
        self.status = status
        self.content = content()
        self.controls = controls
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(Lifted(part: \.content))
            // 加在控制区外面这一层，点控制区不算
            .endsTyping($typing)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                controls($typing)
                    // 离窗口的角近的两个角和窗口圆角同心，远的用最小圆角
                    .glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(Metrics.controlRadius))))
                    .padding(.horizontal, Metrics.controlMargin)
                    // Home 条那一截够高就贴着它，不够的补到 controlMargin；拉开抽屉时不改这里，由 WindowLift 挪到窗口底边上面。
                    // 键盘不一样：不贴着它，照样留 controlMargin。不另加动画：keyboardShown 和键盘让出的安全区在同一次更新里变，
                    // 边距跟着键盘自己的动画走，和键盘同步
                    .padding(.bottom, keyboardShown ? Metrics.controlMargin : max(Metrics.controlMargin - homeInset, 0))
                    .frame(maxWidth: .infinity)
                    .background { bottomFade }
                    .overlay(alignment: .bottom) { statusLine }
                    // 打字时在输入框里上下拖是选字、滚动，不拉 action 栏
                    .pullsDrawer(enabled: !typing)
                    .modifier(Lifted(part: \.controls))
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                HeaderBar(header: header, openSidebar: sidebarAction)
                    #if os(iOS)
                    .background { topFade }
                    #endif
            }
            // 标题栏后面垫软边，iPhone 上再叠 topFade：软边只模糊不提白，内容滚到标题后面时字会糊在一起。
            // Mac 上标题栏矮、没有状态栏，只要软边
            // 控制区后面用自己的渐变遮罩，见 bottomFade
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
    }

    /// 标题栏左边按钮的动作：先收起键盘，再拉开侧边栏。
    private var sidebarAction: (@MainActor () -> Void)? {
        guard let openSidebar else { return nil }
        return {
            typing = false
            openSidebar()
        }
    }

    #if os(iOS)
    /// iPhone 上标题栏后面的渐变遮罩：用窗口的底色，从窗口顶边的不透明过渡到全透明，往上伸过状态栏那一截，
    /// 往下伸过标题栏底边 topFadeOverhang。不透明度是 1 − h²，h 是离窗口顶边的距离占整段高度的比例：
    /// 每一处都比线性的白，越往下掉得越快，和 bottomFade 上下对称。
    private var topFade: some View {
        let stops = (0...10).map { i in
            let h = Double(i) / 10
            return Gradient.Stop(color: Theme.card.opacity(1 - h * h), location: h)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .padding(.bottom, -Metrics.topFadeOverhang)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
    }
    #endif

    /// 控制区后面的渐变遮罩：用窗口的底色，从控制区顶边的全透明过渡到不透明，往下伸过 Home 条那一截到窗口底边，
    /// 内容滚到这里渐渐淡掉。不透明度是 1 − h²，h 是离窗口底边的距离占整段高度的比例：底下一截接近不透，越往上掉得越快。
    private var bottomFade: some View {
        let stops = (0...10).map { i in
            let h = 1 - Double(i) / 10
            return Gradient.Stop(color: Theme.card.opacity(1 - h * h), location: 1 - h)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .padding(.bottom, -homeInset)
            .allowsHitTesting(false)
    }

    /// 状态信息：挪到控制区下面，在 Home 条那一截里垂直居中。那一截放不下一行字（拉开抽屉）时不显示。
    @ViewBuilder
    private var statusLine: some View {
        if let status {
            let shown = indicatorHidden && !typing && !keyboardShown && homeInset >= Metrics.statusMinHeight
            status
                .font(Theme.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Metrics.controlMargin)
                .frame(height: homeInset)
                .offset(y: homeInset)
                .opacity(shown ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: shown)
                .modifier(StatusHiding())
                .allowsHitTesting(false)
        }
    }
}

/// 标题栏。Mac 上标题、次要信息排成一行靠左，固定高度垂直居中；卡片的拖动把手由卡片自己叠在上面。
/// iPhone 上居中，次要信息在标题下面，左边是拉开侧边栏的按钮；状态栏的安全区底下本来空着一截，所以上边不留、下边留一点。
private struct HeaderBar: View {
    let header: PaneHeader
    /// iPhone 上拉开侧边栏，Mac 上不用。
    let openSidebar: (@MainActor () -> Void)?

    var body: some View {
        #if os(macOS)
        HeaderLine(header: header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: Metrics.header)
        #else
        HStack(spacing: 0) {
            sidebarButton
            VStack(spacing: 2) {
                Text(header.title).font(Theme.title)
                if let detail = header.detail {
                    Text(detail).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            // 标题只是显示，点它落到下面的内容上：打字时点这里也收起键盘
            .allowsHitTesting(false)
            // 右边垫一个一样宽的空位，标题才在窗口正中
            sidebarButton.hidden()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, Metrics.phoneHeaderBottom)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var sidebarButton: some View {
        if let openSidebar {
            Button(action: openSidebar) {
                Image(systemName: "sidebar.left")
                    .font(Theme.body)
                    .frame(width: Metrics.headerButton, height: Metrics.headerButton)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
        }
    }
    #endif
}

#if os(macOS)
/// Mac 上标题栏里的一行：标题、次要信息。卡片的标题栏和独立窗口的顶栏都用它。
struct HeaderLine: View {
    let header: PaneHeader

    var body: some View {
        HStack(spacing: 8) {
            Text(header.title).font(Theme.title)
            if let detail = header.detail {
                Text(detail).font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}
#endif

/// 窗口的内容，会话在环境里。会话窗口见 SessionPane，其余还是占位。
struct PaneBody: View {
    let pane: Pane

    var body: some View {
        if pane == .session {
            SessionPane()
        } else {
            PlaceholderPane(pane: pane)
        }
    }
}

/// 还没做的窗口：标题栏是窗口的名字，内容是占位色块，控制区是一张空卡片。
private struct PlaceholderPane: View {
    let pane: Pane

    var body: some View {
        PaneWindow(header: PaneHeader(title: pane.name)) {
            RoundedRectangle(cornerRadius: 8).fill(pane.tint.opacity(0.12))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        } controls: { _ in
            Color.clear.frame(height: Metrics.controlHeight)
        }
    }
}

extension EnvironmentValues {
    /// iPhone 上小横条（Home 条）这会儿藏起来了，控制区底下那一截空出来放状态信息。PhoneLayout 给出，Mac 上总是 false。
    @Entry var homeIndicatorHidden = false
    /// 窗口底下被 Home 条盖着的那一截，不含键盘。SwiftUI 的安全区读出来是合在一起的，分不出键盘，
    /// PhoneLayout 从 UIKit 读了给出；Mac 上是 0。
    @Entry var homeIndicatorInset: CGFloat = 0
    /// iPhone 上键盘升起来了。PhoneLayout 在屏幕这一层比出来：SwiftUI 的安全区比 Home 条那一截高。
    /// Mac 上总是 false。
    @Entry var keyboardShown = false

    /// iPhone 上拉开侧边栏，标题栏左边的按钮调它。PhoneLayout 给出，没有就不显示按钮。
    @Entry var openSidebar: (@MainActor () -> Void)?
    /// iPhone 上从控制区往上拖拉出 action 栏：窗口给出拖动的处理，控制区接手势。没有就不接。
    @Entry var drawerPull: DrawerPull?
    /// iPhone 上拉开抽屉时窗口里的东西往上挪多少，PhoneLayout 逐帧给出；Mac 上不挪。
    @Entry var windowLift = WindowLift()
}

/// 按 WindowLift 往上挪，只改 offset，不重新排版。
private struct Lifted: ViewModifier {
    let part: KeyPath<WindowLift, CGFloat>
    @Environment(\.windowLift) private var lift

    func body(content: Content) -> some View {
        content.offset(y: -lift[keyPath: part])
    }
}

/// 拉开抽屉、Home 条那一截放不下时藏起状态信息。和 Lifted 一样单独一个修饰符。
private struct StatusHiding: ViewModifier {
    @Environment(\.windowLift) private var lift

    func body(content: Content) -> some View {
        content
            .opacity(lift.hidesStatus ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: lift.hidesStatus)
    }
}

/// iPhone 上拉开抽屉时窗口里的东西往上挪多少，缩放前的点。窗口里一直照铺满屏幕排，抽屉动的时候不重新排，只挪：
/// 内容整个往上挪 content，跟着升上来的窗口底边，像键盘把对话顶上去；控制区挪 controls，停在窗口底边上面。
struct WindowLift: Equatable {
    var content: CGFloat = 0
    var controls: CGFloat = 0
    /// 窗口底下 Home 条还盖着的那一截放不下状态信息。
    var hidesStatus = false
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

private extension View {
    /// 打字时点这里收起键盘，只在 iPhone 上。和这里原有的点按（展开折起来的一行等）同时生效，不抢它们。
    @ViewBuilder
    func endsTyping(_ typing: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
        simultaneousGesture(TapGesture().onEnded { typing.wrappedValue = false }, isEnabled: typing.wrappedValue)
        #else
        self
        #endif
    }

    /// 在这里往上拖拉出 action 栏，只在 iPhone 上。和控制区里的点按、输入同时生效，不抢它们。
    @ViewBuilder
    func pullsDrawer(enabled: Bool) -> some View {
        #if os(iOS)
        modifier(DrawerPullModifier(enabled: enabled))
        #else
        self
        #endif
    }
}

#if os(iOS)
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
#endif
