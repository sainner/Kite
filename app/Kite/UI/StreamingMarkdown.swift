import Foundation

/// 生成中的 Markdown 先按写完的样子显示：末尾半截的标记补齐或先不显示，写完的那一下样子不跳。
/// - 「这里**很重」直接按粗体显示，不先露出两个星号；行内代码、删除线同样补上收尾。
/// - 「[文件名](app/Ki」先只显示文件名，写完才成链接。
/// - 表头那行等分隔行写完再出现，不先原样露出一行竖线。
/// - 末尾一行只有「-」「1.」「#」「>」「```」这类标记时先不显示：上一段不临时变成标题，也不闪一个空列表项、空引用；
///   代码块开头那行写完（语言定了）才出现，收尾的围栏半截时不当成代码里的字。
/// 只动最后一行（表格看末尾连着的几行），前面写完的部分原样不动；写完以后照原文显示。
enum StreamingMarkdown {
    static func settle(_ source: String) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.last else { return source }
        if let fence = openFence(lines) {
            // 开头那行还没写完，语言名还会变；收尾的围栏写了一半
            if fence.line == lines.count - 1 || closes(last, fence) { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
        // 表格：末尾连着的竖线行只有表头，或分隔行还没写完
        let finished = last.isEmpty
        let rows = lines.dropLast(finished ? 1 : 0).reversed().prefix(while: tableLine).count
        if rows == 1 || rows == 2 && !finished {
            lines.removeLast(rows + (finished ? 1 : 0))
            return lines.joined(separator: "\n")
        }
        if bareMarker(last) {
            lines.removeLast()
        } else if !tableLine(last) {
            lines[lines.count - 1] = Substring(inline(last))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 块

    /// 没收尾的代码块：围栏的字符、长度、开头在第几行。
    private static func openFence(_ lines: [Substring]) -> (mark: Character, count: Int, line: Int)? {
        var open: (mark: Character, count: Int, line: Int)?
        for (index, line) in lines.enumerated() {
            let rest = line.drop { $0 == " " }
            guard let mark = rest.first, mark == "`" || mark == "~" else { continue }
            let count = rest.prefix { $0 == mark }.count
            guard count >= 3 else { continue }
            let after = rest.dropFirst(count)
            if let fence = open {
                if mark == fence.mark, count >= fence.count, after.allSatisfy({ $0 == " " }) { open = nil }
            } else if !(mark == "`" && after.contains("`")) {
                open = (mark, count, index)
            }
        }
        return open
    }

    /// 代码块里的最后一行是写了一半的收尾围栏。
    private static func closes(_ line: Substring, _ fence: (mark: Character, count: Int, line: Int)) -> Bool {
        let rest = line.drop { $0 == " " }
        return !rest.isEmpty && rest.count < fence.count && rest.allSatisfy { $0 == fence.mark }
    }

    /// 竖线开头的一行，表格的表头、分隔行或一行数据。
    private static func tableLine(_ line: Substring) -> Bool {
        line.drop { $0 == " " }.first == "|"
    }

    /// 一行只有块的标记、还没写到内容：列表项、标题、引用、分隔线或标题下划线、代码围栏的开头。
    private static func bareMarker(_ line: Substring) -> Bool {
        var rest = line.drop { $0 == " " }
        var quoted = false
        while rest.first == ">" {
            quoted = true
            rest = rest.dropFirst().drop { $0 == " " }
        }
        let marks = rest.trimmingCharacters(in: .whitespaces)
        if marks.isEmpty { return quoted }
        if marks.allSatisfy({ "-=*_+ ".contains($0) }) { return true }
        if marks.count <= 6, marks.allSatisfy({ $0 == "#" }) { return true }
        if marks.allSatisfy({ $0 == "`" }) || marks.allSatisfy({ $0 == "~" }) { return true }
        let digits = marks.last == "." || marks.last == ")" ? marks.dropLast() : Substring(marks)
        return !digits.isEmpty && digits.count <= 9 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    // MARK: - 行内

    /// 最后一行补上没收尾的行内标记：行内代码、粗体斜体、删除线补收尾，没写完的链接只留文字。
    /// 末尾刚写出的标记（「这是**」）先不显示，等后面有字；它要是收尾，下面照样补回来。
    private static func inline(_ line: Substring) -> String {
        var characters = Array(line)
        while let last = characters.last, last == " " || last == "\t" { characters.removeLast() }
        while let last = characters.last, last == "*" || last == "~" || last == "`" { characters.removeLast() }
        var code: (start: Int, ticks: Int)?
        var marks: [(mark: Character, count: Int)] = []
        /// 没写完的链接：[ 在哪（图片是 ![ 的 !），] 在哪，( 开了没有。
        var link: (start: Int, close: Int?, destination: Bool)?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "`" {
                let ticks = run(characters, from: index)
                if let open = code {
                    if open.ticks == ticks { code = nil }
                } else {
                    code = (index, ticks)
                }
                index += ticks
                continue
            }
            if code != nil {
                index += 1
                continue
            }
            if link?.destination == true {
                if character == ")" { link = nil }
                index += 1
                continue
            }
            switch character {
            case "*", "~":
                let count = run(characters, from: index)
                index = close(characters, at: index, count: count, marks: &marks)
                continue
            case "[":
                let image = index > 0 && characters[index - 1] == "!"
                link = (image ? index - 1 : index, nil, false)
            case "]":
                if var open = link, open.close == nil {
                    if index + 1 == characters.count {
                        open.close = index
                        link = open
                    } else if characters[index + 1] == "(" {
                        open.close = index
                        open.destination = true
                        link = open
                        index += 2
                        continue
                    } else {
                        link = nil
                    }
                }
            default: break
            }
            index += 1
        }
        // 行内代码在最里面，先收它
        if let code { characters.append(contentsOf: String(repeating: "`", count: code.ticks)) }
        if let link {
            // 只留链接的文字：去掉 [（图片连同 !），] 以后的网址
            if let close = link.close { characters.removeSubrange(close...) }
            let opener = characters[link.start] == "!" ? 2 : 1
            characters.removeSubrange(link.start..<(link.start + opener))
        }
        while let last = characters.last, last == " " || last == "\t" { characters.removeLast() }
        for mark in marks.reversed() { characters.append(contentsOf: String(repeating: mark.mark, count: mark.count)) }
        return String(characters)
    }

    /// 从 index 起有几个相同的字符。
    private static func run(_ characters: [Character], from index: Int) -> Int {
        var end = index
        while end < characters.count, characters[end] == characters[index] { end += 1 }
        return end - index
    }

    /// 一串 * 或 ~：前面贴着字的能收尾，收掉同样长的那个开头；后面贴着字、前面不是英文字母数字的能开头（2*3 不算）。
    /// ~ 只认两个的删除线。返回这串之后的位置。
    private static func close(_ characters: [Character], at index: Int, count: Int, marks: inout [(mark: Character, count: Int)]) -> Int {
        let mark = characters[index]
        let end = index + count
        guard mark == "*" ? count <= 3 : count == 2 else { return end }
        let before = index > 0 ? characters[index - 1] : " "
        let after = end < characters.count ? characters[end] : " "
        if !before.isWhitespace, let opened = marks.lastIndex(where: { $0.mark == mark && $0.count == count }) {
            marks.remove(at: opened)
        } else if !after.isWhitespace, !(before.isASCII && (before.isLetter || before.isNumber)) {
            marks.append((mark, count))
        }
        return end
    }
}
