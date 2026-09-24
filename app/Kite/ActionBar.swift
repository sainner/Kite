import SwiftUI

/// 对话里的一行认谁：人发的消息按消息的 id（排队中和收到了是同一行），其余按记录派生出来的序号。
/// 点开了操作栏的那一行也这样认。
enum RowID: Hashable {
    case item(Int)
    case message(UUID)
}

extension EnvironmentValues {
    /// 对话里点开了操作栏的那一行，一次只有一行。SessionPane 给出，点别处、滚动时收起。
    @Entry var selectedRow: Binding<RowID?> = .constant(nil)
    /// 对话里没被标题栏、控制区挡住的那一段有多高，从标题栏底下算起。操作栏按它决定放在上面还是底下。SessionPane 给出。
    @Entry var visibleHeight = CGFloat.infinity
}

extension Binding where Value == RowID? {
    /// 点了这一行：没开就打开它的操作栏（别的收起），开着就收起。
    func toggle(_ id: RowID) {
        withAnimation(.actionBar) { wrappedValue = wrappedValue == id ? nil : id }
    }

    /// 收起操作栏。
    func close() {
        withAnimation(.actionBar) { wrappedValue = nil }
    }
}

extension Animation {
    /// 开关操作栏时别处跟着变的（比如这一行垫到最上面）。操作栏自己的出现、收起见 ActionBar。
    static let actionBar = Animation.snappy(duration: 0.25)
}

extension View {
    /// 在这里打开这一行的操作栏，开着就收起：iPhone 上点一下，Mac 上右键（或按住 Control 点）。
    /// Mac 上左键留给选字：开着文字选择的字会把单击整个吃掉，点击手势收不到（实测）。
    /// iPhone 上不用长按：长按是选字，两件事会一起来。
    func opensActionBar(_ id: RowID) -> some View {
        modifier(OpensActionBar(id: id))
    }

    /// 给对话里的一行挂上操作栏：这一行被点开（selectedRow 是 id）时出现。操作栏是个浮层，不挤开别的内容，
    /// 和这一行的 side 那边对齐，也从那边往外展开；平常在这一行底下，底下放不下（会压到控制区或窗口底边）就放到上面。
    /// 在哪里打开由这一行自己定（opensActionBar）。
    func actionBar<Bar: View>(_ id: RowID, side: HorizontalEdge, @ViewBuilder bar: @escaping () -> Bar) -> some View {
        modifier(ActionBarPlacement(id: id, side: side, bar: bar))
    }
}

private struct OpensActionBar: ViewModifier {
    let id: RowID
    @Environment(\.selectedRow) private var selection

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay { SecondaryClickArea { selection.toggle(id) } }
        #else
        content.onTapGesture { selection.toggle(id) }
        #endif
    }
}

#if os(macOS)
/// 盖在上面只接右键的一层。SwiftUI 没有右键手势。
private struct SecondaryClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView {
        ClickView()
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action
    }

    final class ClickView: NSView {
        var action: (() -> Void)?

        /// 只接右键和按住 Control 的左键；左键选字、滚动、悬停都让给底下
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.secondary(event) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func mouseDown(with event: NSEvent) {
            if Self.secondary(event) { action?() }
        }

        private static func secondary(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }
    }
}
#endif

private struct ActionBarPlacement<Bar: View>: ViewModifier {
    let id: RowID
    let side: HorizontalEdge
    let bar: () -> Bar
    @Environment(\.selectedRow) private var selection
    @Environment(\.visibleHeight) private var visibleHeight
    /// 操作栏放在上面：底下放不下。
    @State private var above = false

    func body(content: Content) -> some View {
        content
            // 只在跨过能不能放下的那条线时才回调，滚动时不是每一帧都重画。
            // .scrollView 的原点在标题栏底下，没被挡住的一段是 0 到 visibleHeight（实测）
            .onGeometryChange(for: Bool.self) { proxy in
                let frame = proxy.frame(in: .scrollView)
                let room = Metrics.actionBarGap + Metrics.actionBarButton
                return frame.maxY + room > visibleHeight && frame.minY - room >= 0
            } action: { above = $0 }
            .overlay(alignment: Alignment(horizontal: side == .leading ? .leading : .trailing, vertical: above ? .top : .bottom)) {
                ActionBar(shown: selection.wrappedValue == id, side: side, from: above ? .bottom : .top, content: bar)
                    // 在底下时顶边离这一行的底边 actionBarGap，在上面时底边离上边这么远。
                    // 参考线要加在 ActionBar 这一层：加在它里面 if 包着的视图上，overlay 对齐时不认（实测）
                    .alignmentGuide(above ? .top : .bottom) {
                        above ? $0[.bottom] + Metrics.actionBarGap : $0[.top] - Metrics.actionBarGap
                    }
            }
    }
}

/// 点对话里的一行弹出的操作栏：一排只有图标的按钮，装在一个液态玻璃胶囊里。
/// 出现时整条从贴着这一行、靠 side 那边的角等比放大，带一点回弹，边放大边淡显；收起时缩回那个角，不回弹，边缩边淡出。
/// 关着时什么都不画。
/// 和系统的编辑菜单（UIEditMenuInteraction）一个做法：按原本的大小排好一次，动画只改整体的缩放，不改尺寸，
/// 玻璃和按钮当一整层放大，里面不重排，也就不抖。改尺寸的做法玻璃每一帧都要把按钮重排一遍，按钮会亚像素地抖。
struct ActionBar<Content: View>: View {
    let shown: Bool
    /// 和这一行哪一边对齐。
    let side: HorizontalEdge
    /// 贴着这一行的是哪条边：在这一行底下时是上边，在上面时是下边。
    let from: VerticalEdge
    @ViewBuilder let content: () -> Content

    var body: some View {
        // 外面垫一层 ZStack：放它的地方给的对齐参考线要加在不随 shown 变的这一层才认
        ZStack {
            if shown {
                HStack(spacing: 0) { content() }
                    .padding(.horizontal, Metrics.actionBarButton / 10)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .fixedSize()
                    .transition(.scale(scale: 0.3, anchor: corner).combined(with: .opacity))
            }
        }
        // 出现和收起用各自的动画，不管开关它的那一处用的是什么
        .animation(shown ? .spring(duration: 0.35, bounce: 0.3) : .snappy(duration: 0.2), value: shown)
    }

    private var corner: UnitPoint {
        switch (side, from) {
        case (.leading, .top): .topLeading
        case (.leading, .bottom): .bottomLeading
        case (.trailing, .top): .topTrailing
        case (.trailing, .bottom): .bottomTrailing
        }
    }
}

/// 操作栏上的一个按钮。名字不显示，Mac 上鼠标停在上面时提示，读屏时读出来。
struct ActionButton: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            ActionIcon(icon: icon, destructive: role == .destructive)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 操作栏上点了再弹一层菜单的按钮，比如回退分三种。
struct ActionMenu<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        Menu {
            Section(title) { content }
        } label: {
            ActionIcon(icon: icon, destructive: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(enabled ? 1 : 0.35)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ActionIcon: View {
    let icon: String
    let destructive: Bool

    var body: some View {
        Image(systemName: icon)
            .font(Theme.body)
            .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .frame(width: Metrics.actionBarButton, height: Metrics.actionBarButton)
            .contentShape(Rectangle())
    }
}

/// 复制到剪贴板。
func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
