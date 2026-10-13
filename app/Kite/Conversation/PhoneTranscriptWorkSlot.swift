#if os(iOS)
import SwiftUI
import UIKit

/// 两段话之间 agent 做的事折成的一行，照 WorkRow：汇总一行原生画（汇总、出错和没跑完的步数、箭头，一行，放不下截汇总）；
/// 有调用在跑时托管原来的汇总行（WorkSummaryLine，正在做什么带像素扫掠，原生不画着色器）。点开后下面托管原来的步骤（WorkSteps），
/// 展开收起和下面的行一起按 0.25 秒的普通缓出动，箭头跟着转、步骤跟着淡入淡出；收起走完拿掉步骤，同 SwiftUI 版不留展开状态。
/// 量法、展开进度和 Mac 共用（WorkLayout）。
final class PhoneWorkRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var container: PhoneWorkRowView?
    private var work: Work?
    private var expanded = false
    private var context: TranscriptRowContext?
    private var headerHeight: CGFloat = 0
    private var stepsHeight: CGFloat = 0
    private var steps: UIHostingController<AnyView>?
    /// 有调用在跑时托管的汇总行。
    private var running: UIHostingController<AnyView>?

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

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .work(let work) = item.kind else { return }
        self.work = work
        self.context = context
        guard container != nil else { return }
        show()
    }

    /// 汇总行换上这一组的内容：在跑时托管 SwiftUI 的汇总行，原生的只接点击。
    private func show() {
        guard let work, let context, let container else { return }
        let environment = context.environment
        if work.running != nil {
            let root = AnyView(WorkSummaryLine(work: work, expanded: expanded).environment(\.self, environment))
            if let running {
                running.rootView = root
            } else {
                let controller = Self.host(root)
                // 托管的垫在原生汇总行下面只画，点击照样落在汇总行上
                controller.view.isUserInteractionEnabled = false
                container.insertSubview(controller.view, belowSubview: container.header)
                running = controller
            }
            container.header.showRunning(work, expanded: expanded)
        } else {
            running?.view.removeFromSuperview()
            running = nil
            container.header.show(work, expanded: expanded, environment: environment)
        }
        steps?.rootView = stepsRoot()
    }

    private static func host(_ root: AnyView) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: root)
        controller.sizingOptions = []
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        return controller
    }

    private func stepsRoot() -> AnyView {
        guard let work, let context else { return AnyView(EmptyView()) }
        return AnyView(HostedRowFrame {
            WorkSteps(work: work)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] in self?.stepsReported($0) }
        }
        .environment(\.self, context.environment))
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let container = rowView
        if let running {
            headerHeight = running.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        } else {
            headerHeight = container.header.height
        }
        if expanded, let steps {
            stepsHeight = steps.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let height = WorkLayout.height(header: headerHeight, steps: stepsHeight, expanded: expanded)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：按它算走到哪了，箭头转多少、步骤多透明都跟着它。
    override func layoutView(in frame: CGRect) {
        guard let container else { return }
        let progress = WorkLayout.progress(rowHeight: frame.height, header: headerHeight, steps: stepsHeight, expanded: expanded)
        let header = CGRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        container.header.frame = header
        container.header.turn = progress
        running?.view.frame = header
        if let steps {
            steps.view.frame = CGRect(x: 0, y: headerHeight + WorkLayout.spacing, width: frame.width, height: stepsHeight)
            steps.view.alpha = progress
            // 收起走完拿掉步骤
            if !expanded, progress == 0 {
                steps.willMove(toParent: nil)
                steps.view.removeFromSuperview()
                steps.removeFromParent()
                self.steps = nil
            }
        }
    }

    private func toggle() {
        guard let container else { return }
        context?.select(nil)
        expanded.toggle()
        if expanded, steps == nil {
            let controller = Self.host(stepsRoot())
            container.addSubview(controller.view)
            controller.view.alpha = 0
            adopt(controller)
            steps = controller
        }
        show()
        measured = nil
        heightChanged?(WorkLayout.motion)
    }

    /// 步骤自己变高变矮（点开某一步）：和它同样的走法。
    private func stepsReported(_ height: CGFloat) {
        guard expanded, abs(height - stepsHeight) > 0.5, let measured else { return }
        stepsHeight = height
        self.measured = (measured.width, WorkLayout.height(header: headerHeight, steps: height, expanded: true))
        heightChanged?(WorkLayout.motion)
    }

    func didPlace() {
        if let steps { adopt(steps) }
    }

    func releaseView() {
        steps?.removeFromParent()
        steps = nil
        running = nil
        container = nil
        // 重建时是收着的，量过的高（可能带着展开的步骤）作废
        if expanded { measured = nil }
        expanded = false
    }
}

/// 工具行的视图：汇总行、展开后的步骤，按自己的范围截（收起时退场的步骤不画到后面的行上，同 WorkRow 的 clipped）。
final class PhoneWorkRowView: UIView {
    let header = PhoneWorkHeader()

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 工具组汇总行的原生版，照 WorkSummaryLine：一行次要色小字，HStack(spacing: 8) 竖着居中：汇总、出错步数（红）、没跑完步数、小号箭头；
/// 汇总放不下截掉。整行可点。
final class PhoneWorkHeader: PhonePlainControl {
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat = 0 {
        didSet { if turn != oldValue { chevron.transform = CGAffineTransform(rotationAngle: .pi / 2 * turn) } }
    }
    private let summary = PhoneTextLine()
    private let failed = PhoneTextLine()
    private let unfinished = PhoneTextLine()
    private let chevron = UIImageView()
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)

    override init() {
        super.init()
        for view in [summary, failed, unfinished] as [UIView] { content.addSubview(view) }
        content.addSubview(chevron)
        chevron.contentMode = .center
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ work: Work, expanded: Bool, environment: EnvironmentValues) {
        font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as UIFont
        let failedCount = work.count(.failed) + work.count(.unknown), unfinishedCount = work.count(.unfinished)
        set(summary, work.summary, color: .secondaryLabel)
        set(failed, failedCount > 0 ? "\(failedCount) 步出错" : "", color: UIColor(Theme.danger))
        set(unfinished, unfinishedCount > 0 ? "\(unfinishedCount) 步没跑完" : "", color: .secondaryLabel)
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))
        chevron.tintColor = .secondaryLabel
        chevron.isHidden = false
        describe(work, expanded: expanded)
        setNeedsLayout()
    }

    /// 有调用在跑：汇总行由下面托管的 WorkSummaryLine 画，这里不画字，只接点击。
    func showRunning(_ work: Work, expanded: Bool) {
        for view in content.subviews { view.isHidden = true }
        describe(work, expanded: expanded)
    }

    private func describe(_ work: Work, expanded: Bool) {
        accessibilityLabel = work.accessibilitySummary
        accessibilityValue = expanded ? "已展开" : "已收起"
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
        let tail = [failed, unfinished].filter { !$0.isHidden }
        let imageSize = chevron.image?.size ?? .zero
        let tailWidth = tail.reduce(0) { $0 + $1.naturalWidth + spacing } + imageSize.width
        let summaryWidth = min(summary.naturalWidth, max(bounds.width - tailWidth - spacing, 0))
        var x: CGFloat = 0
        summary.frame = CGRect(x: x, y: 0, width: summaryWidth, height: bounds.height)
        x += summaryWidth + spacing
        for line in tail {
            let width = line.naturalWidth
            line.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + spacing
        }
        let transform = chevron.transform
        chevron.transform = .identity
        // 位置对到像素，同 SwiftUI 画的时候
        chevron.frame = PhonePixel.align(CGRect(x: x, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height))
        chevron.transform = transform
    }
}

/// 生成中的思考，同 ThinkingRow：一行次要色小字，换行当空格，放不下截掉。
final class PhoneThinkingRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var label: PhoneTextLine?
    private var text = ""
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)

    override var hasView: Bool { label != nil }

    override var view: UIView {
        if let label { return label }
        let label = PhoneTextLine()
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        self.label = label
        show()
        return label
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .thinking(let text) = item.kind else { return }
        self.text = text.isEmpty ? "思考中" : text.replacingOccurrences(of: "\n", with: " ")
        font = Theme.secondary.resolve(in: context.environment.fontResolutionContext).ctFont as UIFont
        show()
    }

    private func show() {
        label?.set(text, font: font, color: .secondaryLabel)
        label?.accessibilityLabel = text
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = PhonePixel.ceil(font.lineHeight)
        measured = (width, height)
        return height
    }

    func didPlace() {}

    func releaseView() {
        label = nil
    }
}
#endif
