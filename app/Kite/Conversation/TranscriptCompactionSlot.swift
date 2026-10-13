#if os(macOS)
import AppKit
import SwiftUI

/// 压缩的分界，照 CompactedDivider：一行次要字号的「之前的对话已压缩成摘要」，两边细线，整行可点。点开下面是摘要（能选）和一排文字按钮：
/// 被收起的原文能展开（「显示原文」），Kite 的压缩还能撤销；原文是一列原生的行，左边一道竖线。
/// 展开收起和下面的行一起按 snappy 的弹簧动（SwiftUI 版的托管行里先动、列表的行后跳，用户 2026-10-13 定跟着动）：
/// 行按自己的范围截，新露出来的一截按露出多少淡入，标签的两种字交叉淡变；收起走完拿掉摘要和原文，同 SwiftUI 版不留它们的状态。
final class CompactionRowSlot: TranscriptRowSlot {
    private let container = CompactionRowView()
    private var compaction: Compaction?
    private var children: [Item] = []
    private var context: TranscriptRowContext?
    private var expanded = false
    /// 展开了原文。收起摘要时原文一起收起，但这个状态留着，再展开摘要时原文还在，同 SwiftUI 版的 @State。
    private var original = false
    private var summary: MarkdownTextBlock?
    private var stack: TranscriptStack?
    /// 量过的各段高：标签那一行、摘要、按钮那一行、原文。
    private var headerHeight: CGFloat = 0
    private var summaryHeight: CGFloat = 0
    private var buttonsHeight: CGFloat = 0
    private var stackHeight: CGFloat = 0
    /// 「显示原文」「收起原文」正在换字，跟着原文那一段露出多少走。
    private var originalSwitching = false
    /// 在看会话能不能撤销压缩，变了再看一次。
    private var watchingThread = false

    /// 标签、摘要、按钮、原文之间的间距，同 CompactedDivider 的 VStack。
    private static let spacing: CGFloat = 10
    static let motion = RowMotion.spring(.snappy)

    override init(row: TranscriptRow) {
        super.init(row: row)
        container.header.action = { [weak self] in self?.toggle() }
        container.buttons.original.action = { [weak self] in self?.toggleOriginal() }
        container.buttons.revert.action = { [weak self] in self?.revert() }
    }

    override var hasView: Bool { true }
    override var view: NSView { container }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .compacted(let compaction, let children) = item.kind else { return }
        self.compaction = compaction
        self.children = children
        self.context = context
        let environment = context.environment
        let font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        container.header.show(collapsed: TranscriptSpeech.compaction(compaction), expanded: "收起摘要", font: font,
                              rule: Theme.rule.resolve(in: environment).cgColor)
        container.header.expanded = expanded
        let accent = NSColor(cgColor: Color.accentColor.resolve(in: environment).cgColor) ?? .controlAccentColor
        container.buttons.style(font: font, color: accent)
        container.rule.backgroundColor = Theme.rule.resolve(in: environment).cgColor
        showButtons()
        if expanded { showSummary() }
        if let stack { stack.update(rows, context: nested, resized: resized) }
    }

    /// 原文的行：没有操作栏，序号和主对话的会撞。
    private var nested: TranscriptRowContext {
        TranscriptRowContext(environment: context?.environment ?? EnvironmentValues(), actionable: false, toggleActions: { _ in })
    }

    private var rows: [TranscriptRow] { TranscriptRow.rows(items: children, pending: []) }

    /// 按钮那一行：有原文才有「显示原文」，Kite 的压缩（有 id）才能撤销，没连上、在跑这些时候撤销不了（WorkThread.canCompact）。
    private func showButtons() {
        guard let compaction, let context else { return }
        let buttons = container.buttons
        buttons.original.isHidden = children.isEmpty
        buttons.original.title = TranscriptSpeech.original(shown: original)
        buttons.revert.isHidden = compaction.id == nil
        let thread = context.environment[WorkThread.self]
        // 能不能撤销跟着会话的状态变；只挂一个观察，变了重新挂
        guard !watchingThread else {
            buttons.revert.isEnabled = thread?.canCompact ?? false
            return
        }
        watchingThread = true
        buttons.revert.isEnabled = withObservationTracking { thread?.canCompact ?? false } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchingThread = false
                self?.showButtons()
            }
        }
    }

    private var hasButtons: Bool { !children.isEmpty || compaction?.id != nil }

    private func showSummary() {
        guard let compaction, let context else { return }
        let summary = summary ?? {
            let block = MarkdownTextBlock()
            block.changed = { [weak self] in
                guard let self else { return }
                measured = nil
                heightChanged?(nil)
            }
            block.text.setAccessibilityLabel(TranscriptSpeech.compactionSummary)
            container.insertContent(block.text)
            self.summary = block
            return block
        }()
        summary.show(compaction.summary, environment: context.environment, font: Theme.secondary, color: .secondaryLabelColor)
    }

    private func showStack() {
        guard stack == nil else { return }
        let stack = TranscriptStack()
        stack.changed = { [weak self] motion in
            guard let self, let measured else { return }
            self.measured = nil
            _ = height(width: measured.width)
            heightChanged?(motion)
        }
        container.insertContent(stack.view)
        stack.update(rows, context: nested, resized: true)
        self.stack = stack
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        headerHeight = container.header.height
        var height = headerHeight
        if expanded, let summary {
            summaryHeight = summary.height(width: width)
            buttonsHeight = hasButtons ? container.buttons.height : 0
            height += Self.spacing + summaryHeight + (hasButtons ? Self.spacing + buttonsHeight : 0)
            if original, !children.isEmpty, let stack {
                stackHeight = stack.height(width: max(width - Self.originalInset, 0))
                height += Self.spacing + stackHeight
            }
        }
        measured = (width, height)
        return height
    }

    /// 原文往里缩多少，竖线画在最左边。
    private static let originalInset: CGFloat = 12

    /// 动画中行的高在收起和展开之间：摘要那一段、原文那一段各按露出了多少淡入淡出，标签跟着摘要那一段换字，
    /// 「显示原文」换「收起原文」跟着原文那一段换字。
    override func layoutView(in frame: CGRect) {
        let width = frame.width
        let height = frame.height
        container.header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        container.clip(width: width, height: height, top: headerHeight)
        var y = headerHeight
        let summaryTop = y
        if let summary {
            y += Self.spacing
            summary.text.frame = summary.frame(in: CGRect(x: 0, y: y, width: width, height: summaryHeight))
            y += summaryHeight
            if hasButtons {
                y += Self.spacing
                container.buttons.frame = CGRect(x: 0, y: y, width: width, height: buttonsHeight)
                y += buttonsHeight
            }
        }
        let summaryShown = fraction(height, from: summaryTop, to: y)
        let stackTop = y
        if let stack {
            y += Self.spacing
            // 原文里有一行自己在展开收起：整列的高跟着这一行的高走；不然原文整段按量的高摆，靠这一行截住露出来的那截
            let current = stack.animating ? max(height - y, 0) : stackHeight
            stack.view.frame = CGRect(x: Self.originalInset, y: y, width: max(width - Self.originalInset, 0), height: current)
            stack.layout(height: current)
            container.rule.frame = CGRect(x: 0, y: y, width: 1, height: current)
            y += current
        }
        let stackShown = fraction(height, from: stackTop, to: y)
        container.header.fraction = summary == nil ? 0 : summaryShown
        summary?.text.alphaValue = summaryShown
        container.buttons.alphaValue = summaryShown
        container.buttons.isHidden = summary == nil || !hasButtons
        if originalSwitching {
            let progress = original ? stackShown : 1 - stackShown
            container.buttons.original.fraction = progress
            if progress >= 1 { originalSwitching = false }
        }
        stack?.view.alphaValue = stackShown
        container.rule.opacity = Float(stackShown)
        container.rule.isHidden = stack == nil
        // 收起走完拿掉：摘要连同按钮，或者只有原文
        if !expanded, summaryShown == 0, let summary {
            summary.text.removeFromSuperview()
            self.summary = nil
        }
        if !(expanded && original), stackShown == 0, let stack {
            stack.view.removeFromSuperview()
            self.stack = nil
        }
    }

    /// 行高 height 时，从 top 到 bottom 这一段露出来多少，0～1。
    private func fraction(_ height: CGFloat, from top: CGFloat, to bottom: CGFloat) -> CGFloat {
        guard bottom > top else { return height >= bottom ? 1 : 0 }
        return min(max((height - top) / (bottom - top), 0), 1)
    }

    private func toggle() {
        expanded.toggle()
        container.header.expanded = expanded
        if expanded {
            showSummary()
            if original, !children.isEmpty { showStack() }
        }
        measured = nil
        heightChanged?(Self.motion)
    }

    private func toggleOriginal() {
        original.toggle()
        container.buttons.original.switchTitle(to: TranscriptSpeech.original(shown: original))
        originalSwitching = true
        if original { showStack() }
        measured = nil
        heightChanged?(Self.motion)
    }

    private func revert() {
        guard let id = compaction?.id, let thread = context?.environment[WorkThread.self] else { return }
        thread.revertCompaction(id)
    }
}

/// 压缩分界这一行的视图：标签，下面摘要、按钮、原文和它左边的竖线放在 content 里，按这一行的范围截（展开收起时没露出来的不画到后面的行上）。
/// 标签不截：收起时弹簧往回弹会比标签矮一点，标签照样画全。content 的坐标原点对着这一行的顶边，里面按行的坐标摆。
final class CompactionRowView: NSView {
    let header = CompactionHeaderView()
    let content = FlippedLayerView()
    let buttons = CompactionButtonsView()
    let rule = CALayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content)
        addSubview(header)
        content.layer?.masksToBounds = true
        content.addSubview(buttons)
        content.layer?.addSublayer(rule)
        rule.isHidden = true
        rule.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        buttons.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 摘要、原文垫在按钮下面，按出现的先后。
    func insertContent(_ view: NSView) {
        content.addSubview(view, positioned: .below, relativeTo: buttons)
    }

    /// 标签以下那一截：行这会儿 height 高。
    func clip(width: CGFloat, height: CGFloat, top: CGFloat) {
        content.frame = CGRect(x: 0, y: top, width: width, height: max(height - top, 0))
        content.setBoundsOrigin(NSPoint(x: 0, y: top))
    }
}

/// 分界的标签：一行字居中，两边各一道 1 pt 的细线，字和线之间 10，同 HStack(spacing: 10)。整行可点，指针是手形，按下没有反馈（同 SwiftUI 的 plain 按钮）。
/// 展开后字换成「收起摘要」：fraction 是换到了哪，两种字交叉淡变，线跟着字宽伸缩。
final class CompactionHeaderView: NSView {
    var action: (() -> Void)?
    var expanded = false {
        didSet { if expanded != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) } }
    }
    var fraction: CGFloat = 0 {
        didSet { if fraction != oldValue { needsLayout = true } }
    }
    private let collapsed = LineLabel()
    private let open = LineLabel()
    private let left = CALayer()
    private let right = CALayer()
    private var collapsedText = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for rule in [left, right] {
            rule.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(rule)
        }
        addSubview(collapsed)
        addSubview(open)
        for label in [collapsed, open] { label.setAccessibilityElement(false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(collapsed text: String, expanded: String, font: NSFont, rule: CGColor) {
        collapsedText = text
        let color = NSColor.secondaryLabelColor
        collapsed.set(text, font: font, color: color)
        open.set(expanded, font: font, color: color)
        left.backgroundColor = rule
        right.backgroundColor = rule
        needsLayout = true
    }

    /// 一行字的高。
    var height: CGFloat { collapsed.lineHeight }

    /// 位置按 SwiftUI 的 HStack 算（字的宽不取整，两边的线平分剩下的），每样东西的起点各自取到最近的像素。
    override func layout() {
        super.layout()
        let spacing: CGFloat = 10
        let width = collapsed.exactWidth + (open.exactWidth - collapsed.exactWidth) * fraction
        let rule = max((bounds.width - width - spacing * 2) / 2, 0)
        let lineY = (bounds.height - 1) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        left.frame = CGRect(x: 0, y: lineY, width: pixel(rule), height: 1)
        let rightX = pixel(rule + spacing + width + spacing)
        right.frame = CGRect(x: rightX, y: lineY, width: max(bounds.width - rightX, 0), height: 1)
        CATransaction.commit()
        for label in [collapsed, open] {
            let x = pixel((bounds.width - label.exactWidth) / 2)
            label.frame = CGRect(x: x, y: 0, width: ceil(label.exactWidth), height: bounds.height)
        }
        collapsed.alphaValue = 1 - fraction
        open.alphaValue = fraction
    }

    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    // MARK: - 读屏：展开收起的三角，读的是收起时那句话

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { collapsedText }
    override func accessibilityValue() -> Any? { expanded ? 1 : 0 }
    override func isAccessibilityExpanded() -> Bool { expanded }
    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

/// 摘要下面那排文字按钮：主题色、次要字号，按钮之间 16，同 HStack(spacing: 16)。「显示原文」换字时后面的按钮跟着它的宽挪。
final class CompactionButtonsView: NSView {
    let original = TextButton()
    let revert = TextButton()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(original)
        addSubview(revert)
        revert.title = TranscriptSpeech.revertCompaction
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(font: NSFont, color: NSColor) {
        original.style(font: font, color: color)
        revert.style(font: font, color: color)
    }

    var height: CGFloat { original.lineHeight }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if !original.isHidden {
            original.frame = CGRect(x: x, y: 0, width: original.width, height: bounds.height)
            x += original.width + 16
        }
        revert.frame = CGRect(x: x, y: 0, width: revert.width, height: bounds.height)
    }
}

/// 一列原生的行，竖着排、不滚，同 TranscriptView：行距加上各行自己多空的 gap。压缩前的原文用它，每一行都建视图（原文展开时才有）。
/// 某一行自己展开收起（工具行、折起来的长消息）时报给外面（changed 带着走法），外面的行按这个走法变高，这一行跟着外面的高走。
@MainActor final class TranscriptStack {
    let view = FlippedLayerView()
    private(set) var slots: [TranscriptRowSlot] = []
    private var byID: [RowID: TranscriptRowSlot] = [:]
    private var shapes: [RowID: Int] = [:]
    /// 有一行自己变高变矮了：motion 是它的走法，nil 是直接换。
    var changed: ((RowMotion?) -> Void)?
    private var width: CGFloat = 0
    /// 最近一次摆的时候整列多高。
    private var laidHeight: CGFloat = 0
    /// 正在动的那一行：它的高从哪到哪，整列的高从哪到哪。
    private var animation: (id: RowID, from: CGFloat, to: CGFloat, stackFrom: CGFloat, stackTo: CGFloat)?

    init() {
        view.layer?.masksToBounds = false
    }

    func update(_ rows: [TranscriptRow], context: TranscriptRowContext, resized: Bool) {
        var next: [TranscriptRowSlot] = []
        var nextByID: [RowID: TranscriptRowSlot] = [:]
        for row in rows {
            var hasher = Hasher()
            row.shape(into: &hasher)
            let shape = hasher.finalize()
            let slot: TranscriptRowSlot
            if let existing = byID[row.id], transcriptRowSlotFits(existing, row) {
                slot = existing
                if resized || shapes[row.id] != shape { slot.update(row, context: context, resized: true) }
            } else {
                slot = makeTranscriptRowSlot(row)
                slot.heightChanged = { [weak self, weak slot] motion in
                    guard let self, let slot else { return }
                    childChanged(slot, motion: motion)
                }
                slot.update(row, context: context, resized: true)
            }
            shapes[row.id] = shape
            next.append(slot)
            nextByID[row.id] = slot
        }
        for (id, slot) in byID where nextByID[id] !== slot {
            if slot.hasView { slot.view.removeFromSuperview() }
            shapes[id] = nil
        }
        slots = next
        byID = nextByID
    }

    private func childChanged(_ slot: TranscriptRowSlot, motion: RowMotion?) {
        guard width > 0 else { return changed?(nil) ?? () }
        if let motion {
            let from = slot.frame.height
            let to = slot.height(width: width)
            animation = (slot.id, from, to, laidHeight, laidHeight + to - from)
            changed?(motion)
        } else {
            changed?(nil)
        }
    }

    /// 有一行正在自己展开收起。
    var animating: Bool { animation != nil }

    /// 按宽量整列多高。
    func height(width: CGFloat) -> CGFloat {
        self.width = width
        var height: CGFloat = 0
        for (index, slot) in slots.enumerated() {
            if index > 0 { height += Metrics.rowSpacing + slot.row.gap }
            height += slot.height(width: width)
        }
        return height
    }

    /// 按眼下整列的高摆各行：动画中那一行按整列走到哪给它中间的高，其余按量的高。
    func layout(height: CGFloat) {
        laidHeight = height
        var progress: CGFloat = 1
        if let animation {
            let span = animation.stackTo - animation.stackFrom
            progress = span == 0 ? 1 : (height - animation.stackFrom) / span
            if abs(height - animation.stackTo) < 0.01 { self.animation = nil }
        }
        var y: CGFloat = 0
        for (index, slot) in slots.enumerated() {
            if index > 0 { y += Metrics.rowSpacing + slot.row.gap }
            var rowHeight = slot.height(width: width)
            if let animation, animation.id == slot.id {
                rowHeight = animation.from + (animation.to - animation.from) * progress
            }
            slot.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
            let frame = slot.viewFrame(in: slot.frame)
            let child = slot.view
            if child.superview !== view { view.addSubview(child) }
            if child.frame != frame { child.frame = frame }
            slot.layoutView(in: CGRect(origin: .zero, size: frame.size))
            y += rowHeight
        }
    }
}
#endif
