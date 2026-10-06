#if os(iOS)
import CoreText
import UIKit

extension NSAttributedString.Key {
    nonisolated static let quoteDecoration = NSAttributedString.Key("kite.quoteDecoration")
    nonisolated static let inlineCodeDecoration = NSAttributedString.Key("kite.inlineCodeDecoration")
}

nonisolated final class InlineCodeDecoration: NSObject, Sendable {
    let fill: CGColor
    init(fill: CGColor) { self.fill = fill }
}

/// 引用竖线：x 是文本容器坐标，top 是段落上方的间隔。
nonisolated final class QuoteDecoration: NSObject, Sendable {
    let x: CGFloat
    let top: CGFloat
    let fill: CGColor

    init(x: CGFloat, top: CGFloat, fill: CGColor) {
        self.x = x
        self.top = top
        self.fill = fill
    }
}

/// 先画引用竖线和行内代码背景，再画原生文字。
/// 行内代码只覆盖系统排版返回的文字范围，每次折行分别绘制圆角。
nonisolated final class DecoratedFragment: NSTextLayoutFragment {
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
        // 绘制原点已包含段落缩进，将容器坐标换成片段局部坐标。
        return CGRect(x: decoration.x - layoutFragmentFrame.minX, y: decoration.top,
                      width: 3, height: layoutFragmentFrame.height - decoration.top)
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
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil))
        context.setFillColor(decoration.fill)
        context.fillPath()
        context.restoreGState()
    }

    private func drawInlineCode(at point: CGPoint, in context: CGContext) {
        guard hasInlineCode else { return }
        context.saveGState()
        defer { context.restoreGState() }
        for line in textLineFragments {
            // segment 是选区边界，会吸收部分 kern 和中英文间距，不能当作字形边界。
            // 沿用 TextKit 的断行，只向 CoreText 取得这一行的字形位置。
            let typesetter = CTTypesetterCreateWithAttributedString(line.attributedString)
            let range = line.characterRange
            let shaped = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
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
                if attributes[NSAttributedString.Key.attachment.rawValue] == nil {
                    let font = attributes[kCTFontAttributeName] as! CTFont
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(), &glyphs)
                    // 字体原始宽度不含外侧 kern；附件则保留图标本身的排版宽度。
                    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &widths, count)
                }
                // 跳过 WORD JOINER 等零宽字形，不让它们撑大背景。
                for index in 0..<count where advances[index].width > 0 && widths[index].width > 0 {
                    box = box.union(CGRect(x: positions[index].x, y: 0, width: widths[index].width,
                                           height: line.typographicBounds.height))
                }
            }
            drawBox()
        }
    }
}
#endif
