import Foundation

/// 简写的归属由消息所在工作区提供；完整链接可以脱离当前焦点传递。
struct ReferenceScope: Equatable, Hashable, Sendable {
    let machineID: String
    let workspaceID: String
    /// 工作区目录，以 / 结尾，不知道时为空：绝对路径在它里面才是工作区的路径，见 FileReference.parse。
    let root: String
    /// 工作区目录顶层的名字，由工作机随工作区信息给出：路径的开头必须是其中之一。
    let names: Set<String>
    /// names 按首字分组，正文里逐字找路径开头时只试首字对得上的。
    let starts: [Character: [String]]

    init(machineID: String, workspaceID: String, root: String = "", names: [String] = []) {
        self.machineID = machineID
        self.workspaceID = workspaceID
        self.root = root.isEmpty || root == "/" ? "" : root.hasSuffix("/") ? root : root + "/"
        self.names = Set(names)
        starts = Dictionary(grouping: self.names.filter { !$0.isEmpty }, by: { $0.first! })
    }

    /// 完整链接是不是这个工作区的。链接里只有工作机和工作区，不比目录。
    func owns(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "machine" }?.value == machineID && items.first { $0.name == "workspace" }?.value == workspaceID
    }
}

struct FileReference: Equatable, Hashable, Sendable {
    var path: String
    var diffID: String?
    var startLine: Int?
    var endLine: Int?

    var label: String { (path as NSString).lastPathComponent }
    /// 没有扩展名、也没带定位的可能是目录，打开时先按目录试（见 FileBrowser.open）。
    var mayBeDirectory: Bool { diffID == nil && startLine == nil && (path as NSString).pathExtension.isEmpty }

    // 正文里每个像路径的词都要经这几条正则；编译比匹配贵得多，对话建行时曾占到正文属性串构建的四成（2026-10-12 实测）
    private static let lineSuffix = try! NSRegularExpression(pattern: #"#L(\d+)(?:-L?(\d+))?$"#)
    /// 定位里的 diff 编号和行号，这里的正则和正文里认定位的（ReferenceText.locator）共用。
    fileprivate static let diffPattern = "diff_[A-Za-z0-9_-]+"
    fileprivate static let linePattern = "[1-9][0-9]*"
    private static let parts = try! NSRegularExpression(pattern: #"^(.+?)(?::(\#(diffPattern)))?(?::(\#(linePattern))(?:-(\#(linePattern)))?)?$"#)
    private static let fileExtension = try! NSRegularExpression(pattern: #"\.[A-Za-z][A-Za-z0-9_-]*$"#)

    /// 工作机只打开工作区里的文件和目录，所以开头必须是工作区顶层的名字（scope.names）：绝对路径在工作区目录里的换成相对路径，
    /// 在外面的（比如网址的路径 /crevo/login）不算。只有顶层名字一段时，带扩展名的文件或写了结尾 / 的目录才算，免得 app、docs 这类词被当成路径。
    static func parse(_ source: String, in scope: ReferenceScope) -> Self? {
        var value = source
        if value.hasPrefix("file://"), let url = URL(string: value) { value = url.path }
        guard !value.contains("://"), !value.contains("\n"), !value.contains("\r") else { return nil }
        value = lineSuffix.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: ":$1-$2")
        if value.hasSuffix("-") { value.removeLast() }
        guard let match = parts.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func part(_ i: Int) -> String? { Range(match.range(at: i), in: value).map { String(value[$0]) } }
        guard var path = part(1), !path.contains(":") else { return nil }
        if path.hasPrefix("/") {
            guard !scope.root.isEmpty, path.hasPrefix(scope.root), path.count > scope.root.count else { return nil }
            path.removeFirst(scope.root.count)
        } else if path.hasPrefix("./") {
            path.removeFirst(2)
        }
        let directory = path.hasSuffix("/")
        if directory { path.removeLast() }
        guard let first = path.split(separator: "/").first, scope.names.contains(String(first)),
              path.contains("/") || directory || hasExtension(path) else { return nil }
        let start = part(3).flatMap(Int.init), end = part(4).flatMap(Int.init)
        guard part(3) == nil || start != nil, part(4) == nil || end != nil,
              end == nil || (start != nil && end! >= start!) else { return nil }
        return Self(path: path, diffID: part(2), startLine: start, endLine: end)
    }

    /// 最后一段带扩展名（.gitignore 这类点开头的名字也算）。
    static func hasExtension(_ path: String) -> Bool {
        fileExtension.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    func url(in scope: ReferenceScope) -> URL {
        var url = URLComponents()
        url.scheme = "kite"; url.host = "file"
        url.queryItems = [URLQueryItem(name: "machine", value: scope.machineID), URLQueryItem(name: "workspace", value: scope.workspaceID),
                          URLQueryItem(name: "path", value: path)]
        for (name, value) in [("diff", diffID), ("start", startLine.map(String.init)), ("end", endLine.map(String.init))] {
            if let value { url.queryItems?.append(URLQueryItem(name: name, value: value)) }
        }
        return url.url!
    }

    init(path: String, diffID: String? = nil, startLine: Int? = nil, endLine: Int? = nil) {
        self.path = path; self.diffID = diffID; self.startLine = startLine; self.endLine = endLine
    }

    init?(url: URL) {
        guard url.scheme == "kite", url.host == "file", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)).isSubset(of: ["machine", "workspace", "path", "diff", "start", "end"]),
              let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let start = value("start").flatMap(Int.init), end = value("end").flatMap(Int.init)
        guard value("start") == nil || (start ?? 0) > 0, value("end") == nil || (end ?? 0) > 0,
              end == nil || (start != nil && end! >= start!),
              value("diff") == nil || value("diff")!.range(of: "^\(Self.diffPattern)$", options: .regularExpression) != nil else { return nil }
        self.init(path: path, diffID: value("diff"), startLine: start, endLine: end)
    }
}

/// 本机地址上某个端口的网页：工作机上运行中的终端监听的端口，在所属工作区内解析到那个终端，打开到链接的路径（AppModel.openLocalPort）。
struct LocalPort: Equatable {
    private static let hosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
    let port: Int
    /// 端口后面的路径、查询和锚点，网页视图直接打开到这里；只到首页时为空。
    let path: String

    init?(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host(percentEncoded: false)?.lowercased(),
              Self.hosts.contains(host), let port = url.port, (1...65535).contains(port),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        self.port = port
        path = (components.percentEncodedPath == "/" ? "" : components.percentEncodedPath)
            + (components.percentEncodedQuery.map { "?\($0)" } ?? "") + (components.percentEncodedFragment.map { "#\($0)" } ?? "")
    }

    /// 正文里裸写的 localhost:端口，可以带路径，当作 http 链接。
    static func bare(_ text: String) -> URL? {
        guard let colon = text.firstIndex(of: ":"), hosts.contains(text[..<colon].lowercased()),
              let url = URL(string: "http://\(text)"), Self(url) != nil else { return nil }
        return url
    }
}

/// 点一次本机网页链接：终端的网页视图打开到它的路径。每点一次是新的一个，同一个链接再点也回到那里（见 PortPreview）。
struct WebLink: Equatable {
    let target: LocalPort
    let id = UUID()
}

/// 识别只看文字和工作区顶层的名字，不查文件是否存在；正文保留在原始记录中，缩短的文件名只用于显示。规则见 docs/资源引用.md。
enum ReferenceText {
    private static let webTokens = try! NSRegularExpression(pattern: #"https?://[^\s<>`\"'，。；！？（）]+|(?:localhost|127\.0\.0\.1|0\.0\.0\.0):[0-9]{1,5}(?:[/?#][^\s<>`\"'，。；！？（）]*)?"#)
    /// 路径后面紧跟的定位：#L 行号，或 diff 与行号。
    private static let locator: NSRegularExpression = {
        let (diff, line) = (FileReference.diffPattern, FileReference.linePattern)
        return try! NSRegularExpression(pattern: #"#L\#(line)(?:-L?\#(line))?|(?::\#(diff))?(?::\#(line)(?:-\#(line))?)?"#)
    }()

    private enum Found {
        case file(FileReference)
        case web(URL)
    }

    static func decorate(_ source: AttributedString, scope: ReferenceScope, compact: Bool = true) -> AttributedString {
        var result = AttributedString()
        var labels = 0
        func label(_ text: String, from source: AttributedString, link: URL) -> AttributedString {
            labels += 1
            return Self.label(text, from: source, link: link, id: labels)
        }
        func render(_ found: Found, _ original: AttributedString) -> AttributedString {
            switch found {
            case .file(let file):
                return label(compact ? file.label : String(original.characters), from: original, link: file.url(in: scope))
            case .web(let url):
                var text = original
                text.link = url
                return text
            }
        }
        for (link, intent, range) in source.runs[\.link, \.inlinePresentationIntent] {
            var part = AttributedString(source[range])
            if let link {
                if let file = FileReference(url: link) {
                    part = label(compact ? file.label : String(part.characters), from: part, link: link)
                } else if let file = FileReference.parse(link.absoluteString.removingPercentEncoding ?? link.absoluteString, in: scope) {
                    part = label(compact ? file.label : String(part.characters), from: part, link: file.url(in: scope))
                } else if link.scheme == nil {
                    // 不是工作区路径的相对链接（比如工作区外的 /crevo/login）没有地方打开，按普通文字显示
                    part.link = nil
                }
                result.append(part)
                continue
            }
            let plain = String(part.characters)
            // 行内代码整段是一个候选：路径里的括号、方括号不切开；带空白的（比如一条命令）不认。
            if intent?.contains(.code) == true {
                let found = plain.contains(where: \.isWhitespace) ? nil
                    : FileReference.parse(plain, in: scope).map(Found.file) ?? Self.web(plain).map(Found.web)
                result.append(found.map { render($0, part) } ?? part)
                continue
            }
            var cursor = plain.startIndex
            for (range, found) in references(in: plain, scope: scope) {
                result.append(slice(part, plain: plain, range: cursor..<range.lowerBound))
                result.append(render(found, slice(part, plain: plain, range: range)))
                cursor = range.upperBound
            }
            result.append(slice(part, plain: plain, range: cursor..<plain.endIndex))
        }
        return result
    }

    /// 正文里的网址和工作区路径，按先后、不重叠。
    private static func references(in text: String, scope: ReferenceScope) -> [(Range<String.Index>, Found)] {
        var webs: [(Range<String.Index>, Found)] = []
        for match in webTokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard var range = Range(match.range, in: text) else { continue }
            // 嵌在标识符里的碎片和邮箱地址不认
            if range.lowerBound > text.startIndex, "@:".contains(text[text.index(before: range.lowerBound)]) { continue }
            while let last = text[range].last, ".,;!?)。".contains(last) { range = range.lowerBound..<text.index(before: range.upperBound) }
            if let url = web(String(text[range])) { webs.append((range, .web(url))) }
        }
        // 从前往后，先开始的算：路径读进后面的网址时（src/localhost:3000）网址不算
        var found: [(Range<String.Index>, Found)] = []
        var next = webs.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            while next < webs.endIndex, webs[next].0.lowerBound < i { next += 1 }
            if next < webs.endIndex, webs[next].0.lowerBound == i {
                found.append(webs[next])
                i = webs[next].0.upperBound
            } else if let (range, file) = path(in: text, at: i, scope: scope) {
                found.append((range, .file(file)))
                i = range.upperBound
            } else {
                i = text.index(after: i)
            }
        }
        return found
    }

    /// 从 i 起的工作区路径：开头是工作区顶层的名字（目录后面接 /，文件带扩展名），往后一段段读到路径结束，再带上定位。
    private static func path(in text: String, at i: String.Index, scope: ReferenceScope) -> (Range<String.Index>, FileReference)? {
        // 前面紧挨着英文、数字或路径符号的是别的词的一部分
        if i > text.startIndex, case let previous = text[text.index(before: i)], continues(previous) || "@:".contains(previous) { return nil }
        var start = i
        if text[i] == ".", text[i...].hasPrefix("./") {
            start = text.index(i, offsetBy: 2)
        } else if text[i] == "/" {
            guard !scope.root.isEmpty, text[i...].hasPrefix(scope.root) else { return nil }
            start = text.index(i, offsetBy: scope.root.count)
        }
        guard start < text.endIndex, let names = scope.starts[text[start]] else { return nil }
        // 顶层名字取最长的：目录后面接 /，文件后面不再接文件名里的字
        var anchor: (end: String.Index, directory: Bool)?
        for name in names where text[start...].hasPrefix(name) {
            let after = text.index(start, offsetBy: name.count)
            if anchor.map({ after <= $0.end }) == true { continue }
            if after < text.endIndex, text[after] == "/" { anchor = (after, true) }
            else if FileReference.hasExtension(name), ends(text, at: after) { anchor = (after, false) }
        }
        guard let anchor else { return nil }
        var end = anchor.end
        if anchor.directory {
            end = text.index(after: end)
            while end < text.endIndex {
                let segment = segmentEnd(in: text, from: end)
                guard segment > end else { break }
                end = segment
                guard end < text.endIndex, text[end] == "/" else { break }
                end = text.index(after: end)
            }
        }
        // 句末的点不算路径
        while text[i..<end].hasSuffix("."), end > anchor.end { end = text.index(before: end) }
        if let match = locator.firstMatch(in: text, options: .anchored, range: NSRange(end..., in: text)),
           let range = Range(match.range, in: text) { end = range.upperBound }
        // 后面还接着 :字母数字 的是认不出的定位，不截一半当引用
        if end < text.endIndex, text[end] == ":", case let next = text.index(after: end), next < text.endIndex, continues(text[next]) { return nil }
        guard let file = FileReference.parse(String(text[i..<end]), in: scope) else { return nil }
        return (i..<end, file)
    }

    /// 一段名字到哪里结束：返回 / 或结束处的位置。
    /// 扩展名后面接的不是英文字母、数字、点、横线、下划线或 / 就结束；英文名字后面接中文也结束，除非中文后面紧跟扩展名（v2版本说明.md）；
    /// 括起英文名字的成对括号、方括号算名字的一部分（Next.js 的 (auth)、[id]）；空白和其他标点结束。
    private static func segmentEnd(in text: String, from start: String.Index) -> String.Index {
        var j = start
        var ascii = false
        while j < text.endIndex {
            let c = text[j]
            if c == "/" { return j }
            if c == "(" || c == "[" {
                let close: Character = c == "(" ? ")" : "]"
                var k = text.index(after: j)
                while k < text.endIndex, named(text[k]) { k = text.index(after: k) }
                guard k < text.endIndex, text[k] == close else { return j }
                ascii = true
                j = text.index(after: k)
                continue
            }
            if c == ".", let k = extensionEnd(in: text, at: j) {
                if ends(text, at: k) { return k }
                ascii = true
                j = k
                continue
            }
            if named(c) {
                ascii = true
                j = text.index(after: j)
                continue
            }
            if wide(c) {
                var k = j
                while k < text.endIndex, wide(text[k]) { k = text.index(after: k) }
                if ascii, k == text.endIndex || text[k] != "." || extensionEnd(in: text, at: k) == nil { return j }
                j = k
                continue
            }
            return j
        }
        return j
    }

    /// i 处的点开始一个扩展名（点后面是英文字母，接着英文字母或数字）时，扩展名结束的位置。
    private static func extensionEnd(in text: String, at i: String.Index) -> String.Index? {
        var k = text.index(after: i)
        guard k < text.endIndex, text[k].isASCII, text[k].isLetter else { return nil }
        while k < text.endIndex, text[k].isASCII, text[k].isLetter || text[k].isNumber { k = text.index(after: k) }
        return k
    }

    /// 名字在 k 处结束：后面不再接名字里的字；句末的点也算结束。
    private static func ends(_ text: String, at k: String.Index) -> Bool {
        guard k < text.endIndex, continues(text[k]) else { return true }
        guard text[k] == "." else { return false }
        let next = text.index(after: k)
        return next == text.endIndex || !continues(text[next])
    }

    /// 接在路径字符后面时仍属于同一个名字或路径的字符。
    private static func continues(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "._-/".contains(c))
    }

    /// 英文名字里的字。
    private static func named(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "._-@~+".contains(c))
    }

    /// 中文这类非英文的字和数字。
    private static func wide(_ c: Character) -> Bool {
        !c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func web(_ text: String) -> URL? {
        text.hasPrefix("https://") || text.hasPrefix("http://") ? URL(string: text) : LocalPort.bare(text)
    }

    private static func slice(_ value: AttributedString, plain: String, range: Range<String.Index>) -> AttributedString {
        let start = value.characters.index(value.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
        let end = value.characters.index(start, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
        return AttributedString(value[start..<end])
    }

    private static func label(_ label: String, from source: AttributedString, link: URL, id: Int) -> AttributedString {
        var result = AttributedString(label)
        if let attributes = source.runs.first?.attributes { result.setAttributes(attributes) }
        result.link = link
        result[ReferenceOriginalAttribute.self] = ReferenceOriginal(id: id, length: String(source.characters).utf16.count)
        return result
    }
}

/// 换成文件名显示的引用原来有多长（UTF-16）：显示的字和原文对不上，复制时按它对回原文。id 区分相邻的两个引用。
nonisolated struct ReferenceOriginal: Hashable, Sendable {
    let id: Int
    let length: Int
}

nonisolated enum ReferenceOriginalAttribute: AttributedStringKey {
    typealias Value = ReferenceOriginal
    static let name = "kite.referenceOriginal"
}
