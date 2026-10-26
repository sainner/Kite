#if os(iOS)
import SwiftUI
import UIKit

/// 两段话之间 agent 做的事折成的一行：汇总一行（思考、正在做什么或汇总，出错和没跑完的步数、箭头，一行，放不下截汇总；
/// 回合在跑、这是最后一组时不说汇总，一直带像素扫掠，见 PhoneActivityView），点开后下面是每一步（PhoneWorkSteps）。
/// 展开收起和下面的行一起按 0.25 秒的普通缓出动，箭头跟着转、步骤跟着淡入淡出；收起走完拿掉步骤，不留各步的展开状态。
/// 一步自己展开收起时，这一行的高由列表的行高动画给，多出、少掉的那截交给步骤去摆。量法、展开进度和 Mac 共用（WorkLayout）。
final class PhoneWorkRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var container: PhoneWorkRowView?
    private var work: Work?
    private var expanded = false
    private var context: TranscriptRowContext?
    private var headerHeight: CGFloat = 0
    private var stepsHeight: CGFloat = 0
    private var steps: PhoneWorkSteps?

    override var hasView: Bool { container != nil }
    override var view: UIView { rowView }

    private var rowView: PhoneWorkRowView {
        if let container { return container }
        let container = PhoneWorkRowView()
        container.header.action = { [weak self] in self?.toggle() }
        self.container = container
        show()
        return container
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .work(let work) = item.kind else { return }
        self.work = work
        self.context = context
        guard container != nil else { return }
        show()
    }

    private func show() {
        guard let work, let context, let container else { return }
        container.header.show(work, expanded: expanded, environment: context.environment)
        steps?.show(work, context: context)
    }

    /// 拖缝中步骤里嵌着的对话按近似量的话记作 provisional，停下后列表补量成准确的高，同 Mac 的 WorkRowSlot。
    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional || resizing { return measured.height }
        headerHeight = rowView.header.height
        provisional = false
        if expanded, let steps {
            stepsHeight = steps.height(width: width)
            provisional = steps.approximate
        }
        let height = WorkLayout.height(header: headerHeight, steps: stepsHeight, expanded: expanded)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：按它算走到哪了，箭头转多少、步骤多透明都跟着它。一步在展开收起时步骤是展开着的，
    /// 行的高全给步骤去摆。
    override func layoutView(in frame: CGRect) {
        guard let container else { return }
        let inner = steps?.animating != nil
        let progress = inner ? 1 : WorkLayout.progress(rowHeight: frame.height, header: headerHeight, steps: stepsHeight, expanded: expanded)
        container.header.frame = CGRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        container.header.turn = progress
        guard let steps else { return }
        let top = headerHeight + WorkLayout.spacing
        steps.frame = CGRect(x: 0, y: top, width: frame.width, height: inner ? max(frame.height - top, 0) : stepsHeight)
        steps.alpha = progress
        steps.layoutIfNeeded()
        // 收起走完拿掉步骤
        if !expanded, progress == 0 {
            steps.release()
            steps.removeFromSuperview()
            self.steps = nil
        }
    }

    private func toggle() {
        guard let container, let work, let context else { return }
        context.select(nil)
        expanded.toggle()
        if expanded, steps == nil {
            let steps = PhoneWorkSteps()
            steps.changed = { [weak self] motion in self?.stepsChanged(motion) }
            steps.alpha = 0
            container.addSubview(steps)
            steps.show(work, context: context)
            self.steps = steps
        }
        steps?.animating = nil
        container.header.show(work, expanded: expanded, environment: context.environment)
        measured = nil
        heightChanged?(WorkLayout.motion)
    }

    /// 一步展开收起了、步骤里嵌着的对话变了：重量步骤，和它同样的走法。
    private func stepsChanged(_ motion: RowMotion?) {
        guard expanded, let steps, let measured else { return }
        stepsHeight = steps.height(width: measured.width)
        self.measured = (measured.width, WorkLayout.height(header: headerHeight, steps: stepsHeight, expanded: true))
        heightChanged?(motion)
    }

    func didPlace() {}

    func releaseView() {
        steps?.release()
        steps = nil
        container = nil
        // 重建时是收着的，量过的高（可能带着展开的步骤）作废
        if expanded { measured = nil }
        expanded = false
    }
}

/// 工具行的视图：汇总行、展开后的步骤，按自己的范围截（收起时退场的步骤不画到后面的行上）。
final class PhoneWorkRowView: UIView {
    let header = PhoneWorkHeader()

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 工具组的汇总行：一行次要色小字，间距 8、竖着居中：汇总（见 Work.headline）、
/// 没跑完步数、小号箭头；汇总放不下截掉。这组还在做事（Work.active）时一直带像素扫掠（PhoneActivityView），展开着也扫。整行可点。
final class PhoneWorkHeader: PhonePlainControl {
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat = 0 {
        didSet { if turn != oldValue { chevron.transform = CGAffineTransform(rotationAngle: .pi / 2 * turn) } }
    }
    private let activity = PhoneActivityView()
    private let summary = PhoneTextLine()
    private let unfinished = PhoneTextLine()
    private let chevron = UIImageView()
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)

    override init() {
        super.init()
        content.addSubview(activity)
        activity.content.addSubview(summary)
        content.addSubview(unfinished)
        content.addSubview(chevron)
        chevron.contentMode = .center
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ work: Work, expanded: Bool, environment: EnvironmentValues) {
        font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont
        let unfinishedCount = work.count(.unfinished)
        set(summary, work.headline, color: .secondaryLabel)
        set(unfinished, unfinishedCount > 0 ? "\(unfinishedCount) 步没跑完" : "", color: .secondaryLabel)
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))
        chevron.tintColor = .secondaryLabel
        activity.contentChanged()
        activity.show(work.active ? .sweeping : .none, presence: environment.panePresence)
        accessibilityLabel = TranscriptSpeech.work(work)
        accessibilityValue = TranscriptSpeech.expanded(expanded)
        setNeedsLayout()
    }

    private func set(_ line: PhoneTextLine, _ text: String, color: UIColor) {
        line.set(text, font: font, color: color)
        line.isHidden = text.isEmpty
    }

    /// 一行字的高，同 SwiftUI 的 Text。
    var height: CGFloat { summary.lineHeight }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing: CGFloat = 8
        let imageSize = chevron.image?.size ?? .zero
        let unfinishedWidth = unfinished.isHidden ? 0 : unfinished.naturalWidth + spacing
        let summaryWidth = min(summary.naturalWidth, max(bounds.width - unfinishedWidth - imageSize.width - spacing, 0))
        var x: CGFloat = 0
        activity.frame = CGRect(x: x, y: 0, width: summaryWidth, height: bounds.height)
        summary.frame = activity.bounds
        x += summaryWidth + spacing
        if !unfinished.isHidden {
            unfinished.frame = CGRect(x: x, y: 0, width: unfinished.naturalWidth, height: bounds.height)
            x += unfinishedWidth
        }
        let transform = chevron.transform
        chevron.transform = .identity
        // 位置对到像素，同 SwiftUI 画的时候
        chevron.frame = PhonePixel.align(CGRect(x: x, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height))
        chevron.transform = transform
    }
}

/// 生成中、前面不是工具组的思考：一行次要色小字，取哪段字见 TranscriptSpeech.thinking，放不下截掉；同工具组汇总行说思考时一样一直带像素扫掠。
final class PhoneThinkingRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var container: PhoneThinkingRowView?
    private var text = ""
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)
    private var presence: PanePresence?

    override var hasView: Bool { container != nil }

    override var view: UIView {
        if let container { return container }
        let container = PhoneThinkingRowView()
        self.container = container
        show()
        return container
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .thinking(let text) = item.kind else { return }
        self.text = TranscriptSpeech.thinking(text)
        font = Theme.secondary.resolve(in: context.environment.fontResolutionContext).ctFont as UIFont
        presence = context.environment.panePresence
        show()
    }

    private func show() {
        container?.show(text, font: font, presence: presence)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = PhonePixel.ceil(font.lineHeight)
        measured = (width, height)
        return height
    }

    func didPlace() {}

    func releaseView() {
        container = nil
    }
}

/// 思考行的视图：扫掠（PhoneActivityView）只盖在字上，不盖后面的空白，同工具组的汇总行。扫掠时字所在的层是透明的，读屏读这一整行。
final class PhoneThinkingRowView: UIView {
    private let activity = PhoneActivityView()
    private let label = PhoneTextLine()

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        addSubview(activity)
        activity.content.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, font: UIFont, presence: PanePresence?) {
        label.set(text, font: font, color: .secondaryLabel)
        accessibilityLabel = text
        activity.contentChanged()
        activity.show(.sweeping, presence: presence)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        activity.frame = CGRect(x: 0, y: 0, width: min(label.naturalWidth, bounds.width), height: bounds.height)
        label.frame = activity.bounds
    }
}
#endif
