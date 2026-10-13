#if os(macOS)
import AppKit
import SwiftUI

/// 人发的一条消息，原生气泡，样子和行为照 MessageBubble：靠右，贴着字宽（有代码段时占满）；收到了填上底色、白字，
/// 排队中只描边、跟系统文字色，两者之间 0.3 秒淡入淡出；太长的折到 messageFold 高，底下渐隐，下面一个展开、收起的按钮；
/// 附件排在气泡上面（托管原来的 MessageAttachmentRow，很少有）。正文和代码段用 SelectableText 同一套属性串，复制给打的原文。
/// 刚发出去时从下面 bubbleRise 处浮上来、淡显，跟着对话往上滑的那一下走，见 TranscriptListView.rise。
final class BubbleRowSlot: TranscriptRowSlot {
    private let container = BubbleRowView()
    private let coordinator = ProseRowCoordinator()
    private let attachments = BlockAttachments()
    private(set) var message: Message?
    private(set) var queued = false
    /// 展开了全文。
    private(set) var expanded = false
    private var context: TranscriptRowContext?
    /// 正文连同上下边距不折时多高，量的时候算出来。
    private var contentHeight: CGFloat = 0
    private var textWidth: CGFloat = 0
    private var attachmentsHeight: CGFloat = 0
    private var hasBlocks = false

    /// 折起来时显示多高，比它高出不少（1.4 倍）才折，同 MessageBubble。
    private static var foldHeight: CGFloat { Metrics.messageFold }

    override init(row: TranscriptRow) {
        super.init(row: row)
        let text = container.text
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainerInset = .zero
        text.clipsViewport = true
        // 行宽由 height(width:) 按贴字的宽设，视图跟着放窄时不再重排一次
        text.textContainer?.widthTracksTextView = false
        text.displaysLinkToolTips = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.usesFontPanel = false
        text.delegate = coordinator
        text.textLayoutManager?.delegate = coordinator
        coordinator.view = text
        coordinator.resized = { [weak self] in
            guard let self else { return }
            measured = nil
            heightChanged?(nil)
        }
        container.fold.action = { [weak self] in self?.setExpanded(!(self?.expanded ?? false)) }
    }

    override var hasView: Bool { true }
    override var view: NSView { container }

    var foldable: Bool { contentHeight > Self.foldHeight * 1.4 }


    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .message(let message, let queued) = row.content else { return }
        let wasQueued = self.queued
        let first = self.message == nil
        self.message = message
        self.queued = queued
        self.context = context
        let id = row.id
        let toggle: () -> Void = { context.toggleActions(id) }
        container.text.secondaryClick = toggle
        container.bubble.secondaryClick = toggle
        guard resized else { return }
        let environment = context.environment
        let body = Theme.body.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let code = Theme.code.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        // 已接收的实色气泡恒用白字；排队中的透明描边气泡仍跟随系统文字色
        let content = SelectableText.content(message, color: queued ? .labelColor : .white, body: body, code: code, attachments: attachments)
        hasBlocks = !content.blocks.isEmpty
        container.text.source = content.source
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(environment))
        if coordinator.shown != content.text, !coordinator.appendTail(of: content.text) {
            let textChanged = coordinator.shown?.string != content.text.string
            let selection = container.text.selectedRange()
            coordinator.shown = content.text
            container.text.textStorage?.setAttributedString(content.text)
            if !textChanged { container.text.setSelectedRange(selection) }
        }
        container.style(queued: queued, animated: !first && wasQueued != queued, environment: environment)
        container.setAttachments(message.attachments.isEmpty ? nil : AnyView(
            MessageAttachmentRow(attachments: message.attachments).environment(\.self, environment)))
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        guard let storage = container.text.textStorage else { return 0 }
        let padding = Metrics.bubblePadding
        let most = max(width - padding.width * 2, 0)
        // 有代码段时占满气泡能给的宽度，只有字时贴着字，同 SelectableText。贴字的宽照 SelectableText 用 boundingRect 量：
        // 它按最优断行量，长消息改宽时每次几毫秒（2026-10-13 实测）。拖缝和吸附中改用近似：按能给的最宽排，取最宽的一行，
        // 和 boundingRect 只差零点几点，但中文避头尾在临界宽度下会让个别行折得不一样（逐像素对过），所以停下后按精确的重量
        let textHeight: CGFloat
        provisional = WindowLayout.anyResizing && !hasBlocks
        if hasBlocks {
            textWidth = most
            textHeight = container.text.measure(lineWidth: most)
        } else if provisional, foldable, !expanded, let height = foldedHeight(most: most) {
            textHeight = height
        } else if provisional {
            var height = container.text.measure(lineWidth: most)
            textWidth = min(ceil(container.text.widestLine) + 1, most)
            if textWidth < most, container.text.wraps { height = container.text.measure(lineWidth: textWidth) }
            textHeight = height
        } else {
            textWidth = ProseTextCoordinator.naturalWidth(of: storage, most: most)
            textHeight = container.text.measure(lineWidth: textWidth)
        }
        contentHeight = textHeight + padding.height * 2
        attachmentsHeight = container.attachmentsHeight(width: width)
        let height = attachmentsHeight + bubbleHeight(expanded: expanded)
        measured = (width, height)
        return height
    }

    /// 折着的长消息拖缝时只排露出来的那截：贴字的宽按这截里最宽的一行，全文多高按上次量的随宽度反比估，只用来判断还折不折。
    /// 不然每步都要把整条长消息重排一遍，露出来的只有开头几行。
    private func foldedHeight(most: CGFloat) -> CGFloat? {
        guard let start = container.text.textLayoutManager?.documentRange.location,
              var laid = container.text.measure(lineWidth: most, from: start, through: Self.foldHeight) else { return nil }
        let previous = (height: contentHeight - Metrics.bubblePadding.height * 2, width: textWidth)
        textWidth = min(ceil(container.text.widestLine) + 1, most)
        if textWidth < most, container.text.wraps,
           let narrow = container.text.measure(lineWidth: textWidth, from: start, through: Self.foldHeight) {
            laid = narrow
        }
        return ceil(max(laid.bottom, previous.height * previous.width / max(textWidth, 1)))
    }

    /// 气泡多高：折起来的正文，加上能折时的按钮。
    private func bubbleHeight(expanded: Bool) -> CGFloat {
        guard foldable else { return contentHeight }
        return (expanded ? contentHeight : Self.foldHeight) + container.fold.height
    }

    override func viewFrame(in column: CGRect) -> CGRect { column }

    /// 摆好气泡里的东西：行的高可能正在展开、收起的动画里（比量的矮或高），正文按它截。
    override func layoutView(in frame: CGRect) {
        let bubbleWidth = textWidth + Metrics.bubblePadding.width * 2
        let bubbleHeight = max(frame.height - attachmentsHeight, 0)
        container.place(bubble: CGRect(x: frame.width - bubbleWidth, y: attachmentsHeight, width: bubbleWidth, height: bubbleHeight),
                        attachmentsHeight: attachmentsHeight, contentHeight: contentHeight, textWidth: textWidth,
                        foldable: foldable, expanded: expanded)
    }

    /// 浮上来的过程：1 在下面藏着，0 到位。浮的过程中正文不能选字，同 MessageBubble 的 Rising。
    override var rise: CGFloat {
        didSet {
            container.alphaValue = 1 - rise
            container.text.isSelectable = rise == 0
        }
    }

    /// 气泡内容在这一行里占的范围（附件连同气泡，靠右），操作栏和它右边对齐。
    override var actionAnchor: CGRect {
        let width = max(textWidth + Metrics.bubblePadding.width * 2, container.attachmentsWidth)
        return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
    }

    override func actionBar() -> (side: HorizontalEdge, content: AnyView)? {
        guard let message, let context else { return nil }
        let expanded = Binding { [weak self] in self?.expanded ?? false } set: { [weak self] in self?.setExpanded($0) }
        return (.trailing, AnyView(MessageActionButtons(message: message, queued: queued, foldable: foldable, expanded: expanded)
            .environment(\.self, context.environment)))
    }

    /// 展开、收起：气泡和下面的行一起按 snappy 的弹簧动，见 TranscriptListView 的行高动画。
    func setExpanded(_ expanded: Bool) {
        guard expanded != self.expanded, foldable else { return }
        self.expanded = expanded
        if let measured { self.measured = (measured.width, attachmentsHeight + bubbleHeight(expanded: expanded)) }
        container.fold.expanded = expanded
        heightChanged?(.spring(.snappy))
    }
}

/// 气泡这一行的视图：上面的附件、气泡（底色、描边、截住的正文、展开按钮）。翻转坐标。
final class BubbleRowView: NSView {
    let bubble = BubbleView()
    let text = ProseTextView.make()
    let fold = BubbleFoldButton()
    /// 正文按折起来的高截住，底下渐隐。
    private let clip = FlippedLayerView()
    private let fade = CAGradientLayer()
    private var attachments: NSHostingController<AnyView>?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(bubble)
        bubble.addSubview(clip)
        clip.addSubview(text)
        bubble.addSubview(fold)
        clip.layer?.masksToBounds = true
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        clip.layer?.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(queued: Bool, animated: Bool, environment: EnvironmentValues) {
        bubble.style(queued: queued, animated: animated, environment: environment)
        let color: NSColor = queued ? .labelColor : .white
        fold.style(color: color, font: Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont)
    }

    func setAttachments(_ content: AnyView?) {
        if let content {
            if let attachments {
                attachments.rootView = content
            } else {
                let controller = NSHostingController(rootView: content)
                controller.sizingOptions = []
                addSubview(controller.view)
                attachments = controller
            }
        } else if let attachments {
            attachments.view.removeFromSuperview()
            self.attachments = nil
        }
    }

    /// 附件那一行连同和气泡之间的间距多高，没有附件为 0。
    func attachmentsHeight(width: CGFloat) -> CGFloat {
        guard let attachments else { return 0 }
        return ceil(attachments.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height) + 6
    }

    var attachmentsWidth: CGFloat { attachments?.view.frame.width ?? 0 }

    func place(bubble frame: CGRect, attachmentsHeight: CGFloat, contentHeight: CGFloat, textWidth: CGFloat,
               foldable: Bool, expanded: Bool) {
        if let attachments {
            let size = attachments.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            attachments.view.frame = CGRect(x: bounds.width - size.width, y: 0, width: size.width, height: attachmentsHeight - 6)
        }
        if bubble.frame != frame { bubble.frame = frame }
        let padding = Metrics.bubblePadding
        let foldHeight = foldable ? fold.height : 0
        // 正文这一块（连同上下边距）这会儿露出多高：动画中在折起和全文之间
        let shown = max(frame.height - foldHeight, 0)
        clip.frame = CGRect(x: 0, y: 0, width: frame.width, height: shown)
        // 正文只给到露出来的底边：折着时文本视图不去排、画折下去的那些（拖缝时那截也没排，见 foldedHeight）
        let textHeight = min(contentHeight - padding.height * 2, shown - padding.height)
        let textFrame = CGRect(x: padding.width, y: padding.height, width: textWidth, height: max(textHeight, 0))
        if text.frame != textFrame { text.frame = textFrame }
        // 底下渐隐：被截掉的越多越透，全露出来时不渐隐
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        let hidden = min(max((contentHeight - shown) / Metrics.messageFoldFade, 0), 1)
        let fadeStart = max(0, 1 - Metrics.messageFoldFade / max(shown, 1))
        fade.locations = [0, NSNumber(value: fadeStart), 1]
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(1 - hidden).cgColor]
        CATransaction.commit()
        fold.isHidden = !foldable
        fold.expanded = expanded
        fold.frame = CGRect(x: 0, y: shown, width: frame.width, height: foldHeight)
    }
}

/// 气泡：底色（收到了）和描边（排队中）按气泡的形状画，里面的正文、按钮按形状截。右键开操作栏。
final class BubbleView: NSView {
    var secondaryClick: (() -> Void)?
    private let fill = CAShapeLayer()
    private let stroke = CAShapeLayer()
    private let shape = CAShapeLayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(fill)
        layer?.addSublayer(stroke)
        stroke.fillColor = nil
        stroke.lineWidth = 1
        layer?.mask = shape
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(queued: Bool, animated: Bool, environment: EnvironmentValues) {
        fill.fillColor = Theme.bubble.resolve(in: environment).cgColor
        stroke.strokeColor = Theme.bubbleStroke.resolve(in: environment).cgColor
        // 排队中到收到，底色填进来
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        fill.opacity = queued ? 0 : 1
        stroke.opacity = queued ? 1 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 翻转坐标的视图，图层坐标也是左上为原点（实测），路径按视图坐标直接用
        let cgPath = Theme.bubbleShape.path(in: bounds).cgPath
        for layer in [fill, shape] {
            layer.frame = bounds
            layer.path = cgPath
        }
        stroke.frame = bounds
        stroke.path = Theme.bubbleShape.path(in: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        CATransaction.commit()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let secondaryClick { secondaryClick() } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if let secondaryClick, event.modifierFlags.contains(.control) { secondaryClick() } else { super.mouseDown(with: event) }
    }
}

/// 折起来的气泡下面的按钮：「展开全文」「收起」连同箭头，居中，跟着气泡的宽。
final class BubbleFoldButton: NSView {
    var action: (() -> Void)?
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            label.stringValue = expanded ? "收起" : "展开全文"
            chevron.image = Self.symbol(expanded ? "chevron.up" : "chevron.down", font: label.font)
            needsLayout = true
        }
    }
    private let label = NSTextField(labelWithString: "展开全文")
    private let chevron = NSImageView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(label)
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(color: NSColor, font: NSFont) {
        label.font = font
        label.textColor = color
        chevron.image = Self.symbol(expanded ? "chevron.up" : "chevron.down", font: font)
        chevron.contentTintColor = color
        needsLayout = true
    }

    /// 上下边距加一行字。
    var height: CGFloat {
        ceil(label.intrinsicContentSize.height) + Metrics.bubblePadding.height * 2
    }

    private static func symbol(_ name: String, font: NSFont?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: font?.pointSize ?? 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    override func layout() {
        super.layout()
        // 按字本身的宽居中：NSTextField 的固有宽度两边各多出单元格的边距（约 2 pt），按它排字会偏
        let labelSize = label.intrinsicContentSize
        let inset = (labelSize.width - textWidth) / 2
        let imageSize = chevron.image?.size ?? .zero
        // 字和箭头之间：SwiftUI 的 HStack(spacing: 6) 排符号图片时两边比 NSImage 的尺寸多留约 1 pt，逐像素对过取 8
        let spacing: CGFloat = 8
        let width = textWidth + spacing + imageSize.width
        let scale = window?.backingScaleFactor ?? 2
        let x = ((bounds.width - width) / 2 * scale).rounded() / scale
        label.frame = CGRect(x: x - inset, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
        chevron.frame = CGRect(x: x + textWidth + spacing, y: (bounds.height - imageSize.height) / 2,
                               width: imageSize.width, height: imageSize.height)
    }

    private var textWidth: CGFloat {
        label.attributedStringValue.size().width
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func mouseDown(with event: NSEvent) {}
}

/// 翻转坐标、带图层的视图，截住正文用。
final class FlippedLayerView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
