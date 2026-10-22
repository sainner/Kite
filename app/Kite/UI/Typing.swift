#if os(macOS)
import AppKit
#endif
import SwiftUI

extension View {
    /// 打字时点这块区域收起键盘，只在 iPhone 上。和区域里原有的点按（展开折起来的一行等）同时生效，不抢它们；
    /// 点到区域里标了 typingTarget 的输入框不算。
    func endsTyping(_ typing: Bool, end: @escaping () -> Void) -> some View {
        modifier(EndsTyping(typing: typing, end: end))
    }

    /// 原地编辑的输入框（改名这类，见 InlineNameField）：按到它外面的任何地方就交出焦点，提交还是收起由它自己的失焦处理决定。
    /// AppKit 和 UIKit 按到不接焦点的地方（空白、列表行）都不会让输入框失焦。加在 TextField 上，editing 是它自己有没有焦点。
    func endsEditingOnOutsideTap(_ editing: Bool) -> some View {
        background(OutsideTapEndsEditing(active: editing))
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

    /// 能滚动的多行输入框只在打字时滚：没在打字时在框里拖，拖动留给所在的地方（控制区上拉抽屉、横滑换窗口、外面的滚动），
    /// 框里的字不跟着滚。加在 TextField 上，typing 是它自己有没有焦点。只在 iPhone 与 iPad 上。
    @ViewBuilder
    func scrollsOnlyWhileTyping(_ typing: Bool) -> some View {
        #if os(iOS)
        background(TextScrollLock(locked: !typing))
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// 所在区域正在打字，里面的输入框要报上自己的位置。
    @Entry var collectsTypingTargets = false
}

extension ContainerValues {
    /// 窗口控制区里的这一项自己排了收起键盘按钮（上下文编辑工具栏、网页预览的浏览控件），窗口不再在左边加。
    @Entry var placesKeyboardButton = false
}

/// iPhone 上有底栏的地方，键盘升起时在底栏最左边放收起键盘：窗口的控制区由 PaneWindow 加，弹窗与初始配置的按钮栏由 CardActions 加。
/// 收的是当前的输入框，SwiftUI 的输入框和 UITextView 一样，焦点状态跟着同步。
/// 只放在给键盘让位的地方（keyboardShown）：紧凑布局里只有外壳上的那一条控制区知道键盘升了（见 CompactPaneControlsBar）。
/// 横滑那一行的窗口都建着，按钮插进每个窗口的控制区的话，每个控制区都要重排、把输入框重量一遍，
/// 三个窗口时键盘升起多卡约 70 毫秒（2026-10-11 真机实测）。
struct KeyboardDismissButton: View {
    static let icon = "keyboard.chevron.compact.down"
    @Environment(\.keyboardShown) private var keyboardShown

    var body: some View {
        #if os(iOS)
        if ScreenKeyboard.shared.shown && keyboardShown {
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

/// 控制区里的一组按钮在键盘升起时原地换成另一组，什么时候算升起同 KeyboardDismissButton（只在 iPhone 上）；active 为 false 时不换。
/// 网页预览用它把后退换成收起键盘、重新加载换成清除输入。自己放了收起键盘的控制区要标 placesKeyboardButton，不在最左边再加一个。
struct KeyboardSwap<Normal: View, Shown: View>: View {
    var active = true
    @ViewBuilder var normal: Normal
    @ViewBuilder var shown: Shown
    @Environment(\.keyboardShown) private var keyboardShown

    var body: some View {
        #if os(iOS)
        // 原地换掉，两块玻璃不互相融合
        if active && ScreenKeyboard.shared.shown && keyboardShown {
            shown.glassEffectTransition(.identity)
        } else {
            normal.glassEffectTransition(.identity)
        }
        #else
        normal
        #endif
    }
}

#if os(iOS)
/// 多行 TextField 在 iOS 上是一个 UITextView，scrollDisabled 管不到它（iOS 26 模拟器实测 isScrollEnabled 不变）。
/// 垫在输入框后面的空视图按屏幕上的位置找到重合的那个 UITextView，没在打字时停掉它的滚动手势。
/// 按渲染后的位置找：紧凑布局几个窗口排版位置相同，只在渲染时平移开（模拟器实测叠放两框能各自配对）。
private struct TextScrollLock: UIViewRepresentable {
    let locked: Bool

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.locked = locked
        view.apply()
    }

    final class Probe: UIView {
        var locked = true
        private weak var target: UITextView?
        /// 进窗口后没找到时只再等一轮。
        private var retried = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            retried = false
            apply()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        func apply() {
            if target?.window == nil { target = find() }
            if let target {
                target.panGestureRecognizer.isEnabled = !locked
            } else if window != nil, !retried {
                // 输入框可能还没排好，下一轮再找一次
                retried = true
                DispatchQueue.main.async { [weak self] in self?.apply() }
            }
        }

        /// 从近到远往上找，取和自己重合得最多的可编辑 UITextView。
        private func find() -> UITextView? {
            guard let window, bounds.width > 0, bounds.height > 0 else { return nil }
            let mine = convert(bounds, to: window)
            func overlap(_ view: UITextView) -> CGFloat {
                let shared = view.convert(view.bounds, to: window).intersection(mine)
                return shared.isNull ? 0 : shared.width * shared.height
            }
            func editable(in view: UIView) -> [UITextView] {
                if let text = view as? UITextView { return text.isEditable ? [text] : [] }
                return view.subviews.flatMap(editable)
            }
            var ancestor = superview
            while let view = ancestor {
                if let best = editable(in: view).max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
                ancestor = view.superview
            }
            return nil
        }
    }
}

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

/// 垫在输入框后面量它的范围；有焦点时盯着整个 App 的按下，按在范围外就让输入框交出焦点。按下照常往下分发，点到的东西照常响应。
#if os(macOS)
private struct OutsideTapEndsEditing: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) { view.active = active }

    final class Anchor: NSView {
        var active = false { didSet { if active != oldValue { watch() } } }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch()
        }

        private func watch() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard active, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.end(unless: event)
                return event
            }
        }

        private func end(unless event: NSEvent) {
            guard let window else { return }
            let frame = convert(bounds, to: nil)
            if event.window === window, frame.contains(event.locationInWindow) { return }
            // 只收自己的：焦点已经换到别的输入框的不动
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView, field.convert(field.bounds, to: nil).intersects(frame) else { return }
            window.makeFirstResponder(nil)
        }
    }
}
#else
private struct OutsideTapEndsEditing: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ view: Anchor, context: Context) { view.active = active }

    final class Anchor: UIView, UIGestureRecognizerDelegate {
        var active = false { didSet { if active != oldValue { watch() } } }
        private var tap: UITapGestureRecognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            watch()
        }

        /// 点按挂在窗口上，不拦触摸、和别的手势同时认，滑动不算。
        private func watch() {
            if let tap { tap.view?.removeGestureRecognizer(tap) }
            tap = nil
            guard active, let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            self.tap = tap
        }

        @objc private func tapped(_ tap: UITapGestureRecognizer) {
            guard let window, !convert(bounds, to: window).contains(tap.location(in: window)) else { return }
            dismissKeyboard()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
