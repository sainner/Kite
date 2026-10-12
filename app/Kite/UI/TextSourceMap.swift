import Foundation

/// 文本视图里显示的字对应原文的哪里。复制时按选区取回原文：对话正文给 Markdown 原文，用户消息给打的原文（用户 2026-10-12 决定一律给原文）。
/// 起点落在一块的开头（含块前的列表编号、符号）就从这块原文的行首起，终点落在一块的末尾就到这块原文的行尾，中间原样照搬；
/// 落在一块中间时，和原文逐字相同的字从中间截，粗体、代码、链接、缩短显示的文件引用这类扩到整段连标记。
/// 代码块、表格、分隔线是一个附件字符，选到就是整块。下标都是 UTF-16 的，和 NSString、NSRange 一致。
nonisolated struct TextSourceMap: Equatable, Sendable {
    var blocks: [Block] = []

    struct Block: Equatable, Sendable {
        /// 这一块在显示串里的范围，含列表编号这类前缀，不含块间的换行。
        var display: NSRange
        /// 正文在显示串里从哪起（前缀之后）。
        var content: Int
        /// 原文里这一块占的整行。
        var lines: NSRange
        /// 正文里一段一段的字；整块嵌进来的没有。
        var pieces: [Piece] = []
    }

    struct Piece: Equatable, Sendable {
        var display: NSRange
        /// 逐字对应时显示的字对应的原文。
        var source: NSRange
        /// 起止落在这段中间、又不能逐字截时，扩到的原文。
        var outer: NSRange
        var exact: Bool
    }

    /// 选区对应的原文范围；选区为空或对不上时是 nil。
    func sourceRange(for selection: NSRange) -> NSRange? {
        guard selection.length > 0 else { return nil }
        let end = NSMaxRange(selection)
        guard let first = blocks.first(where: { NSMaxRange($0.display) > selection.location }),
              let last = blocks.last(where: { $0.display.location < end }), first.display.location < end else { return nil }
        let lower: Int
        if selection.location <= first.content {
            lower = first.lines.location
        } else if let piece = first.pieces.first(where: { NSLocationInRange(selection.location, $0.display) }) {
            lower = piece.exact ? piece.source.location + selection.location - piece.display.location : piece.outer.location
        } else {
            lower = first.lines.location
        }
        let upper: Int
        if end >= NSMaxRange(last.display) {
            upper = NSMaxRange(last.lines)
        } else if let piece = last.pieces.first(where: { NSLocationInRange(end - 1, $0.display) }) {
            upper = piece.exact ? piece.source.location + end - piece.display.location : NSMaxRange(piece.outer)
        } else {
            upper = NSMaxRange(last.lines)
        }
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// 选区对应的原文。
    func text(for selection: NSRange, in source: String) -> String? {
        let text = source as NSString
        guard let range = sourceRange(for: selection), NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }
}

extension MarkdownSource {
    /// block.text 里 original 这段字显示在 display。只落在一段逐字相同的普通字里的，从原文截出同样一段，可以从中间截；
    /// atomic（链接、缩短的引用）和带标记的、有转义的，只能整段取，扩到标记外。
    func piece(display: NSRange, original: NSRange, atomic: Bool) -> TextSourceMap.Piece {
        let covered = runs.filter { $0.start < NSMaxRange(original) && $0.start + $0.length > original.location }
        guard let first = covered.first, let last = covered.last else {
            let at = NSRange(location: NSMaxRange(lines), length: 0)
            return .init(display: display, source: at, outer: at, exact: false)
        }
        if covered.count == 1, first.exact, !first.styled {
            let part = NSRange(location: first.span.location + original.location - first.start, length: original.length)
            return .init(display: display, source: part, outer: part, exact: !atomic)
        }
        return .init(display: display, source: NSUnionRange(first.span, last.span), outer: NSUnionRange(first.outer, last.outer), exact: false)
    }
}

/// 文本视图要放的东西：属性串、嵌在里面的块、复制时取原文用的对照。
struct TextViewContent {
    var text: NSAttributedString
    /// 嵌在字里的块，按出现的顺序；附件就在 text 里，这里另外带上它该显示的内容，流式更新时属性串不变也能换。
    var blocks: [(attachment: BlockAttachment, content: EmbeddedBlock)] = []
    /// 原文和对照；没有时复制按显示的字。
    var source: (text: String, map: TextSourceMap)?

    init(text: NSAttributedString, blocks: [(attachment: BlockAttachment, content: EmbeddedBlock)] = [],
         source: (text: String, map: TextSourceMap)? = nil) {
        self.text = text
        self.blocks = blocks
        self.source = source
    }
}
