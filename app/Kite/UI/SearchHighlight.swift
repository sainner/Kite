import SwiftUI

/// 窗口里查找时要标出来的字：每个匹配垫浅色底，当前那个垫深一点。怎么算匹配见 TextSearch。
struct SearchHighlight: Equatable {
    let query: String
    /// 当前匹配在这一段里是第几个；不在这一段是 nil。
    var current: Int?

    private static let match = Theme.warning.opacity(0.3)
    private static let currentMatch = Theme.warning.opacity(0.75)

    func apply(to text: AttributedString) -> AttributedString {
        let plain = String(text.characters)
        let found = TextSearch.ranges(of: query, in: plain)
        guard !found.isEmpty else { return text }
        // 按字符偏移换成 AttributedString 的下标，从上一个匹配接着数；在原文上切段拼出结果，不在改过的串上取下标。
        var result = AttributedString()
        var (plainCursor, cursor) = (plain.startIndex, text.startIndex)
        for (index, range) in found.enumerated() {
            let start = text.characters.index(cursor, offsetBy: plain.distance(from: plainCursor, to: range.lowerBound))
            let end = text.characters.index(start, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            result.append(text[cursor..<start])
            var match = AttributedString(text[start..<end])
            match.backgroundColor = index == current ? Self.currentMatch : Self.match
            result.append(match)
            (plainCursor, cursor) = (range.upperBound, end)
        }
        result.append(text[cursor...])
        return result
    }

    func apply(to text: String) -> AttributedString { apply(to: AttributedString(text)) }
}

extension EnvironmentValues {
    /// 文件预览里查找时要标出的字：Markdown 预览按它标出每一块里的匹配，代码块的语法高亮也叠上它；没在找是 nil。
    @Entry var searchHighlight: SearchHighlight?
}
