import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformTextView = UITextView

extension UITextView {
    /// 文本容器在视图里的原点，同 NSTextView 的 textContainerOrigin。
    var textContainerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }
}
#else
import AppKit
typealias PlatformTextView = NSTextView
#endif

extension NSTextLayoutManager {
    /// 文本里 range 那一段（按 UTF-16 数）在 TextKit 2 里的范围。
    func textRange(for range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

/// 对话正文文本视图（Mac 的 ProseTextView、iOS 的 PhoneProseTextView）共用的协调器：流式只补末尾的字、新字淡入、
/// 附件变高后重排那一段、行内代码和引用的装饰片段。两端原生列表的行和 Mac 的表格卡片各持一个。
/// 只碰 textStorage 和 textLayoutManager：读 layoutManager 会让视图退回 TextKit 1。
class ProseTextCoordinator: NSObject, NSTextLayoutManagerDelegate {
    weak var view: PlatformTextView? {
        didSet {
            fade.view = view
            if view == nil { fade.stop() }
        }
    }
    /// 附件变高、重排了那一段以后调：原生行借它重新量高（文本视图自己改尺寸时不调）。
    var resized: (() -> Void)?
    /// 文本视图里现在放的字。
    var shown: NSAttributedString?

    /// 生成中新放出来的字淡入。
    private let fade = StreamFade()

    /// 两端的 textStorage 只差可选性。
    private var storage: NSTextStorage? { view?.textStorage }

    /// 新串只是旧串原样接着往后长时，只往 textStorage 末尾补字，TextKit 2 从编辑处起重排；选区在前面的字上，不动它。
    /// 流式回复每次整段重设会让 TextKit 2 把整段从头重排，iPhone 真机上卡几百毫秒（2026-10-11 Time Profiler）。
    /// 前缀用 isEqual 连属性一起比：装饰按值比，但引用图标的 NSTextAttachment 按身份比，带图标的段落走整段重设，接受。
    /// 补了返回 true；不是接着长的返回 false，由 show 整段重设。
    private func appendTail(of text: NSAttributedString) -> Bool {
        guard let old = shown, text.length > old.length,
              text.attributedSubstring(from: NSRange(location: 0, length: old.length)).isEqual(to: old) else { return false }
        let added = text.attributedSubstring(from: NSRange(location: old.length, length: text.length - old.length))
        storage?.replaceCharacters(in: NSRange(location: old.length, length: 0), with: added)
        shown = text
        return true
    }

    /// 放字：接着长的只补末尾，否则整段重设。外观变化时也换掉已经解析成 CGColor 的装饰；字没变、只换颜色时保留选区。
    /// refreshingAppearance 在整段重设前后各调一次（只换外观时先给真、换完给假），iOS 的交互借它不把这次重设当成取消选择。
    /// fading：生成中，接着原来的字长出来的那截淡入；之前没放过字的（回复刚开头）整段淡入，已经写了一大段的（打开时正在生成）直接显示。
    func show(_ text: NSAttributedString, fading: Bool = false, refreshingAppearance: (Bool) -> Void = { _ in }) {
        guard shown != text else { return }
        let old = shown
        let appended = appendTail(of: text)
        if !appended { replace(with: text, refreshingAppearance: refreshingAppearance) }
        fade.clamp(to: text.length)
        guard fading else { return }
        if let old {
            if appended || text.length > old.length && text.string.hasPrefix(old.string) {
                fade.add(NSRange(location: old.length, length: text.length - old.length))
            }
        } else if text.length <= 400 {
            fade.add(NSRange(location: 0, length: text.length))
        }
    }

    /// 整段重设。
    private func replace(with text: NSAttributedString, refreshingAppearance: (Bool) -> Void) {
        guard let view else { return }
        let textChanged = shown?.string != text.string
        shown = text
        #if canImport(UIKit)
        let selection = view.selectedRange
        let selectable = view.isSelectable
        refreshingAppearance(!textChanged)
        view.attributedText = text
        if !textChanged {
            view.isSelectable = selectable
            view.selectedRange = selection
        }
        refreshingAppearance(false)
        #else
        let selection = view.selectedRange()
        view.textStorage?.setAttributedString(text)
        if !textChanged { view.setSelectedRange(selection) }
        #endif
    }

    /// 不占满时贴着字的宽度，最多 most。多留一点，免得文本视图排出来比量的宽、多折一行。
    static func naturalWidth(of text: NSAttributedString, most: CGFloat) -> CGFloat {
        let natural = text.boundingRect(with: CGSize(width: most, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return min(ceil(natural.width) + 1, most)
    }

    /// 把内容和环境交给附件。附件的高可能变了（流式时代码越来越长）就重排那一块：字没变时只有这一步，
    /// 后面接着补了字的，只补末尾的排版不会回头重排前面的附件。
    func update(_ blocks: [(attachment: BlockAttachment, content: EmbeddedBlock)], environment: EmbeddedEnvironment) {
        var changed: [BlockAttachment] = []
        for (attachment, content) in blocks {
            attachment.resized = { [weak self] in self?.relayout([$0]) }
            if attachment.update(content, environment: environment) { changed.append(attachment) }
        }
        if !changed.isEmpty, shown != nil { relayout(changed) }
    }

    /// 附件的高变了：重排它所在的那一段，告诉行重新量高。
    private func relayout(_ changed: [BlockAttachment]) {
        guard let view, let layout = view.textLayoutManager, let storage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? BlockAttachment, changed.contains(where: { $0 === attachment }),
                  let textRange = layout.textRange(for: range) else { return }
            layout.invalidateLayout(for: textRange)
        }
        #if canImport(UIKit)
        view.setNeedsLayout()
        #else
        view.needsLayout = true
        view.needsDisplay = true
        #endif
        view.invalidateIntrinsicContentSize()
        resized?()
    }

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        DecoratedFragment.fragment(for: textElement)
    }
}
