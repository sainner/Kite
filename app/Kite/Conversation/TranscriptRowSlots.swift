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
    case .kite: KiteRowSlot(row: row)
    case .compaction: CompactionRowSlot(row: row)
    }
}

/// 这一行用的实现还能不能接着用：种类变了换一个新的。
@MainActor func transcriptRowSlotFits(_ slot: TranscriptRowSlot, _ row: TranscriptRow) -> Bool {
    switch slotKind(row) {
    case .prose: slot is ProseRowSlot
    case .bubble: slot is BubbleRowSlot
    case .work: slot is WorkRowSlot
    case .thinking: slot is ThinkingRowSlot
    case .kite: slot is KiteRowSlot
    case .compaction: slot is CompactionRowSlot
    }
}

/// agent 说的一段话：原生文本视图，属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套（见 MarkdownTextBlock）。
final class ProseRowSlot: TranscriptRowSlot, ActionBarProviding {
    private let body = MarkdownTextBlock()
    private var environment: EnvironmentValues?
    private var actionable = false
    /// 拖缝时只排一截、按住看着的那截，两端共用。量过的高作废时跟着作废。
    private let layout = ProseLayout()

    private var text: ProseTextView { body.text }
    /// 这段话的原文，操作栏复制它。
    var source: String? { body.source }

    override var measured: (width: CGFloat, height: CGFloat)? {
        didSet { if measured == nil { layout.invalidate() } }
    }

    /// 上次整段排准、没有一段被行宽折下来、也没有嵌块：最宽一行的宽（排版坐标）。拖缝时新的行宽还放得下它，排出来一样：
    /// 不再量，文本容器也留在原来的宽（视图跟着列宽改、容器不跟，见 layoutView），文本视图不用重排。停下后照常补量。
    private var unwrapped: CGFloat?
    /// 拖缝中文本容器留在原来的宽，摆视图时不跟着改。
    private var keepsContainer = false

    override init(row: TranscriptRow) {
        super.init(row: row)
        body.changed = { [weak self] in
            guard let self else { return }
            measured = nil
            heightChanged?(nil)
        }
        // 容器的宽由量高（fit）和摆视图（layoutView）定，不跟着视图的宽：拖缝中没折行的短段落留在原来的宽
        text.textContainer?.widthTracksTextView = false
    }

    override var hasView: Bool { true }
    override var view: NSView { text }

    /// 主对话里 agent 的话：复制、翻译、分叉（后两个还没做），和这段话左边对齐，同 AgentTextActions。
    func actionItems() -> (side: HorizontalEdge, items: [ActionItem])? {
        guard actionable, let source, let environment else { return nil }
        let selection = environment.selectedRow
        let toast = environment.toast
        return (.leading, [
            ActionItem(title: "复制", icon: "doc.on.doc") {
                copyToPasteboard(source, toast: toast)
                selection.close()
            },
            // 翻译成另一种语言，还没做
            ActionItem(title: "翻译", icon: "translate", enabled: false) { selection.close() },
            // 分出一个新会话，从这段话之后接着说；还没做
            ActionItem(title: "从这里分叉", icon: "arrow.triangle.branch", enabled: false) { selection.close() },
        ])
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .text(let source) = item.kind else { return }
        let id = row.id
        actionable = context.actionable
        text.secondaryClick = context.actionable ? { context.toggleActions(id) } : nil
        text.setAccessibilityCustomActions(context.actionable
            ? [NSAccessibilityCustomAction(name: TranscriptSpeech.actions) { context.toggleActions(id); return true }] : nil)
        environment = context.environment
        body.show(source, environment: context.environment, font: context.environment.font ?? .body, color: .label)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional { return measured.height }
        let height = body.height(width: width)
        provisional = false
        keepsContainer = false
        unwrapped = body.hasBlocks || text.softWraps ? nil : text.widestLine
        measured = (width, height)
        return height
    }

    /// 拖缝时只排 band 那一截，见 ProseLayout；这截占了大半行时整段排。没折行的短段落新宽还放得下就不排（见 unwrapped）。
    override func height(width: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        if let unwrapped, let measured, unwrapped <= width {
            provisional = true
            keepsContainer = true
            self.measured = (width, measured.height)
            return measured.height
        }
        keepsContainer = false
        unwrapped = nil
        guard let measured,
              let banded = layout.height(of: text, width: width, band: band, topInset: body.topInset, measured: measured, exact: !provisional)
        else { return height(width: width) }
        provisional = true
        self.measured = (width, banded)
        return banded
    }

    override func pin(at y: CGFloat) {
        layout.pin(text, at: y, topInset: body.topInset)
    }

    override var pinShift: CGFloat {
        layout.pinShift(text)
    }

    override func viewFrame(in column: CGRect) -> CGRect {
        body.frame(in: column)
    }

    /// 容器跟着摆好的视图的宽（视图两边各伸出 inlineCodePadding），拖缝中留在原来的宽的除外。
    override func layoutView(in frame: CGRect) {
        guard !keepsContainer else { return }
        text.fit(lineWidth: max(frame.width - Metrics.inlineCodePadding * 2, 0))
    }
}

/// 一段 Markdown 排进原生文本视图，agent 的话和压缩摘要用：属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套。
/// 文本视图两边各伸出 inlineCodePadding 给行内代码背景留绘制余量，正文的宽和起点不变；开头是标题时上面多半个块距，同 SelectableMarkdown。
@MainActor final class MarkdownTextBlock {
    let text = ProseTextView.makeReadOnly()
    private let coordinator = ProseRowCoordinator()
    private let document = MarkdownDocument()
    private let attachments = BlockAttachments()
    private(set) var source: String?
    /// 嵌着块（代码、表格、分隔线）：块的宽跟着行宽变。
    private(set) var hasBlocks = false
    private var environment: EnvironmentValues?
    private var font: Font = .body
    private var color: NSColor = .label
    private(set) var topInset: CGFloat = 0
    /// 引用图标要加载的网址，变了才重新加载。
    private var urls: [URL] = []
    /// 排出来的高可能变了：附件变高、引用图标载完重排。
    var changed: (() -> Void)?
    /// 看着引用图标（ReferenceIcons），载完重排。
    private let tracking = ModelTracking()

    init() {
        text.textContainerInset = NSSize(width: Metrics.inlineCodePadding, height: 0)
        text.delegate = coordinator
        text.textLayoutManager?.delegate = coordinator
        coordinator.view = text
        coordinator.resized = { [weak self] in self?.changed?() }
    }

    /// 换上原文和环境：font 是正文的字号（对话里是正文，压缩摘要小一号），color 是正文的字色。
    func show(_ source: String, environment: EnvironmentValues, font: Font, color: NSColor) {
        coordinator.openURL = environment.openURL
        self.source = source
        self.environment = environment
        self.font = font
        self.color = color
        // 原文、环境换了，要看的引用图标跟着换
        tracking.cancel()
        build()
    }

    /// 按 source 和环境排出属性串。读了引用图标（ReferenceIcons），图标载完重排一次。
    private func build() {
        guard let source, let environment else { return }
        let content = tracking.track {
            let body = font.resolve(in: environment.fontResolutionContext).ctFont as NSFont
            let prose = SelectableMarkdown.prose(document.blocks(for: source), source: source, body: body, color: color,
                                                 environment: environment, attachments: attachments, loaded: &urls)
            topInset = prose.topInset
            return prose.content
        } changed: { [weak self] in
            // 通知在图标写进去之前发出，下一拍再按新的排
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                build()
                changed?()
            }
        }
        text.source = content.source
        hasBlocks = !content.blocks.isEmpty
        // 附件先换好内容再放字：放字时 TextKit 就会量附件的高
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(environment))
        coordinator.show(content.text)
    }

    /// 按这一段的宽整段排出来多高。
    func height(width: CGFloat) -> CGFloat {
        text.measure(lineWidth: width) + topInset
    }

    /// 文本视图在 column（这一段占的范围）里的 frame。
    func frame(in column: CGRect) -> CGRect {
        CGRect(x: column.minX - Metrics.inlineCodePadding, y: column.minY + topInset,
               width: column.width + Metrics.inlineCodePadding * 2, height: max(column.height - topInset, 0))
    }
}

#endif
