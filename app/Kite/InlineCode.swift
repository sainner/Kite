import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 两条原生渲染路径共用字号比例，并保留所在标题、表头的字重与倾斜。
enum InlineCodeStyle {
    static func font(relativeTo base: Font.Resolved) -> Font {
        let font = Font.system(size: base.pointSize * Metrics.inlineCodeFontScale, weight: base.weight, design: .monospaced)
        return base.isItalic ? font.italic() : font
    }

    #if os(iOS)
    static func font(relativeTo base: UIFont) -> UIFont {
        let traits = base.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let fallbackWeight: UIFont.Weight = base.fontDescriptor.symbolicTraits.contains(.traitBold) ? .bold : .regular
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? fallbackWeight.rawValue
        let font = UIFont.monospacedSystemFont(ofSize: base.pointSize * Metrics.inlineCodeFontScale,
                                              weight: .init(rawValue: weight))
        let inherited = base.fontDescriptor.symbolicTraits.intersection(.traitItalic)
        guard !inherited.isEmpty,
              let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(inherited)) else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }
    #endif
}

/// 只标记文字范围，背景绘制不拆分原生文本的排版、选择和链接。
struct InlineCodeAttribute: TextAttribute {
    var trailingSpace: CGFloat = 0
}

/// 只增大代码边界处的字距；原文、代码内部字距和复制内容都不变。
enum InlineCodeSpacing {
    static func apply(to source: AttributedString) -> AttributedString {
        var result = source
        var ranges: [Range<AttributedString.Index>] = []
        for (intent, range) in source.runs[\.inlinePresentationIntent] where intent?.contains(.code) == true {
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        let spacing = Metrics.inlineCodePadding + Metrics.inlineCodeGap
        for range in ranges {
            if range.lowerBound > source.startIndex {
                let previous = source.characters.index(before: range.lowerBound)
                if !source.characters[previous].isNewline {
                    result[previous..<range.lowerBound].swiftUI.kern = spacing
                }
            }
            if range.upperBound < source.endIndex, !source.characters[range.upperBound].isNewline {
                let last = source.characters.index(before: range.upperBound)
                result[last..<range.upperBound].swiftUI.kern = spacing
            }
        }
        return result
    }
}

extension Text {
    init(inline source: AttributedString, codeFont: Font) {
        self = source.runs.reduce(Text("")) { result, run in
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            var value = AttributedString(source[run.range])
            if isCode {
                // 字体由共用规则决定，避免系统再对 code 应用默认字体变换。
                var font = codeFont
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { font = font.bold() }
                if run.inlinePresentationIntent?.contains(.emphasized) == true { font = font.italic() }
                value.inlinePresentationIntent?.subtract([.code, .stronglyEmphasized, .emphasized])
                value.font = font
            }
            let text = Text(value)
            let styled = isCode ? text.customAttribute(InlineCodeAttribute(trailingSpace: run.swiftUI.kern ?? 0)) : text
            return Text("\(result)\(styled)")
        }
    }
}

/// 按原生排版的每一行画底色；同一段代码因链接或字体拆成多个 run 时合成一个背景。
struct InlineCodeBackground: ViewModifier {
    func body(content: Content) -> some View {
        let background = Theme.codeBackground
        let padding = Metrics.inlineCodePadding
        return content.backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { proxy in
                Canvas { context, _ in
                    context.translateBy(x: padding, y: 0)
                    for anchored in layouts {
                        let origin = proxy[anchored.origin]
                        for line in anchored.layout {
                            var box: CGRect?
                            func fill() {
                                guard let box else { return }
                                let rect = box.offsetBy(dx: origin.x, dy: origin.y)
                                    .insetBy(dx: -padding, dy: 0)
                                context.fill(Path(roundedRect: rect, cornerRadius: Metrics.inlineCodeRadius),
                                             with: .color(background))
                            }
                            for run in line {
                                if let code = run[InlineCodeAttribute.self] {
                                    var rect = run.typographicBounds.rect
                                    // 末字的额外字距留在背景之外。
                                    rect.size.width -= code.trailingSpace
                                    box = box.map { $0.union(rect) } ?? rect
                                } else {
                                    fill()
                                    box = nil
                                }
                            }
                            fill()
                        }
                    }
                }
                // Canvas 只绘制自身边界内的内容；连画布一起扩宽，再移回文字原点。
                .frame(width: proxy.size.width + padding * 2, height: proxy.size.height)
                .offset(x: -padding)
            }
            .allowsHitTesting(false)
        }
    }
}
