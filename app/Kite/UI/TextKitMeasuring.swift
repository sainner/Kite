import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 对话正文的文本视图（TextKit 2）两端共用的量高：按行宽量高、只排一截、找已经排好的段落、贴字的宽。
/// Mac 的 ProseTextView 遵循它；iOS 原生对话的正文以后也遵循，两端的原生列表按同一套量。
/// 只碰 textLayoutManager：读 layoutManager 会让视图退回 TextKit 1。改容器的宽（fit）各端自己实现。
protocol TextKitMeasuring: AnyObject {
    var textLayoutManager: NSTextLayoutManager? { get }
    /// 按 lineWidth 定容器的宽；文本容器跟着视图宽度时先把视图的宽放上去。
    func fit(lineWidth: CGFloat)
    /// 量出来的高往上取整到多细：一点分成几份。Mac 取整点（原来 SwiftUI 版量的就是整点）；iOS 取到像素，
    /// 同原来 SwiftUI 版用的 UITextView.sizeThatFits（一行 17 pt 正文 20.33 pt，取整点要高出 0.67 pt）。
    var heightRounding: CGFloat { get }
}

extension TextKitMeasuring {
    var heightRounding: CGFloat { 1 }

    /// 按 heightRounding 往上取整。
    func roundedHeight(_ height: CGFloat) -> CGFloat {
        ceil(height * heightRounding) / heightRounding
    }

    /// 刚排好的各行里最宽的一行有多宽（排版坐标），按它算贴着字的宽度：和 NSAttributedString 的 boundingRect 量的一样，
    /// 但不用再按最优断行把全文排一遍（长消息改宽时每次几毫秒，2026-10-13 实测）。
    var widestLine: CGFloat {
        guard let layout = textLayoutManager else { return 0 }
        var widest: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            guard fragment.state == .layoutAvailable else { return true }
            let origin = fragment.layoutFragmentFrame.minX
            for line in fragment.textLineFragments {
                widest = max(widest, origin + line.typographicBounds.maxX)
            }
            return true
        }
        return widest
    }

    /// 刚排好的折没折行（不止一行）。
    var wraps: Bool {
        guard let layout = textLayoutManager else { return false }
        var count = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            if fragment.state == .layoutAvailable { count += fragment.textLineFragments.count }
            return count < 2
        }
        return count > 1
    }

    /// 刚排好的段落里有没有被行宽折下来的（一段排成了不止一行）。没有的话，行宽只要还放得下最宽的那行，排出来都一样。
    var softWraps: Bool {
        guard let layout = textLayoutManager else { return false }
        var wrapped = false
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            if fragment.state == .layoutAvailable, fragment.textLineFragments.count > 1 { wrapped = true }
            return !wrapped
        }
        return wrapped
    }

    /// 按 lineWidth 的行宽排出来多高（不含上下边距）。
    func measure(lineWidth: CGFloat) -> CGFloat {
        guard let layout = textLayoutManager else { return 0 }
        fit(lineWidth: lineWidth)
        layout.ensureLayout(for: layout.documentRange)
        return roundedHeight(layout.usageBoundsForTextContainer.height)
    }

    /// 改到 lineWidth 的行宽，从 location 那段起边排边往下，排够 height 高为止（排版坐标）。改宽让整段作废后只排这一截：
    /// 上面没排的段落 TextKit 按估的高占位，所以这截的位置是估的，从它往下才排准；往上再补排会和这截叠在一起，不会把它往下推。
    /// 长回复、折着的长消息拖缝时用（2026-10-13 离屏实测，7.5 万字整段重排约 35 ms，只排 1400 pt 约 1.9 ms）。返回这截的上下沿和最后一段的结束位置。
    func measure(lineWidth: CGFloat, from location: NSTextLocation, through height: CGFloat)
        -> (top: CGFloat, bottom: CGFloat, end: NSTextLocation)? {
        guard let layout = textLayoutManager else { return nil }
        fit(lineWidth: lineWidth)
        var top: CGFloat?
        var bottom: CGFloat = 0
        var end = location
        layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let first = top ?? frame.minY
            top = first
            bottom = frame.maxY
            end = fragment.rangeInElement.endLocation
            return bottom < first + height
        }
        return top.map { ($0, bottom, end) }
    }

    /// 已经排好的段落里 y 处（排版坐标）那一段，落在段间空隙时取下面那段。不触发排版。
    func laidFragment(at y: CGFloat) -> NSTextLayoutFragment? {
        guard let layout = textLayoutManager else { return nil }
        var found: NSTextLayoutFragment?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            guard fragment.state == .layoutAvailable, fragment.layoutFragmentFrame.maxY > y else { return true }
            found = fragment
            return false
        }
        return found
    }

    /// location 起头的那一段排好了的话在哪（排版坐标）。不触发排版。
    func laidFrame(at location: NSTextLocation) -> CGRect? {
        var frame: CGRect?
        textLayoutManager?.enumerateTextLayoutFragments(from: location, options: []) { fragment in
            if fragment.state == .layoutAvailable { frame = fragment.layoutFragmentFrame }
            return false
        }
        return frame
    }
}

/// 整段排准时的各段：段尾的字数、底边，按顺序。长正文拖缝时只排一截，没排的那些按它估。
struct RestLayout {
    let width: CGFloat
    private var ends: [Int] = []
    private var bottoms: [CGFloat] = []

    /// 各段都排好了才记，不然给 nil。
    init?(_ layout: NSTextLayoutManager, width: CGFloat) {
        self.width = width
        let start = layout.documentRange.location
        var complete = true
        var ends: [Int] = [], bottoms: [CGFloat] = []
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            complete = fragment.state == .layoutAvailable
            ends.append(layout.offset(from: start, to: fragment.rangeInElement.endLocation))
            bottoms.append(fragment.layoutFragmentFrame.maxY)
            return complete
        }
        guard complete else { return nil }
        self.ends = ends
        self.bottoms = bottoms
    }

    /// 从 offset 起头的那段是第几段。
    func paragraph(startingAt offset: Int) -> Int? {
        if offset == 0 { return 0 }
        return ends.firstIndex(of: offset).map { $0 + 1 }.flatMap { $0 < ends.count ? $0 : nil }
    }

    func start(of index: Int) -> Int { index == 0 ? 0 : ends[index - 1] }

    func height(of index: Int) -> CGFloat { bottoms[index] - (index == 0 ? 0 : bottoms[index - 1]) }

    /// 段尾在 end 的那段下面还有多高。
    func below(end: Int) -> CGFloat? {
        ends.firstIndex(of: end).map { (bottoms.last ?? 0) - bottoms[$0] }
    }
}
