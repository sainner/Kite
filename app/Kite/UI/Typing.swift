import SwiftUI

extension View {
    /// 打字时点这块区域收起键盘，只在 iPhone 上。和区域里原有的点按（展开折起来的一行等）同时生效，不抢它们；
    /// 点到区域里标了 typingTarget 的输入框不算。
    func endsTyping(_ typing: Bool, end: @escaping () -> Void) -> some View {
        modifier(EndsTyping(typing: typing, end: end))
    }

    /// 没有底栏的页面（单页表单、侧栏搜索）在 iPhone 键盘上方放收起键盘；有底栏的窗口和弹窗由底栏给，见 KeyboardDismissButton。
    @ViewBuilder
    func keyboardDismissToolbar() -> some View {
        #if os(iOS)
        toolbar {
            if ScreenKeyboard.applies {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("收起键盘", systemImage: KeyboardDismissButton.icon, action: dismissKeyboard)
                    Spacer()
                }
            }
        }
        #else
        self
        #endif
    }

    /// 标出一块输入框：点它是要打字，所在区域的 endsTyping 不收键盘。
    func typingTarget() -> some View { modifier(TypingTarget()) }
}

extension EnvironmentValues {
    /// 所在区域正在打字，里面的输入框要报上自己的位置。
    @Entry var collectsTypingTargets = false
}

extension ContainerValues {
    /// 窗口控制区里的这一项自己排了收起键盘按钮（上下文编辑工具栏），窗口不再在左边加。
    @Entry var placesKeyboardButton = false
}

/// iPhone 上有底栏的地方，键盘升起时在底栏最左边放收起键盘：窗口的控制区由 PaneWindow 加，弹窗与初始配置的按钮栏由 CardActions 加。
/// 收的是当前的输入框，SwiftUI 的输入框和 UITextView 一样，焦点状态跟着同步。
struct KeyboardDismissButton: View {
    static let icon = "keyboard.chevron.compact.down"

    var body: some View {
        #if os(iOS)
        if ScreenKeyboard.shared.shown {
            PaneHeaderButtonGroup {
                // 等按钮松手这次更新过去再收：同步收的话键盘让位会沿用玻璃松手的回弹，整条底栏落下时弹一下
                ActionButton("收起键盘", icon: Self.icon) { Task { dismissKeyboard() } }
            }
            // 出现、消失时占的是空白，玻璃不和旁边融合
            .glassEffectTransition(.identity)
        }
        #endif
    }
}

#if os(iOS)
/// 让当前的输入框交出焦点，键盘随之收起。
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// iPhone 的屏幕键盘是否升起，按系统的键盘通知记下。iPad 的键盘自带收起键，不加按钮。
@Observable
final class ScreenKeyboard {
    static let applies = UIDevice.current.userInterfaceIdiom == .phone
    static let shared = ScreenKeyboard()
    private(set) var shown = false

    private init() {
        guard Self.applies else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(true) }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(false) }
        }
    }

    /// 带着动画改：收起键盘按钮插进底栏、撤出来时，旁边的输入框和按钮跟着让位。
    /// 换输入框、换键盘类型也会再来一次升起的通知，没变就不动。
    private func update(_ shown: Bool) {
        guard shown != self.shown else { return }
        withAnimation(.snappy) { self.shown = shown }
    }
}
#endif

/// 只在所在区域打字时量位置：窗口移动、缩放时位置每帧都变，平时不往上报。
private struct TypingTarget: ViewModifier {
    @Environment(\.collectsTypingTargets) private var collecting

    func body(content: Content) -> some View {
        content.background {
            if collecting {
                GeometryReader { geo in
                    Color.clear.preference(key: TypingTargets.self, value: [geo.frame(in: .global)])
                }
            }
        }
    }
}

/// 输入框的位置只在点按时拿来比对，存在这里，变了不引起视图更新。
private final class TypingTargetFrames {
    var frames: [CGRect] = []
}

private struct TypingTargets: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private struct EndsTyping: ViewModifier {
    let typing: Bool
    let end: () -> Void
    @State private var targets = TypingTargetFrames()

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(\.collectsTypingTargets, typing)
            .onPreferenceChange(TypingTargets.self) { [targets] frames in Task { @MainActor in targets.frames = frames } }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                if !targets.frames.contains(where: { $0.contains(tap.location) }) { end() }
            }, isEnabled: typing)
        #else
        content
        #endif
    }
}
