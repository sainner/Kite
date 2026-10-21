#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Mac 上嵌在对话正文里的一块（BlockAttachment 的视图），原生画，样子和行为照 SwiftUI 版（EmbeddedBlockView、BlockCard、CodeBlock、MarkdownTable）：
/// 代码块、表格是带标题栏的卡片，内容太宽时横着滚，里面的字能选、复制给原文；分隔线是一道细线。iPhone 仍托管 EmbeddedBlockView。
/// 高和行宽无关（太宽的横着滚），量一次就记下；内容自己变高（展开全部）时报给附件（resized）。
@MainActor class EmbeddedCardView: NSView {
    /// 内容自己变高了，附件要重排这一块。
    var resized: (() -> Void)?

    override var isFlipped: Bool { true }

    static func make(for content: EmbeddedBlock) -> EmbeddedCardView {
        switch content {
        case .markdown(let block):
            switch block.kind {
            case .table: TableCardView()
            case .rule: RuleCardView()
            default: CodeCardView()
            }
        case .bubbleCode: CodeCardView()
        }
    }

    /// 换内容或环境。markdown 是这段回复的原文，表格复制时取回原文用。
    func update(_ content: EmbeddedBlock, environment: EmbeddedEnvironment, markdown: String?) {}

    /// 按所在行的宽量出多高。
    func height(width: CGFloat) -> CGFloat { 0 }
}

/// 分隔线，同 Divider：1 pt 高，系统分隔线色。
final class RuleCardView: EmbeddedCardView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func height(width: CGFloat) -> CGFloat { 1 }
}

// MARK: - 卡片

/// 代码块、表格共用的卡片，照 BlockCard：标题栏左边是类别（等宽小字），右边是操作按钮，复制总在最右；标题栏下面一道分隔线，再下面是内容。
/// 底色按圆角（连续曲率）画、内容按它截。按住标题栏的按钮时卡片朝按钮倾斜下沉，松手回弹；Force Touch 触控板按得越重压得越深。
class BlockCardView: EmbeddedCardView {
    /// 画底色、截内容、按压时倾斜的那一层；外面这层只给 TextKit 摆位置。
    let surface = CardSurfaceView()
    private let label = LineLabel()
    private let divider = CALayer()
    private(set) var buttons: [CardButton] = []
    let copyButton = CardButton()
    /// 按压的深度：0 静止，按住为 1，Force Touch 在 0.7～1.4 之间随力度变化。
    private let depth = SpringValue()
    /// 按在卡片里的哪（0～1）。
    private var pressLocation = CGPoint(x: 0.5, y: 0.5)
    private var pressureMonitor: Any?
    private var background: Color = Theme.codeBackground
    /// 读屏时这张卡片叫什么。
    var speech = ""

    /// 标题栏的高：按钮加上下留白（codeHeaderInset）。
    static var headerHeight: CGFloat { Metrics.paneButton + Metrics.codeHeaderInset * 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(surface)
        surface.addSubview(label)
        surface.layer?.addSublayer(divider)
        divider.actions = ["position": NSNull(), "bounds": NSNull()]
        copyButton.press = { [weak self] pressed, at in self?.press(pressed, at: at) }
        surface.addSubview(copyButton)
        label.setAccessibilityElement(false)
        depth.changed = { [weak self] _ in self?.applyPress() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 换标题、底色、圆角；actions 排在复制左边。
    func configure(label text: String, copyLabel: String, background: Color, radius: CGFloat, actions: [CardButton]) {
        self.background = background
        surface.radius = radius
        let font = Font.system(.caption, design: .monospaced).resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
        label.set(text, font: font, color: .secondaryLabelColor)
        copyButton.configure(asset: "CodeCopy", label: copyLabel)
        if actions.map(ObjectIdentifier.init) != buttons.map(ObjectIdentifier.init) {
            for button in buttons { button.removeFromSuperview() }
            buttons = actions
            for button in actions {
                button.press = { [weak self] pressed, at in self?.press(pressed, at: at) }
                surface.addSubview(button)
            }
        }
        surface.fill = background
        needsLayout = true
    }

    /// 内容区从哪起。
    var contentTop: CGFloat { Self.headerHeight }

    override func layout() {
        super.layout()
        // 外面这层不动，按压只改里面那层的变换
        surface.frame = bounds
        let header = Self.headerHeight
        // 标题左边的留白让字和按钮里图标的边对齐：按钮比图标宽出的一半，再加 codeHeaderInset
        let iconSize = NSFont.preferredFont(forTextStyle: .body).pointSize
        let leading = (Metrics.paneButton - iconSize) / 2 + Metrics.codeHeaderInset
        let lineHeight = label.lineHeight
        label.frame = CGRect(x: leading, y: pixel(Metrics.codeHeaderInset + (Metrics.paneButton - lineHeight) / 2),
                             width: label.textWidth, height: lineHeight)
        var x = bounds.width - Metrics.paneToolbarInset
        for button in ([copyButton] + buttons.reversed()) {
            x -= Metrics.paneButton
            button.frame = CGRect(x: x, y: Metrics.codeHeaderInset, width: Metrics.paneButton, height: Metrics.paneButton)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Divider 在 Mac 上是 1 pt
        divider.frame = CGRect(x: 0, y: header - 1, width: bounds.width, height: 1)
        if divider.backgroundColor == nil { divider.backgroundColor = resolved(.separatorColor) }
        CATransaction.commit()
        // 改宽时（拖缝每一步）没在按就不动变换
        if depth.value != 0 || !CATransform3DIsIdentity(surface.layer?.transform ?? CATransform3DIdentity) { applyPress() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        divider.backgroundColor = resolved(.separatorColor)
        needsLayout = true
        surface.needsDisplay = true
    }

    func resolved(_ color: NSColor) -> CGColor {
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
        return cgColor
    }

    func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    // MARK: - 按压

    /// 按钮按下、松开：按下时朝按钮中心倾斜下沉（snappy 0.12 秒），松开回弹（0.35 秒、回弹 0.35），同 BlockCard。
    private func press(_ pressed: Bool, at point: CGPoint) {
        guard pressed else {
            stopPressureTracking()
            depth.animate(to: 0, spring: Spring(duration: 0.35, bounce: 0.35), in: self)
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, bounds.width > 0, bounds.height > 0 else { return }
        pressLocation = CGPoint(x: min(1, max(0, point.x / bounds.width)), y: min(1, max(0, point.y / bounds.height)))
        depth.animate(to: 1, spring: .snappy(duration: 0.12), in: self)
        startPressureTracking()
    }

    /// 只在按住期间听压力：第一阶段按压力 0～1 线性加深，到用力点按（第二阶段）时最深。
    private func startPressureTracking() {
        stopPressureTracking()
        pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] event in
            let force = event.stage >= 2 ? 1 : CGFloat(min(max(event.pressure, 0), 1))
            MainActor.assumeIsolated {
                guard let self else { return }
                self.depth.animate(to: 0.7 + 0.7 * force, spring: Spring(duration: 0.15, bounce: 0.15), in: self)
            }
            return event
        }
    }

    private func stopPressureTracking() {
        if let pressureMonitor { NSEvent.removeMonitor(pressureMonitor) }
        pressureMonitor = nil
    }

    /// 离开窗口时停掉压力监听和按压的弹簧（显示链接），回到静止。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        stopPressureTracking()
        depth.stop(at: 0)
        applyPress()
    }

    /// 同 BlockCard 的 rotation3DEffect（绕 x、绕 y，各自透视 0.4，以中心为轴）和朝按压点的 scaleEffect，按这个次序叠。
    private func applyPress() {
        guard let layer = surface.layer else { return }
        let value = depth.value
        let size = bounds.size
        var transform = CATransform3DIdentity
        if value != 0, size.width > 0, size.height > 0 {
            let tiltX = (0.5 - pressLocation.y) * 5 * value * .pi / 180
            let tiltY = (pressLocation.x - 0.5) * 5 * value * .pi / 180
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            transform = CATransform3DConcat(Self.rotation(tiltX, x: 1, y: 0, center: center, size: size),
                                            Self.rotation(tiltY, x: 0, y: 1, center: center, size: size))
            let scale = 1 - value * 0.012
            let anchor = CGPoint(x: pressLocation.x * size.width, y: pressLocation.y * size.height)
            var scaling = CATransform3DMakeTranslation(-anchor.x, -anchor.y, 0)
            scaling = CATransform3DConcat(scaling, CATransform3DMakeScale(scale, scale, 1))
            scaling = CATransform3DConcat(scaling, CATransform3DMakeTranslation(anchor.x, anchor.y, 0))
            transform = CATransform3DConcat(transform, scaling)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 翻转坐标的视图，图层坐标也是左上为原点、锚点在左上（同 BubbleView），变换按视图坐标直接用
        layer.transform = transform
        CATransaction.commit()
    }

    /// 以 center 为轴绕 (x, y) 转 angle，透视同 SwiftUI 的 rotation3DEffect(perspective: 0.4)。
    private static func rotation(_ angle: CGFloat, x: CGFloat, y: CGFloat, center: CGPoint, size: CGSize) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(-center.x, -center.y, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(angle, x, y, 0))
        var perspective = CATransform3DIdentity
        perspective.m34 = -0.4 / max(size.width, size.height)
        transform = CATransform3DConcat(transform, perspective)
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(center.x, center.y, 0))
    }

    // MARK: - 读屏

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { speech }

    /// 读屏先走标题栏的按钮（从左到右），再走内容。
    override func accessibilityChildren() -> [Any]? {
        let views = surface.subviews.filter { !$0.isHidden }.sorted {
            $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
        return NSAccessibility.unignoredChildren(from: views)
    }
}

/// 卡片里画底色、截内容的那一层：底色按圆角（连续曲率）画，子视图按同一个形状截。
final class CardSurfaceView: NSView {
    var fill: Color = Theme.codeBackground { didSet { needsDisplay = true } }
    var radius: CGFloat = Metrics.contentRadius { didSet { needsLayout = true } }
    private let shape = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = shape
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        var color = NSColor(fill).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor(fill).cgColor }
        layer?.backgroundColor = color
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        // 图层坐标原点在左下，SwiftUI 的路径按翻转的坐标给，形状上下对称，直接用
        shape.path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: bounds).cgPath
        CATransaction.commit()
    }
}

/// 卡片标题栏上的按钮，照 PaneButtonStyle：28 pt 见方，图标和正文一样大、次要色；悬停时垫一个灰色圆（每边缩 2），
/// 按下时圆深一点、整体淡到 0.7；停用时淡到 0.45、不接悬停和点击。鼠标停住时提示名字，读屏读名字。
/// 按下、松开时告诉卡片（press），卡片朝按钮倾斜。
final class CardButton: HighlightButton {
    var press: ((_ pressed: Bool, _ at: CGPoint) -> Void)?
    private let icon = NSImageView()
    private var title = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        icon.hideFromAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(asset: String, label: String) {
        title = label
        toolTip = label
        icon.image = NSImage(named: asset)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        icon.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func pressChanged(_ pressed: Bool) {
        press?(pressed, CGPoint(x: frame.midX, y: frame.midY))
    }

    override func accessibilityLabel() -> String? { title }
}

// MARK: - 代码块

/// 代码块，照 CodeBlock：标题是语言（没写是 text），shell 类的多一个「在终端中执行」（不在工作区窗口里时停用）；
/// 代码等宽、按语言着色，太宽横着滚，太长先只显示开头 14 行（只多出几行的不折），底下「显示全部 N 行」。
/// 人发的消息里的代码不折、底色是气泡里的不透明蓝、圆角和气泡同心、字是系统文字色。
final class CodeCardView: BlockCardView {
    private let scroller = OverflowScrollView()
    private let text = CodeTextView()
    private let terminal = CardButton()
    private let foldButton = TextButton()
    private var code = ""
    private var language: String?
    private var maxLines: Int? = 14
    private var expanded = false
    private var environment: EmbeddedEnvironment?
    /// 着色：哪一份代码、深浅色，和着好的串。
    private var highlighted: (code: String, dark: Bool, text: NSAttributedString)?
    private var highlighting: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroller.document.addSubview(text)
        surface.addSubview(scroller)
        surface.addSubview(foldButton)
        terminal.configure(asset: "CodeTerminal", label: "在终端中执行")
        terminal.toolTip = "在终端中执行"
        terminal.action = { [weak self] in
            guard let self else { return }
            environment?.runInTerminal?.run(code)
        }
        foldButton.action = { [weak self] in self?.expand() }
        copyButton.action = { [weak self] in
            guard let self else { return }
            copyToPasteboard(code, toast: environment?.toast)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var languageLabel: String {
        language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "text"
    }

    private var isShell: Bool {
        ["bash", "sh", "shell", "zsh", "ksh", "fish"].contains(languageLabel.lowercased())
    }

    override func update(_ content: EmbeddedBlock, environment: EmbeddedEnvironment, markdown: String?) {
        self.environment = environment
        let bubble: Bool, user: Bool
        switch content {
        case .markdown(let block):
            guard case .code(let language) = block.kind else { return }
            code = String(block.text.characters)
            self.language = language
            maxLines = 14
            (bubble, user) = (false, false)
        case .bubbleCode(let text, let language, let fromUser):
            code = text
            self.language = language
            // 整条消息统一折叠，代码不再单独截断
            maxLines = nil
            (bubble, user) = (true, fromUser)
        }
        configure(label: languageLabel, copyLabel: "复制代码", background: user ? Theme.userCodeBackground : Theme.codeBackground,
                  radius: bubble ? Metrics.nestedRadius(inset: Metrics.bubblePadding.height) : Metrics.contentRadius,
                  actions: isShell ? [terminal] : [])
        terminal.isEnabled = environment.runInTerminal != nil
        let secondary = Theme.secondary.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
        foldButton.style(font: secondary, color: .secondaryLabelColor)
        speech = TranscriptSpeech.code(language: languageLabel)
        show()
    }

    /// 折着时显示的那几行和总行数。只多出几行的不折，省得点一下只多看两行，同 Folded。
    private var shown: (text: String, total: Int, folded: Bool) {
        let lines = splitLines(code)
        let limit = maxLines ?? lines.count
        let folded = !expanded && lines.count > limit + 4
        return (folded ? lines.prefix(limit).joined(separator: "\n") : lines.joined(separator: "\n"), lines.count, folded)
    }

    private func show() {
        let shown = shown
        let font = Theme.code.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        text.show(colored(shown.text, dark: dark), font: font, plain: shown.text)
        foldButton.title = "显示全部 \(shown.total) 行"
        foldButton.isHidden = !shown.folded
        highlight(shown.text, dark: dark)
        needsLayout = true
    }

    /// 着好色的串：这份代码着过色就用；流式时新代码接着旧的往后长，旧的那截先用着旧的颜色，新长出来的先不着色，免得每次刷新整段闪成白的。
    private func colored(_ code: String, dark: Bool) -> NSAttributedString? {
        guard let highlighted, highlighted.dark == dark else { return nil }
        if highlighted.code == code { return highlighted.text }
        guard code.hasPrefix(highlighted.code) else { return nil }
        let result = NSMutableAttributedString(attributedString: highlighted.text)
        result.append(NSAttributedString(string: String(code.dropFirst(highlighted.code.count))))
        return result
    }

    /// 着色在后台的解析器里做，着好了换上，同 HighlightedCode。
    private func highlight(_ code: String, dark: Bool) {
        guard highlighted?.code != code || highlighted?.dark != dark else { return }
        highlighting?.cancel()
        let language = language
        highlighting = Task { [weak self] in
            let result = await CodeHighlighter.shared.highlight(code, language: language, dark: dark)
            guard !Task.isCancelled, let self else { return }
            let colored = (try? NSAttributedString(result, including: \.appKit)) ?? NSAttributedString(string: code)
            highlighted = (code, dark, colored)
            if self.shown.text == code { show() }
        }
    }

    private func expand() {
        expanded = true
        show()
        resized?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !code.isEmpty { show() }
    }

    /// 标题栏、代码（左右各 12、上下各 10 的留白）、折着时底下的按钮（左右各 12、下面 10）。
    override func height(width: CGFloat) -> CGFloat {
        let shown = shown
        var height = contentTop + text.size.height + 20
        if shown.folded { height += foldButton.lineHeight + 10 }
        return height
    }

    override func layout() {
        super.layout()
        let size = text.size
        let codeHeight = size.height + 20
        scroller.frame = CGRect(x: 0, y: contentTop, width: bounds.width, height: codeHeight)
        scroller.contentWidth = size.width + 24
        text.frame = CGRect(x: 12, y: 10, width: size.width, height: size.height)
        foldButton.frame = CGRect(x: 12, y: contentTop + codeHeight, width: foldButton.width, height: foldButton.lineHeight)
    }
}

/// 代码的文本视图：不折行、只读、能选，复制给原样的代码。TextKit 2，量出排好的宽和高。
final class CodeTextView: ProseTextView {
    private(set) var size: CGSize = .zero

    convenience init() {
        self.init(usingTextLayoutManager: true)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        usesFontPanel = false
        setAccessibilityLabel("代码")
    }

    /// colored 是着好色的串（只有颜色），没有时按系统文字色排。
    func show(_ colored: NSAttributedString?, font: NSFont, plain: String) {
        let result = NSMutableAttributedString(string: plain, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        colored?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: min(colored?.length ?? 0, result.length))) { value, range, _ in
            if let color = value as? NSColor { result.addAttribute(.foregroundColor, value: color, range: range) }
        }
        let whole = NSRange(location: 0, length: result.length)
        source = (plain, TextSourceMap(blocks: [.init(display: whole, content: 0, lines: whole,
                                                        pieces: [.init(display: whole, source: whole, exact: true)])]))
        guard textStorage?.isEqual(to: result) != true else { return }
        let selection = selectedRange()
        let sameText = textStorage?.string == plain
        textStorage?.setAttributedString(result)
        if sameText { setSelectedRange(selection) }
        measure()
    }

    private func measure() {
        guard let layout = textLayoutManager else { return }
        layout.ensureLayout(for: layout.documentRange)
        let bounds = layout.usageBoundsForTextContainer
        size = CGSize(width: ceil(bounds.width), height: (bounds.height * 2).rounded() / 2)
    }
}

// MARK: - 表格

/// 表格，照 MarkdownTable：标题「表格」，右边导出为图片、复制为 Markdown；表头半粗，行与行之间分隔线顶到卡片两边，
/// 格子上下各 8、列之间 16、首尾两列外侧各 12，表格比卡片窄时最后一列补足宽度，太宽横着滚。
/// 整张表是一个文本视图（一行一段，格子按制表位对齐），能跨格选字，复制给原文。
final class TableCardView: BlockCardView {
    private let scroller = OverflowScrollView()
    private let text = ProseTextView.makeReadOnly()
    /// 行内代码的底色由它给的排版片段画（DecoratedFragment），链接交给 openURL。
    private let decorations = ProseRowCoordinator()
    /// 行间的分隔线画在文本视图上面这一层。
    private let rules = PassThroughView()
    private let exportButton = CardButton()
    private var dividers: [CALayer] = []
    private var header: [AttributedString] = []
    private var rows: [[AttributedString]] = []
    private var environment: EmbeddedEnvironment?
    private var font = NSFont.preferredFont(forTextStyle: .body)
    /// 表格本身多宽（不算补足的那截）、多高。
    private var tableSize: CGSize = .zero
    private var shownKey: TableKey?
    /// 看着网页链接的站点图标（ReferenceIcons），载完重排这张表。
    private let iconTracking = ModelTracking()
    /// 引用图标要加载的网址，变了才重新加载。
    private var urls: [URL] = []
    /// 行间分隔线的颜色，外观变了才重新解析。
    private var dividerColor: CGColor?

    private struct TableKey: Equatable {
        let block: MarkdownBlock
        let markdown: String?
        let font: Font?
        let scope: ReferenceScope
        let dark: Bool
    }

    private static let edgeInset: CGFloat = 12
    private static let columnSpacing: CGFloat = 16
    private static let cellPadding: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.clipsViewport = false
        text.textContainer?.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 0, height: Self.cellPadding)
        text.setAccessibilityLabel(TranscriptSpeech.table)
        text.textLayoutManager?.delegate = decorations
        text.delegate = decorations
        decorations.view = text
        scroller.document.addSubview(text)
        scroller.document.addSubview(rules)
        surface.addSubview(scroller)
        exportButton.configure(asset: "ImageExport", label: "导出为图片")
        exportButton.action = { [weak self] in self?.exportImage() }
        copyButton.action = { [weak self] in
            guard let self else { return }
            copyToPasteboard(MarkdownTable.markdown(header: header, rows: rows), toast: environment?.toast)
        }
        configure(label: "表格", copyLabel: "复制表格", background: Theme.codeBackground, radius: Metrics.contentRadius, actions: [exportButton])
        speech = TranscriptSpeech.table
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func update(_ content: EmbeddedBlock, environment: EmbeddedEnvironment, markdown: String?) {
        guard case .markdown(let block) = content, case .table(let header, let rows) = block.kind else { return }
        self.environment = environment
        self.header = header
        self.rows = rows
        decorations.openURL = environment.openURL
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = TableKey(block: block, markdown: markdown, font: environment.font, scope: environment.referenceScope, dark: dark)
        guard key != shownKey else { return }
        shownKey = key
        build(block, markdown: markdown, environment: environment, dark: dark)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let key = shownKey, let environment else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        dividerColor = nil
        needsLayout = true
        guard dark != key.dark else { return }
        shownKey = TableKey(block: key.block, markdown: key.markdown, font: key.font, scope: key.scope, dark: dark)
        build(key.block, markdown: key.markdown, environment: environment, dark: dark)
    }

    /// 排出整张表：每格按 SelectableMarkdown 的行内样式排（行内代码底色、引用图标、链接），量出各列多宽，
    /// 一行一段、格子之间是制表符，制表位按列宽放；格子在原文里的位置记成对照，选字复制时取回原文。
    private func build(_ block: MarkdownBlock, markdown: String?, environment: EmbeddedEnvironment, dark: Bool) {
        font = (environment.font ?? .body).resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
        let bold = Self.semibold(font)
        let scheme: ColorScheme = dark ? .dark : .light
        let iconTint = NSColor.controlAccentColor.resolved(for: scheme)
        let codeFill = Theme.codeBackground.resolvedCGColor(for: scheme)
        let sources = markdown.map { block.tableCellSources(in: $0) } ?? []
        let decorated = ([header] + rows).map { row in row.map { ReferenceText.decorate($0, scope: environment.referenceScope) } }
        // 网页链接前面的站点图标：没载过的去载，载完（ReferenceIcons 变了）重排一次
        let urls = decorated.flatMap { $0.flatMap { $0.runs.compactMap(\.link) } }
        if urls != self.urls {
            self.urls = urls
            Task { await ReferenceIcons.shared.load(urls) }
        }
        // 先按格排好，量宽
        iconTracking.cancel()
        let cells = iconTracking.track {
            decorated.enumerated().map { index, row in
                row.enumerated().map { column, value -> (text: NSAttributedString, pieces: [TextSourceMap.Piece], source: MarkdownSource?) in
                    let source = index < sources.count && column < sources[index].count ? sources[index][column] : nil
                    let (text, pieces) = SelectableMarkdown.inline(value, source: source, offset: 0, font: index == 0 ? bold : font,
                                                                   color: .labelColor, iconTint: iconTint, codeFill: codeFill)
                    return (text, pieces, source)
                }
            }
        } changed: { [weak self] in
            // 通知在图标写进去之前发出，下一拍再按新的排
            DispatchQueue.main.async { [weak self] in
                guard let self, let key = shownKey, let environment = self.environment else { return }
                build(key.block, markdown: key.markdown, environment: environment, dark: key.dark)
                resized?()
            }
        }
        let columns = cells.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in cells {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], Self.width(of: cell.text)) }
        }
        // 各列的起点：首列外侧留 edgeInset，列之间 columnSpacing，都取到像素
        var stops: [CGFloat] = []
        var x = Self.edgeInset
        for width in widths {
            stops.append(pixel(x))
            x += width + Self.columnSpacing
        }
        let tableWidth = x - Self.columnSpacing + Self.edgeInset
        let style = NSMutableParagraphStyle()
        style.tabStops = stops.dropFirst().map { NSTextTab(textAlignment: .left, location: $0) }
        style.firstLineHeadIndent = Self.edgeInset
        style.headIndent = Self.edgeInset
        style.lineBreakMode = .byClipping
        // 格子上下各 8，行间还隔着一道 1 pt 的分隔线（Divider）
        style.paragraphSpacing = Self.cellPadding * 2 + 1
        let result = NSMutableAttributedString()
        var map = TextSourceMap()
        var mapped = markdown != nil
        let original = (markdown ?? "") as NSString
        for (index, row) in cells.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style])) }
            let rowStart = result.length
            var pieces: [TextSourceMap.Piece] = []
            var lines: NSRange?
            for (column, cell) in row.enumerated() {
                if column > 0 { result.append(NSAttributedString(string: "\t", attributes: [.font: font])) }
                let start = result.length
                pieces += cell.pieces.map { piece in
                    TextSourceMap.Piece(display: NSRange(location: piece.display.location + start, length: piece.display.length),
                                        source: piece.source, exact: piece.exact)
                }
                result.append(cell.text)
                if let source = cell.source {
                    lines = lines.map { NSUnionRange($0, source.lines) } ?? source.lines
                } else {
                    mapped = false
                }
            }
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: rowStart, length: result.length - rowStart))
            // 一行一块：选到行首、行尾就连表格的竖线一起取这一整行原文，落在格子中间按格子里的字取
            if let lines, NSMaxRange(lines) <= original.length {
                var start = 0, end = 0
                original.getLineStart(&start, end: nil, contentsEnd: &end, for: lines)
                map.blocks.append(.init(display: NSRange(location: rowStart, length: result.length - rowStart), content: rowStart,
                                        lines: NSRange(location: start, length: end - start), pieces: pieces))
            } else {
                mapped = false
            }
        }
        // 容器宽给表格本身的宽（不小于视图的宽就行）：容器无限宽时，视图比排出来的范围窄或差不多宽，
        // 文本视图会把容器原点往左挪到 -5～-10，首列外侧的 edgeInset 被吃掉（2026-10-19 实测）
        let containerWidth = ceil(tableWidth)
        if text.textContainer?.size.width != containerWidth {
            text.textContainer?.size = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }
        text.source = mapped ? (markdown ?? "", map) : nil
        if text.textStorage?.isEqual(to: result) != true { text.textStorage?.setAttributedString(result) }
        if let layout = text.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            let height = (layout.usageBoundsForTextContainer.height * 2).rounded() / 2
            tableSize = CGSize(width: ceil(tableWidth), height: height + Self.cellPadding * 2)
        }
        needsLayout = true
    }

    private static func semibold(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// 一格字排成一行多宽（连同链接前面插的图标），往上取到像素。
    private static func width(of text: NSAttributedString) -> CGFloat {
        (text.size().width * 2).rounded(.up) / 2
    }

    override func height(width: CGFloat) -> CGFloat {
        contentTop + tableSize.height
    }

    override func layout() {
        super.layout()
        let width = max(tableSize.width, bounds.width)
        scroller.frame = CGRect(x: 0, y: contentTop, width: bounds.width, height: tableSize.height)
        scroller.contentWidth = width
        text.frame = CGRect(x: 0, y: 0, width: width, height: tableSize.height)
        rules.frame = text.frame
        layoutDividers(width: width)
    }

    /// 行与行之间的分隔线：每行字的下沿再往下 8，顶到表格两边。
    private func layoutDividers(width: CGFloat) {
        guard let layout = text.textLayoutManager else { return }
        var bottoms: [CGFloat] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first {
                bottoms.append(fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY)
            }
            return true
        }
        let count = max(bottoms.count - 1, 0)
        let color = dividerColor ?? resolved(.separatorColor)
        dividerColor = color
        while dividers.count < count {
            let layer = CALayer()
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            rules.layer?.addSublayer(layer)
            dividers.append(layer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in dividers.enumerated() {
            layer.isHidden = index >= count
            guard index < count else { continue }
            layer.frame = CGRect(x: 0, y: Self.cellPadding + bottoms[index] + Self.cellPadding, width: width, height: 1)
            if layer.backgroundColor != color { layer.backgroundColor = color }
        }
        CATransaction.commit()
    }

    /// 导出整张表为图片（按眼下的外观、字号和屏幕倍率），选个地方存，同 MarkdownTable。
    private func exportImage() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = MarkdownTableImage(header: header, rows: rows, font: environment?.font ?? Theme.body,
                                       colorScheme: dark ? .dark : .light, scale: window?.backingScaleFactor ?? 2)
        guard let data = image.png() else {
            environment?.toast?.show("导出失败", systemImage: "exclamationmark.triangle")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "表格.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            environment?.toast?.show("导出失败", systemImage: "exclamationmark.triangle")
        }
    }
}

// MARK: - 横着滚

/// 卡片里横着滚的那一块，照 ScrollView(.horizontal, showsIndicators: false).hintsScrollOverflow(.horizontal)：
/// 不显示滚动条；哪一头还有看不到的内容，那一头渐隐，边上正中一个箭头指着它（只是提示，不接点击），变化时 0.15 秒缓出。
/// 竖着的滑动由对话列表接走（见 TranscriptListView.takeScroll）。
final class OverflowScrollView: NSView {
    let document = FlippedLayerView()
    private let scroll = NSScrollView()
    private let fade = CAGradientLayer()
    private let leading = CaretView()
    private let trailing = CaretView()
    private var overflow: (before: Bool, after: Bool) = (false, false)
    /// 内容多宽。
    var contentWidth: CGFloat = 0 { didSet { if contentWidth != oldValue { needsLayout = true } } }

    /// 一个箭头沿滚动方向占的长度、离边多远；渐隐的长度：边上的距离、箭头，再加一个模数的过渡。
    private static let caretExtent = DotMetrics.module
    private static let caretInset = DotMetrics.module / 2
    private static let fadeLength = caretInset + caretExtent + DotMetrics.module

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .automatic
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.wantsLayer = true
        addSubview(scroll)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.layer?.mask = fade
        for (view, name) in [(leading, "chevron.left"), (trailing, "chevron.right")] {
            let font = Theme.status.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            view.contentTintColor = .secondaryLabelColor
            view.alphaValue = 0
            view.hideFromAccessibility()
            addSubview(view)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        document.frame = CGRect(x: 0, y: 0, width: max(contentWidth, bounds.width), height: bounds.height)
        for (view, before) in [(leading, true), (trailing, false)] {
            let size = view.image?.size ?? .zero
            let x = before ? Self.caretInset + (Self.caretExtent - size.width) / 2
                : bounds.width - Self.caretInset - Self.caretExtent + (Self.caretExtent - size.width) / 2
            view.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
        update(animated: false)
    }

    @objc private func scrolled() {
        update(animated: true)
    }

    /// 前后两头各自还有没有内容被截掉，变了就换渐隐和箭头（0.15 秒缓出，同 hintsScrollOverflow）。
    private func update(animated: Bool) {
        let visible = scroll.contentView.bounds
        let next = (before: visible.minX > 0.5, after: visible.maxX < contentWidth - 0.5)
        let animate = animated && next != overflow
        overflow = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        let end = min(0.5, Self.fadeLength / max(bounds.width, 1))
        fade.locations = [0, NSNumber(value: end), NSNumber(value: 1 - end), 1]
        CATransaction.commit()
        let black = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        let colors = [next.before ? clear : black, black, black, next.after ? clear : black]
        if animate {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = fade.presentation()?.colors ?? fade.colors
            animation.duration = 0.15
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.add(animation, forKey: "colors")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                leading.animator().alphaValue = next.before ? 1 : 0
                trailing.animator().alphaValue = next.after ? 1 : 0
            }
        } else {
            leading.alphaValue = next.before ? 1 : 0
            trailing.alphaValue = next.after ? 1 : 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.colors = colors
        CATransaction.commit()
    }
}

/// 只画、不接点击的一层。
final class PassThroughView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// 滚动提示的箭头：只是提示，不接点击、读屏不读，点到的是下面的内容。
final class CaretView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

// MARK: - 弹簧

/// 按 SwiftUI 的 Spring 逐帧走一个数，中途换目标时接着当前的速度走（同 SwiftUI 的动画合并）。
@MainActor final class SpringValue: NSObject {
    private(set) var value: Double = 0
    var changed: ((Double) -> Void)?
    private var from: Double = 0
    private var target: Double = 0
    private var velocity: Double = 0
    private var spring = Spring.snappy
    private var started: CFTimeInterval?
    private var link: CADisplayLink?

    func animate(to target: Double, spring: Spring, in view: NSView) {
        let now = CACurrentMediaTime()
        // 眼下走到哪、多快，从这里接着走
        if let started {
            let time = now - started
            let current = self.spring.velocity(fromValue: from, toValue: self.target, initialVelocity: velocity, time: time)
            value = self.spring.value(fromValue: from, toValue: self.target, initialVelocity: velocity, time: time)
            velocity = current
        }
        from = value
        self.target = target
        self.spring = spring
        started = now
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// 停下：显示链接作废，停在 value 上。
    func stop(at value: Double) {
        link?.invalidate()
        link = nil
        started = nil
        velocity = 0
        self.value = value
        target = value
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let started else { return }
        let time = link.targetTimestamp - started
        if time >= spring.settlingDuration {
            value = target
            velocity = 0
            self.started = nil
            link.invalidate()
            self.link = nil
        } else {
            value = spring.value(fromValue: from, toValue: target, initialVelocity: velocity, time: time)
        }
        changed?(value)
    }
}
#endif
