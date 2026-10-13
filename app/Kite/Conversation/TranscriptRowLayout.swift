import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// agent 一段话的量高：拖缝时只排一截、按住看着的那截。两端原生列表的正文行委托给它，自己只管视图；整段量直接用 TextKitMeasuring.measure。
/// 用类不用结构：量的途中附件可能报来新高（BlockAttachment.resized），行把量过的高作废时会回头 invalidate，
/// 结构的 mutating 方法正占着这个属性，会撞上 Swift 的独占访问检查。
@MainActor final class ProseLayout {
    /// 拖缝前整段排准时各段的高，估没排的那些用。量过的高作废时跟着作废（invalidate）。
    private var rest: RestLayout?
    /// pin 记下的那段：起头的位置、当时在排版里的上沿。
    private var pinned: (location: NSTextLocation, top: CGFloat)?

    func invalidate() {
        rest = nil
    }

    /// 拖缝时只从 band 上沿那段起排到下沿（行内坐标）：上面没排的按 TextKit 估的高占位，下面没排的按拖缝前排准的段高、随宽度反比估。
    /// measured 是眼下量过的宽和高，exact 是它整段排准了（不是上一步只排一截的近似）。这截占了大半行，或者没有可估的段高时给 nil，由调用方整段排。
    func height(of text: some TextKitMeasuring, width: CGFloat, band: ClosedRange<CGFloat>, topInset: CGFloat,
                         measured: (width: CGFloat, height: CGFloat), exact: Bool) -> CGFloat? {
        guard band.upperBound - band.lowerBound < measured.height * 0.7, let layout = text.textLayoutManager else { return nil }
        // 眼下是整段排准的，记下各段的高
        if exact { rest = RestLayout(layout, width: measured.width) }
        guard let rest else { return nil }
        let start = layout.documentRange.location
        let y = band.lowerBound - topInset
        var from = start, top: CGFloat = 0
        if y > 0 {
            guard let fragment = text.laidFragment(at: y) else { return nil }
            from = fragment.rangeInElement.location
            top = fragment.layoutFragmentFrame.minY
            // 上沿那截还没排（上一步排的在它下面，比如贴底时变宽、内容变矮）：按段高往上补够，免得可见区逐步越过排好的上沿
            if top > y, var index = rest.paragraph(startingAt: layout.offset(from: start, to: from)) {
                while top > y, index > 0 {
                    index -= 1
                    top -= rest.height(of: index) * rest.width / measured.width
                }
                guard let location = layout.location(start, offsetBy: rest.start(of: index)) else { return nil }
                from = location
            }
        }
        guard let laid = text.measure(lineWidth: width, from: from, through: band.upperBound - topInset - top) else { return nil }
        let below = rest.below(end: layout.offset(from: start, to: laid.end)).map { $0 * rest.width / width } ?? 0
        // 同整段排的取整：估的位置带小数，不取整时贴底的可见区跟着它每步错开零点几点，字逐步抖一个像素
        return topInset + text.roundedHeight(laid.bottom + below)
    }

    /// 量高前记下行内 y 处的那段，量完由 pinShift 给出它在行里挪了多少，见 TranscriptRowSlot.pin。
    func pin(_ text: some TextKitMeasuring, at y: CGFloat, topInset: CGFloat) {
        pinned = nil
        guard y > topInset, let fragment = text.laidFragment(at: y - topInset) else { return }
        pinned = (fragment.rangeInElement.location, fragment.layoutFragmentFrame.minY)
    }

    func pinShift(_ text: some TextKitMeasuring) -> CGFloat {
        guard let pinned, let frame = text.laidFrame(at: pinned.location) else { return 0 }
        return frame.minY - pinned.top
    }
}

/// 人发的一条消息的气泡怎么量、怎么摆，两端原生列表的气泡行共用：靠右、贴着字宽（有代码段时占满），太长的折起来、底下渐隐，
/// 下面一个展开收起的按钮，附件排在气泡上面。底色、描边、截住正文的那层、按钮和附件的视图各端自己画，按这里给的框摆。
struct BubbleLayout {
    /// 正文连同上下边距不折时多高，量的时候算出来。
    private(set) var contentHeight: CGFloat = 0
    /// 正文的行宽。
    private(set) var textWidth: CGFloat = 0
    /// 折着的长消息拖缝时上一次排露出来那截的行宽、最宽的一行和这截的底边，见 foldedHeight。换了内容（contentChanged）、
    /// 按别的方式量过（容器换了宽）就作废。
    private var folded: (lineWidth: CGFloat, widest: CGFloat, bottom: CGFloat)?

    /// 正文换了：拖缝中折着的那截要重排。
    mutating func contentChanged() {
        folded = nil
    }

    /// 比折起来的高（foldHeight，iOS 随动态字体变）高出不少（1.4 倍）才折，同 MessageBubble。
    func foldable(foldHeight: CGFloat) -> Bool {
        contentHeight > foldHeight * 1.4
    }

    /// 按内容列的宽量正文。有代码段时占满气泡能给的宽度，只有字时贴着字，同 SelectableText。贴字的宽照 SelectableText 用 boundingRect 量：
    /// 它按最优断行量，长消息改宽时每次几毫秒（2026-10-13 实测）。拖缝和吸附中（resizing）改用近似：按能给的最宽排，取最宽的一行，
    /// 和 boundingRect 只差零点几点，但中文避头尾在临界宽度下会让个别行折得不一样（逐像素对过），所以返回 true，停下后按精确的重量。
    /// 拖缝中按能给的宽排出来的每行都放得下贴字的宽，行和高都一样，容器就留在能给的宽，不再按贴字的宽排第二遍
    /// （iPad 真机拖缝时气泡量高占了大头；Mac 两窗贴底时两条折着的长消息每步约 1.5 ms，2026-10-14）。
    mutating func measure(_ text: some TextKitMeasuring, storage: NSAttributedString, width: CGFloat, hasBlocks: Bool,
                          resizing: Bool, expanded: Bool, foldHeight: CGFloat) -> Bool {
        let padding = Metrics.bubblePadding
        let most = max(width - padding.width * 2, 0)
        let textHeight: CGFloat
        let provisional = resizing && !hasBlocks
        let foldedPath = provisional && foldable(foldHeight: foldHeight) && !expanded
        if !foldedPath { folded = nil }
        if hasBlocks {
            textWidth = most
            textHeight = text.measure(lineWidth: most)
        } else if foldedPath, let height = foldedHeight(text, most: most, foldHeight: foldHeight) {
            textHeight = height
        } else if provisional {
            textHeight = text.measure(lineWidth: most)
            textWidth = min(ceil(text.widestLine) + 1, most)
        } else {
            textWidth = ProseTextCoordinator.naturalWidth(of: storage, most: most)
            textHeight = text.measure(lineWidth: textWidth)
        }
        contentHeight = textHeight + padding.height * 2
        return provisional
    }

    /// 折着的长消息拖缝时只排露出来的那截：贴字的宽按这截里最宽的一行，全文多高按上次量的随宽度反比估，只用来判断还折不折。
    /// 不然每步都要把整条长消息重排一遍，露出来的只有开头几行。
    /// 变窄、还放得下上次排的最宽的一行时不重排：行宽只在放不下时折，排出来每行都和上次一样，容器留在上次的宽。
    private mutating func foldedHeight(_ text: some TextKitMeasuring, most: CGFloat, foldHeight: CGFloat) -> CGFloat? {
        let previous = (height: contentHeight - Metrics.bubblePadding.height * 2, width: textWidth)
        let laid: (lineWidth: CGFloat, widest: CGFloat, bottom: CGFloat)
        if let folded, folded.lineWidth >= most, folded.widest <= most {
            laid = folded
        } else {
            guard let start = text.textLayoutManager?.documentRange.location,
                  let measured = text.measure(lineWidth: most, from: start, through: foldHeight) else { return nil }
            laid = (most, text.widestLine, measured.bottom)
            folded = laid
        }
        textWidth = min(ceil(laid.widest) + 1, most)
        return ceil(max(laid.bottom, previous.height * previous.width / max(textWidth, 1)))
    }

    /// 折着的长消息拖缝时不重量（iOS）：露出来的高是定的，只按能给的宽换正文的行宽（上次折了行的占满，没折的照旧贴字）。
    mutating func keepFolded(most: CGFloat, wraps: Bool) {
        textWidth = wraps ? most : min(textWidth, most)
    }

    /// 气泡多高：折起来的正文，加上能折时的按钮（button 是按钮的高）。
    func bubbleHeight(expanded: Bool, foldHeight: CGFloat, button: CGFloat) -> CGFloat {
        guard foldable(foldHeight: foldHeight) else { return contentHeight }
        return (expanded ? contentHeight : foldHeight) + button
    }

    /// 气泡里的东西摆在哪，都在气泡自己的坐标里，除了 bubble 在行里。
    struct Frames: Equatable {
        var bubble: CGRect
        /// 正文这一块（连同上下边距）这会儿露出多高：展开收起的动画中在折起和全文之间，截住正文的那层就这么高。
        var shown: CGFloat
        var text: CGRect
        var fold: CGRect
        /// 底下渐隐：从哪起渐隐（0～1，截住那层的高的比例），到底边时被截掉的越多越透（0 不透，1 全透）。
        var fadeStart: CGFloat
        var faded: CGFloat
    }

    /// 行这会儿的大小（展开收起的动画中和量的高不一样）里怎么摆：气泡靠右、在附件下面；正文按露出来的高截住，
    /// 只给到露出来的底边（折着时文本视图不去排、画折下去的那些）。button 是折叠按钮的高，不能折时给 0。
    func frames(row size: CGSize, attachmentsHeight: CGFloat, button: CGFloat) -> Frames {
        let padding = Metrics.bubblePadding
        let bubbleWidth = textWidth + padding.width * 2
        let bubble = CGRect(x: size.width - bubbleWidth, y: attachmentsHeight, width: bubbleWidth, height: max(size.height - attachmentsHeight, 0))
        let shown = max(bubble.height - button, 0)
        let textHeight = min(contentHeight - padding.height * 2, shown - padding.height)
        return Frames(bubble: bubble, shown: shown,
                      text: CGRect(x: padding.width, y: padding.height, width: textWidth, height: max(textHeight, 0)),
                      fold: CGRect(x: 0, y: shown, width: bubble.width, height: button),
                      fadeStart: max(0, 1 - Metrics.messageFoldFade / max(shown, 1)),
                      faded: min(max((contentHeight - shown) / Metrics.messageFoldFade, 0), 1))
    }

    /// 气泡内容在行里占的范围（附件连同气泡，靠右），操作栏和它右边对齐。
    func anchor(in frame: CGRect, attachmentsWidth: CGFloat) -> CGRect {
        let width = max(textWidth + Metrics.bubblePadding.width * 2, attachmentsWidth)
        return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
    }
}

/// 两段话之间 agent 做的事折成的一行怎么量、展开到哪了，两端原生列表的工具行共用（照 WorkRow）：汇总一行，点开下面是步骤，
/// 展开收起和下面的行一起按 0.25 秒的普通缓出动，箭头跟着转、步骤跟着淡入淡出。汇总行、步骤的视图各端自己建。
enum WorkLayout {
    /// 汇总行和步骤之间的间距，同 WorkRow 的 VStack。
    static let spacing: CGFloat = 6
    static let motion = RowMotion.curve(.easeOut, duration: 0.25)

    /// 行多高：汇总行，展开时再加上间距和步骤。
    static func height(header: CGFloat, steps: CGFloat, expanded: Bool) -> CGFloat {
        header + (expanded ? spacing + steps : 0)
    }

    /// 动画中行的高在收起和展开之间，按它算走到哪了：0 收起，1 展开。箭头转多少、步骤多透明都跟着它。
    static func progress(rowHeight: CGFloat, header: CGFloat, steps: CGFloat, expanded: Bool) -> CGFloat {
        let full = spacing + steps
        return full > 0 ? min(max((rowHeight - header) / full, 0), 1) : (expanded ? 1 : 0)
    }
}
