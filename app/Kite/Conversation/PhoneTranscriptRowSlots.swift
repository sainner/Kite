#if os(iOS)
import SwiftUI
import UIKit

/// iOS 原生对话列表的行比共用的基类多两件事：放进列表时（didPlace）、收到内存警告放掉视图（releaseView）。
protocol PhoneRowSlot: TranscriptRowSlot {
    /// 第一次放进文档以后：托管的视图接进视图控制器的层级。
    func didPlace()
    /// 放掉视图，下次要时按内容重建；量过的高留着。
    func releaseView()
}

/// iOS 上按 slotKind（两端共用，见 TranscriptSlot）建这一行的实现。
@MainActor func makePhoneTranscriptRowSlot(_ row: TranscriptRow) -> TranscriptRowSlot {
    switch slotKind(row) {
    case .prose: PhoneProseRowSlot(row: row)
    case .bubble: PhoneBubbleRowSlot(row: row)
    case .work: PhoneHostedRowSlot(row: row)
    case .thinking: PhoneHostedRowSlot(row: row)
    case .hosted: PhoneHostedRowSlot(row: row)
    }
}

/// 这一行用的实现还能不能接着用：种类变了换一个新的。
@MainActor func phoneTranscriptRowSlotFits(_ slot: TranscriptRowSlot, _ row: TranscriptRow) -> Bool {
    switch slotKind(row) {
    case .prose: slot is PhoneProseRowSlot
    case .bubble: slot is PhoneBubbleRowSlot
    case .work, .thinking, .hosted: slot is PhoneHostedRowSlot
    }
}

/// agent 说的一段话：原生文本视图，属性串、附件、装饰、复制原文都和 SelectableMarkdown 共用一套，触摸同 PhoneTextInteraction：
/// 长按开操作栏（复制、翻译、分叉，和这段话左边对齐），接着拖是选字；iPad 指针右键开关操作栏。
/// 文本视图两边各伸出 inlineCodePadding 给行内代码背景留绘制余量，正文的宽和起点不变；开头是标题时上面多半个块距，同 SelectableMarkdown。
final class PhoneProseRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var text: PhoneProseTextView?
    private var interaction: PhoneTextInteraction?
    private let coordinator = ProseTextCoordinator()
    private let document = MarkdownDocument()
    private let attachments = BlockAttachments()
    /// 这段话的原文，操作栏复制它。
    private(set) var source: String?
    private var context: TranscriptRowContext?
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
        text.textContainerInset = UIEdgeInsets(top: 0, left: Metrics.inlineCodePadding, bottom: 0, right: Metrics.inlineCodePadding)
        // 行内代码的底色、引用的竖线由自己的排版片段画，要在放字之前接上
        text.textLayoutManager?.delegate = coordinator
        coordinator.view = text
        self.text = text
        interaction = PhoneTextInteraction(text: text, host: text)
        configure()
        build()
        return text
    }

    /// 主对话里 agent 的话：复制、翻译、分叉，和这段话左边对齐。
    override func actionBar() -> (side: HorizontalEdge, content: AnyView)? {
        guard let context, context.actionable, let source else { return nil }
        return (.leading, AnyView(AgentTextActions(text: source).environment(\.self, context.environment)))
    }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext, resized: Bool) {
        super.update(row, context: context, resized: resized)
        guard case .item(let item) = row.content, case .text(let source) = item.kind else { return }
        self.context = context
        self.source = source
        guard text != nil else { return }
        configure()
        build()
    }

    /// 触摸、读屏接上这一行的环境：链接交给 SwiftUI 的 openURL（文件引用由 ReferenceNavigation 打开，网页交给系统）。
    private func configure() {
        guard let context, let interaction, let text else { return }
        let id = row.id
        let openURL = context.environment.openURL
        interaction.openURL = { openURL($0) }
        interaction.showActions = { if context.actionable { context.select(id) } }
        interaction.dismissActions = { context.select(nil) }
        interaction.secondaryClick = context.actionable ? { context.toggleActions(id) } : nil
        text.accessibilityCustomActions = context.actionable
            ? [UIAccessibilityCustomAction(name: "显示操作") { _ in context.select(id); return true }] : nil
    }

    /// 按 source 和环境排出属性串。读了引用图标（ReferenceIcons），图标载完重排一次。
    private func build() {
        guard let source, let context, let text else { return }
        let environment = context.environment
        let content = withObservationTracking { () -> TextViewContent in
            let blocks = document.blocks(for: source)
            let body = (environment.font ?? .body).resolve(in: environment.fontResolutionContext).ctFont as UIFont
            topInset = SelectableMarkdown.startsWithHeading(blocks) ? PhonePixel.round(Metrics.markdownBlockGap(body.pointSize) / 2) : 0
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
        // 附件先换好内容再放字：放字时 TextKit 就会量附件的高。卡片内容区长按开这一行的操作栏
        let id = row.id
        var embedded = environment
        let longPress: @MainActor () -> Void = { context.select(id) }
        embedded.blockCardLongPress = context.actionable ? longPress : nil
        coordinator.update(content.blocks, environment: EmbeddedEnvironment(embedded))
        guard coordinator.shown != content.text, !coordinator.appendTail(of: content.text) else { return }
        // 外观变化时也换掉已经解析成 CGColor 的装饰；只换颜色时保留选区。
        let textChanged = coordinator.shown?.string != content.text.string
        let selection = text.selectedRange
        let selectable = text.isSelectable
        interaction?.refreshingAppearance = !textChanged
        coordinator.shown = content.text
        text.attributedText = content.text
        if !textChanged {
            text.isSelectable = selectable
            text.selectedRange = selection
        }
        interaction?.refreshingAppearance = false
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width, !provisional { return measured.height }
        let height = textView.measure(lineWidth: width) + topInset
        provisional = false
        measured = (width, height)
        return height
    }

    /// 拖缝时只排 band 那一截，见 ProseLayout；这截占了大半行时整段排。
    override func height(width: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        guard let measured,
              let banded = layout.height(of: textView, width: width, band: band, topInset: topInset, measured: measured, exact: !provisional)
        else { return height(width: width) }
        provisional = true
        self.measured = (width, banded)
        return banded
    }

    override func pin(at y: CGFloat) {
        guard let text else { return }
        layout.pin(text, at: y, topInset: topInset)
    }

    override var pinShift: CGFloat {
        text.map { layout.pinShift($0) } ?? 0
    }

    override func viewFrame(in column: CGRect) -> CGRect {
        CGRect(x: column.minX - Metrics.inlineCodePadding, y: column.minY + topInset,
               width: column.width + Metrics.inlineCodePadding * 2, height: column.height - topInset)
    }

    func didPlace() {}

    func releaseView() {
        interaction?.endSelection()
        text = nil
        interaction = nil
        coordinator.view = nil
        coordinator.shown = nil
        layout.invalidate()
    }
}

/// 还没原生化的行：托管原来的 SwiftUI 行视图。只在可见区附近才建；内容自己变高变矮时由 onGeometryChange 报回来。
final class PhoneHostedRowSlot: TranscriptRowSlot, PhoneRowSlot {
    private var controller: UIHostingController<AnyView>?
    private var context: TranscriptRowContext?

    override var hasView: Bool { controller != nil }
    override var hosted: Bool { true }

    override var view: UIView {
        if let controller { return controller.view }
        let controller = UIHostingController(rootView: root())
        controller.sizingOptions = []
        // 不让安全区挤进来，背景透出窗口的点阵
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
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
        // 高留着小数，同 SwiftUI 版：位置累加完再对到像素，见 PhoneTranscriptView.realize
        let height = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        measured = (width, height)
        return height
    }

    /// 排好以后报来的高：和量的不一样（自己展开收起了）就请列表重排。
    private func reported(_ height: CGFloat) {
        guard let measured, measured.width == frame.width, abs(measured.height - height) > 0.5 else { return }
        self.measured = (measured.width, height)
        heightChanged?(nil)
    }

    func didPlace() {
        if let controller { adopt(controller) }
    }

    func releaseView() {
        controller?.willMove(toParent: nil)
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
        controller = nil
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

#endif
