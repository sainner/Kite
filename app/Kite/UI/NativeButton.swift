#if os(macOS)
import AppKit
import SwiftUI

/// Mac 原生按钮的公共底子：对话里的行头、卡片按钮、操作栏、输入区和窗口外壳的按钮都从它派生，行为同 SwiftUI 的 Button，
/// 子类只管自己的样子（stateChanged）。
/// - 点击：按下后在范围里松开才算一次；按住拖出范围就不算按着，拖回来接着算。范围是 contains（默认整个视图，胶囊样子的按胶囊）。
///   整个按钮是一个命中目标，点到里面的字、图标也是按钮接；嵌在里面的按钮照常自己接。
///   不在前台的窗口里第一下只激活窗口，同 SwiftUI 的托管视图。
/// - 悬停：tracksHover 打开时跟；窗口过渡中（台面暂停了光标区域，见 StageView）不算悬停，同过渡中卡片不接悬停。
/// - 停用：不接悬停和点击，指针不变手形，读屏是停用的按钮。可点时手形指针。
/// - 键盘：打开系统的「键盘导航」时能用 Tab 走到，画焦点环（胶囊，整行的按钮画矩形），空格、回车按下。
/// - 读屏：按钮，按下就是这个动作；名字由子类给（accessibilityLabel 或 setAccessibilityLabel）。
class NativeButton: NSView, NativeCursor {
    var action: (() -> Void)?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { hovered = false; pressed = false }
            stateChanged()
            window?.invalidateCursorRects(for: self)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    private(set) var hovered = false {
        didSet { if hovered != oldValue { stateChanged() } }
    }
    private(set) var pressed = false {
        didSet { if pressed != oldValue { stateChanged(); pressChanged(pressed) } }
    }
    /// 悬停时要不要变样子。
    var tracksHover = false { didSet { updateTrackingAreas() } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 样子跟着状态变。
    func stateChanged() {}
    /// 按下、松开（含拖出范围）。
    func pressChanged(_ pressed: Bool) {}

    /// 这一点（自己的坐标）在不在按钮的范围里：命中、按着拖出拖回都按它。
    func contains(_ point: CGPoint) -> Bool { bounds.contains(point) }

    /// 整个按钮大小的胶囊。
    var capsulePath: NSBezierPath {
        let radius = min(bounds.width, bounds.height) / 2
        return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateChanged()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview, contains(convert(point, from: superview)) else { return nil }
        // 嵌在里面的按钮自己接，别的（字、图标）都算按钮
        if let hit = super.hitTest(point), hit !== self, let inner = hit.enclosingButton(below: self) { return inner }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard tracksHover else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = isEnabled && window?.areCursorRectsEnabled != false }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    var nativeCursor: NSCursor? { isEnabled ? .pointingHand : nil }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action?() }
    }

    // MARK: - 键盘

    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
        if isEnabled, event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 {
            action?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        capsulePath.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: - 读屏

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }
}

private extension NSView {
    /// 从这里往上找，到 outer 为止，最近的按钮。
    func enclosingButton(below outer: NSView) -> NativeButton? {
        var view: NSView? = self
        while let current = view, current !== outer {
            if let button = current as? NativeButton { return button }
            view = current.superview
        }
        return nil
    }
}

/// 悬停垫一块灰、按下深一点的按钮，同 PaneButtonHover：灰色胶囊按 inset 缩进（左右另给时按 horizontalInset），悬停 0.10、按下 0.20；
/// 范围是整个按钮大小的胶囊（PaneButtonHover 的 contentShape(Capsule())）；停用时整体淡到 0.45；
/// pressedOpacity 是按下时整体淡到多少（PaneButtonStyle 0.7，标题栏那种 1）。灰块在子视图（图标、字）下面；
/// 实心按钮（PaneButtonView 的 fill）的灰块盖在内容上面，同 PaneButtonHover 有填色时把反馈放在 overlay 里。
class HighlightButton: NativeButton {
    let highlight = CALayer()
    var inset = CGSize(width: 2, height: 2) { didSet { needsLayout = true } }
    var pressedOpacity: CGFloat = 0.7
    /// 灰块盖在内容上面。
    var highlightsOverContent = false {
        didSet { highlight.zPosition = highlightsOverContent ? 1 : 0 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        tracksHover = true
        layer?.addSublayer(highlight)
        highlight.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func contains(_ point: CGPoint) -> Bool { capsulePath.contains(point) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx: inset.width, dy: inset.height)
        highlight.cornerRadius = min(highlight.frame.width, highlight.frame.height) / 2
        CATransaction.commit()
    }

    override func stateChanged() {
        let opacity: CGFloat = pressed && isEnabled ? 0.20 : hovered && isEnabled ? 0.10 : 0
        var color = NSColor(Color.gray.opacity(opacity)).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor(Color.gray.opacity(opacity)).cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.backgroundColor = color
        CATransaction.commit()
        alphaValue = !isEnabled ? 0.45 : pressed ? pressedOpacity : 1
    }
}

/// 原生视图在指针下要的光标，和它的光标区域（addCursorRect）一致。托管在 SwiftUI 里时（输入区玻璃里的输入框、按钮），
/// AppKit 把 cursorUpdate 交给托管视图里面 SwiftUI 自己的视图，往外传到窗口设回箭头，原生视图的光标区域和 cursorUpdate 都轮不到
/// （2026-10-16 记录到）。托管它们的视图在 cursorUpdate 里按 nativeCursorUnderPointer 设，见 ThreadIsland。
/// 能编辑的文字控件不用声明，见 ownCursor。
@MainActor protocol NativeCursor: NSView {
    /// 指针在这个视图上时的光标；nil 交给外层。
    var nativeCursor: NSCursor? { get }
}

extension NSView {
    /// 指针下、在这个视图里面的原生视图要的光标：从指针下最里面的视图往外，到这个视图为止，第一个给出光标的。
    func nativeCursorUnderPointer() -> NSCursor? {
        guard let window, let root = window.contentView?.superview else { return nil }
        var view = root.hitTest(window.mouseLocationOutsideOfEventStream)
        var cursor: NSCursor?
        while let current = view {
            if current === self { return cursor }
            if cursor == nil { cursor = current.ownCursor }
            view = current.superview
        }
        return nil
    }

    /// 视图自己在指针下要的光标：NativeCursor 声明的；能编辑的文字控件一律文字光标，不用逐个声明——输入区的输入框、
    /// 回应卡片里 SwiftUI 输入框底下的 NSTextField、点进去以后接手的字段编辑器都算。原来只认声明过的，卡片里的输入框
    /// 没声明，点进去就成了箭头（2026-10-18）；每加一种控件都要记得声明，所以光标反复丢。
    private var ownCursor: NSCursor? {
        if let native = self as? NativeCursor { return native.nativeCursor }
        if let field = self as? NSTextField { return field.isEnabled && field.isEditable ? .iBeam : nil }
        if let text = self as? NSTextView { return text.isEditable ? .iBeam : nil }
        return nil
    }
}
#endif
