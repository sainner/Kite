#if os(macOS)
import AppKit
import SwiftUI

/// Mac 上按 slotKind（两端共用，见 TranscriptSlot）建这一行的实现。共用层记作托管的几种（kite、事件、压缩分界）Mac 上都已原生，按记录的种类分。
@MainActor func makeTranscriptRowSlot(_ row: TranscriptRow) -> TranscriptRowSlot {
    switch slotKind(row) {
    case .prose: ProseRowSlot(row: row)
    case .bubble: BubbleRowSlot(row: row)
    case .work: WorkRowSlot(row: row)
    case .thinking: ThinkingRowSlot(row: row)
    case .hosted:
        switch NativeKind(row) {
        case .kite: KiteRowSlot(row: row)
        case .compaction: CompactionRowSlot(row: row)
        case .event: EventRowSlot(row: row)
        }
    }
}

/// 这一行用的实现还能不能接着用：种类变了换一个新的。
@MainActor func transcriptRowSlotFits(_ slot: TranscriptRowSlot, _ row: TranscriptRow) -> Bool {
    switch slotKind(row) {
    case .prose: slot is ProseRowSlot
    case .bubble: slot is BubbleRowSlot
    case .work: slot is WorkRowSlot
    case .thinking: slot is ThinkingRowSlot
    case .hosted:
        switch NativeKind(row) {
        case .kite: slot is KiteRowSlot
        case .compaction: slot is CompactionRowSlot
        case .event: slot is EventRowSlot
        }
    }
}

/// 共用层记作托管的那几种在 Mac 上各用哪个原生行。
private enum NativeKind {
    case kite, compaction, event

    init(_ row: TranscriptRow) {
        switch row.content {
        case .item(let item):
            switch item.kind {
            case .kite: self = .kite
            case .compacted: self = .compaction
            default: self = .event
            }
        case .message: self = .event
        }
    }
}

/// agent 说的一段话：原生文本视图，属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套（见 MarkdownTextBlock）。
final class ProseRowSlot: TranscriptRowSlot {
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

    override init(row: TranscriptRow) {
        super.init(row: row)
        body.changed = { [weak self] in
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
        let id = row.id
        actionable = context.actionable
        text.secondaryClick = context.actionable ? { context.toggleActions(id) } : nil
        environment = context.environment
        body.show(source, environment: context.environment, font: context.environment.font ?? .body, color: .label)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional { return measured.height }
        let height = body.height(width: width)
        provisional = false
        measured = (width, height)
        return height
    }

    /// 拖缝时只排 band 那一截，见 ProseLayout；这截占了大半行时整段排。
    override func height(width: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
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
}

/// 一段 Markdown 排进原生文本视图，agent 的话和压缩摘要用：属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套。
/// 文本视图两边各伸出 inlineCodePadding 给行内代码背景留绘制余量，正文的宽和起点不变；开头是标题时上面多半个块距，同 SelectableMarkdown。
@MainActor final class MarkdownTextBlock {
    let text = ProseTextView.makeReadOnly()
    private let coordinator = ProseRowCoordinator()
    private let document = MarkdownDocument()
    private let attachments = BlockAttachments()
    private(set) var source: String?
    private var environment: EnvironmentValues?
    private var font: Font = .body
    private var color: NSColor = .label
    private(set) var topInset: CGFloat = 0
    /// 引用图标要加载的网址，变了才重新加载。
    private var urls: [URL] = []
    /// 排出来的高可能变了：附件变高、引用图标载完重排。
    var changed: (() -> Void)?

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
        build()
    }

    /// 按 source 和环境排出属性串。读了引用图标（ReferenceIcons），图标载完重排一次。
    private func build() {
        guard let source, let environment else { return }
        let content = withObservationTracking {
            let blocks = document.blocks(for: source)
            let body = font.resolve(in: environment.fontResolutionContext).ctFont as NSFont
            topInset = SelectableMarkdown.startsWithHeading(blocks) ? Metrics.markdownBlockGap(body.pointSize) / 2 : 0
            let urls = blocks.flatMap { ReferenceText.decorate($0.text, scope: environment.referenceScope).runs.compactMap(\.link) }
            if urls != self.urls {
                self.urls = urls
                Task { await ReferenceIcons.shared.load(urls) }
            }
            return SelectableMarkdown.content(blocks, source: source, body: body, color: color, colorScheme: environment.colorScheme,
                                              scope: environment.referenceScope, attachments: attachments)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.build()
                self.changed?()
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

/// 链接交给 SwiftUI 的 openURL：文件引用由 ReferenceNavigation 打开，网页交给系统。同 SelectableTextView.Coordinator。
final class ProseRowCoordinator: ProseTextCoordinator, NSTextViewDelegate {
    var openURL: OpenURLAction?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        openURL?(url)
        return true
    }
}
#endif
