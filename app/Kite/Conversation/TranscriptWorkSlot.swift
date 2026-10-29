#if os(macOS)
import AppKit
import SwiftUI

/// 两段话之间 agent 做的事折成的一行：汇总一行（汇总、出错和没跑完的步数、箭头，一行，放不下截汇总；接着生成思考时先说思考，
/// 有调用在跑时说正在做什么；回合在跑、这是最后一组时不说汇总，一直带像素扫掠，见 ToolActivityView）。点开后下面是步骤（WorkStepsView），展开收起和下面的行一起按 0.25 秒的普通缓出动，
/// 箭头跟着转、步骤跟着淡入淡出；收起走完拿掉步骤，不留各步的展开状态。某一步自己展开收起时只有步骤跟着变高，箭头和透明度不动。
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

    override init(row: TranscriptRow) {
        super.init(row: row)
        container.header.action = { [weak self] in self?.toggle() }
    }

    override var hasView: Bool { true }
    override var view: NSView { container }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .work(let work) = item.kind else { return }
        self.work = work
        self.context = context
        container.header.show(work, environment: context.environment)
        steps?.show(work, environment: context.environment)
    }

    /// 拖缝时步骤里看不见的详情、子 agent 的行按上次的高占位，记作 provisional，停下后列表补量成准确的高。
    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional || WindowLayout.anyResizing { return measured.height }
        headerHeight = container.header.height
        provisional = false
        if expanded, let steps {
            stepsHeight = steps.height(width: width)
            provisional = steps.approximate
        }
        let height = WorkLayout.height(header: headerHeight, steps: stepsHeight, expanded: expanded)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：自己展开收起时按它算走到哪了，箭头转多少、步骤多透明都跟着它；
    /// 里面某一步在动时，步骤整块的高跟着行高走。
    override func layoutView(in frame: CGRect) {
        var progress: CGFloat = expanded ? 1 : 0
        if toggling {
            progress = WorkLayout.progress(rowHeight: frame.height, header: headerHeight, steps: stepsHeight, expanded: expanded)
            if let measured, abs(frame.height - measured.height) < 0.01 { toggling = false }
        }
        container.header.frame = CGRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        container.header.turn = progress
        if let steps {
            let current = steps.animating ? max(frame.height - headerHeight - WorkLayout.spacing, 0) : stepsHeight
            steps.frame = CGRect(x: 0, y: headerHeight + WorkLayout.spacing, width: frame.width, height: current)
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
        toggling = true
        measured = nil
        heightChanged?(WorkLayout.motion)
    }

    /// 某一步自己变高变矮（点开参数和结果）：按它的走法，步骤整块跟着行高走。
    private func stepsChanged(_ motion: RowMotion?) {
        guard expanded, let measured, let steps else { return }
        stepsHeight = steps.height(width: measured.width)
        self.measured = (measured.width, WorkLayout.height(header: headerHeight, steps: stepsHeight, expanded: true))
        heightChanged?(motion)
    }
}

/// 会转的展开箭头：工具组的汇总行、Kite 通知上面那一行用。
final class TurningChevron: NSImageView {
    /// 转了多少：0 朝右，1 朝下。
    var turn: CGFloat = 0 {
        // 翻转坐标里正的角度看上去是顺时针（2026-10-20 实测，-90 朝上）
        didSet { if turn != oldValue { frameCenterRotation = 90 * turn } }
    }

    /// 按没转时的样子摆：转着时直接改 frame 会按转过以后的外框算，先转回去，摆好再转回来。
    func place(_ frame: CGRect) {
        let rotation = frameCenterRotation
        frameCenterRotation = 0
        self.frame = frame
        frameCenterRotation = rotation
    }
}

/// 工具组的汇总行：一行次要色小字，汇总、没跑完步数，箭头；整行可点，指针是手形。
final class WorkHeaderView: NativeButton {
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat {
        get { chevron.turn }
        set { chevron.turn = newValue }
    }
    /// 汇总、没跑完的步数和箭头都在它里面：平时扫掠只画在汇总上，换了说的事那一遍扫过整行，步数、箭头也随扫掠换过去。
    private let activity = ToolActivityView()
    private let summary = LineLabel()
    private let unfinished = LineLabel()
    private let chevron = TurningChevron()
    private var font = NSFont.systemFont(ofSize: 11)
    /// 汇总这一行显示着（或扫掠中等着换上）的字：汇总、没跑完的步数，和字体。
    private var shown: (headline: String, unfinished: String, font: NSFont)?

    override var isFlipped: Bool { true }

    /// 读屏读的：汇总行说的连同没跑完的步数。
    private var speech = ""
    /// 展开了步骤，读屏读成展开收起的三角。
    var expanded = false {
        didSet { if expanded != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) } }
    }

    init() {
        super.init(frame: .zero)
        addSubview(activity)
        activity.content.addSubview(summary)
        activity.content.addSubview(unfinished)
        for label in [summary, unfinished] { label.setAccessibilityElement(false) }
        activity.content.addSubview(chevron)
        chevron.hideFromAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 汇总行：思考、正在做什么或汇总，这组还在做事（Work.active）时一直带像素扫掠，展开着也扫；扫掠中换说的事随扫掠换过去（见 ToolActivityView.change）。
    func show(_ work: Work, environment: EnvironmentValues) {
        speech = TranscriptSpeech.work(work)
        font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let secondary = NSColor.secondaryLabelColor
        let unfinishedCount = work.count(.unfinished)
        activity.presence = environment.panePresence
        activity.mode = work.active ? .sweeping : .none
        let headline = work.headline, steps = unfinishedCount > 0 ? "\(unfinishedCount) 步没跑完" : "", font = font
        let apply = { [weak self] in
            guard let self else { return }
            set(summary, headline, color: secondary)
            set(unfinished, steps, color: secondary)
            needsLayout = true
        }
        if let shown, shown.font == font, shown.headline != headline || shown.unfinished != steps {
            activity.change(apply)
        } else if shown?.headline != headline || shown?.unfinished != steps || shown?.font != font {
            apply()
            activity.contentChanged()
        }
        shown = (headline, steps, font)
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
        let imageSize = chevron.image?.size ?? .zero
        let unfinishedWidth = unfinished.isHidden ? 0 : unfinished.textWidth + spacing
        let summaryWidth = min(summary.textWidth, max(bounds.width - unfinishedWidth - imageSize.width - spacing, 0))
        // 几样都摆在扫掠的内容里，坐标同这一行
        var x: CGFloat = 0
        summary.frame = CGRect(x: 0, y: 0, width: summaryWidth, height: bounds.height)
        x += summaryWidth + spacing
        if !unfinished.isHidden {
            unfinished.frame = CGRect(x: x, y: 0, width: unfinished.textWidth, height: bounds.height)
            x += unfinishedWidth
        }
        chevron.place(CGRect(x: x, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height))
        activity.frame = CGRect(x: 0, y: 0, width: min(x + imageSize.width, bounds.width), height: bounds.height)
        activity.sweepWidth = summaryWidth
    }

    override func drawFocusRingMask() { bounds.fill() }

    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { speech }
    override func accessibilityValue() -> Any? { expanded ? 1 : 0 }
    override func isAccessibilityExpanded() -> Bool { expanded }
}

/// 工具行的视图：汇总行、展开后的步骤，按自己的范围截（收起时退场的步骤不画到后面的行上）。
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

/// 生成中、前面不是工具组的思考：一行次要色小字，说的同读屏（TranscriptSpeech.summary），放不下截掉；同工具组汇总行说思考时一样一直带像素扫掠。
/// 思考条目只在生成期间显示，完整摘要仍保留在记录中。正在压缩、最后一项不是工具组时末尾那行整理上下文也是它。
final class ThinkingRowSlot: TranscriptRowSlot {
    private let container = ThinkingRowView()

    override var hasView: Bool { true }
    override var view: NSView { container }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        container.show(TranscriptSpeech.summary(row), environment: context.environment)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = container.height
        measured = (width, height)
        return height
    }
}

/// 思考行的视图：扫掠只盖在字上，不盖后面的空白，同工具组的汇总行。
final class ThinkingRowView: NSView {
    private let activity = ToolActivityView()
    private let label = LineLabel()
    private var shown: (text: String, font: NSFont)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(activity)
        activity.content.addSubview(label)
        activity.mode = .sweeping
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, environment: EnvironmentValues) {
        let font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        activity.presence = environment.panePresence
        // 思考流式刷新时说的字多半没变（有小标题时说小标题），没变就不重画扫掠的贴图；换了小标题随扫掠换过去（见 ToolActivityView.change）
        guard shown?.text != text || shown?.font != font else { return }
        let changing = shown != nil && shown?.font == font
        shown = (text, font)
        let apply = { [weak self] in
            guard let self else { return }
            label.set(text, font: font, color: .secondaryLabelColor)
            needsLayout = true
        }
        if changing { activity.change(apply) } else {
            apply()
            activity.contentChanged()
        }
    }

    /// 一行字的高。
    var height: CGFloat { label.lineHeight }

    override func layout() {
        super.layout()
        let width = min(label.textWidth, bounds.width)
        activity.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        label.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}
#endif
