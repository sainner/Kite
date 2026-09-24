import SwiftUI

/// 窗口标题栏里的信息。不放图标，靠标题区分是哪个窗口。
struct PaneHeader {
    var title: String
    /// 次要信息，比如会话所在的项目：Mac 上在标题右边，iPhone 上在标题下面。
    var detail: String?
}

/// 窗口的共有布局：浮在上面的标题栏、内容、浮在下面的控制区。内容从标题栏和控制区后面滚过去，
/// 标题栏后面垫系统的滚动边缘效果（硬边），控制区后面垫一层渐变遮罩，让底下的状态信息看得清。Mac 上是一张卡片的内容，iPhone 上铺满窗口；各个窗口只给标题栏的信息、内容、控制区里的东西，
/// 和控制区底下的状态信息。
/// 控制区是一张液态玻璃卡片，左右留边，底下贴着 Home 条、键盘让出的安全区；底下没有安全区时（Mac 的卡片、iPhone 拉开抽屉）离窗口底边留一点。
/// 状态信息只看不点，放在控制区底下的安全区里，iPhone 上小横条藏起来以后才显示（它只在进 App 时出来一下），打字时不显示。
/// 控制区里的输入框拿 typing 绑定焦点。iPhone 上打字时点控制区以外的地方收起键盘；不打字时从控制区往上拖拉出 action 栏。
struct PaneWindow<Content: View, Controls: View>: View {
    let header: PaneHeader
    let status: Text?
    let content: Content
    let controls: (FocusState<Bool>.Binding) -> Controls
    @FocusState private var typing: Bool
    /// 窗口底下被 Home 条、键盘盖着的那一截。
    @State private var bottomInset: CGFloat = 0
    @Environment(\.homeIndicatorHidden) private var indicatorHidden

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
            // 加在控制区外面这一层，点控制区不算
            .endsTyping($typing)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                controls($typing)
                    .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
                    .padding(.horizontal, Metrics.controlMargin)
                    // 底下的安全区够高就贴着它，不够的补到 controlMargin；拉开抽屉时安全区慢慢变没，边距跟着慢慢出来
                    .padding(.bottom, max(Metrics.controlMargin - bottomInset, 0))
                    .frame(maxWidth: .infinity)
                    .background { bottomFade }
                    .overlay(alignment: .bottom) { statusLine }
                    // 打字时在输入框里上下拖是选字、滚动，不拉 action 栏
                    .pullsDrawer(enabled: !typing)
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                HeaderBar(header: header)
            }
            // 标题栏后面垫硬边；控制区后面用自己的渐变遮罩，见 bottomFade
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
    }

    /// 控制区后面的渐变遮罩：用窗口的底色，从控制区顶边的全透明线性过渡到底边的不透明，底下的安全区整个盖住，
    /// 内容滚到这里渐渐淡掉，状态信息后面是干净的底色。
    private var bottomFade: some View {
        LinearGradient(colors: [Theme.card.opacity(0), Theme.card], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .bottom) {
                Theme.card.frame(height: bottomInset).offset(y: bottomInset)
            }
            .allowsHitTesting(false)
    }

    /// 状态信息：挪到控制区下面，在安全区里垂直居中。安全区放不下一行字（拉开抽屉）时不显示。
    @ViewBuilder
    private var statusLine: some View {
        if let status {
            let shown = indicatorHidden && !typing && bottomInset >= Metrics.statusMinHeight
            status
                .font(Theme.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Metrics.controlMargin)
                .frame(height: bottomInset)
                .offset(y: bottomInset)
                .opacity(shown ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: shown)
                .allowsHitTesting(false)
        }
    }
}

/// 标题栏。Mac 上标题、次要信息排成一行靠左，固定高度垂直居中；卡片的拖动把手由卡片自己叠在上面。
/// iPhone 上居中，次要信息在标题下面；状态栏的安全区底下本来空着一截，所以上边不留、下边留一点。
private struct HeaderBar: View {
    let header: PaneHeader

    var body: some View {
        #if os(macOS)
        HeaderLine(header: header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: Metrics.header)
        #else
        VStack(spacing: 2) {
            Text(header.title).font(Theme.title)
            if let detail = header.detail {
                Text(detail).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.bottom, Metrics.phoneHeaderBottom)
        .frame(maxWidth: .infinity)
        // 标题栏只是显示，点它落到下面的内容上：打字时点这里也收起键盘
        .allowsHitTesting(false)
        #endif
    }
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

    /// iPhone 上从控制区往上拖拉出 action 栏：窗口给出拖动的处理，控制区接手势。没有就不接。
    @Entry var drawerPull: DrawerPull?
}

/// 拉抽屉的处理：拖动中和松手时手指的位移，屏幕坐标。窗口拖着缩小时拖的地方自己也在动，不能按它自己的坐标算。
struct DrawerPull {
    let changed: @MainActor (CGSize) -> Void
    let ended: @MainActor (_ predicted: CGSize) -> Void

    var gesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { changed($0.translation) }
            .onEnded { ended($0.predictedEndTranslation) }
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

    func body(content: Content) -> some View {
        if let pull {
            content
                .contentShape(Rectangle())
                .simultaneousGesture(pull.gesture, isEnabled: enabled)
        } else {
            content
        }
    }
}
#endif
