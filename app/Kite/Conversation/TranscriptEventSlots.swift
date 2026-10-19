#if os(macOS)
import AppKit
import SwiftUI

/// Kite 的通知：一行次要色小字，图标（子代理回报是它的头像）、那一句、箭头，整块可点；点开下面是正文（写给模型的原文，次要色小字，能选），
/// 和那一句的字对齐。展开收起和下面的行一起按 WorkLayout 的走法动，箭头跟着转、正文跟着淡入淡出，收起走完拿掉正文。
/// 转交的用户回应（你回答了提问这类）是用户自己做的事，靠右，正文贴着字宽也靠右。
final class KiteRowSlot: TranscriptRowSlot {
    private let container = NoticeRowView()
    private var notice: Notice?
    private var expanded = false
    private var font = NSFont.systemFont(ofSize: 11)
    private var headerHeight: CGFloat = 0
    private var bodySize = CGSize.zero
    /// 自己正在展开收起：箭头、正文的透明度跟着行高走。
    private var toggling = false

    override init(row: TranscriptRow) {
        super.init(row: row)
        container.header.action = { [weak self] in self?.toggle() }
    }

    override var hasView: Bool { true }
    override var view: NSView { container }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .kite(let notice) = item.kind else { return }
        self.notice = notice
        font = Theme.secondary.resolve(in: context.environment.fontResolutionContext).ctFont as NSFont
        container.header.show(notice, font: font, environment: context.environment)
        container.body?.showPlain(notice.text, font: font, color: .secondaryLabelColor)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        headerHeight = container.header.height
        if expanded, let body = container.body {
            // 正文和那一句的字对齐；用户回应的贴着字宽、靠右
            let most = max(width - container.header.textX, 0)
            let lineWidth = notice?.response == true
                ? ProseTextCoordinator.naturalWidth(of: body.textStorage ?? NSAttributedString(), most: most) : most
            bodySize = CGSize(width: lineWidth, height: body.measurePixel(lineWidth: lineWidth))
        }
        let height = WorkLayout.height(header: headerHeight, steps: bodySize.height, expanded: expanded)
        measured = (width, height)
        return height
    }

    override func layoutView(in frame: CGRect) {
        var progress: CGFloat = expanded ? 1 : 0
        if toggling {
            progress = WorkLayout.progress(rowHeight: frame.height, header: headerHeight, steps: bodySize.height, expanded: expanded)
            if let measured, abs(frame.height - measured.height) < 0.01 { toggling = false }
        }
        let trailing = notice?.response == true
        let header = container.header
        let headerWidth = min(header.width, frame.width)
        header.frame = CGRect(x: trailing ? frame.width - headerWidth : 0, y: 0, width: headerWidth, height: headerHeight)
        header.turn = progress
        guard let body = container.body else { return }
        body.frame = CGRect(x: trailing ? frame.width - bodySize.width : header.textX, y: headerHeight + WorkLayout.spacing,
                            width: bodySize.width, height: bodySize.height)
        body.alphaValue = progress
        // 收起走完拿掉正文
        if !expanded, progress == 0 { container.removeBody() }
    }

    private func toggle() {
        guard let notice else { return }
        expanded.toggle()
        if expanded, container.body == nil {
            let body = container.addBody()
            body.alphaValue = 0
            body.showPlain(notice.text, font: font, color: .secondaryLabelColor)
        }
        container.header.expanded = expanded
        toggling = true
        measured = nil
        heightChanged?(WorkLayout.motion)
    }
}

/// 通知这一行的视图：那一句、展开后的正文，按自己的范围截（收起时退场的正文不画到后面的行上）。
final class NoticeRowView: NSView {
    let header = NoticeHeaderView()
    private(set) var body: ProseTextView?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addBody() -> ProseTextView {
        let body = ProseTextView.makeReadOnly()
        addSubview(body)
        self.body = body
        return body
    }

    func removeBody() {
        body?.removeFromSuperview()
        body = nil
    }
}

/// 通知的那一句：图标（SwiftUI Label 的摆法，见 SymbolLabelMetrics）或头像（间距 6，竖着居中）、那一句（放不下截掉）、
/// 间距 8、小号箭头，都是次要色。宽是内容的宽，整块可点，指针是手形；读屏读成展开收起的三角。
final class NoticeHeaderView: NativeButton {
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat = 0 {
        didSet { if turn != oldValue { chevron.frameCenterRotation = -90 * turn } }
    }
    var expanded = false {
        didSet { if expanded != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) } }
    }
    private let icon = NSImageView()
    private let avatar = CALayer()
    private let title = LineLabel()
    private let chevron = NSImageView()
    private var font = NSFont.systemFont(ofSize: 11)
    /// 有头像时它的直径，没有为 0。
    private var diameter: CGFloat = 0
    private var avatarContent: (instance: String, environment: EnvironmentValues)?
    private var speech = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(avatar)
        addSubview(icon)
        addSubview(title)
        addSubview(chevron)
        icon.hideFromAccessibility()
        chevron.hideFromAccessibility()
        title.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ notice: Notice, font: NSFont, environment: EnvironmentValues) {
        self.font = font
        let secondary = NSColor.secondaryLabelColor
        speech = TranscriptSpeech.notice(notice)
        title.set(notice.title, font: font, color: secondary)
        if let instance = notice.avatarInstance {
            diameter = AgentAvatar.inlineDiameter(font: font.pointSize)
            avatarContent = (instance, environment)
            icon.isHidden = true
            drawAvatar()
        } else {
            diameter = 0
            avatarContent = nil
            avatar.contents = nil
            icon.isHidden = false
            icon.image = SymbolLabelMetrics.image(notice.symbol, font: font)
            icon.contentTintColor = secondary
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular, scale: .small)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        chevron.contentTintColor = secondary
        needsLayout = true
    }

    private func drawAvatar() {
        guard let avatarContent else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatar.contentsScale = scale
        avatar.contents = AgentAvatar.still(design: AgentAvatar.design(for: avatarContent.instance, environment: avatarContent.environment),
                                            instance: avatarContent.instance, diameter: diameter, scale: scale, environment: avatarContent.environment)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawAvatar()
    }

    /// 那一句从哪起，展开的正文也从这里起。
    var textX: CGFloat { diameter > 0 ? diameter + 6 : SymbolLabelMetrics(font: font, image: icon.image).textX }
    var height: CGFloat { max(title.lineHeight, diameter) }
    /// 内容的宽：图标、那一句、箭头。
    var width: CGFloat { textX + title.textWidth + 8 + (chevron.image?.size.width ?? 0) }

    override func layout() {
        super.layout()
        let line = title.lineHeight
        let top = (bounds.height - line) / 2
        if diameter > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            avatar.frame = CGRect(x: 0, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            CATransaction.commit()
        } else {
            icon.frame = SymbolLabelMetrics(font: font, image: icon.image).iconFrame(lineTop: top)
        }
        let imageSize = chevron.image?.size ?? .zero
        let titleWidth = min(title.textWidth, max(bounds.width - textX - 8 - imageSize.width, 0))
        title.frame = CGRect(x: textX, y: top, width: titleWidth, height: line)
        let rotation = chevron.frameCenterRotation
        chevron.frameCenterRotation = 0
        chevron.frame = CGRect(x: textX + titleWidth + 8, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
        chevron.frameCenterRotation = rotation
    }

    override func drawFocusRingMask() { bounds.fill() }

    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { speech }
    override func accessibilityValue() -> Any? { expanded ? 1 : 0 }
    override func isAccessibilityExpanded() -> Bool { expanded }
}

/// SwiftUI 的 Label 在 Mac 上怎么摆图标和字（2026-10-13 与 SwiftUI 逐像素对过，铃铛、举手、三角、合并四种图标）：
/// 字从图标的对齐宽度（NSImage.alignmentRect，SwiftUI 的图标就这么宽）后面 8 pt 起；图标和字按基线对齐，
/// 图标的基线在它对齐框的底边（离图片底边 alignmentRect.minY），整张图往上取到像素。
/// 举手这种比字高的图标，SwiftUI 会把整行撑高零点几点、字往下挪，这里不撑：图标照样按基线对齐，往上多画一点，字和行高不变。
struct SymbolLabelMetrics {
    let font: NSFont
    let image: NSImage?

    static func image(_ name: String, font: NSFont) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular, scale: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// 字从哪起。
    var textX: CGFloat { (image?.alignmentRect.width ?? 0) + 8 }

    /// 一行字的高。
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// 图标的位置：lineTop 是第一行字的顶边。
    func iconFrame(lineTop: CGFloat) -> CGRect {
        guard let image else { return .zero }
        let baseline = font.ascender + font.leading / 2
        let top = ((baseline + image.alignmentRect.minY - image.size.height) * 2).rounded(.down) / 2
        return CGRect(x: 0, y: lineTop + top, width: image.size.width, height: image.size.height)
    }
}

#endif
