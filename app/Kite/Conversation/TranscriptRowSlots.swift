#if os(macOS)
import AppKit
import SwiftUI

/// 原生对话列表里一行要用的外部环境。
struct TranscriptRowContext {
    /// 字体、外观、引用范围、打开链接、选中的行等，主对话的 SwiftUI 环境整份转交。
    var environment: EnvironmentValues
    /// 点 agent 的话弹出操作栏，见 TranscriptView.actionable。
    var actionable: Bool
    /// 右键开关这一行的操作栏。
    var toggleActions: (RowID) -> Void
}

/// 原生对话列表（TranscriptListView）里的一行：内容、量过的高、视图。
/// 视图只在可见区附近时放进列表：AppKit 改动一个视图在窗口里的位置时要通知它整棵子树，拖缝时每帧都在挪（2026-10-13 实测，
/// 一个长会话的行全建成视图时每步比按需只建可见区附近多约 8 ms）。
@MainActor class TranscriptRowSlot {
    let id: RowID
    private(set) var row: TranscriptRow
    /// 量过的：按哪个内容宽、多高。内容变了作废。
    var measured: (width: CGFloat, height: CGFloat)?
    /// 在文档里占的范围（内容列的宽），排列时算出来。
    var frame = CGRect.zero
    /// 自己变高变矮（展开收起、附件量完）时告诉列表。
    var heightChanged: (() -> Void)?

    init(row: TranscriptRow) {
        id = row.id
        self.row = row
    }

    /// 视图建好了没有。没建过的行按估的高占位。
    var hasView: Bool { false }
    /// 视图，第一次要时建。
    var view: NSView { preconditionFailure("子类给出") }

    /// 换上这一行的新内容和环境。resized：内容或外观变了，量过的高作废；只是选中的行、刚发出的消息变了时不作废。
    func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        self.row = row
        if resized { measured = nil }
    }

    /// 按内容列的宽量出多高，量过同宽的直接给。
    func height(width: CGFloat) -> CGFloat { 0 }

    /// 视图在文档里的 frame：column 是这一行在内容列里占的范围。
    func viewFrame(in column: CGRect) -> CGRect { column }
}

/// 一行该用哪种实现：agent 的话原生排，其余先托管原来的 SwiftUI 行视图。
@MainActor func makeTranscriptRowSlot(_ row: TranscriptRow) -> TranscriptRowSlot {
    if case .item(let item) = row.content, case .text = item.kind { return ProseRowSlot(row: row) }
    return HostedRowSlot(row: row)
}

/// 这一行用的实现还能不能接着用：种类变了换一个新的。
@MainActor func transcriptRowSlotFits(_ slot: TranscriptRowSlot, _ row: TranscriptRow) -> Bool {
    if case .item(let item) = row.content, case .text = item.kind { return slot is ProseRowSlot }
    return slot is HostedRowSlot
}

/// agent 说的一段话：原生文本视图，属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套。
/// 文本视图两边各伸出 inlineCodePadding 给行内代码背景留绘制余量，正文的宽和起点不变；开头是标题时上面多半个块距，同 SelectableMarkdown。
final class ProseRowSlot: TranscriptRowSlot {
    private let text = ProseTextView()
    private let coordinator = ProseRowCoordinator()
    private let document = MarkdownDocument()
    private let attachments = BlockAttachments()
    /// 这段话的原文，操作栏复制它。
    private(set) var source: String?
    private var environment: EnvironmentValues?
    private var topInset: CGFloat = 0
    /// 引用图标要加载的网址，变了才重新加载。
    private var urls: [URL] = []

    override init(row: TranscriptRow) {
        super.init(row: row)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: Metrics.inlineCodePadding, height: 0)
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
        text.contentResized = { [weak self] in
            guard let self else { return }
            measured = nil
            heightChanged?()
        }
    }

    override var hasView: Bool { true }
    override var view: NSView { text }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .text(let source) = item.kind else { return }
        coordinator.openURL = context.environment.openURL
        let id = row.id
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
                self.heightChanged?()
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
        if let measured, measured.width == width { return measured.height }
        guard let layout = text.textLayoutManager else { return 0 }
        text.lineWidth(width)
        layout.ensureLayout(for: layout.documentRange)
        let height = ceil(layout.usageBoundsForTextContainer.height) + topInset
        measured = (width, height)
        return height
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
            TranscriptRowView(row: row, actionable: context.actionable)
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
        heightChanged?()
    }
}
/// 托管的行按内容的理想高报尺寸、贴顶摆：量高时给无限高也只报内容多高（不然 maxHeight 无限的框会把无限高原样报回来），
/// 内容自己变高、列表还没跟上的那一帧往下伸，不居中。
private struct HostedRowFrame: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
#endif
