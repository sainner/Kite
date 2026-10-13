#if os(iOS)
import CoreText
import SwiftUI
import UIKit

/// 工具行点开后的步骤：一步一行，同批调用之间隔横向虚线，不同批隔实线，整块圆角 8、细描边。
/// 每一步再点开看参数和结果（PhoneCallDetail），按 0.25 秒的普通缓出展开。
/// 一步展开收起时，它的高由列表的行高动画给：整块按给的高摆，多出、少掉的那截都给正在动的那一步（见 layout）。
final class PhoneWorkSteps: UIView {
    /// 一步展开收起了、或者里面嵌着的对话变了：带着走法报给工具行，工具行再报给列表。
    var changed: ((RowMotion?) -> Void)?
    /// 正在展开收起的那一步。工具行自己展开收起时清掉。
    var animating: Int?
    private var rows: [PhoneCallRow] = []
    private var separators: [CAShapeLayer] = []
    private let content = UIView()
    private let clip = CAShapeLayer()
    private let border = CAShapeLayer()
    private var heights: [CGFloat] = []
    private var rule: CGColor?

    init() {
        super.init(frame: .zero)
        addSubview(content)
        content.layer.mask = clip
        border.fillColor = nil
        border.lineWidth = 1
        layer.addSublayer(border)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ work: Work, context: TranscriptRowContext) {
        // 步骤按原来的序号认，后续调用到来、形成批次时，已经展开的那一步不重建
        while rows.count < work.calls.count {
            let row = PhoneCallRow()
            row.changed = { [weak self, weak row] motion in
                guard let self, let row, let index = rows.firstIndex(where: { $0 === row }) else { return }
                animating = index
                changed?(motion)
            }
            rows.append(row)
            content.addSubview(row)
        }
        while rows.count > work.calls.count {
            let row = rows.removeLast()
            row.release()
            row.removeFromSuperview()
        }
        for (index, call) in work.calls.enumerated() { rows[index].show(call, context: context) }
        rule = Theme.toolRule.resolve(in: context.environment).cgColor
        let count = max(work.calls.count - 1, 0)
        while separators.count < count {
            let separator = CAShapeLayer()
            separator.lineWidth = 1
            separator.fillColor = nil
            content.layer.addSublayer(separator)
            separators.append(separator)
        }
        while separators.count > count { separators.removeLast().removeFromSuperlayer() }
        for (index, separator) in separators.enumerated() {
            let batch = work.calls[index].use.batch
            let sameBatch = batch != nil && batch == work.calls[index + 1].use.batch
            separator.lineDashPattern = sameBatch ? [4, 3] : nil
            separator.strokeColor = rule
        }
        border.strokeColor = rule
        setNeedsLayout()
    }

    /// 各步不在动时的高加上分隔线。
    func height(width: CGFloat) -> CGFloat {
        heights = rows.map { $0.height(width: width) }
        return heights.reduce(0, +) + CGFloat(separators.count)
    }

    /// 上次量的时候嵌着的对话里有按近似量的行（拖缝中），见 PhoneTranscriptStack.approximate。
    var approximate: Bool { rows.contains { $0.approximate } }

    /// 放掉嵌着的对话里的视图和托管的宿主：工具行放掉视图、被删掉、收起拿掉步骤时调。
    func release() {
        for row in rows { row.release() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let total = heights.reduce(0, +) + CGFloat(separators.count)
        var y: CGFloat = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, row) in rows.enumerated() where index < heights.count {
            if index > 0 {
                let separator = separators[index - 1]
                separator.frame = CGRect(x: 0, y: y, width: bounds.width, height: 1)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: bounds.width, y: 0.5))
                separator.path = path
                y += 1
            }
            var height = heights[index]
            // 动画中多出、少掉的那截给正在动的那一步
            if index == animating { height = max(height + bounds.height - total, row.collapsedHeight) }
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            row.layout(height: height)
            y += height
        }
        content.frame = bounds
        clip.frame = bounds
        clip.path = RoundedRectangle(cornerRadius: Metrics.toolGroupRadius).path(in: bounds).cgPath
        border.frame = bounds
        border.path = RoundedRectangle(cornerRadius: Metrics.toolGroupRadius).inset(by: 0.5).path(in: bounds).cgPath
        CATransaction.commit()
    }
}

/// 一次工具调用：标题行（图标、名字、摘要或文件引用、补丁行数和运行时间），点开下面是参数和结果，按自己的范围截。
final class PhoneCallRow: UIView {
    var changed: ((RowMotion?) -> Void)?
    private let header = PhoneCallHeader()
    private var detail: PhoneCallDetail?
    private var call: Call?
    private var context: TranscriptRowContext?
    private var expanded = false
    private var headerHeight: CGFloat = 0
    private var detailHeight: CGFloat = 0
    private static let motion = RowMotion.curve(.easeOut, duration: 0.25)

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(header)
        header.toggle = { [weak self] in self?.toggle() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ call: Call, context: TranscriptRowContext) {
        self.call = call
        self.context = context
        header.show(call, expanded: expanded, context: context)
        detail?.show(call, context: context)
    }

    var collapsedHeight: CGFloat { headerHeight }

    func height(width: CGFloat) -> CGFloat {
        headerHeight = header.height
        guard expanded, let detail else { return headerHeight }
        detailHeight = detail.height(width: max(width - Metrics.toolRowInset * 2, 0))
        return headerHeight + detailHeight + 10
    }

    var approximate: Bool { expanded && detail?.approximate == true }

    func release() {
        detail?.release()
    }

    /// 按给的高摆：动画中在收起和展开之间，详情按露出多少淡入淡出；收起走完拿掉详情，不留它的状态。
    func layout(height: CGFloat) {
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        guard let detail else { return }
        let full = detailHeight + 10
        let progress = full > 0 ? min(max((height - headerHeight) / full, 0), 1) : 0
        detail.frame = CGRect(x: Metrics.toolRowInset, y: headerHeight, width: max(bounds.width - Metrics.toolRowInset * 2, 0), height: detailHeight)
        detail.alpha = progress
        if !expanded, progress == 0 {
            detail.release()
            detail.removeFromSuperview()
            self.detail = nil
        }
    }

    private func toggle() {
        guard let call, let context else { return }
        context.select(nil)
        expanded.toggle()
        if expanded, detail == nil {
            let detail = PhoneCallDetail()
            detail.changed = { [weak self] motion in self?.changed?(motion) }
            detail.alpha = 0
            addSubview(detail)
            detail.show(call, context: context)
            self.detail = detail
        }
        header.show(call, expanded: expanded, context: context)
        changed?(Self.motion)
    }
}

/// 一步的标题行：图标（16 宽）、名字（半粗）、摘要或文件引用，间距 6，右边是小标签；
/// 竖着居中，高是 toolRowHeight 随字号缩放。整行点开、收起；点在文件引用上打开引用。等待中、执行中带动效（PhoneActivityView）。
final class PhoneCallHeader: UIControl, UIPointerInteractionDelegate {
    var toggle: (() -> Void)?
    private let activity = PhoneActivityView()
    private let icon = UIImageView()
    private let name = PhoneTextLine()
    private let summary = PhoneLinkLine()
    private let diff = PhoneChip()
    private let duration = PhoneChip()
    private var openURL: OpenURLAction?
    private var touched: CGPoint?
    private var height0: CGFloat = 36
    /// 在跑的命令每秒更新运行时间。
    private var timer: Timer?
    private var call: Call?

    init() {
        super.init(frame: .zero)
        addSubview(activity)
        for view in [icon, name, summary] as [UIView] { activity.content.addSubview(view) }
        icon.contentMode = .center
        addSubview(diff)
        addSubview(duration)
        addTarget(self, action: #selector(triggered), for: .primaryActionTriggered)
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ call: Call, expanded: Bool, context: TranscriptRowContext) {
        self.call = call
        let environment = context.environment
        openURL = environment.openURL
        let font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont
        let failed = call.state == .failed || call.state == .unknown
        let danger = UIColor(Theme.danger)
        icon.image = UIImage(systemName: call.use.kind.icon, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))
        icon.tintColor = failed ? danger : .secondaryLabel
        let semibold = UIFont(descriptor: font.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]]),
                              size: 0)
        name.set(call.use.displayName, font: semibold, color: failed ? danger : .label)
        let root = environment.workingDirectory
        let text = call.use.rowSummary(relativeTo: root, generating: call.state == .generating)
        let color: UIColor = failed ? danger : .secondaryLabel
        if call.state != .generating, !call.fileReferences.isEmpty {
            // 文件引用：带下划线的链接，中间用 · 隔开，放不下截中间
            let result = NSMutableAttributedString()
            for (index, reference) in call.fileReferences.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: color])) }
                result.append(NSAttributedString(string: reference.label, attributes: [
                    .font: font, .foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: reference.url(in: environment.referenceScope)]))
            }
            summary.set(result, font: font, truncation: .middle)
        } else {
            summary.set(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]), font: font,
                        truncation: call.use.kind == .command ? .end : .middle)
        }
        activity.contentChanged()
        activity.show(call.state, presence: environment.panePresence)
        let status = Theme.status.resolve(in: environment.fontResolutionContext).ctFont as UIFont
        diff.show(call.use.diffSummary, font: status.monospacedDigits, fill: Theme.codeBackground.resolve(in: environment).cgColor)
        diff.accessibilityLabel = call.use.diffSummary.map(TranscriptSpeech.patchLines)
        duration.font = status.monospacedDigits
        duration.fill = Theme.codeBackground.resolve(in: environment).cgColor
        updateDuration()
        height0 = UIFontMetrics(forTextStyle: .subheadline).scaledValue(
            for: Metrics.toolRowHeight, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(environment.dynamicTypeSize)))
        let spoken = TranscriptSpeech.call(call, summary: text)
        accessibilityLabel = spoken.label
        accessibilityValue = spoken.value
        accessibilityHint = TranscriptSpeech.callHint(expanded: expanded)
        setNeedsLayout()
    }

    /// 命令的运行时间：跑完了按开始到结束，在跑时每秒按现在更新。
    private func updateDuration() {
        timer?.invalidate()
        timer = nil
        guard let call, call.use.kind == .command, let start = call.use.startedAt else { return duration.show(nil, font: nil, fill: nil) }
        if let finish = call.use.finishedAt {
            showDuration(finish - start)
        } else if call.state == .running {
            showDuration(Date().timeIntervalSince1970 * 1000 - start)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { return }
                    self.showDuration(Date().timeIntervalSince1970 * 1000 - start)
                    self.setNeedsLayout()
                }
            }
        } else {
            duration.show(nil, font: nil, fill: nil)
        }
    }

    private func showDuration(_ milliseconds: Double) {
        let value = max(0, milliseconds)
        let text = value < 1000
            ? value.formatted(.number.precision(.fractionLength(0))) + " ms"
            : (value / 1000).formatted(.number.precision(.fractionLength(0...1))) + " s"
        duration.show(text, font: nil, fill: nil)
        duration.accessibilityLabel = TranscriptSpeech.duration(text)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil, call?.state == .running {
            updateDuration()
        }
    }

    var height: CGFloat { height0 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = Metrics.toolLabelGap
        let inset = Metrics.toolRowInset
        // 右边的小标签：HStack(spacing: 4)
        let chips = [diff, duration].filter { !$0.isHidden }
        let chipsWidth = chips.reduce(0) { $0 + $1.size.width } + CGFloat(max(chips.count - 1, 0)) * 4
        var x = bounds.width - inset - chipsWidth
        for chip in chips {
            chip.frame = PhonePixel.align(CGRect(x: x, y: (bounds.height - chip.size.height) / 2, width: chip.size.width, height: chip.size.height))
            x += chip.size.width + 4
        }
        // 左边一组：图标、名字不截，摘要放不下截
        let room = max(bounds.width - inset * 2 - chipsWidth - gap * 2, 0)
        let imageSize = icon.image?.size ?? .zero
        let nameWidth = name.naturalWidth
        let summaryWidth = min(summary.naturalWidth, max(room - Metrics.toolIcon - gap - nameWidth - gap, 0))
        let groupWidth = Metrics.toolIcon + gap + nameWidth + gap + summaryWidth
        let lineHeight = max(name.lineHeight, summary.lineHeight)
        let groupHeight = max(lineHeight, imageSize.height)
        activity.frame = PhonePixel.align(CGRect(x: inset, y: (bounds.height - groupHeight) / 2, width: groupWidth, height: groupHeight))
        icon.frame = PhonePixel.align(CGRect(x: (Metrics.toolIcon - imageSize.width) / 2, y: (groupHeight - imageSize.height) / 2,
                                             width: imageSize.width, height: imageSize.height))
        name.frame = PhonePixel.align(CGRect(x: Metrics.toolIcon + gap, y: (groupHeight - name.lineHeight) / 2, width: nameWidth, height: name.lineHeight))
        summary.frame = PhonePixel.align(CGRect(x: Metrics.toolIcon + gap + nameWidth + gap, y: (groupHeight - summary.lineHeight) / 2,
                                                width: summaryWidth, height: summary.lineHeight))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touched = touch.location(in: summary)
        return super.beginTracking(touch, with: event)
    }

    /// 点在文件引用上打开它，别处展开、收起。
    @objc private func triggered() {
        if let touched, let url = summary.link(at: touched) {
            openURL?(url)
        } else {
            toggle?()
        }
        touched = nil
    }

    /// 正文上的点按不抢这一行的点，见 PhonePlainControl。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer, gestureRecognizer.view !== self { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .automatic(UITargetedPreview(view: self)))
    }
}

/// 一个小标签：最小号的等宽数字，次要色，左右 6、上下 2 的胶囊底。
final class PhoneChip: UIView {
    private let label = PhoneTextLine()
    var font: UIFont?
    var fill: CGColor? { didSet { layer.backgroundColor = fill } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        isHidden = true
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 给 nil 不显示。font、fill 给 nil 时沿用上次的。
    func show(_ text: String?, font: UIFont?, fill: CGColor?) {
        if let font { self.font = font }
        if let fill { self.fill = fill }
        guard let text, let font = self.font else {
            isHidden = true
            return
        }
        isHidden = false
        label.set(text, font: font, color: .secondaryLabel)
        size = CGSize(width: label.naturalWidth + 12, height: label.lineHeight + 4)
        setNeedsLayout()
    }

    private(set) var size: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 6, y: 2, width: max(bounds.width - 12, 0), height: label.lineHeight)
        layer.cornerRadius = bounds.height / 2
    }
}

/// 一步的参数和结果：两张卡片（参数、结果）隔 6，子 agent 做的事接在下面、左边空 12。字是等宽的次要字号。
final class PhoneCallDetail: UIView {
    var changed: ((RowMotion?) -> Void)?
    private let input = PhoneDetailCard()
    private let result = PhoneDetailCard()
    private var children: PhoneTranscriptStack?
    private var heights: (input: CGFloat, result: CGFloat, children: CGFloat) = (0, 0, 0)
    private static let spacing: CGFloat = 6

    init() {
        super.init(frame: .zero)
        addSubview(input)
        addSubview(result)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ call: Call, context: TranscriptRowContext) {
        var fields = call.detailInput.detailFields
        if call.state == .generating { fields.append(("arguments（原文）", .string(call.use.arguments ?? ""))) }
        input.show(fields, context: context)
        result.show(call.detailResult.detailFields, context: context)
        if call.children.isEmpty {
            children?.release()
            children?.view.removeFromSuperview()
            children = nil
        } else {
            let stack = children ?? {
                let stack = PhoneTranscriptStack()
                stack.changed = { [weak self] motion in self?.changed?(motion) }
                addSubview(stack.view)
                children = stack
                return stack
            }()
            stack.update(TranscriptRow.rows(items: call.children, pending: []), context: context.nested, force: false)
        }
    }

    func height(width: CGFloat) -> CGFloat {
        heights.input = input.height(width: width)
        heights.result = result.height(width: width)
        heights.children = children?.height(width: max(width - 12, 0)) ?? 0
        return heights.input + Self.spacing + heights.result + (children == nil ? 0 : Self.spacing + heights.children)
    }

    var approximate: Bool { children?.approximate == true }

    func release() {
        children?.release()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        input.frame = CGRect(x: 0, y: 0, width: bounds.width, height: heights.input)
        result.frame = CGRect(x: 0, y: heights.input + Self.spacing, width: bounds.width, height: heights.result)
        if let children {
            let y = heights.input + Self.spacing + heights.result + Self.spacing
            children.view.frame = CGRect(x: 12, y: y, width: max(bounds.width - 12, 0), height: max(bounds.height - y, 0))
            children.layout(height: max(bounds.height - y, 0))
        }
    }
}

/// 一张详情卡片：列间 12、行间 8，每行左边是键（次要色，最宽 96，长了折行），右边是值（序列化成一行的 JSON，
/// 文件路径是链接，长了折行，能选字），四边空 10，代码底色、圆角 8。
final class PhoneDetailCard: UIView {
    private var rows: [(key: PhoneTextLine, value: PhoneDetailValue)] = []
    private let background = CAShapeLayer()
    private var keyWidth: CGFloat = 0
    private var rowHeights: [CGFloat] = []

    init() {
        super.init(frame: .zero)
        layer.addSublayer(background)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ fields: [(key: String, value: JSON)], context: TranscriptRowContext) {
        let environment = context.environment
        let font = Theme.code.resolve(in: environment.fontResolutionContext).ctFont as UIFont
        while rows.count < fields.count {
            let key = PhoneTextLine()
            key.lines = 0
            let value = PhoneDetailValue()
            addSubview(key)
            addSubview(value.text)
            rows.append((key, value))
        }
        while rows.count > fields.count {
            let row = rows.removeLast()
            row.key.removeFromSuperview()
            row.value.text.removeFromSuperview()
        }
        for (index, field) in fields.enumerated() {
            rows[index].key.set(field.key, font: font, color: .secondaryLabel)
            rows[index].value.show(field.value.detailText, font: font, context: context)
        }
        background.fillColor = Theme.codeBackground.resolve(in: environment).cgColor
        setNeedsLayout()
    }

    func height(width: CGFloat) -> CGFloat {
        let inner = max(width - 20, 0)
        keyWidth = min(rows.map(\.key.naturalWidth).max() ?? 0, 96)
        let valueWidth = max(inner - keyWidth - 12, 0)
        rowHeights = rows.map { max($0.key.height(width: keyWidth), $0.value.height(width: valueWidth)) }
        return 20 + rowHeights.reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let valueWidth = max(bounds.width - 20 - keyWidth - 12, 0)
        var y: CGFloat = 10
        for (index, row) in rows.enumerated() where index < rowHeights.count {
            row.key.frame = CGRect(x: 10, y: y, width: keyWidth, height: row.key.height(width: keyWidth))
            // 视图宽固定（见 PhoneProseTextView.clipViewport），字排在值那一列的宽里
            row.value.text.frame = CGRect(x: 10 + keyWidth + 12, y: y, width: PhoneProseTextView.widest, height: row.value.height(width: valueWidth))
            y += rowHeights[index] + 8
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        background.path = RoundedRectangle(cornerRadius: Metrics.toolGroupRadius).path(in: bounds).cgPath
        CATransaction.commit()
    }
}

/// 详情里的一个值，照 ReferenceLabel(compact: false)：文件路径换成链接（不带图标），能长按拖选、点链接。
@MainActor final class PhoneDetailValue {
    let text = PhoneProseTextView.make()
    private var interaction: PhoneTextInteraction?
    private var shown: String?
    private var measured: (width: CGFloat, height: CGFloat)?

    init() {
        interaction = PhoneTextInteraction(text: text, host: text)
        text.clipViewport()
        text.textContainerInset = .zero
    }

    func show(_ value: String, font: UIFont, context: TranscriptRowContext) {
        let openURL = context.environment.openURL
        interaction?.openURL = { openURL($0) }
        let key = "\(value)\u{0}\(font.pointSize)\u{0}\(context.environment.colorScheme)"
        guard key != shown else { return }
        shown = key
        measured = nil
        let decorated = InlineCodeSpacing.apply(to: ReferenceText.decorate(AttributedString(value), scope: context.environment.referenceScope,
                                                                           compact: false))
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .standard
        let result = NSMutableAttributedString()
        for run in decorated.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: style]
            if let link = run.link { attributes[.link] = link }
            if let kern = run.swiftUI.kern { attributes[.kern] = kern }
            result.append(NSAttributedString(string: String(decorated[run.range].characters), attributes: attributes))
        }
        text.attributedText = result
    }

    func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = text.measure(lineWidth: width)
        measured = (width, height)
        return height
    }
}

extension TranscriptRowContext {
    /// 嵌着的对话（子 agent 做的事、压缩前的原文）里的行：没有操作栏，序号和主对话的会撞。同 Mac 的 TranscriptStack。
    var nested: TranscriptRowContext {
        TranscriptRowContext(environment: environment, actionable: false, toggleActions: { _ in })
    }
}

/// 嵌着的一段对话（子 agent 做的事、压缩前的原文）：原生的行一行行竖着排，行距 rowSpacing 加每行的 gap；
/// 全部建着、全部量，行视图和主对话同一套（makePhoneTranscriptRowSlot）。
/// 一行自己展开收起时报给外面，按给的高摆，多出、少掉的那截给正在动的那一行。
@MainActor final class PhoneTranscriptStack {
    let view = UIView()
    var changed: ((RowMotion?) -> Void)?
    private var slots: [TranscriptRowSlot] = []
    private var shapes: [RowID: Int] = [:]
    private var heights: [CGFloat] = []
    private var width: CGFloat = 0
    private var animating: RowID?

    /// force：外观变了，所有行都换一遍。
    func update(_ rows: [TranscriptRow], context: TranscriptRowContext, force: Bool) {
        let old = Dictionary(slots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [TranscriptRowSlot] = []
        for row in rows {
            var hasher = Hasher()
            row.shape(into: &hasher)
            let shape = hasher.finalize()
            if let slot = old[row.id], phoneTranscriptRowSlotFits(slot, row) {
                if force || shapes[row.id] != shape { slot.update(row, context: context) }
                next.append(slot)
            } else {
                let slot = makePhoneTranscriptRowSlot(row)
                slot.heightChanged = { [weak self, weak slot] motion in
                    guard let self, let slot else { return }
                    animating = slot.id
                    changed?(motion)
                }
                slot.update(row, context: context)
                next.append(slot)
            }
            shapes[row.id] = shape
        }
        for slot in slots where !next.contains(where: { $0 === slot }) {
            if slot.hasView { slot.view.removeFromSuperview() }
            (slot as? PhoneRowSlot)?.releaseView()
            shapes[slot.id] = nil
        }
        slots = next
    }

    /// 上次量的时候有行按近似量（拖缝中，见 TranscriptRowSlot.provisional）：外面那一行也记作 provisional，停下后整列重量。
    private(set) var approximate = false

    /// 按宽量整列多高。拖缝中各行同列表里一样按近似量（气泡见 PhoneBubbleRowSlot），停下后按近似量过的作废重量。
    func height(width: CGFloat) -> CGFloat {
        self.width = width
        let resizing = WindowLayout.anyResizing
        approximate = false
        heights = slots.map { slot in
            if !resizing, slot.provisional { slot.measured = nil }
            slot.resizing = resizing
            let height = slot.height(width: width)
            if slot.provisional { approximate = true }
            return height
        }
        return heights.reduce(0, +) + spacing
    }

    /// 各行放掉视图和托管的宿主：外面那一行放掉视图、被删掉、收起拿掉这一列时调。
    func release() {
        for slot in slots { (slot as? PhoneRowSlot)?.releaseView() }
    }

    /// 行距：第一行以外每行上面 rowSpacing 加它的 gap。
    private var spacing: CGFloat {
        slots.dropFirst().reduce(0) { $0 + Metrics.rowSpacing + $1.row.gap }
    }

    func layout(height: CGFloat) {
        let total = heights.reduce(0, +) + spacing
        var y: CGFloat = 0
        for (index, slot) in slots.enumerated() where index < heights.count {
            if index > 0 { y += Metrics.rowSpacing + slot.row.gap }
            var rowHeight = heights[index]
            if slot.id == animating { rowHeight = max(rowHeight + height - total, 0) }
            let frame = PhonePixel.align(slot.viewFrame(in: CGRect(x: 0, y: y, width: width, height: rowHeight)))
            let view = slot.view
            if view.superview !== self.view {
                self.view.addSubview(view)
                (slot as? PhoneRowSlot)?.didPlace()
            }
            if view.frame != frame { view.frame = frame }
            slot.layoutView(in: CGRect(origin: .zero, size: frame.size))
            y += rowHeight
        }
    }
}

/// 一行带链接的字（工具步骤的摘要、文件引用）：CoreText 排一行，放不下按 truncation 截（中间或末尾），能查出点在哪个链接上。
/// 一行高、基线同 PhoneTextLine（Text 的取整）。
final class PhoneLinkLine: UIView {
    private var text = NSAttributedString()
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)
    private var truncation = CTLineTruncationType.end

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 不截时多宽，换了字作废。
    private var natural: CGFloat?

    func set(_ text: NSAttributedString, font: UIFont, truncation: CTLineTruncationType) {
        self.text = text
        self.font = font
        self.truncation = truncation
        natural = nil
        setNeedsDisplay()
    }

    var naturalWidth: CGFloat {
        if let natural { return natural }
        let width = PhonePixel.ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(core(text)), nil, nil, nil))
        natural = width
        return width
    }

    var lineHeight: CGFloat { PhonePixel.ceil(font.lineHeight) }

    /// CoreText 只认 CGColor：字色按这个视图的外观解析成 CGColor。
    private func core(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let color = value as? UIColor else { return }
            result.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                value: color.resolvedColor(with: traitCollection).cgColor, range: range)
        }
        return result
    }

    /// 按眼下的宽截好的一行。
    private var line: CTLine {
        let full = CTLineCreateWithAttributedString(core(text))
        guard CTLineGetTypographicBounds(full, nil, nil, nil) > bounds.width else { return full }
        let attributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        let token = CTLineCreateWithAttributedString(core(NSAttributedString(string: "…", attributes: attributes.filter {
            $0.key != .link && $0.key != .underlineStyle })))
        return CTLineCreateTruncatedLine(full, Double(bounds.width), truncation, token) ?? full
    }

    /// point 处（这个视图的坐标）的链接。
    func link(at point: CGPoint) -> URL? {
        guard bounds.insetBy(dx: 0, dy: -8).contains(point) else { return nil }
        var x: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
            if point.x >= x, point.x < x + width {
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any]
                return attributes?[.link] as? URL
            }
            x += width
        }
        return nil
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: lineHeight - font.lineHeight + font.ascender)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
#endif
