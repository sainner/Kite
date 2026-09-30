import Foundation

/// 简写的归属由消息所在工作区提供；完整链接可以脱离当前焦点传递。
struct ReferenceScope: Equatable, Hashable, Sendable {
    let machineID: String
    let workspaceID: String
}

struct FileReference: Equatable, Hashable, Sendable {
    var path: String
    var diffID: String?
    var startLine: Int?
    var endLine: Int?

    var label: String { (path as NSString).lastPathComponent }

    static func parse(_ source: String) -> Self? {
        var value = source
        if value.hasPrefix("file://"), let url = URL(string: value) { value = url.path }
        guard !value.contains("://"), !value.contains("\n"), !value.contains("\r") else { return nil }
        value = value.replacingOccurrences(of: #"#L(\d+)(?:-L?(\d+))?$"#, with: ":$1-$2", options: .regularExpression)
        if value.hasSuffix("-") { value.removeLast() }
        let pattern = #"^(.+?)(?::(diff_[A-Za-z0-9_-]+))?(?::([1-9][0-9]*)(?:-([1-9][0-9]*))?)?$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func part(_ i: Int) -> String? { Range(match.range(at: i), in: value).map { String(value[$0]) } }
        guard let path = part(1), !path.contains(":"),
              path.contains("/") || path.range(of: #"\.[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
        let start = part(3).flatMap(Int.init), end = part(4).flatMap(Int.init)
        guard part(3) == nil || start != nil, part(4) == nil || end != nil,
              end == nil || (start != nil && end! >= start!) else { return nil }
        return Self(path: path, diffID: part(2), startLine: start, endLine: end)
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
              value("diff") == nil || value("diff")!.range(of: #"^diff_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        self.init(path: path, diffID: value("diff"), startLine: start, endLine: end)
    }

    static func scope(of url: URL) -> ReferenceScope? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let machine = items.first(where: { $0.name == "machine" })?.value,
              let workspace = items.first(where: { $0.name == "workspace" })?.value else { return nil }
        return ReferenceScope(machineID: machine, workspaceID: workspace)
    }
}

/// 纯文本识别不访问磁盘或网络；正文保留在原始记录中，缩短的文件名只用于显示。
enum ReferenceText {
    private static let tokens = try! NSRegularExpression(pattern: #"https?://[^\s<>`\"'，。；！？（）]+|(?:\.?\.?/|/)?[\p{L}\p{N}_@.~-]+(?:/[\p{L}\p{N}_@.~-]+)*(?::diff_[A-Za-z0-9_-]+)?(?::[1-9][0-9]*(?:-[1-9][0-9]*)?)?"#)

    static func decorate(_ source: AttributedString, scope: ReferenceScope, compact: Bool = true) -> AttributedString {
        var result = AttributedString()
        for (link, range) in source.runs[\.link] {
            var part = AttributedString(source[range])
            if let link {
                if let file = FileReference(url: link) {
                    part = label(compact ? file.label : String(part.characters), from: part, link: link)
                } else if let file = FileReference.parse(link.absoluteString.removingPercentEncoding ?? link.absoluteString) {
                    part = label(compact ? file.label : String(part.characters), from: part, link: file.url(in: scope))
                }
                result.append(part)
                continue
            }
            let plain = String(part.characters)
            var cursor = plain.startIndex
            for match in tokens.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let range = Range(match.range, in: plain) else { continue }
                // 嵌在标识符中的碎片、邮箱地址和未支持的后缀不猜作文件。
                if range.lowerBound > plain.startIndex, "@:".contains(plain[plain.index(before: range.lowerBound)]) { continue }
                if range.upperBound < plain.endIndex, plain[range.upperBound] == ":" { continue }
                var raw = String(plain[range])
                while raw.last.map({ ".,;!?)。".contains($0) }) == true { raw.removeLast() }
                let file = FileReference.parse(raw)
                let web = raw.hasPrefix("https://") || raw.hasPrefix("http://") ? URL(string: raw) : nil
                guard file != nil || web != nil else { continue }
                let end = plain.index(range.lowerBound, offsetBy: raw.count)
                result.append(slice(part, plain: plain, range: cursor..<range.lowerBound))
                let original = slice(part, plain: plain, range: range.lowerBound..<end)
                if let file { result.append(label(compact ? file.label : String(original.characters), from: original, link: file.url(in: scope))) }
                else { var text = original; text.link = web; result.append(text) }
                cursor = end
            }
            result.append(slice(part, plain: plain, range: cursor..<plain.endIndex))
        }
        return result
    }

    private static func slice(_ value: AttributedString, plain: String, range: Range<String.Index>) -> AttributedString {
        let start = value.characters.index(value.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
        let end = value.characters.index(start, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
        return AttributedString(value[start..<end])
    }

    private static func label(_ label: String, from source: AttributedString, link: URL) -> AttributedString {
        var result = AttributedString(label)
        if let attributes = source.runs.first?.attributes { result.setAttributes(attributes) }
        result.link = link
        return result
    }
}
