import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 嵌在对话正文里的一块：回复里的代码块、表格、分隔线，用户消息里的代码块。
enum EmbeddedBlock: Equatable {
    case markdown(MarkdownBlock)
    case userCode(String, language: String?)

    /// 同一种块换内容时复用附件和宿主（流式时代码越来越长），换了种类就另建。
    func sameKind(as other: EmbeddedBlock) -> Bool {
        switch (self, other) {
        case (.markdown(let a), .markdown(let b)):
            switch (a.kind, b.kind) {
            case (.code, .code), (.table, .table), (.rule, .rule): true
            default: false
            }
        case (.userCode, .userCode): true
        default: false
        }
    }
}

/// 嵌进来的块排在自己的 SwiftUI 宿主里，读不到文本视图外面的环境；它们用到的几项由文本视图转交。
struct EmbeddedEnvironment {
    var font: Font?
    var referenceScope: ReferenceScope
    var toast: ToastCenter?
    var openURL: OpenURLAction
    #if os(iOS)
    var longPress: (@MainActor () -> Void)?
    #endif

    init(_ values: EnvironmentValues) {
        font = values.font
        referenceScope = values.referenceScope
        toast = values.toast
        openURL = values.openURL
        #if os(iOS)
        longPress = values.blockCardLongPress
        #endif
    }

    /// 变了会影响排出来多高的几项。
    func sameLayout(as other: EmbeddedEnvironment) -> Bool {
        font == other.font && referenceScope == other.referenceScope
    }
}

/// 文本里的一个附件字符，显示成一块 SwiftUI 视图：照旧用 MarkdownBlockView、CodeBlock 排，外观、折叠、横滑、按钮都和原来一样。
/// 宽是所在行的宽，高是 SwiftUI 的理想高；内容自己变高（展开全部、表格量完宽）时通知文本视图重排这一行。
/// 代码块、表格太宽时横着滚，高和行宽无关，量一次就记下：改窗口宽度时不用每种宽度都再量一遍。
/// 附件和宿主跨流式更新复用：属性串里的附件按身份比较，内容变了属性串不变，文本视图不用重放字，宿主里的状态（展开、横滑位置）也留着。
/// NSTextAttachment 不归主线程，TextKit 的回调在文本视图排版时进来，也就是主线程；宿主和状态都标在主线程上。
nonisolated final class BlockAttachment: NSTextAttachment {
    @MainActor private(set) var content: EmbeddedBlock
    @MainActor private var environment: EmbeddedEnvironment?
    #if canImport(UIKit)
    @MainActor private lazy var controller: UIHostingController<EmbeddedBlockView> = {
        let controller = UIHostingController(rootView: root)
        // 尺寸由 TextKit 按 attachmentBounds 摆，宿主不自己报尺寸，也不让安全区挤进来
        controller.sizingOptions = []
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        return controller
    }()
    #else
    @MainActor private lazy var controller: NSHostingController<EmbeddedBlockView> = {
        let controller = NSHostingController(rootView: root)
        // 尺寸由 TextKit 按 attachmentBounds 摆，宿主不自己报尺寸，也不让安全区挤进来
        controller.sizingOptions = []
        controller.safeAreaRegions = []
        return controller
    }()
    #endif
    /// 量过的理想高。
    @MainActor private var height: CGFloat?
    /// 最近一次排在多宽的行里。
    @MainActor private var width: CGFloat?
    /// 内容自己变了高，文本视图要重排这一块。
    @MainActor var resized: ((BlockAttachment) -> Void)?

    @MainActor init(content: EmbeddedBlock) {
        self.content = content
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// 换内容或环境。返回 true 表示排出来的高可能变了，文本视图要重排这一块。
    @MainActor func update(_ content: EmbeddedBlock, environment: EmbeddedEnvironment) -> Bool {
        let layout = content != self.content || !(self.environment.map { $0.sameLayout(as: environment) } ?? false)
        guard layout || self.environment == nil else { return false }
        self.content = content
        self.environment = environment
        height = nil
        render()
        return layout
    }

    @MainActor private var root: EmbeddedBlockView {
        EmbeddedBlockView(content: content, environment: environment) { [weak self] size in
            self?.laidOut(size)
        }
    }

    @MainActor private func render() {
        controller.rootView = root
    }

    /// TextKit 会给这一行换新的提供者（实测流式在它后面接字时会换），每个提供者一个容器；宿主只有一个，
    /// 哪个容器进了窗口就挪进去，状态（展开、横滑位置）跟着宿主走。
    @MainActor fileprivate func adopt(into container: EmbeddedContainerView) {
        #if canImport(UIKit)
        // UIKit 的 view 是隐式解包的可选值，AppKit 不是
        let view: PlatformView = controller.view
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
        }
        // 挂进视图控制器的层级，ShareLink 这类要弹出界面的按钮才找得到从哪弹
        var responder: UIResponder? = container.superview
        while let current = responder, !(current is UIViewController) { responder = current.next }
        if let parent = responder as? UIViewController, controller.parent !== parent {
            controller.willMove(toParent: nil)
            controller.removeFromParent()
            parent.addChild(controller)
            controller.didMove(toParent: parent)
        }
        #else
        container.host(controller.view)
        #endif
    }

    /// 底边对齐到这一行字的下沿，行高就是块的高：字体的下伸部分不再在块下面多出一截。
    @MainActor fileprivate func bounds(descent: CGFloat, lineWidth: CGFloat) -> CGRect {
        CGRect(x: 0, y: -descent, width: lineWidth, height: measure(width: lineWidth))
    }

    /// TextKit 的回调里换到主线程量：先取出这一行字体的下伸和段落缩进，附件自己按身份传过去（回调本来就在主线程）。
    /// TextKit 给的行宽是整个文本容器的，不减段落缩进（嵌套列表里的块）。
    fileprivate static func bounds(of attachment: NSTextAttachment?, attributes: [NSAttributedString.Key: Any], lineWidth: CGFloat) -> CGRect {
        let descent = (attributes[.font] as? PlatformFont).map { abs($0.descender) } ?? 0
        let indent = (attributes[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        nonisolated(unsafe) let attachment = attachment as? BlockAttachment
        return MainActor.assumeIsolated { attachment?.bounds(descent: descent, lineWidth: max(lineWidth - indent, 0)) ?? .zero }
    }

    /// 附件那一段用的字体：字号极小，这一行的高就是块的高，分隔线这种比字矮的块不被字撑高。
    @MainActor static let lineFont = PlatformFont.systemFont(ofSize: 0.1)

    @MainActor private func measure(width: CGFloat) -> CGFloat {
        self.width = width
        if let height { return height }
        if environment == nil { render() }
        let height = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        self.height = height
        return height
    }

    /// 宿主按摆好的宽排完以后报来的理想高；和量的不一样（自己展开了、表格量完宽）就请文本视图重排。
    @MainActor private func laidOut(_ size: CGSize) {
        guard let width, abs(size.width - width) < 0.5, let height, abs(height - size.height) > 0.5 else { return }
        self.height = size.height
        resized?(self)
    }

    // 边界由提供者给：附件自己覆写 attachmentBounds 时 TextKit 不再走视图这条路；提供者不开 tracksTextAttachmentViewBounds 时
    // TextKit 不问它的边界、按默认的 32×32 摆（2026-10-12 macOS 27.2 实测）。
    #if canImport(UIKit)
    override func viewProvider(for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = BlockAttachmentViewProvider(textAttachment: self, parentView: parentView,
                                                   textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
    #else
    override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = BlockAttachmentViewProvider(textAttachment: self, parentView: parentView,
                                                   textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
    #endif
}

/// 一个提供者的容器：TextKit 按附件的边界摆它，它进了窗口就把附件的宿主接过来；iPhone 上顺带把宿主挂进视图控制器的层级。
final class EmbeddedContainerView: PlatformView {
    weak var attachment: BlockAttachment?

    #if canImport(UIKit)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { attachment?.adopt(into: self) }
    }
    #else
    private weak var hostedView: NSView?
    private weak var clipView: NSClipView?
    private var synchronizingHost = false

    override var isFlipped: Bool { true }

    func host(_ view: NSView) {
        hostedView = view
        view.autoresizingMask = []
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        synchronizeHost()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachment?.adopt(into: self) }
        synchronizeHost()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        synchronizeHost()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeHost()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        synchronizeHost()
    }

    override func layout() {
        synchronizeHost()
        super.layout()
    }

    private func observeClip(_ clip: NSClipView?) {
        guard clipView !== clip else { return }
        if let previous = clipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: previous)
        }
        clipView = clip
        if let clip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        synchronizeHost()
    }

    private func synchronizeHost() {
        guard !synchronizingHost else { return }
        // TextKit 换提供者后，旧容器的滚动通知不能再改已经迁走的宿主。
        guard let hostedView, hostedView.superview === self else {
            observeClip(nil)
            return
        }
        synchronizingHost = true
        defer { synchronizingHost = false }

        let clip = window == nil ? nil : enclosingScrollView?.contentView
        observeClip(clip)
        // 长回复仍由 TextKit 排整段；屏外附件只保留行边界和宿主状态，不逐帧重排内部 SwiftUI。
        if let clip, !convert(bounds, to: clip).intersects(clip.bounds) {
            if !hostedView.isHidden { hostedView.isHidden = true }
            return
        }

        // 滚入视口时先跟上最新边界再显示，容器与附件高度始终仍由 TextKit 管理。
        if hostedView.frame != bounds { hostedView.frame = bounds }
        if hostedView.isHidden { hostedView.isHidden = false }
    }
    #endif
}

#if canImport(UIKit)
typealias PlatformView = UIView
#else
typealias PlatformView = NSView
#endif

nonisolated private final class BlockAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        nonisolated(unsafe) let provider = self
        nonisolated(unsafe) let attachment = textAttachment as? BlockAttachment
        MainActor.assumeIsolated {
            let container = EmbeddedContainerView()
            container.attachment = attachment
            provider.view = container
        }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        BlockAttachment.bounds(of: textAttachment, attributes: attributes, lineWidth: proposedLineFragment.width)
    }
}

/// 一个文本视图里的附件，按第几个嵌入块复用：流式更新时同一块还是同一个附件。
final class BlockAttachments {
    private var list: [BlockAttachment] = []

    func attachment(_ ordinal: Int, for content: EmbeddedBlock) -> BlockAttachment {
        if ordinal < list.count, list[ordinal].content.sameKind(as: content) { return list[ordinal] }
        let attachment = BlockAttachment(content: content)
        if ordinal < list.count { list[ordinal] = attachment } else { list.append(attachment) }
        return attachment
    }

    /// content 作为下一个附件字符接在 result 末尾，自成一段，记进 embedded。返回这一段的属性：段尾的换行也用它，换行的字体不把这一行撑高。
    func embed(_ content: EmbeddedBlock, paragraph: NSParagraphStyle, into result: NSMutableAttributedString,
               embedded: inout [(attachment: BlockAttachment, content: EmbeddedBlock)]) -> [NSAttributedString.Key: Any] {
        let attachment = attachment(embedded.count, for: content)
        embedded.append((attachment, content))
        let attributes: [NSAttributedString.Key: Any] = [.font: BlockAttachment.lineFont, .paragraphStyle: paragraph]
        let part = NSMutableAttributedString(attachment: attachment)
        part.addAttributes(attributes, range: NSRange(location: 0, length: part.length))
        result.append(part)
        return attributes
    }
}

/// 宿主里的根视图：块本身，量理想高。卡片底色是半透明的，选区拖过时文本视图的选区色从底下透出来，不另外上色。
struct EmbeddedBlockView: View {
    let content: EmbeddedBlock
    let environment: EmbeddedEnvironment?
    let laidOut: (CGSize) -> Void

    var body: some View {
        block
            // 高取理想高，不随给的高伸缩：量的时候给的是无限高
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { laidOut($0) }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(EmbeddedEnvironmentModifier(environment: environment))
    }

    @ViewBuilder
    private var block: some View {
        switch content {
        case .markdown(let block):
            MarkdownBlockView(block: block)
        case .userCode(let text, let language):
            // 整条消息统一折叠；代码不再单独截断，展开全文后一次看完。
            CodeBlock(text: text, language: language, maxLines: nil, background: Theme.userCodeBackground,
                      radius: Metrics.nestedRadius(inset: Metrics.bubblePadding.height))
                .foregroundStyle(Color.primary)
        }
    }
}

private struct EmbeddedEnvironmentModifier: ViewModifier {
    let environment: EmbeddedEnvironment?

    func body(content: Content) -> some View {
        if let environment {
            content
                .font(environment.font)
                .environment(\.referenceScope, environment.referenceScope)
                .environment(\.toast, environment.toast)
                .environment(\.openURL, environment.openURL)
                #if os(iOS)
                .environment(\.blockCardLongPress, environment.longPress)
                #endif
        } else {
            content
        }
    }
}
