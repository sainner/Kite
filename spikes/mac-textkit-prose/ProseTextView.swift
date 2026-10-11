import AppKit
import CoreText
import SwiftUI

// Mac 上把连续的散文块（段落、标题、引用、列表项）排进一个 NSTextView（TextKit 2）。
// 属性串按 app/Kite/UI/SelectableMarkdown.swift（iOS）的 attributed/inline 搬到 AppKit；
// 行内代码背景和引用竖线按 app/Kite/UI/TextKitDecorations.swift 搬成 NSTextLayoutFragment 子类。
// 字号、行距、块距、缩进这些常量直接用编进来的 Theme/Metrics（见 build.sh）。

// MARK: - 装饰（TextKitDecorations.swift 的 AppKit 版）

extension NSAttributedString.Key {
    nonisolated static let quoteDecoration = NSAttributedString.Key("kite.quoteDecoration")
    nonisolated static let inlineCodeDecoration = NSAttributedString.Key("kite.inlineCodeDecoration")
}

nonisolated final class InlineCodeDecoration: NSObject, Sendable {
    let fill: CGColor
    init(fill: CGColor) { self.fill = fill }
    override func isEqual(_ object: Any?) -> Bool { (object as? InlineCodeDecoration)?.fill == fill }
    override var hash: Int { fill.hashValue }
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
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? QuoteDecoration else { return false }
        return other.x == x && other.top == top && other.fill == fill
    }
    override var hash: Int { x.hashValue ^ top.hashValue ^ fill.hashValue }
}

/// 先画引用竖线和行内代码背景，再画原生文字。与 iOS 版唯一的差别是 NSTextView 是 flipped 视图：
/// TextKit 2 交给 draw(at:in:) 的 context 已经按片段局部坐标（y 向下）设好，这里不用再翻。
nonisolated final class DecoratedFragment: NSTextLayoutFragment {
    /// tuned 变体：背景块高度按代码字体自己的 ascent+descent、贴在基线上，和 SwiftUI 的 run.typographicBounds 一样；
    /// 照搬 iOS 时用整行的 typographicBounds.height，比 SwiftUI 的高约 2pt。
    nonisolated(unsafe) static var codeBoxFollowsRunFont = false

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
            let typesetter = CTTypesetterCreateWithAttributedString(line.attributedString)
            let range = line.characterRange
            let shaped = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            var box = CGRect.null
            var fill: CGColor?
            func drawBox() {
                guard !box.isNull, let fill else { return }
                let rect = box.offsetBy(dx: point.x + line.typographicBounds.minX, dy: point.y + line.typographicBounds.minY)
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
                    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &widths, count)
                }
                // 照搬 iOS：背景块占整行高；tuned：按代码字体自己的 ascent+descent、贴在基线上（SwiftUI 的 run.typographicBounds 就是这样）
                var boxY: CGFloat = 0, boxHeight = line.typographicBounds.height
                if Self.codeBoxFollowsRunFont, let font = attributes[kCTFontAttributeName] {
                    let ct = font as! CTFont
                    boxY = line.glyphOrigin.y - CTFontGetAscent(ct)
                    boxHeight = CTFontGetAscent(ct) + CTFontGetDescent(ct)
                }
                // 跳过 WORD JOINER 等零宽字形，不让它们撑大背景。
                for index in 0..<count where advances[index].width > 0 && widths[index].width > 0 {
                    box = box.union(CGRect(x: positions[index].x, y: boxY, width: widths[index].width, height: boxHeight))
                }
            }
            drawBox()
        }
    }
}

// MARK: - 属性串（SelectableMarkdown.attributed/inline 的 AppKit 版）

enum ProseAttributes {
    /// 实验里量到的 SwiftUI 一、二级标题行高（见 README），tuned 变体用固定行高逼近；正式代码没有这个数，列在这里只为验证能不能对齐。
    /// 三级标题两边本来就一样高（16），不动。TextKit 给固定行高之外还会再加字体的 leading，所以设的时候要先减掉。
    nonisolated static let swiftUIHeadingLineHeight: [Int: CGFloat] = [1: 20.02, 2: 19.0]

    /// 几块拼成一段带属性的字，块和块之间空 markdownBlockGap，标题上面再多空一点，和 MarkdownBlockView 排的一样。
    /// tuned：按第一轮量出的差异补偿——块距减去 TextKit 放在段首行上方的行距、引用竖线顶边也下移一个行距、标题行高硬凑成
    /// SwiftUI 的值、.standard 折行；代码背景块的高度由 DecoratedFragment.codeBoxFollowsRunFont 控制。
    /// linkColor 给链接文字（SwiftUI 的 Text 用系统 linkColor），tint 给文件图标（SwiftUI 用 .tint，即 App 主题色）。
    static func build(_ blocks: [MarkdownBlock], scope: ReferenceScope, appearance: NSAppearance, linkColor: NSColor, tint: NSColor,
                      tuned: Bool = false) -> NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let blockGap = Metrics.markdownBlockGap(body.pointSize)
        let lineSpacing = Metrics.markdownLineSpacing(body.pointSize)
        let codeFill = cgColor(Theme.codeBackground, appearance)
        let ruleFill = cgColor(Theme.rule, appearance)
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacingBefore = index > 0 ? (tuned ? blockGap - lineSpacing : blockGap) : 0
            // 第一轮量到 SwiftUI 的 Text 不在中文词中间折行（「正文」不拆），和 TextKit 默认的逐字折行不同；tuned 变体试 .standard
            if tuned { style.lineBreakStrategy = .standard }
            let indent = CGFloat(max(block.depth - 1, 0)) * Metrics.listIndent
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            var font = body
            var color = NSColor.labelColor
            var prefix = ""
            var decoration: QuoteDecoration?
            var headingBaselineOffset: CGFloat = 0
            switch block.kind {
            case .heading(let level):
                font = level <= 1 ? semibold(.title2) : level == 2 ? semibold(.title3) : .preferredFont(forTextStyle: .headline)
                style.paragraphSpacingBefore += blockGap / 2
                if tuned, let height = Self.swiftUIHeadingLineHeight[level] {
                    // 固定行高后 TextKit 的基线比 SwiftUI 高（量到二级 1pt、一级 2pt），用 baselineOffset 挪回去；
                    // baselineOffset 又会让行高缩同样的数，所以行高再补上。固定行高之外 TextKit 还会加字体的 leading，先减掉。纯粹硬凑
                    headingBaselineOffset = level <= 1 ? 2 : 1
                    style.minimumLineHeight = height - font.leading + headingBaselineOffset
                    style.maximumLineHeight = height - font.leading + headingBaselineOffset
                }
            case .quote:
                color = .secondaryLabelColor
                style.firstLineHeadIndent = indent + 12
                style.headIndent = indent + 12
                // 第一轮量到：TextKit 2 把 lineSpacing 放在每一行上方（段落第一行也有），片段顶边比字高出一个行距
                decoration = QuoteDecoration(x: indent, top: style.paragraphSpacingBefore + (tuned ? lineSpacing : 0), fill: ruleFill)
            case .listItem(let marker):
                let text = indent + Metrics.listMarker + 6
                style.tabStops = [NSTextTab(textAlignment: .right, location: indent + Metrics.listMarker),
                                  NSTextTab(textAlignment: .left, location: text)]
                style.headIndent = text
                prefix = "\t\(marker ?? "")\t"
            default:
                break
            }
            let part = NSMutableAttributedString(string: prefix, attributes: [.font: monospacedDigits(body), .foregroundColor: color])
            part.append(inline(ReferenceText.decorate(block.text, scope: scope), font: font, color: color, linkColor: linkColor, tint: tint, codeFill: codeFill))
            part.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: part.length))
            if headingBaselineOffset != 0 {
                part.addAttribute(.baselineOffset, value: headingBaselineOffset, range: NSRange(location: 0, length: part.length))
            }
            if let decoration {
                part.addAttribute(.quoteDecoration, value: decoration, range: NSRange(location: 0, length: part.length))
            }
            result.append(part)
        }
        return result
    }

    /// 行内的样式：粗体、斜体、行内代码、删除线、链接，和 SwiftUI 的 Text 认的一样。
    private static func inline(_ text: AttributedString, font: NSFont, color: NSColor, linkColor: NSColor, tint: NSColor, codeFill: CGColor) -> NSAttributedString {
        let text = InlineCodeSpacing.apply(to: text)
        let result = NSMutableAttributedString()
        let codeDecoration = InlineCodeDecoration(fill: codeFill)
        var previousLink: URL?
        for run in text.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let kern = run.swiftUI.kern { attributes[.kern] = kern }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = inlineCodeFont(relativeTo: font)
                    attributes[.inlineCodeDecoration] = codeDecoration
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits))
                    runFont = NSFont(descriptor: descriptor, size: 0) ?? runFont
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let url = run.link, url != previousLink {
                let image = url.scheme == "kite" ? tinted(ReferenceIcons.file, tint)
                    : ReferenceIcons.shared.image(for: url) ?? ReferenceIcons.webpage
                let scaled = ReferenceIcons.scaled(image, to: runFont.pointSize * Metrics.referenceIconScale, trailingSpace: Metrics.referenceIconGap)
                let attachment = NSTextAttachment()
                attachment.image = scaled
                attachment.bounds = CGRect(origin: CGPoint(x: 0, y: Metrics.referenceIconBaselineOffset), size: scaled.size)
                let icon = NSMutableAttributedString(attachment: attachment)
                icon.append(NSAttributedString(string: ReferenceIcons.nameJoiner))
                icon.addAttributes([.link: url, .font: runFont], range: NSRange(location: 0, length: icon.length))
                if run.inlinePresentationIntent?.contains(.code) == true {
                    icon.addAttribute(.inlineCodeDecoration, value: codeDecoration, range: NSRange(location: 0, length: icon.length))
                }
                result.append(icon)
            }
            previousLink = run.link
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// InlineCodeStyle.font(relativeTo: UIFont) 的 AppKit 版：等宽、字号按比例、保留字重和倾斜。
    static func inlineCodeFont(relativeTo base: NSFont) -> NSFont {
        let traits = base.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let fallbackWeight: NSFont.Weight = base.fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .regular
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? fallbackWeight.rawValue
        let font = NSFont.monospacedSystemFont(ofSize: base.pointSize * Metrics.inlineCodeFontScale, weight: .init(rawValue: weight))
        let inherited = base.fontDescriptor.symbolicTraits.intersection(.italic)
        guard !inherited.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(inherited))
        return NSFont(descriptor: descriptor, size: 0) ?? font
    }

    /// 系统文本样式的半粗体，和 Theme 里标题的写法一样。
    static func semibold(_ style: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
        return NSFont(descriptor: descriptor, size: 0) ?? base
    }

    /// 数字等宽，列表的编号对得齐。
    static func monospacedDigits(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: 0) ?? font
    }

    /// 模板图标按链接色着色：附件里的 NSImage 不会像 SwiftUI 的 .template 那样跟着 foregroundStyle。
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.alignmentRect = image.alignmentRect
        return result
    }

    /// TextKit 的绘制片段只保存 CGColor，按窗口外观解析。
    static func cgColor(_ color: Color, _ appearance: NSAppearance) -> CGColor {
        var resolved = CGColor.black
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor(color).cgColor }
        return resolved
    }
}

// MARK: - 文本视图

/// 记下右键是否走到了 NSTextView 自己的菜单，实验里对照用；suppressMenu 时不弹系统菜单，右键传给上层。
final class ProseNSTextView: NSTextView {
    var suppressMenu = false
    var menuRequests = 0
    var scrollWheelEvents = 0
    var drawCalls = 0
    var rightClicks = 0
    var frameSizeChanges = 0
    var frameOriginChanges = 0

    override func draw(_ dirtyRect: NSRect) {
        drawCalls += 1
        super.draw(dirtyRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { frameSizeChanges += 1 }
        super.setFrameSize(newSize)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin != frame.origin { frameOriginChanges += 1 }
        super.setFrameOrigin(newOrigin)
    }

    override func rightMouseDown(with event: NSEvent) {
        rightClicks += 1
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuRequests += 1
        return suppressMenu ? nil : super.menu(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        scrollWheelEvents += 1
        super.scrollWheel(with: event)
    }
}

/// NSTextView 包成 SwiftUI 视图：高度按给定宽度量、按宽度缓存；链接交给 onLink；文本和外观变了才重设属性串。
struct ProseTextView: NSViewRepresentable {
    let text: NSAttributedString
    /// 两侧为行内代码背景留的绘制余量，外层用负 padding 抵消。
    var inset: CGFloat = Metrics.inlineCodePadding
    var suppressMenu = false
    var onLink: (URL) -> Void = { _ in }
    var onMake: (ProseNSTextView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProseNSTextView {
        let view = ProseNSTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainerInset = NSSize(width: inset, height: 0)
        view.displaysLinkToolTips = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.usesFontPanel = false
        view.delegate = context.coordinator
        // 行内代码的底色、引用的竖线由自己的排版片段画，要在放字之前接上
        view.textLayoutManager?.delegate = context.coordinator
        context.coordinator.parent = self
        onMake(view)
        return view
    }

    func updateNSView(_ view: ProseNSTextView, context: Context) {
        context.coordinator.parent = self
        view.suppressMenu = suppressMenu
        // 链接不画下划线，颜色跟主题色，光标是手形；和 SwiftUI 的 Text 一样
        view.linkTextAttributes = [.foregroundColor: context.coordinator.linkColor, .cursor: NSCursor.pointingHand]
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        context.coordinator.sizes = [:]
        view.textStorage?.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseNSTextView, context: Context) -> CGSize? {
        let coordinator = context.coordinator
        coordinator.sizeQueries += 1
        if let size = coordinator.sizes[proposal.width] { return size }
        guard let width = proposal.width, width.isFinite, let layout = view.textLayoutManager, let container = view.textContainer else {
            return nil
        }
        // 文本容器跟着视图宽度，先把宽度放上去再量；SwiftUI 之后会按返回的尺寸再设一次 frame
        if view.frame.width != width { view.setFrameSize(NSSize(width: width, height: view.frame.height)) }
        container.size = NSSize(width: width - inset * 2, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        let height = ceil(layout.usageBoundsForTextContainer.height)
        let size = CGSize(width: width, height: height)
        coordinator.sizes[proposal.width] = size
        coordinator.measurements += 1
        return size
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate {
        var parent: ProseTextView?
        var shown: NSAttributedString?
        var sizes: [CGFloat?: CGSize] = [:]
        var measurements = 0
        var sizeQueries = 0
        /// 第一轮实验量到 SwiftUI 的 Text 给链接文字用的是系统 linkColor（浅色 #0068DA），不是 App 的主题色，这里跟它。
        var linkColor = NSColor.linkColor

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            parent?.onLink(url)
            return true
        }

        nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                           in textElement: NSTextElement) -> NSTextLayoutFragment {
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
    }
}
