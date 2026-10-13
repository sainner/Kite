#if os(iOS)
import SwiftUI
import UIKit

/// 对话正文的 UIKit 文本视图（TextKit 2）：不可编辑，平时不开系统的选字，没有自己的滚动，也不接点状态栏回顶。
/// iPhone、iPad 的原生对话列表（PhoneTranscriptView）和 SwiftUI 里的 SelectableTextView 共用；触摸见 PhoneTextInteraction，
/// 补字、附件重排、装饰片段见 ProseTextCoordinator。拷贝给原文：有对照（TextSourceMap）时选区换成原文放进剪贴板，只放纯文本。
final class PhoneProseTextView: UITextView, TextKitMeasuring {
    var source: (text: String, map: TextSourceMap)?
    /// 原生对话列表里的：视图宽固定、只排露出来的那截，见 clipViewport。SwiftUI 里的不开。
    private(set) var clipsViewport = false
    /// 上次给 TextKit 的视口（自己的坐标）。外层滚动时露出来的那截还在里面就不用重排。
    private var viewport = CGRect.null
    /// 只露出上面这么高（自己的坐标），比如折着的长消息：底下被截住的不排。nil 是整个视图都可能露出来。
    var shownHeight: CGFloat? {
        didSet {
            guard shownHeight != oldValue, clipsViewport, #available(iOS 27.0, *) else { return }
            // 露出来的变多了（展开的动画中）：底下新露出来的要排
            if let shownHeight, !viewport.isNull, shownHeight <= viewport.maxY { return }
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    /// 视图固定的宽：最宽的内容列，连同两边给行内代码背景留的余量。
    static let widest = Metrics.transcriptWidth + Metrics.inlineCodePadding * 2

    /// TextKit 2 的一套自己搭，视图走指定构造器：UITextView(usingTextLayoutManager:) 走 UIKit 自己的构造路径，
    /// Swift 子类存储属性的初始值不会设上（shownHeight 读出来是 0 不是 nil，正文只排第一段，2026-10-13 iPad 真机）。
    /// 这一套由这个属性拿着：容器到排版管理器、排版管理器到内容存储都是弱引用，删掉它整套就没了。
    private var stack: (content: NSTextContentStorage, layout: NSTextLayoutManager)?

    /// TextKit 2，文本容器跟着视图宽度、不加边距。
    static func make() -> PhoneProseTextView {
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        let content = NSTextContentStorage()
        content.addTextLayoutManager(layout)
        content.primaryTextLayoutManager = layout
        let view = PhoneProseTextView(frame: .zero, textContainer: container)
        view.stack = (content, layout)
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        // 文本视图也是滚动视图：开着的话和列表一起算点状态栏回顶的候选，系统一个都不滚
        view.scrollsToTop = false
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainer.lineFragmentPadding = 0
        view.linkTextAttributes = [.foregroundColor: UIColor.link]
        return view
    }

    /// 原生对话列表里用，照 spikes/ios-native-transcript V1 的 H：关了滚动的 UITextView 一改 frame（宽或高）就把整段重设容器、重排，
    /// iPad 拖缝时这占了主线程的大头（2026-10-13 真机 Time Profiler：setFrame → _resyncContainerFrame → ensureLayout）。改成：
    /// - 开着滚动（容器不再跟着视图高），关掉它自己的拖动、滚动条、回弹和安全区边距，滚不动也不滚；
    /// - 视图宽固定成最宽的内容列，改宽、量高都只改容器宽，视图只改高；比字宽出来的那截不接触摸（point(inside:)）；
    /// - iOS 27 起覆写 viewportBounds(for:)，视口裁到外层可见区上下各半屏（拖缝中十分之一屏），外层滚出这截时再请它重排（outerScrolled）。
    ///   iOS 26 不会问，照旧按整个视图排。
    func clipViewport() {
        clipsViewport = true
        isScrollEnabled = true
        panGestureRecognizer.isEnabled = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = false
        contentInsetAdjustmentBehavior = .never
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        frame.size.width = Self.widest
    }

    /// 量高见 TextKitMeasuring：按 lineWidth 定容器的宽。
    /// - 列表里的（clipsViewport）只改容器，不动视图。
    /// - SwiftUI 里的视图宽先跟上（容器跟着视图宽度，设 frame 时会被改回 frame 的宽）；关了滚动的 UITextView 把容器高定成视图高，
    ///   量的时候放开，不然只排到视图那么高（spikes/ios-native-transcript V1）。
    func fit(lineWidth: CGFloat) {
        if !clipsViewport {
            let total = lineWidth + textContainerInset.left + textContainerInset.right
            if frame.width != total { frame.size.width = total }
        }
        let size = CGSize(width: lineWidth, height: .greatestFiniteMagnitude)
        if textContainer.size != size { textContainer.size = size }
    }

    /// 视图比字宽（固定成最宽的内容列），字以外的那截不接触摸，落到后面去。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard clipsViewport else { return super.point(inside: point, with: event) }
        let width = textContainerInset.left + textContainer.size.width + textContainerInset.right
        return point.x >= 0 && point.x < width && point.y >= 0 && point.y < bounds.height
    }

    /// 外面的滚动视图（对话列表；文本视图自己也是滚动视图，不算）。
    private var outerScroll: UIScrollView? {
        var current = superview
        while let view = current {
            if let scroll = view as? UIScrollView, !(view is UITextView) { return scroll }
            current = view.superview
        }
        return nil
    }

    /// 外层滚动区露出来的范围上下各加半屏，换到自己的坐标。拖缝、吸附中不加：多出来的每步都要跟着改宽重排，
    /// 也不能越过列表这时排准的那截（滚动区上下各加十分之一可见区，见 TranscriptArrangement.arrange 的 reach），越过的话补排的段落会叠上去。
    private var outerVisible: CGRect? {
        guard let outer = outerScroll else { return nil }
        let visible = outer.convert(outer.bounds, to: self)
        guard !WindowLayout.anyResizing else { return visible }
        return visible.insetBy(dx: 0, dy: -outer.bounds.height * TranscriptArrangement.margin)
    }

    @available(iOS 27.0, *)
    override func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let full = super.viewportBounds(for: textViewportLayoutController)
        guard clipsViewport, window != nil, var visible = outerVisible else {
            viewport = full
            return full
        }
        if let shownHeight { visible = visible.intersection(CGRect(x: visible.minX, y: 0, width: visible.width, height: shownHeight)) }
        let clipped = full.intersection(visible)
        viewport = clipped.isNull ? CGRect(x: full.minX, y: full.minY, width: full.width, height: 0) : clipped
        return viewport
    }

    /// 外层滚了、这一行挪了：露出来的那截出了上次的视口就请 TextKit 按新视口重排。折着的（shownHeight）只看截住以内的那截。
    func outerScrolled() {
        guard clipsViewport, #available(iOS 27.0, *), let outer = outerScroll else { return }
        var visible = outer.convert(outer.bounds, to: self).intersection(bounds)
        if let shownHeight { visible = visible.intersection(CGRect(x: visible.minX, y: 0, width: visible.width, height: shownHeight)) }
        // 只比上下：段落整行排，横着挪（拖缝时列跟着居中、行左右挪）不用重排
        guard !visible.isNull, visible.height > 0, !(viewport.minY <= visible.minY && viewport.maxY >= visible.maxY) else { return }
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// 改宽重排过（整段或一截）以后让 TextKit 的视口从新排的位置找起。视口记着上次排在顶上的那段和它的 y，
    /// 那段还在视口里时下次照旧摆回那个 y：上面的段落变高了它也不往下挪，和量出来的位置、高对不上，
    /// 行底下空出一截或露出别的段落（拖缝中，2026-10-14 iPad 真机）。
    func relocateViewport() {
        guard clipsViewport, #available(iOS 27.0, *), !viewport.isNull, let layout = textLayoutManager,
              let fragment = laidFragment(at: max(viewport.minY, 0)) else { return }
        layout.textViewportLayoutController.relocateViewport(to: fragment.rangeInElement.location)
    }

    /// 读屏的焦点框按字的宽：视图宽固定成最宽的内容列（clipViewport），iPhone 上比屏幕宽，框会伸出屏幕。
    override var accessibilityFrame: CGRect {
        get {
            guard clipsViewport else { return super.accessibilityFrame }
            let width = textContainerInset.left + textContainer.size.width + textContainerInset.right
            return UIAccessibility.convertToScreenCoordinates(CGRect(x: 0, y: 0, width: width, height: bounds.height), in: self)
        }
        set { super.accessibilityFrame = newValue }
    }

    /// 量出来的高取到像素，同原来 SwiftUI 版用的 sizeThatFits。
    var pixelScale: CGFloat { PhonePixel.scale }
    var measuresPixels: Bool { true }

    /// 排完版，嵌着的卡片看看露没露出来：TextKit 挪的是包着它们的排版片段，卡片自己收不到位置变了，见 EmbeddedContainerView。
    override func layoutSubviews() {
        super.layoutSubviews()
        // 开着滚动的（列表里的）字比视图先长出来的那一下，它会把自己往上滚去露出末尾；视图跟着变高前也不让它滚
        if clipsViewport, contentOffset != .zero { contentOffset = .zero }
        EmbeddedContainerView.synchronize(in: self)
    }

    override func copy(_ sender: Any?) {
        guard let source, let text = source.map.text(for: selectedRange, in: source.text) else { return super.copy(sender) }
        UIPasteboard.general.string = text
    }
}

/// 对话正文上的触摸，iPhone 和 iPad（触控板、鼠标同一套）一样。SwiftUI 的 Text 在 iPhone 上只能长按整段拷贝，不告诉手指下面是第几个字，
/// 也画不了选区，所以用文本视图自己协调：
/// - 点一下只处理链接与取消选区。平时没开系统的选字，链接自己不响应，按手指下的字命中。
/// - 长按不动显示操作栏（showActions）。长按期间对话不滚动，所以不和滚动抢。
/// - 长按以后接着拖就是选字：从按下的那个字选到手指下面，开始选时轻震一下、调 dismissActions（操作栏自己收起），
///   松手留着选区和系统的编辑菜单；系统自己清掉选区（点了别处、拷贝完）时关回平时的样子。
/// - 代码块、表格这类是附件（BlockAttachment）：在卡片上长按、点按、横滑都归卡片自己（长按弹操作栏），选字从正文拖起能拖过卡片。
/// - 平时不开系统的选字，免得长按、双击时它自己选一个词、弹出编辑菜单。
/// 手势挂在 host 上：agent 的话是文本视图自己；气泡是整个气泡，内边距、折叠按钮上长按也开操作栏（坐标换到文本视图里算）。
@MainActor final class PhoneTextInteraction: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate {
    private weak var text: UITextView?
    private weak var host: UIView?
    var openURL: (URL) -> Void = { _ in }
    var showActions: () -> Void = {}
    var dismissActions: () -> Void = {}
    /// iPad 上指针右键开关这一行的操作栏；原生对话列表给，SwiftUI 里没有。
    var secondaryClick: (() -> Void)? {
        didSet { secondary.isEnabled = secondaryClick != nil && enabled }
    }
    /// 关掉时点按、长按都不接：气泡浮上来的途中不能选字，同 Mac。
    var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            press.isEnabled = enabled
            tap.isEnabled = enabled
            secondary.isEnabled = secondaryClick != nil && enabled
            if !enabled { endSelection() }
        }
    }
    /// 只换颜色、重放同样的字时置上：重放引起的选区变化不当成系统清掉了选区。
    var refreshingAppearance = false
    private let press = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let secondary = UITapGestureRecognizer()
    private let menu = UIEditMenuInteraction(delegate: nil)
    /// 长按的地方和那里的字；接着拖挪过 slop 才算选字。
    private var start: CGPoint = .zero
    private var anchor: UITextPosition?
    private var selecting = false
    private static let slop: CGFloat = 8

    init(text: UITextView, host: UIView) {
        self.text = text
        self.host = host
        super.init()
        text.delegate = self
        press.addTarget(self, action: #selector(press(_:)))
        press.minimumPressDuration = 0.4
        press.allowableMovement = 8
        press.delegate = self
        host.addGestureRecognizer(press)
        tap.addTarget(self, action: #selector(tap(_:)))
        tap.require(toFail: press)
        tap.delegate = self
        host.addGestureRecognizer(tap)
        secondary.addTarget(self, action: #selector(secondaryTap(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.isEnabled = false
        host.addGestureRecognizer(secondary)
        text.addInteraction(menu)
    }

    /// 卡片上的触摸归卡片自己：横滑、按钮、长按弹操作栏都在 SwiftUI 里，这里的点按和长按选字不接。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let candidate = current, candidate !== host {
            if candidate is EmbeddedContainerView { return false }
            current = candidate.superview
        }
        return true
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let text else { return }
        dismissActions()
        // 有选区时点一下只是取消选区
        if text.selectedRange.length > 0 {
            endSelection()
            return
        }
        if let url = link(at: gesture.location(in: text)) { openURL(url) }
    }

    @objc private func secondaryTap(_ gesture: UITapGestureRecognizer) {
        secondaryClick?()
    }

    private func link(at point: CGPoint) -> URL? {
        guard let text, let range = text.characterRange(at: point) else { return nil }
        // 按手指下的字符命中，不用最近插入点，避免点在链接末字右半边时落到下一个字符。
        // UIKit 在文字以外也可能返回最近字符，要确认点在字上。
        guard text.firstRect(for: range).insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        let offset = text.offset(from: text.beginningOfDocument, to: range.start)
        guard offset >= 0, offset < text.attributedText.length else { return nil }
        return text.attributedText.attribute(.link, at: offset, effectiveRange: nil) as? URL
    }

    @objc private func press(_ gesture: UILongPressGestureRecognizer) {
        guard let text else { return }
        let point = gesture.location(in: text)
        switch gesture.state {
        case .began:
            endSelection()
            start = point
            anchor = text.closestPosition(to: point)
            selecting = false
            showActions()
        case .changed:
            if !selecting {
                guard hypot(point.x - start.x, point.y - start.y) > Self.slop else { return }
                selecting = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismissActions()
                text.isSelectable = true
                text.becomeFirstResponder()
            }
            guard let anchor, let current = text.closestPosition(to: point) else { return }
            let forward = text.compare(anchor, to: current) != .orderedDescending
            text.selectedTextRange = text.textRange(from: forward ? anchor : current, to: forward ? current : anchor)
        case .ended:
            // 松手留着选区，弹出系统的编辑菜单（拷贝、全选这些）
            if selecting, text.selectedRange.length > 0 {
                menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            } else if selecting {
                endSelection()
            }
            selecting = false
            anchor = nil
        default:
            dismissActions()
            if selecting { endSelection() }
            selecting = false
            anchor = nil
        }
    }

    /// 系统自己把选区清掉了（点了别处、拷贝完），关回平时的样子
    func textViewDidChangeSelection(_ view: UITextView) {
        guard !refreshingAppearance else { return }
        if !selecting, view.isSelectable, view.selectedRange.length == 0 { endSelection() }
    }

    func endSelection() {
        guard let text, text.isSelectable else { return }
        text.selectedTextRange = nil
        text.isSelectable = false
        text.resignFirstResponder()
    }
}
/// 原生对话列表按像素对齐尺寸：原来的 SwiftUI 版把每个视图的位置和大小都对到像素（3 倍屏上 1/3 pt），
/// 原生行的高、边距照样对齐，排出来才和原来逐像素一样（模拟器并排截屏对过）。
enum PhonePixel {
    /// 一点几个像素。还没进窗口时按当前的特征取，取不到按 3 倍屏算。
    static var scale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 3
    }

    /// 往上取到像素：量出来的高。
    static func ceil(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded(.up) / scale
    }

    /// 取最近的像素，正好一半时往大取：边距、位置，同 SwiftUI。
    static func round(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// 四条边各自对到最近的像素：SwiftUI 排版时位置、高都带着小数累加，画的时候才对齐，托管的行的高带小数时这样才对得上。
    static func align(_ rect: CGRect) -> CGRect {
        let minX = round(rect.minX), minY = round(rect.minY)
        return CGRect(x: minX, y: minY, width: round(rect.maxX) - minX, height: round(rect.maxY) - minY)
    }
}
#endif
