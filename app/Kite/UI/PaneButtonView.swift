#if os(macOS)
import AppKit
import SwiftUI

/// 控制区和工具条按钮的原生版，照 PaneButtonStyle 与 PaneButtonHover：图标占 paneButton 见方，文字按字宽加左右 paneToolbarInset、
/// 至少 paneButton 宽；比按钮四边各缩 2 的胶囊在悬停时垫 0.10 灰、按下时 0.20 灰，按下时整个按钮 0.7 透明；
/// 实心的（发送、停止）胶囊填色，内容白色粗体，悬停、按下的灰叠在填色上面；禁用时 0.45 透明、不接悬停与点击，可点时手形指针。
/// 命中范围是整个按钮大小的胶囊。按下后移出按钮不算，移回来接着算，在按钮里松手才触发，和 SwiftUI 的 Button 一样。
/// 全键盘访问打开时可以 Tab 到，空格触发，焦点环是同一个胶囊。玻璃由所在容器提供。
final class PaneButtonView: NSView {
    enum Label: Equatable {
        case symbol(String)
        case text(String)
    }

    var label: Label = .symbol("circle") {
        didSet { if label != oldValue { labelChanged() } }
    }
    /// 实心按钮的填色；nil 是普通按钮。
    var fill: Color? {
        didSet { if fill != oldValue { labelChanged() } }
    }
    /// 内容色，实心按钮不用（白色）。
    var foreground: Color = .secondary {
        didSet { if foreground != oldValue { applyColors() } }
    }
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { pressed = false }
            updateState()
            window?.invalidateCursorRects(for: self)
        }
    }
    /// 解析颜色用的 SwiftUI 环境（主题色等从这里来），外观按这个视图自己的。
    var environment = EnvironmentValues() {
        didSet { applyColors() }
    }
    var action: (() -> Void)?
    /// 读屏念的名字。
    var title = "" {
        didSet { setAccessibilityLabel(title) }
    }

    private let image = NSImageView()
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var text = NSAttributedString()
    /// text 的字宽，取整到点。
    private var textWidth: CGFloat = 0
    private var hovered = false
    private var pressed = false

    /// 胶囊比按钮四边缩进多少。
    private static let inset: CGFloat = 2

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        image.imageScaling = .scaleNone
        image.isEditable = false
        image.refusesFirstResponder = true
        addSubview(image)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 正文字号；实心按钮加粗。字体随环境变时由外面再设一次。
    func setFont(_ font: NSFont) {
        guard font != self.font else { return }
        self.font = font
        labelChanged()
    }

    /// 按内容的宽：图标是 paneButton 见方，文字按字宽加两边留白，至少 paneButton。字宽在标签、字体变了时量一次（textWidth），
    /// 拖缝时底栏每步都要排，不再每次量字。
    var width: CGFloat {
        switch label {
        case .symbol: Metrics.paneButton
        case .text: max(textWidth + 2 * Metrics.paneToolbarInset, Metrics.paneButton)
        }
    }

    private var weightedFont: NSFont {
        fill == nil ? font : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private func labelChanged() {
        switch label {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: fill == nil ? .regular : .bold, scale: .medium)
            image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            image.isHidden = false
            text = NSAttributedString()
            textWidth = 0
        case .text(let string):
            image.image = nil
            image.isHidden = true
            text = NSAttributedString(string: string, attributes: [.font: weightedFont])
            textWidth = ceil(text.size().width)
        }
        applyColors()
        needsLayout = true
        needsDisplay = true
    }

    private func applyColors() {
        image.contentTintColor = fill == nil ? resolved(foreground) : .white
        needsDisplay = true
    }

    /// 颜色按这个视图当前的外观解析成 SwiftUI 里同样的值。
    private func resolved(_ color: Color) -> NSColor {
        var environment = environment
        environment.colorScheme = effectiveAppearance.isDark ? .dark : .light
        return NSColor(cgColor: color.resolve(in: environment).cgColor) ?? .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        if let symbol = image.image {
            // 横向按字形的对齐范围居中、取整到像素（同 SwiftUI：mic 图宽 14、对齐宽 13.5，SwiftUI 画在 7.5，按图宽居中是 7，2026-10-13 逐像素比过）
            let size = symbol.size, alignment = symbol.alignmentRect
            let scale = window?.backingScaleFactor ?? 2
            let x = (((bounds.width - alignment.width) / 2 - alignment.minX) * scale).rounded() / scale
            image.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
    }

    private var capsule: CGRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    private func capsulePath(_ rect: CGRect) -> NSBezierPath {
        let radius = min(rect.width, rect.height) / 2
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = capsulePath(capsule)
        if let fill {
            resolved(fill).setFill()
            path.fill()
        }
        let feedback: CGFloat = pressed && isEnabled ? 0.20 : hovered && isEnabled ? 0.10 : 0
        if feedback > 0 {
            resolved(Color.gray.opacity(feedback)).setFill()
            path.fill()
        }
        if case .text(let string) = label {
            let color = fill == nil ? resolved(foreground) : .white
            let line = NSAttributedString(string: string, attributes: [.font: weightedFont, .foregroundColor: color])
            // 同 SwiftUI 的 Text：一行的高（不取整到点）居中，位置和高都取整到像素（2026-10-13 逐像素比过）
            let scale = window?.backingScaleFactor ?? 2
            func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            let height = pixel(weightedFont.ascender - weightedFont.descender + weightedFont.leading)
            let width = textWidth
            line.draw(with: CGRect(x: (bounds.width - width) / 2, y: pixel((bounds.height - height) / 2), width: width, height: height),
                      options: [.usesLineFragmentOrigin])
        }
    }

    private func updateState() {
        alphaValue = !isEnabled ? 0.45 : pressed ? 0.7 : 1
        needsDisplay = true
    }

    // MARK: - 悬停与点击

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// 窗口过渡中（拖动、拖缝、排布动画）整个窗口的光标区域暂停（见 freezesCursor），这时不算悬停，同 SwiftUI 版过渡中卡片不接悬停。
    private func setHovered(_ hovered: Bool) {
        let hovered = hovered && window?.areCursorRectsEnabled != false
        guard hovered != self.hovered else { return }
        self.hovered = hovered
        needsDisplay = true
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return capsulePath(bounds).contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        setPressed(capsulePath(bounds).contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = capsulePath(bounds).contains(convert(event.locationInWindow, from: nil))
        setPressed(false)
        if inside { action?() }
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != self.pressed else { return }
        self.pressed = pressed
        updateState()
    }

    // MARK: - 键盘与读屏

    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        capsulePath(bounds).fill()
    }

    override func keyDown(with event: NSEvent) {
        if isEnabled, event.charactersIgnoringModifiers == " " { action?() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
#endif
