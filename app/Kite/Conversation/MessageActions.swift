import SwiftUI

/// 对话里的一行认谁：人发的消息按消息的 id（排队中和收到了是同一行），其余按记录派生出来的序号。
/// 点开了操作栏的那一行也这样认。
enum RowID: Hashable {
    case item(Int)
    case message(String)
}

extension EnvironmentValues {
    /// 对话里点开了操作栏的那一行，一次只有一行。ThreadPane 给出，点别处、滚动时收起。
    @Entry var selectedRow: Binding<RowID?> = .constant(nil)
    /// 对话里没被标题栏、控制区挡住的那一段有多高，从标题栏底下算起。操作栏按它决定放在上面还是底下。ThreadPane 给出。
    @Entry var visibleHeight = CGFloat.infinity
}

extension Binding where Value == RowID? {
    /// 长按显示这一行的操作栏；继续拖动选字时由文本组件收起。
    func show(_ id: RowID) {
        withAnimation(.actionBar) { wrappedValue = id }
    }

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
    /// 在这里打开这一行的操作栏：iPhone 上长按，Mac 上右键（或按住 Control 点）开关。
    /// Mac 上左键留给选字：开着文字选择的字会把单击整个吃掉，点击手势收不到（实测）。
    /// iPhone 的可选文字由 SelectableTextView 协调长按和拖动选字，不再额外挂这个手势。
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
        content.onLongPressGesture(minimumDuration: 0.4, maximumDistance: 8) { selection.show(id) }
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
                let room = Metrics.actionBarGap + Metrics.paneToolbarHeight
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
