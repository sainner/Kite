#if os(iOS)
import SwiftUI
import UIKit

/// iOS 原生对话列表的行比共用的基类多几件事：放进列表时（didPlace）、收到内存警告放掉视图（releaseView）、操作栏（actionBar）。
protocol PhoneRowSlot: TranscriptRowSlot {
    /// 第一次放进文档以后：行里托管的 SwiftUI（附件、嵌在正文里的卡片这些）接进视图控制器的层级。
    func didPlace()
    /// 放掉视图，下次要时按内容重建；量过的高留着。
    func releaseView()
    /// 这一行的操作栏：和哪边对齐、上面的按钮。没有操作栏的行给 nil。Mac 的见 ActionBarProviding。
    func actionBar() -> (side: HorizontalEdge, content: AnyView)?
    /// 行里直接放着的文本视图，滚动时列表逐帧请它们看要不要按新视口重排；nil 表示不定，由列表往行的视图里找。
    var proseViews: [PhoneProseTextView]? { get }
}

extension PhoneRowSlot {
    func actionBar() -> (side: HorizontalEdge, content: AnyView)? { nil }
    var proseViews: [PhoneProseTextView]? { nil }
}

/// iOS 上按 slotKind（两端共用，见 TranscriptSlot）建这一行的实现。
@MainActor func makePhoneTranscriptRowSlot(_ row: TranscriptRow) -> TranscriptRowSlot {
    switch slotKind(row) {
    case .prose: PhoneProseRowSlot(row: row)
    case .bubble: PhoneBubbleRowSlot(row: row)
    case .work: PhoneWorkRowSlot(row: row)
    case .thinking: PhoneThinkingRowSlot(row: row)
    case .compaction: PhoneCompactedRowSlot(row: row)
    }
}

/// 这一行用的实现还能不能接着用：种类变了换一个新的。
@MainActor func phoneTranscriptRowSlotFits(_ slot: TranscriptRowSlot, _ row: TranscriptRow) -> Bool {
    switch slotKind(row) {
    case .prose: slot is PhoneProseRowSlot
    case .bubble: slot is PhoneBubbleRowSlot
    case .work: slot is PhoneWorkRowSlot
    case .thinking: slot is PhoneThinkingRowSlot
    case .compaction: slot is PhoneCompactedRowSlot
    }
}

/// agent 说的一段话：原生文本视图，属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套，触摸同 PhoneTextInteraction：
/// 长按开操作栏（复制、翻译、分叉，和这段话左边对齐），接着拖是选字；iPad 指针右键开关操作栏。
/// 文本视图两边各伸出 inlineCodePadding 给行内代码背景留绘制余量，正文的宽和起点不变；开头是标题时上面多半个块距，同 SelectableMarkdown。
final class PhoneProseRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var text: PhoneProseTextView?
    var proseViews: [PhoneProseTextView]? { text.map { [$0] } ?? [] }
    private var interaction: PhoneTextInteraction?
    private let coordinator = ProseTextCoordinator()
    private let document = MarkdownDocument()
    private let attachments = BlockAttachments()
    /// 这段话的原文，操作栏复制它。
    private(set) var source: String?
    /// 生成中：新放出来的字淡入。
    private var streaming = false
    private var context: TranscriptRowContext?
    private var topInset: CGFloat = 0
    /// 引用图标要加载的网址，变了才重新加载。
    private var urls: [URL] = []
    /// 看着引用图标（ReferenceIcons），载完重排。
    private let tracking = ModelTracking()
    /// 拖缝时只排一截、按住看着的那截，两端共用。量过的高作废时跟着作废。
    private let layout = ProseLayout()

    override var measured: (width: CGFloat, height: CGFloat)? {
        didSet { if measured == nil { layout.invalidate() } }
    }

    override init(row: TranscriptRow) {
        super.init(row: row)
        coordinator.resized = { [weak self] in
            guard let self else { return }
            measured = nil
            heightChanged?(nil)
        }
    }

    override var hasView: Bool { text != nil }
    override var view: UIView { textView }

    /// 文本视图，第一次要时建（量高也要它），放掉以后再要时重建、重放字。
    private var textView: PhoneProseTextView {
        if let text { return text }
        let text = PhoneProseTextView.make()
        text.clipViewport()
        text.textContainerInset = UIEdgeInsets(top: 0, left: Metrics.inlineCodePadding, bottom: 0, right: Metrics.inlineCodePadding)
        // 行内代码的底色、引用的竖线由自己的排版片段画，要在放字之前接上
        text.textLayoutManager?.delegate = coordinator
        coordinator.view = text
        self.text = text
        interaction = PhoneTextInteraction(text: text, host: text)
        configure()
        build()
        // 放掉以后重建的（内存警告）：量过的高留着，没人再量，行宽按上次量的给回去
        if let measured { text.fit(lineWidth: measured.width) }
        return text
    }

    /// 主对话里 agent 的话：复制、翻译、分叉，和这段话左边对齐。
    func actionBar() -> (side: HorizontalEdge, content: AnyView)? {
        guard let context, context.actionable, let source else { return nil }
        return (.leading, AnyView(AgentTextActions(text: source).environment(\.self, context.environment)))
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .text(let source) = item.kind else { return }
        self.context = context
        // 生成中：半截的 Markdown 先按写完的样子显示，新放出来的字淡入
        streaming = row.streamingText
        self.source = streaming ? StreamingMarkdown.settle(source) : source
        // 原文、环境换了，要看的引用图标跟着换
        tracking.cancel()
        guard text != nil else { return }
        configure()
        build()
    }

    /// 触摸、读屏接上这一行的环境：链接交给 SwiftUI 的 openURL（文件引用与网页由 ReferenceNavigation 在 Kite 里打开）。
    private func configure() {
        guard let context, let interaction, let text else { return }
        let id = row.id
        let openURL = context.environment.openURL
        interaction.openURL = { openURL($0) }
        interaction.showActions = { if context.actionable { context.select(id) } }
        interaction.dismissActions = { context.select(nil) }
        interaction.secondaryClick = context.actionable ? { context.toggleActions(id) } : nil
        text.accessibilityCustomActions = context.actionable
            ? [UIAccessibilityCustomAction(name: TranscriptSpeech.actions) { _ in context.select(id); return true }] : nil
    }

    /// 按 source 和环境排出属性串。读了引用图标（ReferenceIcons），图标载完重排一次。
    private func build() {
        guard let source, let context, let text else { return }
        let environment = context.environment
        let content = tracking.track { () -> TextViewContent in
            let body = (environment.font ?? .body).resolve(in: environment.fontResolutionContext).ctFont as UIFont
            let prose = SelectableMarkdown.prose(document.blocks(for: source), source: source, body: body, color: .label,
                                                 environment: environment, attachments: attachments, loaded: &urls)
            topInset = prose.topInset
            return prose.content
        } changed: { [weak self] in
            // 通知在图标写进去之前发出，下一拍再按新的排
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                measured = nil
                build()
                heightChanged?(nil)
            }
        }
        text.source = content.source
        // 附件先换好内容再放字：放字时 TextKit 就会量附件的高。卡片内容区长按开这一行的操作栏
        let id = row.id
        var embedded = environment
        let longPress: @MainActor () -> Void = { context.select(id) }
        embedded.blockCardLongPress = context.actionable ? longPress : nil
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(embedded))
        coordinator.show(content.text, fading: streaming) { interaction?.refreshingAppearance = $0 }
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional { return measured.height }
        if let kept = keptHeight(width) { return kept }
        let lineWidth = resizeLineWidth(width)
        let rewrapped = laidLineWidth != lineWidth
        layout.settle(textView)
        let height = textView.measure(lineWidth: lineWidth) + topInset
        if rewrapped { textView.relocateViewport() }
        // 拖缝中整段排过：之后只排一截时按这次的段高估没排的
        if resizing { layout.remember(textView, width: lineWidth) }
        provisional = lineWidth != width
        measured = (width, height)
        return height
    }

    /// 拖缝时只排 band 那一截，见 ProseLayout；这截占了大半行时整段排。
    override func height(width: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        if let kept = keptHeight(width) { return kept }
        guard let measured,
              let banded = layout.height(of: textView, width: width, band: band, topInset: topInset, measured: measured, exact: !provisional)
        else { return height(width: width) }
        textView.relocateViewport()
        provisional = true
        self.measured = (width, banded)
        return banded
    }

    // MARK: 拖缝中少排

    /// 拖缝中字还放得下新的列宽就先不按新宽重排（拖缝中允许暂时不精确，停下后按精确的重量，同气泡的 unwrapped）：
    /// 列变宽时字比列窄，右边多出一截空白；列变窄时字伸进右边的留白一点。超出这些才重排，每步省下文本视图的重排和重画
    /// （iPad 真机拖缝每步约一半的主线程在这上面）。每行的余量错开一点，免得几行挤在同一步重排。
    private func keptHeight(_ width: CGFloat) -> CGFloat? {
        guard resizing, let measured, let laid = laidLineWidth, rewrap.keeps(laid: laid, width: width) else { return nil }
        // 停着时整段排准的：先记下段高，之后只排一截时用（标成不准以后 ProseLayout 不会再记）
        if !provisional, let text { layout.remember(text, width: laid) }
        provisional = true
        self.measured = (width, measured.height)
        return measured.height
    }

    /// 拖缝中重排时排多宽：列变窄时比列再窄一截，接下来几步不用再排（见 keptHeight），别的时候按列宽。
    private func resizeLineWidth(_ width: CGFloat) -> CGFloat {
        guard resizing, let laid = laidLineWidth else { return width }
        return rewrap.narrowed(width, from: laid)
    }

    /// 文本视图眼下排的行宽。
    private var laidLineWidth: CGFloat? {
        guard let width = text?.textContainer.size.width, width > 0, width < .greatestFiniteMagnitude else { return nil }
        return width
    }

    private lazy var rewrap = ResizeRewrap(self)

    override func pin(at y: CGFloat) {
        guard let text else { return }
        layout.pin(text, at: y, topInset: topInset)
    }

    override var pinShift: CGFloat {
        text.map { layout.pinShift($0) } ?? 0
    }

    /// 视图宽固定（见 PhoneProseTextView.clipViewport），字排在容器的宽里：改宽时视图不变，只有容器变。
    override func viewFrame(in column: CGRect) -> CGRect {
        let column = textColumn(column)
        return CGRect(x: column.minX - Metrics.inlineCodePadding, y: column.minY + topInset,
                      width: PhoneProseTextView.widest, height: column.height - topInset)
    }

    func didPlace() {}

    func releaseView() {
        interaction?.endSelection()
        text = nil
        interaction = nil
        coordinator.view = nil
        coordinator.shown = nil
        layout.invalidate()
        attachments.releaseHosts()
    }
}

/// 托管的视图挂进列表所在的视图控制器：菜单、分享这类要弹出界面的按钮才找得到从哪弹（同 BlockAttachment.adopt）。
@MainActor func adopt(_ controller: UIViewController) {
    var responder: UIResponder? = controller.view.superview
    while let current = responder, !(current is UIViewController) { responder = current.next }
    guard let parent = responder as? UIViewController, controller.parent !== parent else { return }
    controller.willMove(toParent: nil)
    controller.removeFromParent()
    parent.addChild(controller)
    controller.didMove(toParent: parent)
}


/// 拖缝中「差得不多先不重新断行」的余量（正文见 PhoneProseRowSlot.keptHeight，还有折着的长消息、折了行的事件）：
/// 列变宽时字比列窄，右边多出一截空白；列变窄时字伸进右边的留白一点。每个持有者按自己的身份错开一点，免得几行挤在同一步重排。
struct ResizeRewrap {
    /// 0～1。
    private let spread: CGFloat

    init(_ owner: AnyObject) {
        spread = CGFloat(UInt(bitPattern: ObjectIdentifier(owner).hashValue) % 1009) / 1009
    }

    /// Debug 带 --exact-resize 时拖缝中每步照旧按新宽重排，对照用。
    private static let exact: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--exact-resize")
        #else
        false
        #endif
    }()

    /// 按 laid 宽排好的字换到 width 还算放得下。
    func keeps(laid: CGFloat, width: CGFloat) -> Bool {
        !Self.exact && (width >= laid ? width - laid <= 16 + 16 * spread : laid - width <= 2 + 6 * spread)
    }

    /// 要重排时排多宽：比 laid 窄时再窄一截，接下来几步不用再排，别的时候按 width。
    func narrowed(_ width: CGFloat, from laid: CGFloat) -> CGFloat {
        !Self.exact && width < laid ? max(width - 8 - 8 * spread, width * 0.85) : width
    }
}
#endif
