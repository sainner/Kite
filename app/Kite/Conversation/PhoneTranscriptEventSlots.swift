#if os(iOS)
import SwiftUI
import UIKit

/// Kite 的通知：一行次要色小字，图标（子代理回报是它的头像）、那一句、箭头，整块可点；点开下面是正文（写给模型的原文，次要色小字，
/// 长按弹出拷贝、共享），和那一句的字对齐。展开收起和下面的行一起按 WorkLayout 的走法动，箭头跟着转、正文跟着淡入淡出，收起走完拿掉正文。
/// 转交的用户回应（你回答了提问这类）是用户自己做的事，靠右，正文贴着字宽也靠右。同 Mac 的 KiteRowSlot。
final class PhoneKiteRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var container: PhoneNoticeRowView?
    private let menu = PhoneCopyMenu()
    private var notice: Notice?
    private var context: TranscriptRowContext?
    private var expanded = false
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)
    private var headerHeight: CGFloat = 0
    private var bodySize = CGSize.zero

    override var hasView: Bool { container != nil }
    override var view: UIView { rowView }

    private var rowView: PhoneNoticeRowView {
        if let container { return container }
        let container = PhoneNoticeRowView()
        container.header.action = { [weak self] in self?.toggle() }
        self.container = container
        show()
        return container
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .kite(let notice) = item.kind else { return }
        self.notice = notice
        self.context = context
        font = Theme.secondary.resolve(in: context.environment.fontResolutionContext).ctFont as UIFont
        menu.text = { notice.text }
        guard container != nil else { return }
        show()
    }

    private func show() {
        guard let notice, let context, let container else { return }
        container.header.show(notice, font: font, expanded: expanded, environment: context.environment)
        container.body?.set(notice.text, font: font, color: .secondaryLabel)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let container = rowView
        headerHeight = container.header.height
        if expanded, let body = container.body {
            // 正文和那一句的字对齐；用户回应的贴着字宽、靠右
            let most = max(width - container.header.textX, 0)
            let lineWidth = notice?.response == true ? min(body.naturalWidth, most) : most
            bodySize = CGSize(width: lineWidth, height: body.height(width: lineWidth))
        }
        let height = WorkLayout.height(header: headerHeight, steps: bodySize.height, expanded: expanded)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：按它算走到哪了，箭头转多少、正文多透明都跟着它。
    override func layoutView(in frame: CGRect) {
        guard let container else { return }
        let progress = WorkLayout.progress(rowHeight: frame.height, header: headerHeight, steps: bodySize.height, expanded: expanded)
        let trailing = notice?.response == true
        let header = container.header
        let headerWidth = min(header.width, frame.width)
        header.frame = CGRect(x: trailing ? frame.width - headerWidth : 0, y: 0, width: headerWidth, height: headerHeight)
        header.turn = progress
        guard let body = container.body else { return }
        body.frame = CGRect(x: trailing ? frame.width - bodySize.width : header.textX, y: headerHeight + WorkLayout.spacing,
                            width: bodySize.width, height: bodySize.height)
        body.alpha = progress
        // 收起走完拿掉正文
        if !expanded, progress == 0 { container.removeBody() }
    }

    private func toggle() {
        guard let notice, let container else { return }
        context?.select(nil)
        expanded.toggle()
        if expanded, container.body == nil {
            let body = container.addBody(menu: menu)
            body.alpha = 0
            body.set(notice.text, font: font, color: .secondaryLabel)
        }
        show()
        measured = nil
        heightChanged?(WorkLayout.motion)
    }

    func didPlace() {}

    func releaseView() {
        container = nil
        // 重建时是收着的，量过的高（可能带着展开的正文）作废
        if expanded { measured = nil }
        expanded = false
    }
}

/// 通知这一行的视图：那一句、展开后的正文，按自己的范围截（收起时退场的正文不画到后面的行上）。
final class PhoneNoticeRowView: UIView {
    let header = PhoneNoticeHeader()
    private(set) var body: PhoneTextLine?

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addBody(menu: PhoneCopyMenu) -> PhoneTextLine {
        let body = PhoneTextLine()
        body.lines = 0
        body.addInteraction(UIContextMenuInteraction(delegate: menu))
        body.isAccessibilityElement = true
        body.accessibilityTraits = .staticText
        addSubview(body)
        self.body = body
        return body
    }

    func removeBody() {
        body?.removeFromSuperview()
        body = nil
    }
}

/// 通知的那一句：图标（间距 8）或头像（间距 6），竖着居中；那一句（放不下截掉）、间距 8、小号箭头，都是次要色。宽是内容的宽，整块可点。
final class PhoneNoticeHeader: PhonePlainControl {
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat = 0 {
        didSet { if turn != oldValue { chevron.transform = CGAffineTransform(rotationAngle: .pi / 2 * turn) } }
    }
    private let icon = UIImageView()
    private let avatar = CALayer()
    private let title = PhoneTextLine()
    private let chevron = UIImageView()
    /// 有头像时它的直径，没有为 0。
    private var diameter: CGFloat = 0
    private var avatarContent: (instance: String, environment: EnvironmentValues)?

    override init() {
        super.init()
        content.layer.addSublayer(avatar)
        content.addSubview(icon)
        content.addSubview(title)
        content.addSubview(chevron)
        icon.contentMode = .center
        chevron.contentMode = .center
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ notice: Notice, font: UIFont, expanded: Bool, environment: EnvironmentValues) {
        title.set(notice.title, font: font, color: .secondaryLabel)
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
            icon.image = UIImage(systemName: notice.symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))
            icon.tintColor = .secondaryLabel
        }
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))
        chevron.tintColor = .secondaryLabel
        accessibilityLabel = TranscriptSpeech.notice(notice)
        accessibilityValue = TranscriptSpeech.expanded(expanded)
        accessibilityHint = TranscriptSpeech.noticeHint(expanded: expanded)
        setNeedsLayout()
    }

    private func drawAvatar() {
        guard let avatarContent else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatar.contentsScale = scale
        avatar.contents = AgentAvatar.still(design: AgentAvatar.design(for: avatarContent.instance, environment: avatarContent.environment),
                                            instance: avatarContent.instance, diameter: diameter, scale: scale, environment: avatarContent.environment)
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { drawAvatar() }
    }

    /// 那一句从哪起，展开的正文也从这里起。
    var textX: CGFloat { diameter > 0 ? diameter + 6 : (icon.image?.size.width ?? 0) + 8 }
    var height: CGFloat { max(title.lineHeight, diameter, icon.image?.size.height ?? 0) }
    /// 内容的宽：图标、那一句、箭头。
    var width: CGFloat { textX + title.naturalWidth + 8 + (chevron.image?.size.width ?? 0) }

    override func layoutSubviews() {
        super.layoutSubviews()
        if diameter > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            avatar.frame = CGRect(x: 0, y: PhonePixel.round((bounds.height - diameter) / 2), width: diameter, height: diameter)
            CATransaction.commit()
        } else {
            let size = icon.image?.size ?? .zero
            icon.frame = PhonePixel.align(CGRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        let imageSize = chevron.image?.size ?? .zero
        let titleWidth = min(title.naturalWidth, max(bounds.width - textX - 8 - imageSize.width, 0))
        title.frame = CGRect(x: textX, y: PhonePixel.round((bounds.height - title.lineHeight) / 2), width: titleWidth, height: title.lineHeight)
        let transform = chevron.transform
        chevron.transform = .identity
        chevron.frame = PhonePixel.align(CGRect(x: textX + titleWidth + 8, y: (bounds.height - imageSize.height) / 2,
                                                width: imageSize.width, height: imageSize.height))
        chevron.transform = transform
    }
}

/// 压缩的分界：一条横线中间一行次要色小字（「之前的对话已压缩成摘要」，展开后「收起摘要」），整条可点；
/// 点开下面是摘要、显示原文和撤销压缩（PhoneCompactionDetails），原文是一列原生的行。展开收起、显示收起原文都和下面的行一起按
/// snappy 的弹簧走，新露出来的那截按露出多少淡入（用户 2026-10-13 定下面的行跟着走，不跳）。
/// 收起走完拿掉摘要和原文；原文开没开留着，再展开时还在。
final class PhoneCompactedRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var container: PhoneCompactedRowView?
    private var compaction: Compaction?
    private var children: [Item] = []
    private var context: TranscriptRowContext?
    private var expanded = false
    private var original = false
    private var details: PhoneCompactionDetails?
    private var headerHeight: CGFloat = 0
    private var detailsHeight: CGFloat = 0
    /// 正在显示、收起原文：行的高全给摘要那截去摆。摘要那截自己展开收起时清掉。
    private var originalAnimating = false
    private static let spacing: CGFloat = 10
    private static let motion = RowMotion.spring(.snappy)

    override var hasView: Bool { container != nil }
    override var view: UIView { rowView }

    private var rowView: PhoneCompactedRowView {
        if let container { return container }
        let container = PhoneCompactedRowView()
        container.header.action = { [weak self] in self?.toggle() }
        self.container = container
        show(force: true)
        return container
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .compacted(let compaction, let children) = item.kind else { return }
        self.compaction = compaction
        self.children = children
        self.context = context
        show(force: true)
    }

    private func show(force: Bool) {
        guard let compaction, let context, let container else { return }
        let environment = context.environment
        container.header.show(expanded ? "收起摘要" : TranscriptSpeech.compaction(compaction),
                              font: Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont,
                              rule: Theme.rule.resolve(in: environment).cgColor)
        container.header.accessibilityLabel = TranscriptSpeech.compaction(compaction)
        container.header.accessibilityValue = TranscriptSpeech.expanded(expanded)
        details?.show(compaction, children: children, original: original, context: context, force: force)
    }

    /// 拖缝中原文里按近似量的话记作 provisional，停下后列表补量成准确的高。
    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional || resizing { return measured.height }
        headerHeight = rowView.header.height
        provisional = false
        if expanded, let details {
            detailsHeight = details.height(width: width)
            provisional = details.approximate
        }
        let height = headerHeight + (expanded ? Self.spacing + detailsHeight : 0)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：按它算摘要那截露出多少、多透明；显示、收起原文时行的高全给摘要那截去摆。
    override func layoutView(in frame: CGRect) {
        guard let container else { return }
        container.header.frame = CGRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        guard let details else { return }
        let top = headerHeight + Self.spacing
        let full = Self.spacing + detailsHeight
        let progress = originalAnimating ? 1 : full > 0 ? min(max((frame.height - headerHeight) / full, 0), 1) : (expanded ? 1 : 0)
        details.frame = CGRect(x: 0, y: top, width: frame.width, height: originalAnimating ? max(frame.height - top, 0) : detailsHeight)
        details.alpha = progress
        details.layoutIfNeeded()
        // 收起走完拿掉
        if !expanded, progress == 0 {
            details.release()
            details.removeFromSuperview()
            self.details = nil
        }
    }

    private func toggle() {
        guard let container, let compaction, let context else { return }
        context.select(nil)
        expanded.toggle()
        originalAnimating = false
        if expanded, details == nil {
            let details = PhoneCompactionDetails()
            details.toggleOriginal = { [weak self] in self?.toggleOriginal() }
            details.changed = { [weak self] motion in self?.detailsChanged(motion) }
            details.alpha = 0
            container.addSubview(details)
            details.show(compaction, children: children, original: original, context: context, force: true)
            self.details = details
        }
        show(force: false)
        measured = nil
        heightChanged?(Self.motion)
    }

    private func toggleOriginal() {
        guard let compaction, let context, let details else { return }
        original.toggle()
        details.show(compaction, children: children, original: original, context: context, force: false)
        originalAnimating = true
        detailsChanged(Self.motion)
    }

    /// 摘要那截变高变矮（显示、收起原文，原文里展开了什么，摘要的图标载完）：下面的行跟着同样的走法。
    private func detailsChanged(_ motion: RowMotion?) {
        guard expanded, let details, let measured else { return }
        originalAnimating = true
        detailsHeight = details.height(width: measured.width)
        self.measured = (measured.width, headerHeight + Self.spacing + detailsHeight)
        heightChanged?(motion)
    }

    func didPlace() {}

    func releaseView() {
        details?.release()
        details = nil
        container = nil
        // 重建时是收着的，量过的高（可能带着摘要那截）作废
        if expanded { measured = nil }
        expanded = false
    }
}

/// 压缩分界点开以后的那一截：间距 10 竖着排摘要（小一号、次要色，能选字）、
/// 一排文字按钮（「显示原文」「收起原文」、「撤销压缩」，主题色，HStack(spacing: 16)，撤销不了时半透明）、原文（左边空 12，一道竖线）。
/// 按给的高摆：比量的矮或高（显示、收起原文的动画中）时差的那截给原文，原文按露出多少淡入淡出。
final class PhoneCompactionDetails: UIView {
    var changed: ((RowMotion?) -> Void)?
    var toggleOriginal: (() -> Void)?
    private let summary = PhoneProseTextView.make()
    private let coordinator = ProseTextCoordinator()
    private var interaction: PhoneTextInteraction?
    private let document = MarkdownDocument()
    private let attachments = BlockAttachments()
    private var topInset: CGFloat = 0
    private var urls: [URL] = []
    private let originalButton = PhoneTextButton()
    private let revertButton = PhoneTextButton()
    private var stack: PhoneTranscriptStack?
    private let rule = CALayer()
    private var shownOriginal = false
    /// 原文里有一行自己在展开收起：原文按给的高摆，不淡。显示、收起原文时清掉。
    private var stackAnimating = false
    private var heights: (summary: CGFloat, buttons: CGFloat, stack: CGFloat) = (0, 0, 0)
    private var width: CGFloat = 0
    private var source: (summary: String, context: TranscriptRowContext)?
    /// 看着摘要里的引用图标（ReferenceIcons），载完重排。
    private let summaryTracking = ModelTracking()
    /// 看着会话能不能撤销压缩（WorkThread.canCompact）。
    private let threadTracking = ModelTracking()
    private static let spacing: CGFloat = 10

    init() {
        super.init(frame: .zero)
        summary.clipViewport()
        summary.textContainerInset = UIEdgeInsets(top: 0, left: Metrics.inlineCodePadding, bottom: 0, right: Metrics.inlineCodePadding)
        summary.textLayoutManager?.delegate = coordinator
        summary.accessibilityLabel = TranscriptSpeech.compactionSummary
        coordinator.view = summary
        coordinator.resized = { [weak self] in self?.changed?(nil) }
        interaction = PhoneTextInteraction(text: summary, host: summary)
        addSubview(summary)
        addSubview(originalButton)
        addSubview(revertButton)
        // 按下时同别的按钮一样收起操作栏
        originalButton.action = { [weak self] in
            self?.source?.context.select(nil)
            self?.toggleOriginal?()
        }
        revertButton.title = TranscriptSpeech.revertCompaction
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var hasButtons: Bool { !originalButton.isHidden || !revertButton.isHidden }

    func show(_ compaction: Compaction, children: [Item], original: Bool, context: TranscriptRowContext, force: Bool) {
        let environment = context.environment
        let openURL = environment.openURL
        interaction?.openURL = { openURL($0) }
        let font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont
        let accent = UIColor(cgColor: Color.accentColor.resolve(in: environment).cgColor)
        if force || source?.summary != compaction.summary {
            source = (compaction.summary, context)
            // 摘要、环境换了，要看的引用图标跟着换
            summaryTracking.cancel()
            buildSummary()
        }
        originalButton.isHidden = children.isEmpty
        originalButton.title = TranscriptSpeech.original(shown: original)
        revertButton.isHidden = compaction.id == nil
        if let id = compaction.id {
            revertButton.action = { [weak self] in
                self?.source?.context.select(nil)
                self?.revert(id)
            }
        }
        for button in [originalButton, revertButton] { button.style(font: font, color: accent) }
        showRevert(environment)
        rule.backgroundColor = Theme.rule.resolve(in: environment).cgColor
        if original != shownOriginal { stackAnimating = false }
        shownOriginal = original
        if original {
            let stack = stack ?? {
                let stack = PhoneTranscriptStack()
                stack.changed = { [weak self] motion in
                    self?.stackAnimating = true
                    self?.changed?(motion)
                }
                stack.view.layer.addSublayer(rule)
                addSubview(stack.view)
                self.stack = stack
                return stack
            }()
            stack.update(TranscriptRow.rows(items: children, pending: []), context: context.nested, force: force)
        }
        setNeedsLayout()
    }

    /// 摘要按 SelectableMarkdown 排（小一号、次要色），读了引用图标，图标载完重排一次。
    private func buildSummary() {
        guard let (source, context) = self.source else { return }
        let environment = context.environment
        let content = summaryTracking.track { () -> TextViewContent in
            let body = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont
            let prose = SelectableMarkdown.prose(document.blocks(for: source), source: source, body: body, color: .secondaryLabel,
                                                 environment: environment, attachments: attachments, loaded: &urls)
            topInset = prose.topInset
            return prose.content
        } changed: { [weak self] in
            // 通知在图标写进去之前发出，下一拍再按新的排
            DispatchQueue.main.async { [weak self] in
                self?.buildSummary()
                self?.changed?(nil)
            }
        }
        summary.source = content.source
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(environment))
        guard coordinator.shown != content.text else { return }
        coordinator.shown = content.text
        summary.attributedText = content.text
    }

    /// 撤销压缩能不能点跟着会话的状态（WorkThread.canCompact）变。
    private func showRevert(_ environment: EnvironmentValues) {
        let thread = environment[WorkThread.self]
        revertButton.isEnabled = threadTracking.track { thread?.canCompact ?? false } changed: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, let context = source?.context else { return }
                showRevert(context.environment)
            }
        }
    }

    private func revert(_ id: String) {
        source?.context.environment[WorkThread.self]?.revertCompaction(id)
    }

    /// 摘要、按钮、原文不在动时多高。
    func height(width: CGFloat) -> CGFloat {
        self.width = width
        heights.summary = summary.measure(lineWidth: width) + topInset
        heights.buttons = hasButtons ? max(originalButton.height, revertButton.height) : 0
        heights.stack = stack?.height(width: max(width - 12, 0)) ?? 0
        return fixedHeight + (shownOriginal ? Self.spacing + heights.stack : 0)
    }

    /// 上次量的时候原文里有按近似量的行（拖缝中），见 PhoneTranscriptStack.approximate。
    var approximate: Bool { shownOriginal && stack?.approximate == true }

    /// 放掉摘要里卡片的宿主和原文里的视图：压缩分界放掉视图、被删掉、收起拿掉这一截时调。
    func release() {
        attachments.releaseHosts()
        stack?.release()
    }

    private var fixedHeight: CGFloat {
        heights.summary + (hasButtons ? Self.spacing + heights.buttons : 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        summary.frame = CGRect(x: -Metrics.inlineCodePadding, y: topInset, width: PhoneProseTextView.widest,
                               height: heights.summary - topInset)
        var x: CGFloat = 0
        let y = heights.summary + Self.spacing
        for button in [originalButton, revertButton] where !button.isHidden {
            button.frame = CGRect(x: x, y: y, width: button.width, height: heights.buttons)
            x += button.width + 16
        }
        guard let stack else { return }
        let top = fixedHeight + Self.spacing
        let available = max(bounds.height - top, 0)
        let full = Self.spacing + heights.stack
        // 原文按露出多少淡入淡出，收起走完拿掉
        let progress = full > 0 ? min(max((bounds.height - fixedHeight) / full, 0), 1) : 0
        stack.view.frame = CGRect(x: 12, y: top, width: max(width - 12, 0), height: stackAnimating ? available : heights.stack)
        stack.view.alpha = stackAnimating ? 1 : progress
        stack.layout(height: stack.view.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.frame = CGRect(x: -12, y: 0, width: 1, height: stack.view.frame.height)
        CATransaction.commit()
        if !shownOriginal, progress == 0 {
            stack.release()
            stack.view.removeFromSuperview()
            self.stack = nil
        }
    }
}

/// 一个文字按钮，照 pointingPlain 的 Button("…")：主题色的字，按下变淡，撤销不了这种不能点时半透明（同 SwiftUI 量过：主题色 50%）。
final class PhoneTextButton: PhonePlainControl {
    private let label = PhoneTextLine()
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)
    private var color = UIColor.tintColor
    var title = "" {
        didSet { if title != oldValue { update() } }
    }

    override init() {
        super.init()
        content.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(font: UIFont, color: UIColor) {
        self.font = font
        self.color = color
        update()
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { update() } }
    }

    private func update() {
        label.set(title, font: font, color: isEnabled ? color : color.withAlphaComponent(0.5))
        accessibilityLabel = title
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        setNeedsLayout()
    }

    var width: CGFloat { label.naturalWidth }
    var height: CGFloat { label.lineHeight }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: label.lineHeight)
    }
}

/// 压缩分界的视图：分界那一条、点开后的那一截，按自己的范围截（收起时退场的摘要不画到后面的行上）。
final class PhoneCompactedRowView: UIView {
    let header = PhoneDividerHeader()

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 压缩分界的那一条：HStack(spacing: 10) 两边各一条 1 pt 的横线，中间的字按自己的宽居中，竖着居中。
final class PhoneDividerHeader: PhonePlainControl {
    private let title = PhoneTextLine()
    private let left = CALayer()
    private let right = CALayer()

    override init() {
        super.init()
        content.layer.addSublayer(left)
        content.layer.addSublayer(right)
        content.addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, font: UIFont, rule: CGColor) {
        title.set(text, font: font, color: .secondaryLabel)
        left.backgroundColor = rule
        right.backgroundColor = rule
        accessibilityLabel = text
        setNeedsLayout()
    }

    var height: CGFloat { title.lineHeight }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing: CGFloat = 10
        let width = title.naturalWidth
        let side = max((bounds.width - width - spacing * 2) / 2, 0)
        title.frame = CGRect(x: side + spacing, y: 0, width: width, height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let y = PhonePixel.round((bounds.height - 1) / 2)
        left.frame = CGRect(x: 0, y: y, width: side, height: 1)
        right.frame = CGRect(x: side + spacing * 2 + width, y: y, width: side, height: 1)
        CATransaction.commit()
    }
}
#endif
