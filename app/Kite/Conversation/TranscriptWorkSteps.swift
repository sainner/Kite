#if os(macOS)
import AppKit
import SwiftUI

/// 工具行点开后的步骤：一步一行，同批调用之间横向虚线、不同批实线（都占 1 pt），外面 8 pt 圆角描边、按它截。
/// 每一步再点开看参数和结果（CallDetailView），和下面的行一起按 0.25 秒的普通缓出动；步骤按原来的序号认，后续调用到来时不重建已经展开的那步。
/// 某一步自己变高变矮时报给工具行（changed 带着走法），工具行按这个走法变高，这一步跟着工具行的高走。
final class WorkStepsView: NSView {
    /// 有一步自己变高变矮了：motion 是它的走法，nil 是直接换。
    var changed: ((RowMotion?) -> Void)?
    private var rows: [CallRowView] = []
    private var separators: [CAShapeLayer] = []
    private let border = CAShapeLayer()
    private let shape = CAShapeLayer()
    private var work: Work?
    private var environment: EnvironmentValues?
    private var width: CGFloat = 0
    private var laidHeight: CGFloat = 0
    /// 正在动的那一步：它的高从哪到哪，整块的高从哪到哪。
    private var animation: (index: Int, from: CGFloat, to: CGFloat, stepsFrom: CGFloat, stepsTo: CGFloat)?
    /// 最近一次量的各步的高，摆的时候照它摆。
    private var rowHeights: [CGFloat] = []
    /// 最近一次量出来的高里有近似的（拖缝时看不见的详情按上次的高占位），停下后要按准确的重量。
    private(set) var approximate = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.mask = shape
        border.fillColor = nil
        border.lineWidth = 1
        border.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(border)
        border.zPosition = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var animating: Bool { animation != nil }

    /// 内容或外观变了才调（同 TranscriptRowSlot.update），子 agent 的行跟着重排。
    func show(_ work: Work, environment: EnvironmentValues) {
        self.work = work
        self.environment = environment
        while rows.count < work.calls.count {
            let row = CallRowView()
            let index = rows.count
            row.changed = { [weak self, weak row] motion in
                guard let self, let row else { return }
                rowChanged(index, row: row, motion: motion)
            }
            addSubview(row)
            rows.append(row)
        }
        while rows.count > work.calls.count { rows.removeLast().removeFromSuperview() }
        for (row, call) in zip(rows, work.calls) { row.show(call, environment: environment) }
        while separators.count < max(rows.count - 1, 0) {
            let line = CAShapeLayer()
            line.lineWidth = 1
            line.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(line)
            separators.append(line)
        }
        while separators.count > max(rows.count - 1, 0) { separators.removeLast().removeFromSuperlayer() }
        restyle()
        needsLayout = true
    }

    private func restyle() {
        guard let environment else { return }
        let rule = Theme.toolRule.resolve(in: environment).cgColor
        border.strokeColor = rule
        for (index, line) in separators.enumerated() {
            line.strokeColor = rule
            // 同批用虚线，不同批实线
            let batch = work.flatMap { index + 1 < $0.calls.count ? $0.calls[index].use.batch : nil }
            let same = batch != nil && batch == work?.calls[index + 1].use.batch
            line.lineDashPattern = same ? [4, 3] : nil
        }
    }

    private func rowChanged(_ index: Int, row: CallRowView, motion: RowMotion?) {
        guard width > 0 else { return changed?(nil) ?? () }
        if let motion {
            let from = row.frame.height
            let to = row.height(width: width)
            if index < rowHeights.count { rowHeights[index] = to }
            animation = (index, from, to, laidHeight, laidHeight + to - from)
            changed?(motion)
        } else {
            changed?(nil)
        }
    }

    func height(width: CGFloat) -> CGFloat {
        self.width = width
        rowHeights = rows.map { $0.height(width: width) }
        approximate = rows.contains { $0.approximate }
        return rowHeights.reduce(0, +) + CGFloat(max(rows.count - 1, 0))
    }

    /// 按眼下整块的高摆各步：动画中那一步按整块走到哪给它中间的高。
    func layout(height: CGFloat) {
        laidHeight = height
        var progress: CGFloat = 1
        if let animation {
            let span = animation.stepsTo - animation.stepsFrom
            progress = span == 0 ? 1 : (height - animation.stepsFrom) / span
            if abs(height - animation.stepsTo) < 0.01 { self.animation = nil }
        }
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = separators[index - 1]
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                line.frame = CGRect(x: 0, y: y, width: width, height: 1)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: width, y: 0.5))
                line.path = path
                CATransaction.commit()
                y += 1
            }
            var rowHeight = index < rowHeights.count ? rowHeights[index] : row.height(width: width)
            if let animation, animation.index == index {
                rowHeight = animation.from + (animation.to - animation.from) * progress
            }
            row.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
            row.layoutRow()
            y += rowHeight
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        shape.frame = bounds
        shape.path = RoundedRectangle(cornerRadius: Metrics.toolGroupRadius).path(in: bounds).cgPath
        border.frame = bounds
        border.path = RoundedRectangle(cornerRadius: Metrics.toolGroupRadius).inset(by: 0.5).path(in: bounds).cgPath
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// 一次工具调用：标题行（图标、名字、摘要或文件引用、补丁行数、运行时间），点开下面是参数和结果；按自己的范围截。
final class CallRowView: NSView {
    var changed: ((RowMotion?) -> Void)?
    let header = CallHeaderView()
    private var detail: CallDetailView?
    private var call: Call?
    private var environment: EnvironmentValues?
    private var expanded = false
    private var detailHeight: CGFloat = 0

    /// 详情左右、底下的留白。
    private static let inset = Metrics.toolRowInset

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(header)
        header.action = { [weak self] in self?.toggle() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ call: Call, environment: EnvironmentValues) {
        self.call = call
        self.environment = environment
        header.show(call, environment: environment, expanded: expanded)
        detail?.show(call, environment: environment)
    }

    /// 量出来的详情是不是近似的，见 WorkStepsView.approximate。
    private(set) var approximate = false

    /// 拖缝时看不见的详情按上次的高占位（近似），看得见的照常量（里面子 agent 的行再只量看得见的，见 TranscriptStack.height）。
    func height(width: CGFloat) -> CGFloat {
        var height = Metrics.toolRowHeight
        approximate = false
        if expanded, let detail {
            if WindowLayout.anyResizing, detailHeight > 0, visibleRect.isEmpty {
                approximate = true
            } else {
                detailHeight = detail.height(width: max(width - Self.inset * 2, 0))
                approximate = detail.approximate
            }
            height += detailHeight + Self.inset
        }
        return height
    }

    /// 动画中行的高在收起和展开之间：详情按露出多少淡入淡出，收起走完拿掉。
    func layoutRow() {
        let headerHeight = Metrics.toolRowHeight
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        guard let detail else { return }
        detail.frame = CGRect(x: Self.inset, y: headerHeight, width: max(bounds.width - Self.inset * 2, 0), height: detailHeight)
        detail.layoutDetail()
        let full = detailHeight + Self.inset
        let shown = full > 0 ? min(max((bounds.height - headerHeight) / full, 0), 1) : 0
        detail.alphaValue = shown
        if !expanded, shown == 0 {
            detail.removeFromSuperview()
            self.detail = nil
        }
    }

    private func toggle() {
        expanded.toggle()
        if expanded, detail == nil, let call, let environment {
            let view = CallDetailView()
            view.changed = { [weak self] motion in self?.changed?(motion) }
            view.alphaValue = 0
            addSubview(view)
            view.show(call, environment: environment)
            detail = view
        }
        if let call, let environment { header.show(call, environment: environment, expanded: expanded) }
        changed?(WorkLayout.motion)
    }
}

/// 一步的标题行：整行是按钮（指针手形、没有按下的样子），图标、名字、摘要一块带动效（等待呼吸、执行时像素扫掠，见 ToolActivityView），
/// 摘要放不下截掉（命令截尾，其余截中间）；有结果里的文件时换成可点的文件引用；右边补丁行数、命令运行时间。出错时图标、名字、摘要是红的。
final class CallHeaderView: NativeButton {
    private let activity = ToolActivityView()
    private let icon = NSImageView()
    private let name = LineLabel()
    private let summary = LineLabel()
    private let references = ReferenceLineView()
    private let diff = ToolChipView()
    private let duration = ToolChipView()
    private var timer: Timer?
    private var call: Call?
    private var environment: EnvironmentValues?
    private var showsReferences = false
    private var speech = (label: "", value: "", hint: "")

    init() {
        super.init(frame: .zero)
        addSubview(activity)
        for view in [icon, name, summary, references] as [NSView] { activity.content.addSubview(view) }
        addSubview(diff)
        addSubview(duration)
        icon.hideFromAccessibility()
        for label in [name, summary] { label.setAccessibilityElement(false) }
        diff.toolTip = "参数中的新增与删除行数，不代表已写入的改动"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ call: Call, environment: EnvironmentValues, expanded: Bool) {
        self.call = call
        let context = environment.fontResolutionContext
        let font = Theme.secondary.resolve(in: context).ctFont as NSFont
        let failed = call.state == .failed || call.state == .unknown
        let danger = NSColor(cgColor: Theme.danger.resolve(in: environment).cgColor) ?? .systemRed
        let tint = failed ? danger : NSColor.secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        icon.image = NSImage(systemSymbolName: call.use.kind.icon, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        icon.contentTintColor = tint
        let bold = Theme.secondary.weight(.semibold).resolve(in: context).ctFont as NSFont
        name.set(call.use.displayName, font: bold, color: failed ? danger : .labelColor)
        let root = environment.workingDirectory
        let text = call.use.rowSummary(relativeTo: root, generating: call.state == .generating)
        showsReferences = call.state != .generating && !call.fileReferences.isEmpty
        if showsReferences {
            references.show(call.fileReferences, scope: environment.referenceScope, font: font, color: tint, openURL: environment.openURL)
        } else {
            summary.set(text, font: font, color: tint, truncation: call.use.kind == .command ? .byTruncatingTail : .byTruncatingMiddle)
        }
        summary.isHidden = showsReferences
        references.isHidden = !showsReferences
        if let value = call.use.diffSummary {
            diff.show(value, label: TranscriptSpeech.patchLines(value), environment: environment)
            diff.isHidden = false
        } else {
            diff.isHidden = true
        }
        showDuration(environment: environment)
        activity.presence = environment.panePresence
        activity.mode = call.state == .queued ? .breathing : call.state == .running ? .sweeping : .none
        activity.contentChanged()
        let spoken = TranscriptSpeech.call(call, summary: text)
        speech = (spoken.label, spoken.value, TranscriptSpeech.callHint(expanded: expanded))
        needsLayout = true
    }

    /// 命令的运行时间：跑完了是总时长，还在跑时每秒走一次。
    private func showDuration(environment: EnvironmentValues) {
        timer?.invalidate()
        timer = nil
        self.environment = environment
        guard let call, call.use.kind == .command, let start = call.use.startedAt else {
            duration.isHidden = true
            return
        }
        if let finish = call.use.finishedAt {
            showDuration(finish - start)
            duration.isHidden = false
        } else if call.state == .running {
            showDuration(Date().timeIntervalSince1970 * 1000 - start)
            duration.isHidden = false
            // 放进 common 模式：滚动、拖动时也走
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.showDuration(Date().timeIntervalSince1970 * 1000 - start) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            duration.isHidden = true
        }
    }

    private func showDuration(_ milliseconds: Double) {
        guard let environment else { return }
        let value = max(0, milliseconds)
        let text = value < 1000
            ? value.formatted(.number.precision(.fractionLength(0))) + " ms"
            : (value / 1000).formatted(.number.precision(.fractionLength(0...1))) + " s"
        duration.show(text, label: TranscriptSpeech.duration(text), environment: environment)
        needsLayout = true
    }

    /// 离开窗口时停表；回到窗口（行滚远被拿掉、又滚回来）重新起表，接着走。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil, let environment {
            showDuration(environment: environment)
        }
    }

    /// HStack(spacing: 6)：图标格 16 宽、名字不截，摘要占剩下的；右边的 chip 之间 4，离右边 10。
    override func layout() {
        super.layout()
        let gap = Metrics.toolLabelGap
        let inset = Metrics.toolRowInset
        let chips = [diff, duration].filter { !$0.isHidden }
        let chipsWidth = chips.reduce(0) { $0 + $1.size.width } + CGFloat(max(chips.count - 1, 0)) * 4
        var x = bounds.width - inset
        for chip in chips.reversed() {
            let size = chip.size
            x -= size.width
            chip.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x -= 4
        }
        // 摘要能占到的宽：左右留白、名字、两处间距，再空出 chip 和它前面的两处间距（Spacer 两边）
        let nameWidth = name.exactWidth
        let start = Metrics.toolIcon + gap + nameWidth + gap
        let available = max(bounds.width - inset * 2 - chipsWidth - gap * 2 - start, 0)
        let summaryWidth = min(showsReferences ? references.textWidth : summary.textWidth, available)
        let lineHeight = name.lineHeight
        let top = ((bounds.height - lineHeight) / 2).rounded()
        activity.frame = CGRect(x: inset, y: top, width: start + summaryWidth, height: lineHeight)
        // 图标格 16 宽，按图标的对齐宽度居中、取到像素（同 SwiftUI 的符号图片）
        let imageSize = icon.image?.size ?? .zero
        let iconWidth = icon.image?.alignmentRect.width ?? imageSize.width
        icon.frame = CGRect(x: ((Metrics.toolIcon - iconWidth) / 2 * 2).rounded() / 2, y: (lineHeight - imageSize.height) / 2,
                            width: imageSize.width, height: imageSize.height)
        name.frame = CGRect(x: Metrics.toolIcon + gap, y: 0, width: nameWidth, height: lineHeight)
        summary.frame = CGRect(x: start, y: 0, width: summaryWidth, height: lineHeight)
        references.frame = summary.frame
    }

    override func drawFocusRingMask() { bounds.fill() }

    override func accessibilityLabel() -> String? { speech.label }
    override func accessibilityValue() -> Any? { speech.value }
    override func accessibilityHelp() -> String? { speech.hint }
    override func accessibilityChildren() -> [Any]? {
        references.accessibilityLinks + NSAccessibility.unignoredChildren(from: [diff, duration].filter { !$0.isHidden })
    }
}

/// 工具行右边的小 chip：最小一号的数字等宽字，次要色，左右 6、上下 2，代码底色的胶囊。
final class ToolChipView: NSView {
    private let label = LineLabel()
    private let background = CALayer()
    private var environment: EnvironmentValues?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(background)
        background.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        addSubview(label)
        label.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, label speech: String, environment: EnvironmentValues) {
        self.environment = environment
        let font = (Theme.status.resolve(in: environment.fontResolutionContext).ctFont as NSFont).monospacedDigits
        label.set(text, font: font, color: .secondaryLabelColor)
        background.backgroundColor = Theme.codeBackground.resolve(in: environment).cgColor
        setAccessibilityLabel(speech)
        needsLayout = true
    }

    var size: CGSize { CGSize(width: label.exactWidth + 12, height: label.lineHeight + 4) }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 6, y: 2, width: ceil(label.exactWidth), height: label.lineHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        background.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }
}

/// 结果里的文件引用排成一行：文件名带下划线、和整行一样的颜色，之间「 · 」，放不下从中间截；
/// 指针停在文件名上是手形，点了交给 openURL（ReferenceNavigation 打开），点在别处落给标题行。
final class ReferenceLineView: NSView {
    private var text = NSAttributedString()
    private var line: CTLine?
    private var links: [(rect: CGRect, url: URL, label: String)] = []
    /// 读屏：每个文件名一个链接元素。
    private var elements: [ReferenceLinkElement] = []
    private var openURL: OpenURLAction?
    private var pressed: URL?
    private var font = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    func show(_ references: [FileReference], scope: ReferenceScope, font: NSFont, color: NSColor, openURL: OpenURLAction) {
        self.openURL = openURL
        self.font = font
        let result = NSMutableAttributedString()
        for (index, reference) in references.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: color])) }
            result.append(NSAttributedString(string: reference.label, attributes: [
                .font: font, .foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: reference.url(in: scope),
            ]))
        }
        text = result
        line = nil
        needsLayout = true
        needsDisplay = true
    }

    var textWidth: CGFloat { (text.size().width * 2).rounded(.up) / 2 }

    override func layout() {
        super.layout()
        // 放不下从中间截，截掉的地方一个省略号
        let full = CTLineCreateWithAttributedString(text)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]))
        line = CTLineCreateTruncatedLine(full, Double(bounds.width), .middle, token) ?? full
        links = []
        guard let line else { return }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let string = text.string as NSString
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let url = attributes[NSAttributedString.Key.link.rawValue] as? URL else { continue }
            var position = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
            let width = CTRunGetTypographicBounds(run, CFRange(), nil, nil, nil)
            let range = CTRunGetStringRange(run)
            let label = range.location + range.length <= string.length ? string.substring(with: NSRange(location: range.location, length: range.length)) : ""
            links.append((CGRect(x: position.x, y: 0, width: CGFloat(width), height: bounds.height), url, label))
        }
        elements = links.map { ReferenceLinkElement(view: self, rect: $0.rect, url: $0.url, label: $0.label) }
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        // 基线同 SwiftUI 的 Text（也同 LineLabel）：离顶边上伸加半个行距，取到像素
        let baseline = bounds.height - ((font.ascender + font.leading / 2) * 2).rounded(.down) / 2
        context.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func link(at event: NSEvent) -> URL? {
        let point = convert(event.locationInWindow, from: nil)
        return links.first { $0.rect.contains(point) }?.url
    }

    override func resetCursorRects() {
        for link in links { addCursorRect(link.rect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = link(at: event)
        if pressed == nil { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressed == nil { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed else { return super.mouseUp(with: event) }
        self.pressed = nil
        if link(at: event) == pressed { openURL?(pressed) }
    }

    override func isAccessibilityElement() -> Bool { false }

    /// 读屏：截短后露出来的每个文件名一个链接，按下打开。
    var accessibilityLinks: [Any] { isHidden ? [] : elements }

    /// 读屏按下了一个文件名。
    fileprivate func open(_ url: URL) { openURL?(url) }
}

/// 工具步骤里的一个文件引用给读屏的元素：链接，读文件名，按下打开。
/// NSAccessibilityElement 不归主线程，读屏的回调实际在主线程进来，取视图时按主线程处理。
nonisolated final class ReferenceLinkElement: NSAccessibilityElement {
    nonisolated(unsafe) private weak var view: ReferenceLineView?
    private let rect: CGRect
    private let url: URL
    private let label: String

    @MainActor init(view: ReferenceLineView, rect: CGRect, url: URL, label: String) {
        self.view = view
        self.rect = rect
        self.url = url
        self.label = label
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .link }
    override func accessibilityLabel() -> String? { label }

    override func accessibilityParent() -> Any? {
        let view = view
        // 读屏的上级是这一步的标题行（它把链接交给读屏）
        return MainActor.assumeIsolated { () -> NSView? in
            var ancestor = view?.superview
            while let current = ancestor, !(current is CallHeaderView) { ancestor = current.superview }
            return ancestor
        }
    }

    override func accessibilityFrame() -> NSRect {
        let view = view, rect = rect
        return MainActor.assumeIsolated {
            guard let view, let window = view.window else { return .zero }
            return window.convertToScreen(view.convert(rect, to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let view = view, url = url
        MainActor.assumeIsolated { view?.open(url) }
        return true
    }
}

/// 一次调用的详情：参数、结果各一张卡片（键在左、最宽 96，值在右能折行，等宽字、能选），之间 6；
/// 子 agent 做的事接在下面，往里缩 12（一列原生的行，见 TranscriptStack）。
final class CallDetailView: NSView {
    /// 子 agent 的行自己变高了：motion 是它的走法。
    var changed: ((RowMotion?) -> Void)?
    private let input = ToolDetailCardView()
    private let result = ToolDetailCardView()
    private var children: TranscriptStack?
    private var heights: (input: CGFloat, result: CGFloat, children: CGFloat) = (0, 0, 0)
    private var width: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(input)
        addSubview(result)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ call: Call, environment: EnvironmentValues) {
        var fields = Self.fields(Self.input(call))
        if call.state == .generating { fields.append(("arguments（原文）", .string(call.use.arguments ?? ""))) }
        input.show(fields, environment: environment)
        result.show(Self.fields(Self.result(call)), environment: environment)
        if call.children.isEmpty {
            children?.view.removeFromSuperview()
            children = nil
        } else {
            let stack = children ?? {
                let stack = TranscriptStack()
                stack.changed = { [weak self] motion in self?.changed?(motion) }
                addSubview(stack.view)
                children = stack
                return stack
            }()
            stack.update(TranscriptRow.rows(items: call.children, pending: []),
                         context: TranscriptRowContext(environment: environment, actionable: false, toggleActions: { _ in }))
        }
        needsLayout = true
    }

    /// 子 agent 的行里有按近似量的，见 TranscriptStack.approximate。
    var approximate: Bool { children?.approximate ?? false }

    func height(width: CGFloat) -> CGFloat {
        self.width = width
        heights.input = input.height(width: width)
        heights.result = result.height(width: width)
        heights.children = children.map { $0.height(width: max(width - 12, 0)) } ?? 0
        return heights.input + 6 + heights.result + (children == nil ? 0 : 6 + heights.children)
    }

    func layoutDetail() {
        input.frame = CGRect(x: 0, y: 0, width: width, height: heights.input)
        input.layoutCard()
        result.frame = CGRect(x: 0, y: heights.input + 6, width: width, height: heights.result)
        result.layoutCard()
        if let children {
            children.view.frame = CGRect(x: 12, y: result.frame.maxY + 6, width: max(width - 12, 0), height: heights.children)
            children.layout(height: heights.children)
        }
    }

    /// 只列顶层键（参数里的 description 不列）；嵌套的对象和数组整个序列化，不再递归排。不是对象或是空对象时一行，键是空的。
    private static func fields(_ value: JSON) -> [(key: String, value: JSON)] {
        if case .object(let object) = value, !object.isEmpty {
            return object.keys.sorted().compactMap { key in object[key].map { (key, $0) } }
        }
        return [("", value)]
    }

    private static func input(_ call: Call) -> JSON {
        guard case .object(let fields) = call.use.input else { return call.use.input }
        return .object(fields.filter { $0.key != "description" })
    }

    private static func result(_ call: Call) -> JSON {
        var fields: [String: JSON] = [:]
        if let result = call.result {
            fields["output"] = .string(result.text)
            if let diff = result.diff {
                fields["diff"] = .object(["id": .string(diff.id), "paths": .array(diff.paths.map(JSON.string))])
            }
            // 旧记录中的非文本内容仍保留在结果卡片中。
            if result.content.contains(where: { if case .image = $0 { true } else { false } }) {
                fields["content"] = .array(result.content.map { part in
                    switch part {
                    case .text(let text): .object(["type": "text", "text": .string(text)])
                    case .image(let width, let height): .object(["type": "image", "width": .number(Double(width)), "height": .number(Double(height))])
                    }
                })
            }
        } else if !call.use.output.isEmpty {
            fields["output"] = .string(call.use.output)
            fields["outputTruncated"] = .bool(call.use.outputTruncated)
        }
        return .object(fields)
    }
}

/// 参数或结果的卡片：代码底色、8 pt 圆角，内边距 10；只列顶层键，嵌套对象和数组整个序列化成一行；一行一个键，键在左（次要色，占 96 宽，放不下折行），
/// 值在右（JSON 序列化，文件路径、网址可点，能折行），列间 12、行间 8，都是等宽字、能选，复制给原样的字。
final class ToolDetailCardView: NSView {
    private var rows: [(key: ProseTextView, value: ProseTextView, coordinator: ProseRowCoordinator)] = []
    private var heights: [CGFloat] = []
    private var keyWidth: CGFloat = 0
    private let background = CAShapeLayer()

    private static let padding: CGFloat = 10
    private static let columnSpacing: CGFloat = 12
    private static let rowSpacing: CGFloat = 8
    private static let keyMaxWidth: CGFloat = 96

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(background)
        background.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "fillColor": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ fields: [(key: String, value: JSON)], environment: EnvironmentValues) {
        let font = Theme.code.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        while rows.count < fields.count {
            let key = ProseTextView.makeReadOnly(), value = ProseTextView.makeReadOnly()
            let coordinator = ProseRowCoordinator()
            // 键由值带着读（值的说明就是键），读屏不单独读键
            key.setAccessibilityElement(false)
            value.delegate = coordinator
            coordinator.view = value
            addSubview(key)
            addSubview(value)
            rows.append((key, value, coordinator))
        }
        while rows.count > fields.count {
            let row = rows.removeLast()
            row.key.removeFromSuperview()
            row.value.removeFromSuperview()
        }
        // 键那一列是 frame(maxWidth: 96) 的格子，Grid 按最宽给它，总是 96（逐像素对过）
        keyWidth = Self.keyMaxWidth
        for (row, field) in zip(rows, fields) {
            row.key.showPlain(field.key, font: font, color: .secondaryLabelColor)
            row.coordinator.openURL = environment.openURL
            let serialized = Self.serialized(field.value)
            row.value.showLinked(serialized, scope: environment.referenceScope, font: font)
            row.value.setAccessibilityLabel(field.key)
        }
        background.fillColor = Theme.codeBackground.resolve(in: environment).cgColor
        needsLayout = true
    }

    private static func serialized(_ value: JSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "无法序列化" }
        return String(decoding: data, as: UTF8.self)
    }

    func height(width: CGFloat) -> CGFloat {
        let valueWidth = max(width - Self.padding * 2 - keyWidth - Self.columnSpacing, 0)
        heights = rows.map { row in
            max(row.key.measurePixel(lineWidth: keyWidth), row.value.measurePixel(lineWidth: valueWidth))
        }
        return Self.padding * 2 + heights.reduce(0, +) + Self.rowSpacing * CGFloat(max(rows.count - 1, 0))
    }

    func layoutCard() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        background.path = RoundedRectangle(cornerRadius: Metrics.toolGroupRadius).path(in: bounds).cgPath
        CATransaction.commit()
        let valueX = Self.padding + keyWidth + Self.columnSpacing
        let valueWidth = max(bounds.width - Self.padding - valueX, 0)
        var y = Self.padding
        for (index, row) in rows.enumerated() {
            let height = index < heights.count ? heights[index] : 0
            row.key.frame = CGRect(x: Self.padding, y: y, width: keyWidth, height: height)
            row.value.frame = CGRect(x: valueX, y: y, width: valueWidth, height: height)
            y += height + Self.rowSpacing
        }
    }
}

#endif
