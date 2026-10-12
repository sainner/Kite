#if os(macOS)
import AppKit
import SwiftUI

/// AppKit 的文本视图（TextKit 2），Mac 上对话正文选字、点链接用它：不可编辑、可选，没有自己的滚动视图，
/// 滚轮穿过去给外层的对话滚动；高度按给定宽度量出来。SwiftUI 的 Text 不支持跨 Text 选字，连两个段落都选不到一起。
/// 右键不在这里接：opensActionBar 的盖层只对右键和 Control+左键命中，左键拖选、链接点击、悬停光标照常到这里
/// （三种挂法的结论见 spikes/mac-textkit-prose/README.md）。没有盖层的地方右键是 NSTextView 自己的菜单。
/// 气泡上浮时按 messageTextSelectable 关掉选字，和 MessageBubble 的约定一致。
/// fillsWidth：占满给的宽度；不然贴着字的宽度，长的折行。
struct SelectableTextView: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    let text: NSAttributedString
    let inset: CGSize
    let fillsWidth: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = ProseTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
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
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        view.textContainerInset = NSSize(width: inset.width, height: inset.height)
        view.isSelectable = context.environment.messageTextSelectable
        guard context.coordinator.shown != text else { return }
        // 流式回复每次整段重设会让 TextKit 2 从头重排。新串只是旧串原样接着往后长时，只往 textStorage 末尾补字，
        // TextKit 2 从编辑处起重排；选区在前面的字上，不动它。
        // 前缀用 isEqual 连属性一起比：装饰按值比，但引用图标的 NSTextAttachment 按身份比，带图标的段落会落到下面的整段路径，接受。
        // 只能碰 textStorage，读 layoutManager 会让视图退回 TextKit 1。
        if let old = context.coordinator.shown, text.length > old.length,
           text.attributedSubstring(from: NSRange(location: 0, length: old.length)).isEqual(to: old) {
            let added = text.attributedSubstring(from: NSRange(location: old.length, length: text.length - old.length))
            view.textStorage?.replaceCharacters(in: NSRange(location: old.length, length: 0), with: added)
            context.coordinator.shown = text
            return
        }
        // 外观变化时也换掉已经解析成 CGColor 的装饰；只换颜色时保留选区。
        let textChanged = context.coordinator.shown?.string != text.string
        let selection = view.selectedRange()
        context.coordinator.shown = text
        view.textStorage?.setAttributedString(text)
        if !textChanged { view.setSelectedRange(selection) }
    }

    /// 高度照文本视图自己排出来的算。量过的按给的宽度记下：SwiftUI 一次排版会用几种宽度把每段字各量几遍
    /// （实验里问 78 次只有 21 种宽度），每量一次 TextKit 都把这段字从头排一遍。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let key = SizeKey(text: text, inset: inset)
        if context.coordinator.sizedFor != key {
            context.coordinator.sizedFor = key
            context.coordinator.sizes = [:]
        }
        if let size = context.coordinator.sizes[proposal.width] { return size }
        guard let layout = view.textLayoutManager, let container = view.textContainer else { return nil }
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let most = max((proposed ?? .greatestFiniteMagnitude) - inset.width * 2, 0)
        var width = most
        if !fillsWidth || proposed == nil {
            let natural = text.boundingRect(with: CGSize(width: most, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            // 多留一点，免得文本视图排出来比量的宽、多折一行
            width = min(ceil(natural.width) + 1, most)
        }
        // 文本容器跟着视图宽度，先把宽度放上去再量；SwiftUI 之后会按返回的尺寸再设一次 frame
        let total = width + inset.width * 2
        if view.frame.width != total { view.setFrameSize(NSSize(width: total, height: view.frame.height)) }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        let size = CGSize(width: total, height: ceil(layout.usageBoundsForTextContainer.height) + inset.height * 2)
        context.coordinator.sizes[proposal.width] = size
        return size
    }

    /// 露出任何一部分就把整段当作视口。TextKit 2 的 NSTextView 只排、只画 visibleRect 里的片段，而这里的 visibleRect 是外层
    /// SwiftUI 滚动视图的可见区：往上滚时新露出的一条先露底部，视口从中间起，前面的片段按估算高度占位，画出来的字整体
    /// 比真实位置高几十 pt、底下留白，等滚到顶上重排才跳回去，看起来就是先空白、再逐段入场（2026-10-12 离屏实测，
    /// 视口从中间起时渲染面比片段高 70 pt）。整段作视口后片段从头排、位置准确；没露出时照旧空视口，不给屏幕外的字留渲染面。
    /// 只扩到露出的底边（视口逐帧长）实测冷滚丢帧反而更多，所以一露出就整段。
    private final class ProseTextView: NSTextView {
        override var visibleRect: NSRect { super.visibleRect.isEmpty ? .zero : bounds }
    }

    /// 量出的尺寸取决于这些；变了就重新量。
    struct SizeKey: Equatable {
        let text: NSAttributedString
        let inset: CGSize
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate {
        var parent: SelectableTextView?
        /// 文本视图里现在放的字。
        var shown: NSAttributedString?
        /// 量过的尺寸，按给的宽度记。
        var sizedFor: SizeKey?
        var sizes: [CGFloat?: CGSize] = [:]

        /// 链接交给 SwiftUI 的 openURL：文件引用由 ReferenceNavigation 打开，网页交给系统。
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            parent?.openURL(url)
            return true
        }

        nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                           in textElement: NSTextElement) -> NSTextLayoutFragment {
            DecoratedFragment.fragment(for: textElement)
        }
    }
}
#endif
