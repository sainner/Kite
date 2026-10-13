#if os(iOS)
import SwiftUI
import UIKit

/// 人发的一条消息，原生气泡，样子和行为照 MessageBubble：靠右，贴着字宽（有代码段时占满）；收到了填上底色、白字，
/// 排队中只描边、跟系统文字色，两者之间 0.3 秒淡入淡出；太长的折到 messageFold 高（随动态字体缩放），底下渐隐，下面一个展开、收起的按钮；
/// 附件排在气泡上面（托管原来的 MessageAttachmentRow，很少有）。正文和代码段用 SelectableText 同一套属性串，复制给打的原文。
/// 长按气泡任何地方（含内边距、折叠按钮）都开操作栏，接着拖是选字（SwiftUI 版只有正文和代码卡片接长按，用户 2026-10-13 定不照搬）；
/// iPad 指针右键开关操作栏。刚发出去时从下面 bubbleRise 处浮上来、淡显，跟着对话往上滑的那一下走，浮的途中不能选字（同 Mac）。
final class PhoneBubbleRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var container: PhoneBubbleRowView?
    private var interaction: PhoneTextInteraction?
    private let coordinator = ProseTextCoordinator()
    private let attachments = BlockAttachments()
    private(set) var message: Message?
    private(set) var queued = false
    /// 展开了全文。
    private(set) var expanded = false
    private var context: TranscriptRowContext?
    /// 怎么量、怎么摆，两端共用。
    private var layout = BubbleLayout()
    private var attachmentsHeight: CGFloat = 0
    private var hasBlocks = false
    /// 折起来时显示多高：messageFold 随动态字体缩放，同 MessageBubble 的 @ScaledMetric。
    private var foldHeight = Metrics.messageFold

    override init(row: TranscriptRow) {
        super.init(row: row)
        coordinator.resized = { [weak self] in
            guard let self else { return }
            measured = nil
            heightChanged?(nil)
        }
    }

    override var hasView: Bool { container != nil }
    override var view: UIView { rowView }

    /// 气泡这一行的视图，第一次要时建（量高也要它），放掉以后再要时重建、重放字。
    private var rowView: PhoneBubbleRowView {
        if let container { return container }
        let container = PhoneBubbleRowView()
        let text = container.text
        // 行宽由 height(width:) 按贴字的宽设
        text.textContainerInset = .zero
        text.textLayoutManager?.delegate = coordinator
        coordinator.view = text
        container.fold.action = { [weak self] in
            guard let self else { return }
            context?.select(nil)
            setExpanded(!expanded)
        }
        self.container = container
        interaction = PhoneTextInteraction(text: text, host: container.bubble)
        interaction?.enabled = rise == 0
        container.alpha = 1 - rise
        configure()
        build(first: true)
        // 放掉以后重建的（内存警告）：量过的高留着，没人再量，行宽按上次量的给回去；拖缝中折着的照旧只放开头那截
        if measured != nil {
            container.text.fit(lineWidth: layout.textWidth)
            if resizing, foldable, !expanded { fold(true) }
        }
        return container
    }

    var foldable: Bool { layout.foldable(foldHeight: foldHeight) }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .message(let message, let queued) = row.content else { return }
        let wasQueued = self.queued
        self.message = message
        self.queued = queued
        self.context = context
        foldHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: Metrics.messageFold, compatibleWith: Self.traits(context.environment))
        if resized { layout.contentChanged() }
        guard container != nil else { return }
        configure()
        if resized { build(first: false, wasQueued: wasQueued) }
    }

    private static func traits(_ environment: EnvironmentValues) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(environment.dynamicTypeSize))
    }

    /// 触摸、读屏接上这一行的环境。
    private func configure() {
        guard let context, let interaction, let container else { return }
        let id = row.id
        let openURL = context.environment.openURL
        interaction.openURL = { openURL($0) }
        // 嵌着的对话里（压缩前的原文、子 agent 做的事）没有操作栏，同 Mac
        interaction.showActions = { if context.actionable { context.select(id) } }
        interaction.dismissActions = { context.select(nil) }
        interaction.secondaryClick = context.actionable ? { context.toggleActions(id) } : nil
        container.text.accessibilityLabel = TranscriptSpeech.message(queued: queued)
        container.text.accessibilityCustomActions = context.actionable
            ? [UIAccessibilityCustomAction(name: TranscriptSpeech.actions) { _ in context.select(id); return true }] : nil
    }

    /// 排出正文、换上外观。wasQueued：上次是不是排队中，从排队中变成收到时底色填进来。
    private func build(first: Bool, wasQueued: Bool? = nil) {
        guard let message, let context, let container else { return }
        let environment = context.environment
        let (body, code) = SelectableText.phoneFonts
        // 已接收的实色气泡恒用白字；排队中的透明描边气泡仍跟随系统文字色
        let content = SelectableText.content(message, color: queued ? .label : .white, body: body, code: code, attachments: attachments)
        hasBlocks = !content.blocks.isEmpty
        container.text.source = content.source
        let id = row.id
        var embedded = environment
        let longPress: @MainActor () -> Void = { context.select(id) }
        embedded.blockCardLongPress = context.actionable ? longPress : nil
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(embedded))
        full = content.text
        showsPrefix = false
        if coordinator.shown != content.text, !coordinator.appendTail(of: content.text) {
            let text = container.text
            let textChanged = coordinator.shown?.string != content.text.string
            let selection = text.selectedRange
            let selectable = text.isSelectable
            interaction?.refreshingAppearance = !textChanged
            coordinator.shown = content.text
            text.attributedText = content.text
            if !textChanged {
                text.isSelectable = selectable
                text.selectedRange = selection
            }
            interaction?.refreshingAppearance = false
        }
        container.style(queued: queued, animated: !first && wasQueued.map { $0 != queued } == true, environment: environment)
        container.setAttachments(message.attachments.isEmpty ? nil : AnyView(
            MessageAttachmentRow(attachments: message.attachments).environment(\.self, environment)))
    }

    /// 上次整条排过、没有一行是被行宽折下来的：贴字的宽。拖缝时能给的宽还放得下它，排出来一样，不用再排（见 height）。
    private var unwrapped: CGFloat?
    /// 整条正文的属性串，和折着时文本视图里只放的开头那截（见 fold）。
    private var full: NSAttributedString?
    private var showsPrefix = false
    /// 折着时只放开头这么多字（UTF-16），停下来按全文量时按折起来的高能露出多少字算（见 measurePrefix）。
    private var prefixLength = Int.max
    /// 上次按全文量时折了行：拖缝时行宽占满能给的宽。
    private var foldWraps = false

    /// 刚按全文排好时，折起来的高再往下两行处是第几个字；拖缝时内容列最宽能到 transcriptWidth，一行放得下的字跟着多，按比例放大，
    /// 再多留一行。iPad 真机上折着的消息六七百字、露出来的两百来字，整条每步跟着改宽重排要两毫秒。
    private func measurePrefix() -> Int {
        guard let container, let manager = container.text.textLayoutManager else { return Int.max }
        let font = SelectableText.phoneFonts.body
        let y = foldHeight + font.lineHeight * 2
        guard let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return Int.max }
        let start = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
        let inside = y - fragment.layoutFragmentFrame.minY
        let line = fragment.textLineFragments.first { $0.typographicBounds.maxY >= inside } ?? fragment.textLineFragments.last
        let offset = start + (line.map { $0.characterRange.upperBound } ?? 0)
        let widest = Metrics.transcriptWidth - Metrics.bubblePadding.width * 2
        // 再多一行的字：截口落在折起来的高底下两行以外
        let perLine = Double(offset) / Double(max(line.map { _ in fragment.textLineFragments.count } ?? 1, 1))
        return Int((Double(offset) * Double(widest / max(layout.textWidth, 1)) + perLine).rounded(.up))
    }

    /// 拖缝、吸附中折着的长消息，文本视图里只放开头那截：TextKit 一段一段排，长消息常常整条就是一段，每步都要把整段重排
    /// （iPad 真机上占了量高的大头），露出来的只有开头十来行。停下来按全文量时换回全文，静止时一直是全文：读屏、全选拷贝都要整条
    /// （iOS 27 起只排露出来的那截，见 PhoneProseTextView.shownHeight）。展开时换回全文。有选区时不换，免得把选区换掉。
    private func fold(_ prefix: Bool) {
        guard let full, let container, prefix != showsPrefix, !container.text.isSelectable else { return }
        let text: NSAttributedString
        if prefix {
            guard full.length > prefixLength else { return }
            let cut = (full.string as NSString).rangeOfComposedCharacterSequence(at: prefixLength).location
            text = full.attributedSubstring(from: NSRange(location: 0, length: cut))
        } else {
            text = full
        }
        showsPrefix = prefix
        coordinator.shown = text
        container.text.attributedText = text
    }

    /// 量正文见 BubbleLayout：拖缝和吸附中按近似量，记作 provisional，停下后按精确的重量。
    /// 拖缝中没折行的短消息（大多数）能给的宽还放得下就不再排，高照旧：每步改宽时文本视图也就不用重排。
    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        if resizing, let unwrapped, let measured, unwrapped <= width - Metrics.bubblePadding.width * 2 {
            provisional = true
            self.measured = (width, measured.height)
            return measured.height
        }
        let container = rowView
        // 折着的长消息拖缝时不重量：露出来的高是定的，只按能给的宽换行宽，文本视图里只放开头那截、按新的容器宽排
        if resizing, foldable, !expanded, let measured {
            fold(true)
            let most = max(width - Metrics.bubblePadding.width * 2, 0)
            // 折了行的：行宽和能给的宽差得不多就先不重排（同 PhoneProseRowSlot.keptHeight），气泡跟着字的宽，变窄时往里多让一截
            let current = layout.textWidth
            let keeps = foldWraps && current > 0 && !PhoneProseRowSlot.exactResize
                && (most >= current ? most - current <= 16 + 16 * spread : current - most <= 2 + 6 * spread)
            if !keeps {
                let slack = foldWraps && most < current && !PhoneProseRowSlot.exactResize
                layout.keepFolded(most: slack ? max(most - 8 - 8 * spread, most * 0.85) : most, wraps: foldWraps)
                container.text.fit(lineWidth: layout.textWidth)
            }
            provisional = true
            self.measured = (width, measured.height)
            return measured.height
        }
        // 停下来按精确量：要全文多高（折着时放的是开头那截）
        if !resizing { fold(false) }
        let lineWidth = container.text.textContainer.size.width
        provisional = layout.measure(container.text, storage: container.text.textStorage, width: width, hasBlocks: hasBlocks,
                                     resizing: resizing, expanded: expanded, foldHeight: foldHeight)
        if container.text.textContainer.size.width != lineWidth { container.text.relocateViewport() }
        // 折着、拖缝中只排了露出来那截的长消息不算：底下没排的可能折了行
        let whole = !(provisional && foldable && !expanded)
        unwrapped = !hasBlocks && message?.attachments.isEmpty == true && whole && !container.text.softWraps ? layout.textWidth : nil
        if !provisional, foldable {
            foldWraps = container.text.softWraps
            prefixLength = measurePrefix()
        }
        attachmentsHeight = container.attachmentsHeight(width: width)
        let height = attachmentsHeight + bubbleHeight(expanded: expanded)
        measured = (width, height)
        return height
    }

    /// 0～1，每行一个，错开拖缝中各行的余量。
    private lazy var spread = CGFloat(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 1009) / 1009

    /// 气泡多高：折起来的正文，加上能折时的按钮。
    private func bubbleHeight(expanded: Bool) -> CGFloat {
        layout.bubbleHeight(expanded: expanded, foldHeight: foldHeight, button: rowView.fold.height)
    }

    /// 摆好气泡里的东西：行的高可能正在展开、收起的动画里（比量的矮或高），正文按它截。
    override func layoutView(in frame: CGRect) {
        guard let container else { return }
        let frames = layout.frames(row: frame.size, attachmentsHeight: attachmentsHeight, button: foldable ? container.fold.height : 0)
        container.place(frames, textHeight: layout.contentHeight - Metrics.bubblePadding.height * 2, attachmentsHeight: attachmentsHeight,
                        foldable: foldable, expanded: expanded)
    }

    /// 浮上来的过程：1 在下面藏着，0 到位。浮的过程中正文不能选字，同 Mac。
    override var rise: CGFloat {
        didSet {
            container?.alpha = 1 - rise
            interaction?.enabled = rise == 0
        }
    }

    /// 气泡内容在这一行里占的范围（附件连同气泡，靠右），操作栏和它右边对齐。
    override var actionAnchor: CGRect {
        layout.anchor(in: frame, attachmentsWidth: container?.attachmentsWidth ?? 0)
    }

    func actionBar() -> (side: HorizontalEdge, content: AnyView)? {
        guard let message, let context, context.actionable else { return nil }
        let expanded = Binding { [weak self] in self?.expanded ?? false } set: { [weak self] in self?.setExpanded($0) }
        return (.trailing, AnyView(MessageActionButtons(message: message, queued: queued, foldable: foldable, expanded: expanded)
            .environment(\.self, context.environment)))
    }

    /// 展开、收起：气泡和下面的行一起按 snappy 的弹簧动，见 PhoneTranscriptView 的行高动画。
    func setExpanded(_ expanded: Bool) {
        guard expanded != self.expanded, foldable else { return }
        self.expanded = expanded
        // 拖缝中（只放着开头那截）展开时先换回全文
        if expanded { fold(false) }
        if let measured { self.measured = (measured.width, attachmentsHeight + bubbleHeight(expanded: expanded)) }
        container?.fold.expanded = expanded
        heightChanged?(.spring(.snappy))
    }

    func didPlace() {
        container?.adoptAttachments()
    }

    func releaseView() {
        interaction?.endSelection()
        container?.setAttachments(nil)
        container = nil
        interaction = nil
        coordinator.view = nil
        coordinator.shown = nil
        showsPrefix = false
        attachments.releaseHosts()
    }
}

/// 气泡这一行的视图：上面的附件、气泡（底色、描边、截住的正文、展开按钮）。
final class PhoneBubbleRowView: UIView {
    let bubble = PhoneBubbleView()
    let text = PhoneProseTextView.make()
    let fold = PhoneBubbleFoldButton()
    /// 正文按折起来的高截住，底下渐隐。
    private let clip = UIView()
    private let fade = CAGradientLayer()
    /// 渐隐上次设的起点和底下淡掉多少。
    private var faded: (start: CGFloat, amount: CGFloat)?
    private var attachments: UIHostingController<AnyView>?

    init() {
        super.init(frame: .zero)
        text.clipViewport()
        addSubview(bubble)
        bubble.content.addSubview(clip)
        clip.addSubview(text)
        bubble.content.addSubview(fold)
        clip.clipsToBounds = true
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        clip.layer.mask = fade
        // 读屏按附件、正文、展开按钮的顺序读，气泡本身不是一个元素
        accessibilityElements = [text, fold]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(queued: Bool, animated: Bool, environment: EnvironmentValues) {
        bubble.style(queued: queued, animated: animated, environment: environment)
        fold.style(color: queued ? .label : .white)
    }

    func setAttachments(_ content: AnyView?) {
        if let content {
            if let attachments {
                attachments.rootView = content
            } else {
                let controller = UIHostingController(rootView: content)
                controller.sizingOptions = []
                controller.safeAreaRegions = []
                controller.view.backgroundColor = .clear
                addSubview(controller.view)
                attachments = controller
                accessibilityElements = [controller.view!, text, fold]
            }
        } else if let attachments {
            attachments.willMove(toParent: nil)
            attachments.view.removeFromSuperview()
            attachments.removeFromParent()
            self.attachments = nil
            accessibilityElements = [text, fold]
        }
    }

    func adoptAttachments() {
        if let attachments { adopt(attachments) }
    }

    /// 附件那一行连同和气泡之间的间距多高，没有附件为 0。
    func attachmentsHeight(width: CGFloat) -> CGFloat {
        guard let attachments else { return 0 }
        return PhonePixel.ceil(attachments.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height) + 6
    }

    var attachmentsWidth: CGFloat { attachments?.view.frame.width ?? 0 }

    /// 按 BubbleLayout 给的框摆：气泡、截住正文的那层（底下渐隐）、正文、折叠按钮。正文的文本视图按整段的高摆（textHeight），
    /// 由截住的那层截：关了滚动的 UITextView 只排到视图那么高，跨过折叠线的那一行就不排、不画了（原来渐隐里露着半行）；
    /// 展开收起的动画中也只改截住那层的高，不逐帧改文本视图的高（每改一次都要整段重排，spikes/ios-native-transcript V1）。
    func place(_ frames: BubbleLayout.Frames, textHeight: CGFloat, attachmentsHeight: CGFloat, foldable: Bool, expanded: Bool) {
        if let attachments {
            let size = attachments.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
            attachments.view.frame = CGRect(x: bounds.width - size.width, y: 0, width: size.width, height: attachmentsHeight - 6)
        }
        if bubble.frame != frames.bubble { bubble.frame = frames.bubble }
        clip.frame = CGRect(x: 0, y: 0, width: frames.bubble.width, height: frames.shown)
        // 视图宽固定（见 PhoneProseTextView.clipViewport），字排在贴字的容器宽里，由截住正文的那层截
        var textFrame = frames.text
        textFrame.size = CGSize(width: PhoneProseTextView.widest, height: textHeight)
        if text.frame != textFrame { text.frame = textFrame }
        // 折着时截住的那层底下的字不排、不画
        text.shownHeight = foldable ? max(frames.shown - textFrame.minY, 0) : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fade.frame != clip.bounds { fade.frame = clip.bounds }
        // 渐隐只在折着、展开收起的途中变，别的时候不重设
        if faded.map({ $0.start != frames.fadeStart || $0.amount != frames.faded }) ?? true {
            faded = (frames.fadeStart, frames.faded)
            fade.locations = [0, NSNumber(value: frames.fadeStart), 1]
            fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.withAlphaComponent(1 - frames.faded).cgColor]
        }
        CATransaction.commit()
        fold.isHidden = !foldable
        fold.expanded = expanded
        fold.frame = frames.fold
    }
}

/// 气泡：底色（收到了）和描边（排队中）按气泡的形状画，里面的正文、按钮放进 content，按形状截。
/// 形状只截一次：底色是铺满的一层、由 content 的形状遮罩截出圆角；描边在遮罩外面单独画。底色也按路径填再被同一个形状截的话，
/// 圆角边上的像素被抗锯齿两遍、发淡（iPad 模拟器和 SwiftUI 版并排截屏对过）。
final class PhoneBubbleView: UIView {
    let content = UIView()
    private let fill = CALayer()
    private let stroke = CAShapeLayer()
    private let shape = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        layer.addSublayer(stroke)
        addSubview(content)
        content.layer.addSublayer(fill)
        content.layer.mask = shape
        stroke.fillColor = nil
        stroke.lineWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(queued: Bool, animated: Bool, environment: EnvironmentValues) {
        fill.backgroundColor = Theme.bubble.resolve(in: environment).cgColor
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

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        shape.frame = bounds
        shape.path = Theme.bubbleShape.path(in: bounds).cgPath
        // strokeBorder：描边整个画在形状里面，形状往里缩半个线宽
        stroke.frame = bounds
        stroke.path = Theme.bubbleShape.inset(by: 0.5).path(in: bounds).cgPath
        CATransaction.commit()
    }
}

/// 折起来的气泡下面的按钮：「展开全文」「收起」连同箭头，HStack(spacing: 6) 居中，跟着气泡的宽，整条可点。
final class PhoneBubbleFoldButton: PhonePlainControl {
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            update()
        }
    }
    private let label = UILabel()
    private let chevron = UIImageView()

    override init() {
        super.init()
        content.addSubview(label)
        content.addSubview(chevron)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        // 按符号自己的大小居中画，不拉伸到视图的框
        chevron.contentMode = .center
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update() {
        label.text = TranscriptSpeech.fold(expanded: expanded)
        chevron.image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down")
        accessibilityLabel = label.text
        setNeedsLayout()
    }

    func style(color: UIColor) {
        label.textColor = color
        chevron.tintColor = color
    }

    /// 上下边距加一行字（字和箭头取高的那个，同 HStack），取到像素。
    var height: CGFloat {
        PhonePixel.ceil(max(label.intrinsicContentSize.height, chevron.intrinsicContentSize.height)) + Metrics.bubblePadding.height * 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelSize = label.intrinsicContentSize
        let imageSize = chevron.intrinsicContentSize
        let spacing: CGFloat = 6
        let width = labelSize.width + spacing + imageSize.width
        let x = PhonePixel.round((bounds.width - width) / 2)
        label.frame = CGRect(x: x, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
        chevron.frame = CGRect(x: x + labelSize.width + spacing, y: (bounds.height - imageSize.height) / 2,
                               width: imageSize.width, height: imageSize.height)
    }
}
#endif
