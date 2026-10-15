import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 台面上的临时窗口（资源库的变量窗口）点外面就关：放在窗口正文里，同一个 App 窗口里按下时命中的视图不在这张卡片里（正文、标题栏都算），
/// 也不是打开它的按钮（OutsideClickButton），就调 dismiss。只看不拦，按下照常交给点到的地方。
/// 都按命中的视图认，不按位置换算：台面上的托管视图从窗口原点铺开（见 HostedContentContainer），里面的视图换算出的可见范围不可靠，
/// 2026-10-15 实测点上下文窗口任何地方都落在胶囊的范围里；命中的视图每次都对。
/// 紧凑布局里窗口占满内容区、不在卡片里，什么也不做。
struct OutsideClickDismissal {
    /// 按下时才问；为 true 时不关，比如排布正在动，窗口这时不接点击，点到的都在别处。
    let paused: () -> Bool
    let dismiss: () -> Void
}

/// 点了不算点在临时窗口外面的按钮（变量胶囊）：原生按钮盖在样子上面接点击，临时窗口按命中的视图认出它，换内容还是关掉由 action 决定。
/// 按下时 pressed 为 true，样子据此变淡；读屏是名为 label 的按钮。
struct OutsideClickButton {
    let label: String
    let action: () -> Void
    @Binding var pressed: Bool
}

#if os(macOS)
extension OutsideClickDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> Monitor { Monitor() }

    func updateNSView(_ view: Monitor, context: Context) {
        view.paused = paused
        view.dismiss = dismiss
    }

    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: NSView {
        var paused: () -> Bool = { false }
        var dismiss: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.check(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func check(_ event: NSEvent) {
            guard let window, event.window === window, !paused(), let card = enclosing(CardView.self) else { return }
            let hit = window.contentView?.hitTest(event.locationInWindow)
            if let hit, hit.isDescendant(of: card) || hit.enclosing(OutsideClickButton.Target.self) != nil { return }
            dismiss()
        }
    }
}

extension OutsideClickButton: NSViewRepresentable {
    func makeNSView(context: Context) -> Target { Target() }

    func updateNSView(_ view: Target, context: Context) {
        view.action = action
        view.onPress = { pressed = $0 }
        view.setAccessibilityLabel(label)
        view.toolTip = label
    }

    final class Target: NativeButton {
        var onPress: (Bool) -> Void = { _ in }
        override func pressChanged(_ pressed: Bool) { onPress(pressed) }
    }
}

private extension NSView {
    /// 自己或往上最近的 T。
    func enclosing<T: NSView>(_ type: T.Type) -> T? {
        var view: NSView? = self
        while let current = view {
            if let found = current as? T { return found }
            view = current.superview
        }
        return nil
    }
}
#else
extension OutsideClickDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> Monitor { Monitor() }

    func updateUIView(_ view: Monitor, context: Context) {
        view.paused = paused
        view.dismiss = dismiss
    }

    static func dismantleUIView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: UIView {
        var paused: () -> Bool = { false }
        var dismiss: () -> Void = {}
        private var observer: TouchDownObserver?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard let window else { return }
            let observer = TouchDownObserver { [weak self] touch in self?.check(touch) }
            window.addGestureRecognizer(observer)
            self.observer = observer
        }

        func stop() {
            if let observer { observer.view?.removeGestureRecognizer(observer) }
            observer = nil
        }

        private func check(_ touch: UITouch) {
            guard !paused(), let card = enclosing(PhoneCardView.self) else { return }
            if let hit = touch.view, hit.isDescendant(of: card) || hit.enclosing(OutsideClickButton.Target.self) != nil { return }
            dismiss()
        }
    }
}

extension OutsideClickButton: UIViewRepresentable {
    func makeUIView(context: Context) -> Target { Target() }

    func updateUIView(_ view: Target, context: Context) {
        view.action = action
        view.onPress = { pressed = $0 }
        view.accessibilityLabel = label
    }

    final class Target: NativeButton {
        var onPress: (Bool) -> Void = { _ in }
        private var reported = false

        override func stateChanged() {
            guard pressed != reported else { return }
            reported = pressed
            onPress(pressed)
        }
    }
}

private extension UIView {
    /// 自己或往上最近的 T。
    func enclosing<T: UIView>(_ type: T.Type) -> T? {
        var view: UIView? = self
        while let current = view {
            if let found = current as? T { return found }
            view = current.superview
        }
        return nil
    }
}

/// 只看按下不认：按下就放弃，不挡别的手势，也不推迟点击。
private final class TouchDownObserver: UIGestureRecognizer {
    private let began: (UITouch) -> Void

    init(_ began: @escaping (UITouch) -> Void) {
        self.began = began
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { began(touch) }
        state = .failed
    }
}
#endif
