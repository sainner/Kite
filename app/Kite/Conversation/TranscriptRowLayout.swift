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
    /// 上次只排了一截：那截的位置是估的，之后整段 ensureLayout 不一定挪回去（2026-10-19 Mac 实测，停下后整段重量时
    /// 有五段各比上一段的底边多空 16 pt，行高量大 80 pt，稍后视口重排才贴回去，回复下面多出一截空白）。量过的高作废时不清。
    private var banded = false

    func invalidate() {
        rest = nil
    }

    /// 整段量之前调：上次只排过一截的，整段作废，从头排。
    func settle(_ text: some TextKitMeasuring) {
        guard banded, let layout = text.textLayoutManager else { return }
        banded = false
        layout.invalidateLayout(for: layout.documentRange)
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
        banded = true
        guard let laid = text.measure(lineWidth: width, from: from, through: band.upperBound - topInset - top) else { return nil }
        let below = rest.below(end: layout.offset(from: start, to: laid.end)).map { $0 * rest.width / width } ?? 0
        // 同整段排的取整：估的位置带小数，不取整时贴底的可见区跟着它每步错开零点几点，字逐步抖一个像素
        return topInset + text.roundedHeight(laid.bottom + below)
    }

    /// 眼下整段排好了（按 width 的行宽）：记下各段的高，之后只排一截时估没排的那些（iOS 拖缝中先不重排、或比列窄一截整段排的行）。
    func remember(_ text: some TextKitMeasuring, width: CGFloat) {
        guard let layout = text.textLayoutManager, let laid = RestLayout(layout, width: width) else { return }
        rest = laid
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

/// 气泡怎么量、怎么摆，两端原生列表的气泡行共用：人发的靠右、代理来信靠左，贴着字宽（有代码段时占满），太长的折起来、底下渐隐，
/// 下面一个展开收起的按钮；气泡上面是附件（人发的）或头像和名字（代理来信）。底色、描边、截住正文的那层、按钮和上面那一截的视图各端自己画，按这里给的框摆。
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

    /// 比折起来的高（foldHeight，iOS 随动态字体变）高出不少（1.4 倍）才折：只高出一点的不折，省得展开只多看两行。
    func foldable(foldHeight: CGFloat) -> Bool {
        Self.foldable(contentHeight, foldHeight: foldHeight)
    }

    /// 全文 height 高的一段折不折，气泡和工具详情里的值（DetailFold）同一条规则，见 foldable(foldHeight:)。
    static func foldable(_ height: CGFloat, foldHeight: CGFloat) -> Bool {
        height > foldHeight * 1.4
    }

    /// 全文 full 高、露出 shown 高时底下的渐隐：从哪起（0～1，露出那截的比例），到底边淡掉多少（0 不淡，1 全透）。
    static func fade(shown: CGFloat, full: CGFloat) -> (start: CGFloat, faded: CGFloat) {
        (max(0, 1 - Metrics.messageFoldFade / max(shown, 1)), min(max((full - shown) / Metrics.messageFoldFade, 0), 1))
    }

    /// 按内容列的宽量正文。有代码段时占满气泡能给的宽度，只有字时贴着字，同 SelectableText。贴字的宽照 SelectableText 用 boundingRect 量：
    /// 它按最优断行量，长消息改宽时每次几毫秒（2026-10-13 实测）。拖缝和吸附中（resizing）改用近似：按能给的最宽排，取最宽的一行，
    /// 和 boundingRect 只差零点几点，但中文避头尾在临界宽度下会让个别行折得不一样（逐像素对过），所以返回 true，停下后按精确的重量。
    /// 拖缝中容器留在能给的宽、只排这一遍：每行都放得下贴字的宽，显示的就是这一遍的断行和高，不再按贴字的宽排第二遍
    /// （iPad 真机拖缝时气泡量高占了大头；Mac 两窗贴底时两条折着的长消息每步约 1.5 ms，2026-10-14）。
    /// 按贴字的宽重排时个别行会差一个词：上一行以全角收尾标点（」等）结束时，CoreText 要多出约半个字宽才放得下这一行
    /// （2026-10-14 实测，五组样本、每 0.25 pt 一个宽，只有标点密集的那组在约 5% 的宽上差一个词，行数不变）；停下后照常按精确的重量。
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
    /// 变窄、还放得下上次排的最宽的一行时不重排：容器留在上次的宽，显示的还是上次那一遍（每行都放得下贴字的宽）；
    /// 和按新宽实排比，个别行可能差一个词（见 measure），停下后照常重量。
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

    /// 行这会儿的大小（展开收起的动画中和量的高不一样）里怎么摆：气泡靠右（leading 时靠左）、在上面那一截（top）下面；正文按露出来的高截住，
    /// 只给到露出来的底边（折着时文本视图不去排、画折下去的那些）。button 是折叠按钮的高，不能折时给 0。
    func frames(row size: CGSize, top: CGFloat, button: CGFloat, leading: Bool = false) -> Frames {
        let padding = Metrics.bubblePadding
        let bubbleWidth = textWidth + padding.width * 2
        let bubble = CGRect(x: leading ? 0 : size.width - bubbleWidth, y: top, width: bubbleWidth, height: max(size.height - top, 0))
        let shown = max(bubble.height - button, 0)
        let textHeight = min(contentHeight - padding.height * 2, shown - padding.height)
        let fade = Self.fade(shown: shown, full: contentHeight)
        return Frames(bubble: bubble, shown: shown,
                      text: CGRect(x: padding.width, y: padding.height, width: textWidth, height: max(textHeight, 0)),
                      fold: CGRect(x: 0, y: shown, width: bubble.width, height: button),
                      fadeStart: fade.start, faded: fade.faded)
    }

    /// 气泡内容在行里占的范围（上面那一截连同气泡），操作栏和它靠着的那边对齐。
    func anchor(in frame: CGRect, topWidth: CGFloat, leading: Bool = false) -> CGRect {
        let width = max(textWidth + Metrics.bubblePadding.width * 2, topWidth)
        return CGRect(x: leading ? frame.minX : frame.maxX - width, y: frame.minY, width: width, height: frame.height)
    }
}

extension BubbleLayout {
    /// Kite 的通知点开时气泡从左上角放大、淡入，收起时缩回左上角、淡出，同 Mac 操作栏出现、消失的弹簧（见 ActionBarView.appear）。
    /// 绕图层的锚点缩放，锚点要在左上角（Mac 翻转坐标的视图本来就是，iOS 的气泡自己设）。只加图层动画、不动模型值，视图照常按 frame 摆；
    /// 缩回去的停在末帧，播完调 done。中途反过来时从眼下的样子接着走，被接走的那次不调 done。
    static func pop(_ layer: CALayer, shown: Bool, done: @escaping () -> Void = {}) {
        let hidden = (transform: CATransform3DMakeScale(0.3, 0.3, 1), opacity: Float(0))
        let current = layer.animation(forKey: "pop.transform") != nil ? layer.presentation() : nil
        let from = current.map { ($0.transform, $0.opacity) } ?? (shown ? hidden : (CATransform3DIdentity, 1))
        let to = shown ? (CATransform3DIdentity, Float(1)) : hidden
        let spring = shown ? CASpringAnimation(perceptualDuration: 0.35, bounce: 0.3) : CASpringAnimation(perceptualDuration: 0.2, bounce: 0.15)
        layer.setValue(shown, forKey: "popShown")
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            guard layer.value(forKey: "popShown") as? Bool == shown else { return }
            done()
            layer.removeAnimation(forKey: "pop.transform")
            layer.removeAnimation(forKey: "pop.opacity")
        }
        let values: [(key: String, from: Any, to: Any)] = [("transform", from.0, to.0), ("opacity", from.1, to.1)]
        for value in values {
            let animation = spring.copy() as! CASpringAnimation
            animation.keyPath = value.key
            animation.fromValue = value.from
            animation.toValue = value.to
            animation.duration = animation.settlingDuration
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "pop." + value.key)
        }
        CATransaction.commit()
    }
}

extension Notice {
    /// 气泡上面那一行：「Kite-种类」，说的是哪一个的接在后面，比如「Kite-monitor 事件：部署检查」；没标种类的只写 Kite。
    var heading: String {
        guard let name = kindName else { return "Kite" }
        guard let subject, !subject.isEmpty else { return "Kite-" + name }
        return "Kite-" + name + "：" + subject
    }

    private var kindName: String? {
        switch kind {
        case .report: "子代理回报"
        case .workspace: "子工作区结果"
        case .monitor: "monitor 事件"
        case .terminal: "后台命令结束"
        case .line: "收件箱"
        case .conflict: "合并冲突"
        case .moved: "换了工作机"
        case .resumed: "接着上次的任务"
        case .question: "提问回应"
        case .secret: "密钥回应"
        case nil: nil
        }
    }

    /// 气泡上面那一行前面画什么，两端一样：用户自己的回应画用户的头像，Line 替用户回答的提问画 Line 的
    /// （还没有 Line 自己的图标，先用代理头像），别的画 Kite 的铃铛。
    enum Mark { case kite, user, agent(instance: String) }

    var mark: Mark {
        if response { return .user }
        if kind == .question, let instance { return .agent(instance: instance) }
        return .kite
    }
}

/// 来信（代理来信、Kite 的通知）上面那一行：图标、一句。来信默认收着、只有这一行，点开才露出气泡和正文。
struct LetterHeading {
    let mark: Notice.Mark
    let title: String
    /// 读屏读的那一句。
    let speech: String

    init(_ notice: Notice) {
        mark = notice.mark
        title = notice.heading
        speech = TranscriptSpeech.notice(notice)
    }

    /// 代理来信：发信方的头像和名字。
    init(_ sender: Sender, queued: Bool) {
        mark = .agent(instance: sender.instance)
        title = sender.name
        speech = TranscriptSpeech.agent(sender, queued: queued)
    }
}

/// 两段话之间 agent 做的事折成的一行怎么量、展开到哪了，两端原生列表的工具行共用：汇总一行，点开下面是步骤，
/// 展开收起和下面的行一起按 0.25 秒的普通缓出动，箭头跟着转、步骤跟着淡入淡出。汇总行、步骤的视图各端自己建。
enum WorkLayout {
    /// 汇总行和步骤之间的间距。
    static let spacing: CGFloat = 6
    static let motion = RowMotion.curve(.easeOut, duration: 0.25)

    /// 行多高：汇总行，展开时再加上间距和步骤。
    static func height(header: CGFloat, steps: CGFloat, expanded: Bool) -> CGFloat {
        header + (expanded ? spacing + steps : 0)
    }

    /// 动画中行的高在收起和展开之间，按它算走到哪了：0 收起，1 展开。箭头转多少、步骤多透明都跟着它。
    static func progress(rowHeight: CGFloat, header: CGFloat, steps: CGFloat, expanded: Bool) -> CGFloat {
        progress(rowHeight: rowHeight, collapsed: header, extra: spacing + steps, expanded: expanded)
    }

    /// 同上，点开时多出一截的行通用（工具的一步、Kite 的通知）：收起时 collapsed 高，展开多出 extra；多出的为 0 时按 expanded。
    static func progress(rowHeight: CGFloat, collapsed: CGFloat, extra: CGFloat, expanded: Bool) -> CGFloat {
        extra > 0 ? min(max((rowHeight - collapsed) / extra, 0), 1) : (expanded ? 1 : 0)
    }
}

/// 一次调用的详情里的几块：参数、结果的卡片，子 agent 的行。某一块变高变矮时动画中多出、少掉的那截给它。
enum DetailPart {
    case input, result, children
}

/// 工具详情卡片里一个值怎么折，两端共用：比折起来的高（foldHeight，detailFoldLines 行等宽字）高出不少（1.4 倍，同 BubbleLayout.foldable）才折；
/// 折着只露出 foldHeight、底下渐隐，下面靠左一行「展开全文」「收起」（button 是它的高）。展开收起按工具步骤的走法（WorkLayout.motion）动，
/// 动画中这一格的高在折起和全文之间，露出来的那截跟着它走。
struct DetailFold {
    /// 值全排出来多高。
    var full: CGFloat = 0
    var foldHeight: CGFloat = 0
    var expanded = false

    /// 按钮上下的边距：触屏上大一点，好点。
    static var buttonPadding: CGFloat { InputMode.current.isTouch ? 6 : 4 }

    var foldable: Bool { BubbleLayout.foldable(full, foldHeight: foldHeight) }

    /// 停着时这一格多高：露出来的字，能折时加上按钮。
    func height(button: CGFloat) -> CGFloat {
        guard foldable else { return full }
        return (expanded ? full : foldHeight) + button
    }

    /// 这一格眼下给了 height 高（动画中在折起和全文之间）：字露出多高，底下渐隐从哪起（0～1，露出那截的比例）、
    /// 到底边淡掉多少（0 不淡，1 全透），同 BubbleLayout.frames。不能折的整段露出、不渐隐。
    func shown(height: CGFloat, button: CGFloat) -> (height: CGFloat, fadeStart: CGFloat, faded: CGFloat) {
        guard foldable else { return (full, 1, 0) }
        let shown = max(height - button, 0)
        let fade = BubbleLayout.fade(shown: shown, full: full)
        return (shown, fade.start, fade.faded)
    }
}
