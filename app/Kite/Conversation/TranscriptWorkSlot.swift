#if os(macOS)
import AppKit
import SwiftUI

/// 两段话之间 agent 做的事折成的一行，照 WorkRow：汇总一行原生画（汇总、出错和没跑完的步数、箭头，一行，放不下截汇总）；
/// 有调用在跑时托管原来的汇总行（WorkSummaryLine，正在做什么带像素扫掠，原生不画着色器）。点开后下面托管原来的步骤（WorkSteps），
/// 展开收起和下面的行一起按 0.25 秒的普通缓出动，箭头跟着转、步骤跟着淡入淡出；收起走完拿掉步骤，同 SwiftUI 版不留展开状态。
final class WorkRowSlot: TranscriptRowSlot {
    private let container = WorkRowView()
    private var work: Work?
    private var expanded = false
    private var context: TranscriptRowContext?
    private var headerHeight: CGFloat = 0
    private var stepsHeight: CGFloat = 0
    private var steps: NSHostingController<AnyView>?
    /// 有调用在跑时托管的汇总行。
    private var running: NSHostingController<AnyView>?

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
        let environment = context.environment
        if work.running != nil {
            let root = AnyView(WorkSummaryLine(work: work, expanded: expanded).environment(\.self, environment))
            if let running {
                running.rootView = root
            } else {
                let controller = NSHostingController(rootView: root)
                controller.sizingOptions = []
                // 托管的垫在原生汇总行下面只画，点击照样落在汇总行上
                container.addSubview(controller.view, positioned: .below, relativeTo: container.header)
                running = controller
            }
            container.header.showRunning()
        } else {
            running?.view.removeFromSuperview()
            running = nil
            container.header.show(work, environment: environment)
        }
        steps?.rootView = stepsRoot()
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
        if let running {
            headerHeight = ceil(running.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        } else {
            headerHeight = container.header.height
        }
        if expanded, let steps {
            stepsHeight = ceil(steps.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        let height = headerHeight + (expanded ? Self.spacing + stepsHeight : 0)
        measured = (width, height)
        return height
    }

    /// 动画中行的高在收起和展开之间：按它算走到哪了，箭头转多少、步骤多透明都跟着它。
    override func layoutView(in frame: CGRect) {
        let full = Self.spacing + stepsHeight
        let progress = full > 0 ? min(max((frame.height - headerHeight) / full, 0), 1) : (expanded ? 1 : 0)
        let header = CGRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        container.header.frame = header
        container.header.turn = progress
        running?.view.frame = header
        if let steps {
            steps.view.frame = CGRect(x: 0, y: headerHeight + Self.spacing, width: frame.width, height: stepsHeight)
            steps.view.alphaValue = progress
            // 收起走完拿掉步骤
            if !expanded, progress == 0 {
                steps.view.removeFromSuperview()
                self.steps = nil
            }
        }
    }

    private func toggle() {
        expanded.toggle()
        if expanded, steps == nil {
            let controller = NSHostingController(rootView: stepsRoot())
            controller.sizingOptions = []
            container.addSubview(controller.view)
            controller.view.alphaValue = 0
            steps = controller
        }
        if let work, let context, let running {
            running.rootView = AnyView(WorkSummaryLine(work: work, expanded: expanded).environment(\.self, context.environment))
        }
        measured = nil
        heightChanged?(Self.motion)
    }

    /// 步骤自己变高变矮（点开某一步）：和它同样的走法。
    private func stepsReported(_ height: CGFloat) {
        let height = ceil(height)
        guard expanded, abs(height - stepsHeight) > 0.5, let measured else { return }
        stepsHeight = height
        self.measured = (measured.width, headerHeight + Self.spacing + height)
        heightChanged?(Self.motion)
    }
}

/// 工具组汇总行的原生版：一行次要色小字，汇总、出错步数（红）、没跑完步数，箭头；整行可点，指针是手形。
final class WorkHeaderView: NSView {
    var action: (() -> Void)?
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat = 0 {
        didSet { if turn != oldValue { chevron.frameCenterRotation = -90 * turn } }
    }
    private let summary = LineLabel()
    private let failed = LineLabel()
    private let unfinished = LineLabel()
    private let chevron = NSImageView()
    private var font = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for label in [summary, failed, unfinished] { addSubview(label) }
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ work: Work, environment: EnvironmentValues) {
        font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let secondary = NSColor.secondaryLabelColor
        let failedCount = work.count(.failed) + work.count(.unknown), unfinishedCount = work.count(.unfinished)
        set(summary, work.summary, color: secondary)
        set(failed, failedCount > 0 ? "\(failedCount) 步出错" : "", color: NSColor(cgColor: Theme.danger.resolve(in: environment).cgColor) ?? .systemRed)
        set(unfinished, unfinishedCount > 0 ? "\(unfinishedCount) 步没跑完" : "", color: secondary)
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular, scale: .small)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        chevron.contentTintColor = secondary
        chevron.isHidden = false
        needsLayout = true
    }

    /// 有调用在跑：汇总行由下面托管的 WorkSummaryLine 画，这里不画字，只接点击。
    func showRunning() {
        for view in subviews { view.isHidden = true }
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
        summary.frame = CGRect(x: x, y: 0, width: summaryWidth, height: bounds.height)
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
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

/// 托管的步骤按内容的理想高报尺寸、贴顶摆：量高时给无限高也只报内容多高（不然 maxHeight 无限的框会把无限高原样报回来），
/// 内容自己变高、行还没跟上的那一帧往下伸，不居中。
struct HostedRowFrame: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// 一行字，按字形的宽排，放不下末尾截成省略号。SwiftUI 的 lineLimit(1) Text 那样从 0 起画，不像 NSTextField 两边带单元格边距。
final class LineLabel: NSView {
    private var text = NSAttributedString()
    private var font = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    func set(_ string: String, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        self.font = font
        needsDisplay = true
    }

    /// 不截时多宽。
    var textWidth: CGFloat { ceil(text.size().width) }
    /// 不截时多宽，往上取到像素（SwiftUI 的 Text 就这么宽），不取整到点。
    var exactWidth: CGFloat { (text.size().width * 2).rounded(.up) / 2 }

    /// 一行字的高。
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: CGRect(x: 0, y: 0, width: bounds.width, height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
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
