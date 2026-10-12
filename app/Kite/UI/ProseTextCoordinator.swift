import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformTextView = UITextView
#else
import AppKit
typealias PlatformTextView = NSTextView
#endif

/// 对话正文文本视图（Mac 的 MacSelectableTextView、iPhone 的 PhoneSelectableTextView）共用的协调器：流式只补末尾的字、
/// 按宽度记下量过的尺寸、附件变高后重排那一段、行内代码和引用的装饰片段。平台的子类只管建视图、整段重设、手势、链接与复制。
/// 只碰 textStorage 和 textLayoutManager：读 layoutManager 会让视图退回 TextKit 1。
class ProseTextCoordinator: NSObject, NSTextLayoutManagerDelegate {
    weak var view: PlatformTextView?
    /// 文本视图里现在放的字。换了就是排版变了。
    var shown: NSAttributedString? { didSet { revision += 1 } }
    /// 放的字换了、附件的高变了各加一，量过的尺寸跟着作废。按它比，不对整段属性串逐个比。
    private var revision = 0
    private var sizedFor: SizeKey?
    /// 量过的尺寸，按给的宽度记。
    private var sizes: [CGFloat?: CGSize] = [:]

    /// 两端的 textStorage 只差可选性。
    private var storage: NSTextStorage? { view?.textStorage }

    /// 量出的尺寸取决于这些；变了就重新量。字号还跟着动态字体和粗体文字的设置变。
    private struct SizeKey: Equatable {
        let revision: Int
        let inset: CGSize
        let typeSize: DynamicTypeSize
        let weight: LegibilityWeight?
    }

    /// 新串只是旧串原样接着往后长时，只往 textStorage 末尾补字，TextKit 2 从编辑处起重排；选区在前面的字上，不动它。
    /// 流式回复每次整段重设会让 TextKit 2 把整段从头重排，iPhone 真机上卡几百毫秒（2026-10-11 Time Profiler）。
    /// 前缀用 isEqual 连属性一起比：装饰按值比，但引用图标的 NSTextAttachment 按身份比，带图标的段落走整段重设，接受。
    /// 补了返回 true；不是接着长的返回 false，由调用方整段重设。
    func appendTail(of text: NSAttributedString) -> Bool {
        guard let old = shown, text.length > old.length,
              text.attributedSubstring(from: NSRange(location: 0, length: old.length)).isEqual(to: old) else { return false }
        let added = text.attributedSubstring(from: NSRange(location: old.length, length: text.length - old.length))
        storage?.replaceCharacters(in: NSRange(location: old.length, length: 0), with: added)
        shown = text
        return true
    }

    /// 按给的宽度取量过的尺寸，没量过就量一次记下。SwiftUI 一次排版会用几种宽度把每段字各量几遍
    /// （Mac 实验里问 78 次只有 21 种宽度），每量一次 TextKit 都把这段字从头排一遍。
    func size(inset: CGSize, environment: EnvironmentValues, width: CGFloat?, measure: () -> CGSize?) -> CGSize? {
        let key = SizeKey(revision: revision, inset: inset, typeSize: environment.dynamicTypeSize, weight: environment.legibilityWeight)
        if sizedFor != key {
            sizedFor = key
            sizes = [:]
        }
        if let size = sizes[width] { return size }
        guard let size = measure() else { return nil }
        sizes[width] = size
        return size
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

    /// 附件的高变了：重排它所在的那一段，作废量过的尺寸，请 SwiftUI 再量一次。
    private func relayout(_ changed: [BlockAttachment]) {
        revision += 1
        guard let view, let layout = view.textLayoutManager, let storage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? BlockAttachment, changed.contains(where: { $0 === attachment }),
                  let start = layout.location(layout.documentRange.location, offsetBy: range.location),
                  let end = layout.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layout.invalidateLayout(for: textRange)
        }
        #if canImport(UIKit)
        view.setNeedsLayout()
        #else
        view.needsLayout = true
        view.needsDisplay = true
        #endif
        view.invalidateIntrinsicContentSize()
    }

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        DecoratedFragment.fragment(for: textElement)
    }
}
