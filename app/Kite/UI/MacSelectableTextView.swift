#if os(macOS)
import AppKit
import SwiftUI

/// AppKit 的文本视图（TextKit 2），Mac 上对话正文选字、点链接用它：不可编辑、可选，没有自己的滚动视图，
/// 滚轮穿过去给外层的对话滚动；高度按给定宽度量出来。SwiftUI 的 Text 不支持跨 Text 选字，连两个段落都选不到一起。
/// 右键不在这里接：opensActionBar 的盖层只对右键和 Control+左键命中，左键拖选、链接点击、悬停光标照常到这里
/// （三种挂法的结论见 spikes/mac-textkit-prose/README.md）。没有盖层的地方右键是 NSTextView 自己的菜单。
/// 气泡上浮时按 messageTextSelectable 关掉选字，和 MessageBubble 的约定一致。
/// 代码块、表格这类是附件（BlockAttachment），它们的内容和环境在这里交给附件；复制给原文（TextSourceMap）。
/// 补字、量尺寸、附件重排与 iPhone 共用，见 ProseTextCoordinator。
/// fillsWidth：占满给的宽度；不然贴着字的宽度，长的折行。
struct SelectableTextView: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    let content: TextViewContent
    let inset: CGSize
    let fillsWidth: Bool

    private var text: NSAttributedString { content.text }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = ProseTextView.make()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // 悬停不显示 URL 提示，也不自动识别链接、补全，样子和 SwiftUI 的 Text 一样
        view.displaysLinkToolTips = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.usesFontPanel = false
        // 链接不画下划线，颜色是系统 link 色（SwiftUI 的 Text 也用它，不是主题色），光标是手形
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        // 行内代码的底色、引用的竖线由自己的排版片段画，要在放字之前接上
        view.textLayoutManager?.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        view.textContainerInset = NSSize(width: inset.width, height: inset.height)
        view.isSelectable = context.environment.messageTextSelectable
        (view as? ProseTextView)?.source = content.source
        // 附件先换好内容再放字：放字时 TextKit 就会量附件的高
        context.coordinator.update(content.blocks, environment: EmbeddedEnvironment(context.environment))
        guard context.coordinator.shown != text, !context.coordinator.appendTail(of: text) else { return }
        // 外观变化时也换掉已经解析成 CGColor 的装饰；只换颜色时保留选区。
        let textChanged = context.coordinator.shown?.string != text.string
        let selection = view.selectedRange()
        context.coordinator.shown = text
        view.textStorage?.setAttributedString(text)
        if !textChanged { view.setSelectedRange(selection) }
    }

    /// 高度照文本视图自己排出来的算，量过的按给的宽度记下。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        context.coordinator.size(inset: inset, environment: context.environment, width: proposal.width) {
            guard let view = view as? ProseTextView else { return nil }
            let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            let most = max((proposed ?? .greatestFiniteMagnitude) - inset.width * 2, 0)
            let width = fillsWidth && proposed != nil ? most : ProseTextCoordinator.naturalWidth(of: text, most: most)
            // SwiftUI 之后会按返回的尺寸再设一次 frame
            return CGSize(width: width + inset.width * 2, height: view.measure(lineWidth: width) + inset.height * 2)
        }
    }

    final class Coordinator: ProseTextCoordinator, NSTextViewDelegate {
        var parent: SelectableTextView?

        /// 链接交给 SwiftUI 的 openURL：文件引用由 ReferenceNavigation 打开，网页交给系统。
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            parent?.openURL(url)
            return true
        }
    }
}

/// 露出任何一部分就把整段当作视口。TextKit 2 的 NSTextView 只排、只画 visibleRect 里的片段，而这里的 visibleRect 是外层
/// SwiftUI 滚动视图的可见区：往上滚时新露出的一条先露底部，视口从中间起，前面的片段按估算高度占位，画出来的字整体
/// 比真实位置高几十 pt、底下留白，等滚到顶上重排才跳回去，看起来就是先空白、再逐段入场（2026-10-12 离屏实测，
/// 视口从中间起时渲染面比片段高 70 pt）。整段作视口后片段从头排、位置准确；没露出时照旧空视口，不给屏幕外的字留渲染面。
/// 只扩到露出的底边（视口逐帧长）实测冷滚丢帧反而更多，所以一露出就整段。
/// 复制给原文：有对照时选区换成原文写进剪贴板（拷贝、拖出、服务都走这里），只写纯文本。
final class ProseTextView: NSTextView {
    var source: (text: String, map: TextSourceMap)?
    /// 右键或按住 Control 点击打开这一行的操作栏；没有时右键是文本视图自己的菜单。原生对话列表给（见 TranscriptRowSlots）。
    var secondaryClick: (() -> Void)?
    /// 视口只给露出来的那截。原生对话列表的行放进列表前已经整段排好（见 TranscriptRowSlot.height），视口从中间起也按排好的位置找片段，
    /// 不会出现上面说的错位；屏外那截不建渲染面，拖缝时每帧省下整段的视口维护。SwiftUI 里懒加载的行没排就露出，仍整段作视口。
    var clipsViewport = false

    /// TextKit 2，文本容器跟着视图宽度、不加边距。
    static func make() -> ProseTextView {
        let view = ProseTextView(usingTextLayoutManager: true)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        return view
    }

    /// 刚排好的各行里最宽的一行有多宽（排版坐标），按它算贴着字的宽度：和 NSAttributedString 的 boundingRect 量的一样，
    /// 但不用再按最优断行把全文排一遍（长消息改宽时每次几毫秒，2026-10-13 实测）。
    var widestLine: CGFloat {
        guard let layout = textLayoutManager else { return 0 }
        var widest: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            let origin = fragment.layoutFragmentFrame.minX
            for line in fragment.textLineFragments {
                widest = max(widest, origin + line.typographicBounds.maxX)
            }
            return true
        }
        return widest
    }

    /// 按 lineWidth 的行宽排出来多高（不含上下边距）。文本容器跟着视图宽度时，先把宽度放上去再量。
    func measure(lineWidth: CGFloat) -> CGFloat {
        guard let layout = textLayoutManager, let container = textContainer else { return 0 }
        let total = lineWidth + textContainerInset.width * 2
        if container.widthTracksTextView, frame.width != total { setFrameSize(NSSize(width: total, height: frame.height)) }
        if container.size.width != lineWidth { container.size = NSSize(width: lineWidth, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: layout.documentRange)
        return ceil(layout.usageBoundsForTextContainer.height)
    }

    override var visibleRect: NSRect {
        // AppKit 的裁切矩形可能非空但完全落在本视图之外，要先与自身范围相交。
        let visible = super.visibleRect.intersection(bounds)
        if visible.isEmpty { return .zero }
        return clipsViewport ? visible : bounds
    }

    // 光标：NSTextView 把整块注册成文字光标的光标矩形，鼠标移动、cursorUpdate 时也设文字光标，盖过卡片里按钮的手形。
    // 文字光标只给卡片以外的那几条，落在卡片上的移动交给卡片自己。

    /// 嵌着的卡片在这个视图里的位置。
    private var cards: [NSRect] {
        var frames: [NSRect] = []
        func collect(_ view: NSView) {
            for child in view.subviews {
                if child is EmbeddedContainerView { frames.append(child.convert(child.bounds, to: self)) } else { collect(child) }
            }
        }
        collect(self)
        return frames
    }

    override func resetCursorRects() {
        let cards = cards.sorted { $0.minY < $1.minY }
        guard !cards.isEmpty else { return super.resetCursorRects() }
        var top = bounds.minY
        for card in cards {
            if card.minY > top { addCursorRect(NSRect(x: bounds.minX, y: top, width: bounds.width, height: card.minY - top), cursor: .iBeam) }
            top = max(top, card.maxY)
        }
        if bounds.maxY > top { addCursorRect(NSRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top), cursor: .iBeam) }
    }

    /// 卡片随排版挪动，光标矩形跟着重算。
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    private func overCard(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return cards.contains { $0.contains(point) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let secondaryClick { secondaryClick() } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if let secondaryClick, event.modifierFlags.contains(.control) { secondaryClick() } else { super.mouseDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if !overCard(event) { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !overCard(event) { super.cursorUpdate(with: event) }
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        source == nil ? super.writablePasteboardTypes : [.string]
    }

    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let source, let text = source.map.text(for: selectedRange(), in: source.text) else {
            return super.writeSelection(to: pasteboard, types: types)
        }
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(text, forType: .string)
    }
}

#endif
