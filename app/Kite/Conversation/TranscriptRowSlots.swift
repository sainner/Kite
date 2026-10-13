#if os(macOS)
import AppKit
import SwiftUI

/// Mac 上按 slotKind（两端共用，见 TranscriptSlot）建这一行的实现。
@MainActor func makeTranscriptRowSlot(_ row: TranscriptRow) -> TranscriptRowSlot {
    switch slotKind(row) {
    case .prose: ProseRowSlot(row: row)
    case .bubble: BubbleRowSlot(row: row)
    case .work: WorkRowSlot(row: row)
    case .thinking: ThinkingRowSlot(row: row)
    case .hosted: HostedRowSlot(row: row)
    }
}

/// 这一行用的实现还能不能接着用：种类变了换一个新的。
@MainActor func transcriptRowSlotFits(_ slot: TranscriptRowSlot, _ row: TranscriptRow) -> Bool {
    switch slotKind(row) {
    case .prose: slot is ProseRowSlot
    case .bubble: slot is BubbleRowSlot
    case .work: slot is WorkRowSlot
    case .thinking: slot is ThinkingRowSlot
    case .hosted: slot is HostedRowSlot
    }
}

/// agent 说的一段话：原生文本视图，属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套。
/// 文本视图两边各伸出 inlineCodePadding 给行内代码背景留绘制余量，正文的宽和起点不变；开头是标题时上面多半个块距，同 SelectableMarkdown。
final class ProseRowSlot: TranscriptRowSlot {
    private let text = ProseTextView.make()
    private let coordinator = ProseRowCoordinator()
    private let document = MarkdownDocument()
    private let attachments = BlockAttachments()
    /// 这段话的原文，操作栏复制它。
    private(set) var source: String?
    private var environment: EnvironmentValues?
    private var actionable = false
    private var topInset: CGFloat = 0
    /// 引用图标要加载的网址，变了才重新加载。
    private var urls: [URL] = []
    /// 拖缝时只排一截、按住看着的那截，两端共用。量过的高作废时跟着作废。
    private let layout = ProseLayout()

    override var measured: (width: CGFloat, height: CGFloat)? {
        didSet { if measured == nil { layout.invalidate() } }
    }

    override init(row: TranscriptRow) {
        super.init(row: row)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: Metrics.inlineCodePadding, height: 0)
        text.clipsViewport = true
        // 悬停不显示 URL 提示，也不自动识别链接、补全，同 SelectableTextView
        text.displaysLinkToolTips = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.usesFontPanel = false
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        text.delegate = coordinator
        text.textLayoutManager?.delegate = coordinator
        coordinator.view = text
        coordinator.resized = { [weak self] in
            guard let self else { return }
            measured = nil
            heightChanged?(nil)
        }
    }

    override var hasView: Bool { true }
    override var view: NSView { text }

    /// 主对话里 agent 的话：复制、翻译、分叉，和这段话左边对齐。
    override func actionBar() -> (side: HorizontalEdge, content: AnyView)? {
        guard actionable, let source, let environment else { return nil }
        return (.leading, AnyView(AgentTextActions(text: source).environment(\.self, environment)))
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .text(let source) = item.kind else { return }
        coordinator.openURL = context.environment.openURL
        let id = row.id
        actionable = context.actionable
        text.secondaryClick = context.actionable ? { context.toggleActions(id) } : nil
        self.source = source
        environment = context.environment
        build()
    }

    /// 按 source 和环境排出属性串。读了引用图标（ReferenceIcons），图标载完重排一次。
    private func build() {
        guard let source, let environment else { return }
        let content = withObservationTracking {
            let blocks = document.blocks(for: source)
            let body = (environment.font ?? .body).resolve(in: environment.fontResolutionContext).ctFont as NSFont
            topInset = SelectableMarkdown.startsWithHeading(blocks) ? Metrics.markdownBlockGap(body.pointSize) / 2 : 0
            let urls = blocks.flatMap { ReferenceText.decorate($0.text, scope: environment.referenceScope).runs.compactMap(\.link) }
            if urls != self.urls {
                self.urls = urls
                Task { await ReferenceIcons.shared.load(urls) }
            }
            return SelectableMarkdown.content(blocks, source: source, body: body, color: .label, colorScheme: environment.colorScheme,
                                              scope: environment.referenceScope, attachments: attachments)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.measured = nil
                self.build()
                self.heightChanged?(nil)
            }
        }
        text.source = content.source
        // 附件先换好内容再放字：放字时 TextKit 就会量附件的高
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(environment))
        guard coordinator.shown != content.text, !coordinator.appendTail(of: content.text) else { return }
        // 外观变化时也换掉已经解析成 CGColor 的装饰；只换颜色时保留选区。
        let textChanged = coordinator.shown?.string != content.text.string
        let selection = text.selectedRange()
        coordinator.shown = content.text
        text.textStorage?.setAttributedString(content.text)
        if !textChanged { text.setSelectedRange(selection) }
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional { return measured.height }
        let height = text.measure(lineWidth: width) + topInset
        provisional = false
        measured = (width, height)
        return height
    }

    /// 拖缝时只排 band 那一截，见 ProseLayout；这截占了大半行时整段排。
    override func height(width: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        guard let measured,
              let banded = layout.height(of: text, width: width, band: band, topInset: topInset, measured: measured, exact: !provisional)
        else { return height(width: width) }
        provisional = true
        self.measured = (width, banded)
        return banded
    }

    override func pin(at y: CGFloat) {
        layout.pin(text, at: y, topInset: topInset)
    }

    override var pinShift: CGFloat {
        layout.pinShift(text)
    }

    override func viewFrame(in column: CGRect) -> CGRect {
        CGRect(x: column.minX - Metrics.inlineCodePadding, y: column.minY + topInset,
               width: column.width + Metrics.inlineCodePadding * 2, height: column.height - topInset)
    }
}

/// 链接交给 SwiftUI 的 openURL：文件引用由 ReferenceNavigation 打开，网页交给系统。同 SelectableTextView.Coordinator。
final class ProseRowCoordinator: ProseTextCoordinator, NSTextViewDelegate {
    var openURL: OpenURLAction?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        openURL?(url)
        return true
    }
}

/// 还没原生化的行：托管原来的 SwiftUI 行视图。只在可见区附近才建；内容自己变高变矮时由 onGeometryChange 报回来。
/// 托管视图改宽约 0.8 ms 一行、只挪位置也要约 0.2 ms（2026-10-13 实测），常见的行都要换成原生的。
final class HostedRowSlot: TranscriptRowSlot {
    private var controller: NSHostingController<AnyView>?
    private var context: TranscriptRowContext?

    override var hasView: Bool { controller != nil }
    override var hosted: Bool { true }

    override var view: NSView {
        if let controller { return controller.view }
        let controller = NSHostingController(rootView: root())
        controller.sizingOptions = []
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        self.controller = controller
        return controller.view
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        self.context = context
        controller?.rootView = root()
    }

    private func root() -> AnyView {
        guard let context else { return AnyView(EmptyView()) }
        return AnyView(HostedRowFrame {
            TranscriptRowView(row: row)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] in self?.reported($0) }
        }
        .environment(\.self, context.environment))
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        _ = view
        guard let controller else { return 0 }
        let height = ceil(controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        measured = (width, height)
        return height
    }

    /// 排好以后报来的高：和量的不一样（自己展开收起了）就请列表重排。
    private func reported(_ height: CGFloat) {
        let height = ceil(height)
        guard let measured, measured.width == frame.width, abs(measured.height - height) > 0.5 else { return }
        self.measured = (measured.width, height)
        heightChanged?(nil)
    }
}
/// 托管的行按内容的理想高报尺寸、贴顶摆：量高时给无限高也只报内容多高（不然 maxHeight 无限的框会把无限高原样报回来），
/// 内容自己变高、列表还没跟上的那一帧往下伸，不居中。
struct HostedRowFrame: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
#endif
