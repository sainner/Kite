#if os(macOS)
import AppKit
import SwiftUI

/// 两段话之间 agent 做的事折成的一行，照 WorkRow：汇总一行（汇总、出错和没跑完的步数、箭头，一行，放不下截汇总；有调用在跑时说正在做什么，
/// 带像素扫掠，见 ToolActivityView）。点开后下面是步骤（WorkStepsView），展开收起和下面的行一起按 0.25 秒的普通缓出动，
/// 箭头跟着转、步骤跟着淡入淡出；收起走完拿掉步骤，同 SwiftUI 版不留展开状态。某一步自己展开收起时只有步骤跟着变高，箭头和透明度不动。
final class WorkRowSlot: TranscriptRowSlot {
    private let container = WorkRowView()
    private var work: Work?
    private var expanded = false
    private var context: TranscriptRowContext?
    private var headerHeight: CGFloat = 0
    private var stepsHeight: CGFloat = 0
    private var steps: WorkStepsView?
    /// 自己正在展开收起（不是里面某一步）：箭头、步骤的透明度跟着行高走。
    private var toggling = false

    /// 汇总行和步骤之间的间距，同 WorkRow 的 VStack。
    private static let spacing: CGFloat = 6
    static let motion = RowMotion.curve(.easeOut, duration: 0.25)

    override init(row: TranscriptRow) {
        super.init(row: row)
        container.header.action = { [weak self] in self?.toggle() }
    }

    override var hasView: Bool { true }
    override var view: NSView { container }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .work(let work) = item.kind else { return }
        self.work = work
        self.context = context
        container.header.show(work, environment: context.environment, expanded: expanded)
        steps?.show(work, environment: context.environment)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        headerHeight = container.header.height
        if expanded, let steps { stepsHeight = steps.height(width: width) }
        let height = headerHeight + (expanded ? Self.spacing + stepsHeight : 0)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：自己展开收起时按它算走到哪了，箭头转多少、步骤多透明都跟着它；
    /// 里面某一步在动时，步骤整块的高跟着行高走。
    override func layoutView(in frame: CGRect) {
        let full = Self.spacing + stepsHeight
        var progress: CGFloat = expanded ? 1 : 0
        if toggling {
            progress = full > 0 ? min(max((frame.height - headerHeight) / full, 0), 1) : progress
            if let measured, abs(frame.height - measured.height) < 0.01 { toggling = false }
        }
        container.header.frame = CGRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        container.header.turn = progress
        if let steps {
            let current = steps.animating ? max(frame.height - headerHeight - Self.spacing, 0) : stepsHeight
            steps.frame = CGRect(x: 0, y: headerHeight + Self.spacing, width: frame.width, height: current)
            steps.layout(height: current)
            steps.alphaValue = progress
            // 收起走完拿掉步骤
            if !expanded, progress == 0 {
                steps.removeFromSuperview()
                self.steps = nil
            }
        }
    }

    private func toggle() {
        expanded.toggle()
        if expanded, steps == nil, let work, let context {
            let view = WorkStepsView()
            view.changed = { [weak self] motion in self?.stepsChanged(motion) }
            view.alphaValue = 0
            container.addSubview(view)
            view.show(work, environment: context.environment)
            steps = view
        }
        container.header.expanded = expanded
        if let work, let context { container.header.show(work, environment: context.environment, expanded: expanded) }
        toggling = true
        measured = nil
        heightChanged?(Self.motion)
    }

    /// 某一步自己变高变矮（点开参数和结果）：按它的走法，步骤整块跟着行高走。
    private func stepsChanged(_ motion: RowMotion?) {
        guard expanded, let measured, let steps else { return }
        stepsHeight = steps.height(width: measured.width)
        self.measured = (measured.width, headerHeight + Self.spacing + stepsHeight)
        heightChanged?(motion)
    }
}

/// 工具组汇总行的原生版：一行次要色小字，汇总、出错步数（红）、没跑完步数，箭头；整行可点，指针是手形。
final class WorkHeaderView: NativeButton {
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat = 0 {
        didSet { if turn != oldValue { chevron.frameCenterRotation = -90 * turn } }
    }
    /// 汇总（有调用在跑时是正在做什么），扫掠只画在它上面，同 WorkSummaryLine。
    private let activity = ToolActivityView()
    private let summary = LineLabel()
    private let failed = LineLabel()
    private let unfinished = LineLabel()
    private let chevron = NSImageView()
    private var font = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    /// 读屏读的：汇总连同出错、没跑完的步数，有调用在跑时是正在做什么。
    private var speech = ""
    /// 展开了步骤，读屏读成展开收起的三角。
    var expanded = false {
        didSet { if expanded != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) } }
    }

    init() {
        super.init(frame: .zero)
        addSubview(activity)
        activity.content.addSubview(summary)
        for label in [failed, unfinished] { addSubview(label) }
        for label in [summary, failed, unfinished] { label.setAccessibilityElement(false) }
        addSubview(chevron)
        chevron.hideFromAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 汇总行：有调用在跑时说正在做什么，没展开、有调用在执行时带像素扫掠。
    func show(_ work: Work, environment: EnvironmentValues, expanded: Bool) {
        speech = TranscriptSpeech.work(work)
        font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let secondary = NSColor.secondaryLabelColor
        let failedCount = work.count(.failed) + work.count(.unknown), unfinishedCount = work.count(.unfinished)
        set(summary, work.running?.use.title ?? work.summary, color: secondary)
        activity.mode = work.running != nil && !expanded && work.count(.running) > 0 ? .sweeping : .none
        activity.contentChanged()
        set(failed, failedCount > 0 ? "\(failedCount) 步出错" : "", color: NSColor(cgColor: Theme.danger.resolve(in: environment).cgColor) ?? .systemRed)
        set(unfinished, unfinishedCount > 0 ? "\(unfinishedCount) 步没跑完" : "", color: secondary)
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular, scale: .small)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        chevron.contentTintColor = secondary
        chevron.isHidden = false
        needsLayout = true
    }

    private func set(_ label: LineLabel, _ text: String, color: NSColor) {
        label.set(text, font: font, color: color)
        label.isHidden = text.isEmpty
    }

    /// 一行字的高，同 SwiftUI 的 Text。
    var height: CGFloat { summary.lineHeight }

    override func layout() {
        super.layout()
        // HStack(spacing: 8)：汇总放不下时截它，后面几样按自己的宽
        let spacing: CGFloat = 8
        let tail = [failed, unfinished].filter { !$0.isHidden }
        let imageSize = chevron.image?.size ?? .zero
        let tailWidth = tail.reduce(0) { $0 + $1.textWidth + spacing } + imageSize.width
        let summaryWidth = min(summary.textWidth, max(bounds.width - tailWidth - spacing, 0))
        var x: CGFloat = 0
        activity.frame = CGRect(x: x, y: 0, width: summaryWidth, height: bounds.height)
        summary.frame = CGRect(x: 0, y: 0, width: summaryWidth, height: bounds.height)
        x += summaryWidth + spacing
        for label in tail {
            let width = label.textWidth
            label.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + spacing
        }
        let rotation = chevron.frameCenterRotation
        chevron.frameCenterRotation = 0
        chevron.frame = CGRect(x: x, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
        chevron.frameCenterRotation = rotation
    }

    override func drawFocusRingMask() { bounds.fill() }

    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { speech }
    override func accessibilityValue() -> Any? { expanded ? 1 : 0 }
    override func isAccessibilityExpanded() -> Bool { expanded }
}

/// 工具行的视图：汇总行、展开后的步骤，按自己的范围截（收起时退场的步骤不画到后面的行上，同 WorkRow 的 clipped）。
final class WorkRowView: NSView {
    let header = WorkHeaderView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 生成中的思考，同 ThinkingRow：一行次要色小字，换行当空格，放不下截掉。
final class ThinkingRowSlot: TranscriptRowSlot {
    private let label = LineLabel()

    override var hasView: Bool { true }
    override var view: NSView { label }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .thinking(let text) = item.kind else { return }
        label.set(text.isEmpty ? "思考中" : text.replacingOccurrences(of: "\n", with: " "),
                  font: Theme.secondary.resolve(in: context.environment.fontResolutionContext).ctFont as NSFont, color: .secondaryLabelColor)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = label.lineHeight
        measured = (width, height)
        return height
    }
}
#endif
