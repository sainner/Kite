import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension NSAttributedString.Key {
    nonisolated static let quoteDecoration = NSAttributedString.Key("kite.quoteDecoration")
    nonisolated static let inlineCodeDecoration = NSAttributedString.Key("kite.inlineCodeDecoration")
}

/// 装饰都按值比较：消息每次重算都新建一份，一样的字不该算成变了，文本视图不重放、量过的尺寸也不作废。
nonisolated final class InlineCodeDecoration: NSObject, Sendable {
    let fill: CGColor
    init(fill: CGColor) { self.fill = fill }

    override func isEqual(_ object: Any?) -> Bool { (object as? InlineCodeDecoration)?.fill == fill }
    override var hash: Int { fill.hashValue }
}

/// 引用竖线：x 是文本容器坐标，top 是段落上方的间隔。
/// 上下文编辑器里一行一段，连着的几行引用接成一根竖线：joinsAbove、joinsBelow 那一端不画圆头。
nonisolated final class QuoteDecoration: NSObject, Sendable {
    let x: CGFloat
    let top: CGFloat
    let fill: CGColor
    let joinsAbove: Bool
    let joinsBelow: Bool

    init(x: CGFloat, top: CGFloat, fill: CGColor, joinsAbove: Bool = false, joinsBelow: Bool = false) {
        self.x = x
        self.top = top
        self.fill = fill
        self.joinsAbove = joinsAbove
        self.joinsBelow = joinsBelow
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? QuoteDecoration else { return false }
        return other.x == x && other.top == top && other.fill == fill && other.joinsAbove == joinsAbove && other.joinsBelow == joinsBelow
    }
    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(x)
        hasher.combine(top)
        hasher.combine(fill)
        hasher.combine(joinsAbove)
        hasher.combine(joinsBelow)
        return hasher.finalize()
    }
}

/// 先画引用竖线和行内代码背景，再画原生文字。
/// 行内代码只覆盖系统排版返回的文字范围，每次折行分别绘制圆角。
/// 两端的文本视图都是 flipped 坐标，TextKit 2 交给 draw(at:in:) 的 context 已按片段局部坐标设好，Mac 上也不用翻。
nonisolated final class DecoratedFragment: NSTextLayoutFragment {
    /// 段落带引用竖线或行内代码时才用会画装饰的片段，其余用普通片段。两端文本视图的排版代理都从这里取。
    /// TextKit 的回调不在主线程隔离里，绘制参数都跟着字放在不可变属性里。
    static func fragment(for textElement: NSTextElement) -> NSTextLayoutFragment {
        let paragraph = (textElement as? NSTextParagraph)?.attributedString
        if let paragraph, paragraph.length > 0 {
            let decoration = paragraph.attribute(.quoteDecoration, at: 0, effectiveRange: nil) as? QuoteDecoration
            var hasInlineCode = false
            paragraph.enumerateAttribute(.inlineCodeDecoration, in: NSRange(location: 0, length: paragraph.length)) { value, _, stop in
                if value is InlineCodeDecoration {
                    hasInlineCode = true
                    stop.pointee = true
                }
            }
            if decoration != nil || hasInlineCode {
                return DecoratedFragment(textElement: textElement, range: textElement.elementRange,
                                         decoration: decoration, hasInlineCode: hasInlineCode)
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private let decoration: QuoteDecoration?
    private let hasInlineCode: Bool

    init(textElement: NSTextElement, range: NSTextRange?, decoration: QuoteDecoration?, hasInlineCode: Bool) {
        self.decoration = decoration
        self.hasInlineCode = hasInlineCode
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    private var box: CGRect {
        guard let decoration else { return .null }
        // 文档以换行结尾时，换行后的空行也排在最后一段的片段里；竖线不画到这一行（上下文编辑器里按回车就会遇到）。
        var bottom = layoutFragmentFrame.height
        if textLineFragments.count > 1, let last = textLineFragments.last, last.characterRange.length == 0 {
            bottom = last.typographicBounds.minY
        }
        // 绘制原点已包含段落缩进，将容器坐标换成片段局部坐标。
        return CGRect(x: decoration.x - layoutFragmentFrame.minX, y: decoration.top,
                      width: 3, height: bottom - decoration.top)
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds.union(box)
        return hasInlineCode ? bounds.insetBy(dx: -Metrics.inlineCodePadding, dy: 0) : bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let decoration { drawBlock(decoration, at: point, in: context) }
        drawInlineCode(at: point, in: context)
        super.draw(at: point, in: context)
    }

    private func drawBlock(_ decoration: QuoteDecoration, at point: CGPoint, in context: CGContext) {
        let rect = box.offsetBy(dx: point.x, dy: point.y)
        let radius = rect.width / 2
        // 相接的一端把圆头伸出片段再裁掉，留下平头；竖线是半透明色，两段叠画会深一截，所以不靠重叠接。
        let above = decoration.joinsAbove ? radius : 0
        let shape = CGRect(x: rect.minX, y: rect.minY - above, width: rect.width,
                           height: rect.height + above + (decoration.joinsBelow ? radius : 0))
        context.saveGState()
        context.clip(to: rect)
        context.addPath(CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(decoration.fill)
        context.fillPath()
        context.restoreGState()
    }

    private func drawInlineCode(at point: CGPoint, in context: CGContext) {
        guard hasInlineCode else { return }
        context.saveGState()
        defer { context.restoreGState() }
        for line in textLineFragments {
            let shaped = shapedLine(line)
            var box = CGRect.null
            var fill: CGColor?
            func drawBox() {
                guard !box.isNull, let fill else { return }
                let rect = box.offsetBy(dx: point.x + line.typographicBounds.minX,
                                        dy: point.y + line.typographicBounds.minY)
                    .insetBy(dx: -Metrics.inlineCodePadding, dy: 0)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: Metrics.inlineCodeRadius,
                                       cornerHeight: Metrics.inlineCodeRadius, transform: nil))
                context.setFillColor(fill)
                context.fillPath()
            }
            for run in CTLineGetGlyphRuns(shaped) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let decoration = attributes[NSAttributedString.Key.inlineCodeDecoration.rawValue] as? InlineCodeDecoration else {
                    drawBox()
                    box = .null
                    fill = nil
                    continue
                }
                fill = decoration.fill
                let count = CTRunGetGlyphCount(run)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(), &positions)
                CTRunGetAdvances(run, CFRange(), &advances)
                var widths = advances
                let font: CTFont? = attributes[kCTFontAttributeName].flatMap { value in
                    CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() ? (value as! CTFont) : nil
                }
                if attributes[NSAttributedString.Key.attachment.rawValue] == nil, let font {
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(), &glyphs)
                    // 字体原始宽度不含外侧 kern；附件则保留图标本身的排版宽度。
                    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &widths, count)
                }
                // 背景按这段代码字体自己的 ascent+descent 贴在基线上，和 SwiftUI 里 run.typographicBounds 的高一样；
                // 用整行高会比它高约 2 pt（Mac 13 pt 正文下量到 16 对 13.5，见 spikes/mac-textkit-prose/README.md）。
                let top = font.map { line.glyphOrigin.y - CTFontGetAscent($0) } ?? 0
                let height = font.map { CTFontGetAscent($0) + CTFontGetDescent($0) } ?? line.typographicBounds.height
                // 跳过 WORD JOINER 等零宽字形，不让它们撑大背景。
                for index in 0..<count where advances[index].width > 0 && widths[index].width > 0 {
                    box = box.union(CGRect(x: positions[index].x, y: top, width: widths[index].width, height: height))
                }
            }
            drawBox()
        }
    }

    /// 沿用 TextKit 排好的这一行，让 CoreText 再排一遍，只为取字形位置。
    /// TextKit 2 只给插入点位置（locationForCharacter、文本段都等于 CTLineGetOffsetForStringIndex）：插入点落在字距的中间，
    /// 也不含中英文之间自动加的间距（Mac 13 pt 正文下量到两项合计差 4.46 pt），不能当作字形边界。
    /// CoreText 把制表位算在自己这一行的起点，TextKit 算在文本容器的起点；列表项的编号靠制表位定位，
    /// 行起点有缩进时（嵌套列表）两边的字会错开一个缩进，背景块就整体画偏，所以制表位先按行起点平移。
    private func shapedLine(_ line: NSTextLineFragment) -> CTLine {
        var text = line.attributedString
        let range = line.characterRange
        let originX = layoutFragmentFrame.minX + line.typographicBounds.minX
        if originX != 0, range.length > 0, (text.string as NSString).range(of: "\t", options: [], range: range).location != NSNotFound,
           let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle, !style.tabStops.isEmpty {
            let shifted = style.mutableCopy() as! NSMutableParagraphStyle
            shifted.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location - originX, options: $0.options) }
            let copy = NSMutableAttributedString(attributedString: text)
            copy.addAttribute(.paragraphStyle, value: shifted, range: NSRange(location: 0, length: copy.length))
            text = copy
        }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        return CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
    }
}
