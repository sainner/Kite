import SwiftUI
#if os(macOS)
import AppKit
typealias ContextFont = NSFont
typealias ContextImage = NSImage
typealias ContextColor = NSColor
#else
import UIKit
typealias ContextFont = UIFont
typealias ContextImage = UIImage
typealias ContextColor = UIColor
#endif

/// 变量胶囊：变量菜单、条件的变量选择和段落正文里是同一个样子。正文里按一行字的高度画成图片嵌进文字。
struct ContextVariableChip: View {
    let title: String
    var missing = false
    var height: CGFloat?

    var body: some View {
        let tint = missing ? Theme.danger : Color.accentColor
        Text(title)
            .font(Theme.secondary)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, height == nil ? 2 : 0)
            .frame(height: height)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// 正文的字体、颜色与胶囊图片都由这里算；深浅外观、屏幕倍率或字号变了就重画胶囊。
struct ContextTextStyle: Equatable {
    /// 文字离卡片边的距离，与代码块正文一样。
    static let inset: CGFloat = 10

    let variables: [ContextScene.Variable]
    let colorScheme: ColorScheme
    let scale: CGFloat
    let dynamicTypeSize: DynamicTypeSize

    static func == (a: Self, b: Self) -> Bool {
        a.variables.map(\.name) == b.variables.map(\.name) && a.variables.map(\.title) == b.variables.map(\.title)
            && a.colorScheme == b.colorScheme && a.scale == b.scale && a.dynamicTypeSize == b.dynamicTypeSize
    }

    var font: ContextFont {
        #if os(macOS)
        .preferredFont(forTextStyle: .body)
        #else
        .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)))
        #endif
    }

    var attributes: [NSAttributedString.Key: Any] {
        #if os(macOS)
        [.font: font, .foregroundColor: NSColor.labelColor]
        #else
        [.font: font, .foregroundColor: UIColor.label]
        #endif
    }

    /// Markdown 的标记符号淡显，引用与列表符号次要色。
    var markColor: ContextColor {
        #if os(macOS)
        .tertiaryLabelColor
        #else
        .tertiaryLabel
        #endif
    }

    var secondaryColor: ContextColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    /// 行内代码的底色与引用竖线，和对话正文同一套装饰（TextKitDecorations），按外观解析好。
    var codeFill: CGColor { Theme.codeBackground.resolvedCGColor(for: colorScheme) }
    var quoteFill: CGColor { Theme.rule.resolvedCGColor(for: colorScheme) }

    /// 代码围栏里的行与行内代码同一个等宽字号。
    var code: ContextFont { InlineCodeStyle.font(relativeTo: font) }

    /// 引用行给竖线让出位置，和对话正文一样宽。
    var quoteParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = Metrics.quoteIndent
        style.headIndent = Metrics.quoteIndent
        return style
    }

    /// 一级、二级标题放大，三级以下与正文同号，都加粗。
    func heading(_ level: Int) -> ContextFont {
        let size = font.pointSize * (level == 1 ? 1.3 : level == 2 ? 1.15 : 1)
        #if os(macOS)
        return Self.adding(bold: true, to: NSFont(descriptor: font.fontDescriptor, size: size) ?? font)
        #else
        return Self.adding(bold: true, to: UIFont(descriptor: font.fontDescriptor, size: size))
        #endif
    }

    static func adding(bold: Bool, to font: ContextFont) -> ContextFont {
        #if os(macOS)
        let trait: NSFontDescriptor.SymbolicTraits = bold ? .bold : .italic
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
        #else
        let trait: UIFontDescriptor.SymbolicTraits = bold ? .traitBold : .traitItalic
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private var lineHeight: CGFloat { font.ascender - font.descender }

    /// 空段落的高度：没有字可排时按一行算。
    var emptyLineHeight: CGFloat { lineHeight + font.leading }

    /// 胶囊比一行字矮 2 点，上下相邻两行的胶囊不贴在一起；底边落在字的下伸线上方 1 点。
    var chipBaseline: CGFloat { font.descender + 1 }

    func chip(_ name: String) -> ContextImage? {
        let title = variables.first { $0.name == name }?.title
        let renderer = ImageRenderer(content: ContextVariableChip(title: title ?? name, missing: title == nil, height: lineHeight - 2)
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, dynamicTypeSize))
        renderer.scale = scale
        #if os(macOS)
        return renderer.nsImage
        #else
        return renderer.uiImage
        #endif
    }
}

/// 正文里的一个变量，占一个字符。
nonisolated final class ContextVariableAttachment: NSTextAttachment {
    let name: String

    init(name: String) {
        self.name = name
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// TextKit 2 两端一样：尺寸取图片，底边按 baseline 下移。
    @MainActor func show(_ image: ContextImage?, style: ContextTextStyle) {
        guard let image else { return }
        self.image = image
        bounds = CGRect(origin: CGPoint(x: 0, y: style.chipBaseline), size: image.size)
    }
}
