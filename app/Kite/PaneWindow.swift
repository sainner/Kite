import SwiftUI

/// 窗口标题栏里的信息。不放图标，靠标题区分是哪个窗口。
struct PaneHeader {
    var title: String
    /// 次要信息，比如会话所在的项目：Mac 上在标题右边，iPhone 上在标题下面。
    var detail: String?
    /// 在忙，比如回合在跑：标题旁边转圈。
    var busy = false
}

/// 窗口的共有布局：浮在上面的标题栏、内容、浮在下面的控制区。内容从标题栏和控制区后面滚过去，
/// 后面垫系统的滚动边缘效果（硬边）。Mac 上是一张卡片的内容，iPhone 上铺满窗口；各个窗口只给标题栏的信息、内容和控制区。
/// 控制区里的输入框拿 typing 绑定焦点。iPhone 上打字时点控制区以外的地方收起键盘；不打字时从控制区往上拖拉出 action 栏。
struct PaneWindow<Content: View, Controls: View>: View {
    let header: PaneHeader
    let content: Content
    let controls: (FocusState<Bool>.Binding) -> Controls
    @FocusState private var typing: Bool

    init(header: PaneHeader, @ViewBuilder content: () -> Content,
         @ViewBuilder controls: @escaping (_ typing: FocusState<Bool>.Binding) -> Controls) {
        self.header = header
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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    // 打字时在输入框里上下拖是选字、滚动，不拉 action 栏
                    .pullsDrawer(enabled: !typing)
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                HeaderBar(header: header)
            }
            .scrollEdgeEffectStyle(.hard, for: .all)
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
            HStack(spacing: 6) {
                Text(header.title).font(Theme.title)
                if header.busy { Spinner() }
            }
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
/// Mac 上标题栏里的一行：标题、次要信息、在忙时转圈。卡片的标题栏和独立窗口的顶栏都用它。
struct HeaderLine: View {
    let header: PaneHeader

    var body: some View {
        HStack(spacing: 8) {
            Text(header.title).font(Theme.title)
            if let detail = header.detail {
                Text(detail).font(Theme.secondary).foregroundStyle(.secondary)
            }
            if header.busy { Spinner() }
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

/// 还没做的窗口：标题栏是窗口的名字，内容和控制区是占位色块。
private struct PlaceholderPane: View {
    let pane: Pane

    var body: some View {
        PaneWindow(header: PaneHeader(title: pane.name)) {
            RoundedRectangle(cornerRadius: 8).fill(pane.tint.opacity(0.12))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        } controls: { _ in
            RoundedRectangle(cornerRadius: 20).fill(Theme.placeholder)
                .frame(height: Metrics.controlHeight)
        }
    }
}

extension EnvironmentValues {
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
