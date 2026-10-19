import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 一个文件实例共用选择；目录位置和文本页码只属于当前设备。
@Observable
final class FileBrowser {
    let instanceID: String
    let workspaceID: String
    private var client: KitedClient?
    private var textRequest = UUID()
    private(set) var connectionRevision = UUID()
    private(set) var selection = FileSelection(path: nil, revision: "initial")
    private(set) var page: FilePage?
    /// 目录树，只属于当前设备：读过的目录按路径存（根目录是 "."），展开了哪些另记。
    private(set) var listings: [String: FileDirectory] = [:]
    private(set) var expanded: Set<String> = []
    /// 正在读的目录。
    private(set) var loadingPaths: Set<String> = []
    private var listRequests: [String: UUID] = [:]
    /// 按名字搜到的文件和目录；nil 是没在搜。
    private(set) var searchResults: FileSearchResults?
    private(set) var searchingFiles = false
    private var searchRequest = UUID()
    /// 在所选文件里找到的位置，按先后；见 find。
    private(set) var matches: [FileMatch] = []
    private var findRequest = UUID()
    private(set) var loadingText = false
    private(set) var contentRevision = UUID()
    private(set) var selecting = false
    private(set) var diff: FileDiffRecord?
    private(set) var diffRows: [FileDiffRow] = []
    private(set) var focus: FileReference?
    private(set) var focusID = UUID()
    /// 所选文件按什么方式呈现；认不出的文本读失败后改为 other。
    private(set) var format = FileFormat.text
    /// 渲染和系统预览用的本机副本；文本按页读，不经这里。
    private(set) var content: CachedFile?
    /// 整篇渲染的 Markdown 原文。
    private(set) var markdown: String?
    private(set) var info: FileInfo?
    /// 只显示文件信息的原因，例如文本超过上限。
    private(set) var infoNote: String?
    /// 正在下载时的进度。
    private(set) var download: Progress?
    var showDirectory = true
    /// 目录树要滚到的目录：展开到它时设上，目录树滚过去后清掉（见 FilePane.directory）。
    var revealed: String?
    /// Markdown、HTML 显示渲染结果还是原文。
    var rendered = true
    var displayingFile: Bool { selection.path != nil }
    var root: FileDirectory? { listings["."] }
    var loadingDirectory: Bool { loadingPaths.contains(".") }
    var isLocal: Bool { client?.isLocal == true }
    var connection: KitedClient? { client }
    /// 渲染 HTML 时网页报的错。
    var pageError: String?
    var requestKey: String { connectionRevision.uuidString + selection.revision + focusID.uuidString + String(rendered) }
    var locationMessage: String? {
        guard let start = focus?.startLine else { return nil }
        if let page, start > page.totalLines { return "定位行已超出文件范围" }
        if diff != nil, !diffRows.contains(where: { $0.newLine == start }) {
            return "这份差异中没有指定行，已显示首个改动"
        }
        return nil
    }
    var focusedRow: Int? {
        if let start = focus?.startLine,
           let row = diffRows.first(where: { $0.newLine == start }) { return row.id }
        return diffRows.first { $0.kind != .same }?.id
    }

    var directoryError: String?
    var textError: String?

    init(instanceID: String, workspaceID: String, client: KitedClient?, showDirectory: Bool = true) {
        self.instanceID = instanceID
        self.workspaceID = workspaceID
        self.client = client
        self.showDirectory = showDirectory
    }

    func update(_ instance: RemotePluginInstance, client: KitedClient?) {
        if self.client != client {
            self.client = client
            connectionRevision = UUID()
            listRequests = [:]
            textRequest = UUID()
            listings = [:]
            loadingPaths = []
            page = nil
            diff = nil
            diffRows = []
            focus = nil
            resetContent()
            loadingText = false
        }
        receive(FileSelection(path: instance.state?.path, revision: instance.state?.revision ?? "initial", diffId: instance.state?.diffId))
    }

    private func receive(_ value: FileSelection) {
        guard selection != value else { return }
        endFind()
        if selection.path != value.path || selection.diffId != value.diffId { focus = nil }
        selection = value
        diff = nil
        diffRows = []
        textRequest = UUID()
        page = nil
        resetContent()
        format = value.diffId == nil ? FileFormat(path: value.path ?? "") : .text
        textError = nil
        loadingText = false
    }

    private func resetContent() {
        pageError = nil
        content = nil
        markdown = nil
        info = nil
        infoNote = nil
        download = nil
    }

    private struct PathRequest: Encodable {
        let instanceId: String
        let path: String
        let offset: Int
        var limit = 200
    }

    private func operation<T: Decodable>(_ name: String, body: any Encodable, as type: T.Type) async throws -> T {
        guard let client else { throw KitedError(message: "请先连接工作机") }
        return try await client.request("/workspaces/\(workspaceID)/operations/files.\(name)", method: "POST", body: body, as: type)
    }

    /// 重读根目录和展开着的目录，各读第一页。
    func list() async {
        await load(".")
        for path in expanded.sorted() { await load(path) }
    }

    /// 展开或收起一个目录，第一次展开时去读。
    func toggle(_ path: String) async {
        if expanded.remove(path) != nil { return }
        expanded.insert(path)
        if listings[path] == nil { await load(path) }
    }

    /// 目录超过一页时接着读下一页，接在已读的后面。
    func loadMore(_ path: String) async {
        guard let offset = listings[path]?.nextOffset, !loadingPaths.contains(path) else { return }
        await load(path, offset: offset)
    }

    /// 展开到这个目录：它和上面各级都展开，没读过的去读，目录树再滚到它。
    func reveal(_ path: String) async {
        var prefix = ""
        for part in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            expanded.insert(prefix)
            if listings[prefix] == nil { await load(prefix) }
        }
        revealed = path
    }

    /// 按名字在整个工作区里找文件和目录；关键字为空时回到目录树。
    func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespaces)
        let request = UUID()
        searchRequest = request
        guard !query.isEmpty else {
            searchResults = nil
            searchingFiles = false
            return
        }
        searchingFiles = true
        defer { if searchRequest == request { searchingFiles = false } }
        do {
            struct Search: Encodable { let instanceId: String; let query: String }
            let value = try await operation("search", body: Search(instanceId: instanceID, query: query), as: FileSearchResults.self)
            guard searchRequest == request, !Task.isCancelled else { return }
            searchResults = value
        } catch {
            if searchRequest == request && !Task.isCancelled { directoryError = error.localizedDescription }
        }
    }

    func endSearch() {
        searchRequest = UUID()
        searchResults = nil
        searchingFiles = false
    }

    /// 在所选文件里找：历史差异逐行找；文本按页读，这里另取整份文件来找。
    func find(_ query: String) async {
        let request = UUID()
        findRequest = request
        guard !query.isEmpty else { matches = []; return }
        if diff != nil {
            matches = diffRows.flatMap { row in TextSearch.ranges(of: query, in: row.text).indices.map { FileMatch(line: row.id, occurrence: $0) } }
            return
        }
        guard let path = selection.path, let client else { return }
        do {
            let file = try await FileContentCache.shared.file(client: client, workspace: workspaceID, path: path)
            // 读整份、逐行找放到后台，大文件不卡界面。
            let found = try await Task.detached(priority: .userInitiated) {
                try String(contentsOf: file.url, encoding: .utf8).components(separatedBy: "\n").enumerated().flatMap { index, line in
                    TextSearch.ranges(of: query, in: line).indices.map { FileMatch(line: index + 1, occurrence: $0) }
                }
            }.value
            guard findRequest == request, !Task.isCancelled else { return }
            matches = found
        } catch {
            if findRequest == request && !Task.isCancelled { textError = error.localizedDescription }
        }
    }

    func endFind() {
        findRequest = UUID()
        matches = []
    }

    private func load(_ path: String, offset: Int = 0) async {
        let request = UUID()
        listRequests[path] = request
        loadingPaths.insert(path)
        if path == "." { directoryError = nil }
        defer {
            if listRequests[path] == request {
                listRequests[path] = nil
                loadingPaths.remove(path)
            }
        }
        do {
            let value = try await operation("list", body: PathRequest(instanceId: instanceID, path: path, offset: offset), as: FileDirectory.self)
            guard listRequests[path] == request, !Task.isCancelled else { return }
            if offset > 0, let loaded = listings[path] {
                listings[path] = FileDirectory(path: value.path, entries: loaded.entries + value.entries, total: value.total, nextOffset: value.nextOffset)
            } else {
                listings[path] = value
            }
        } catch {
            guard listRequests[path] == request, !Task.isCancelled else { return }
            // 子目录读不了（删掉了、没权限）就收起来
            if path != "." {
                expanded.remove(path)
                listings[path] = nil
            }
            directoryError = error.localizedDescription
        }
    }

    /// 目录树里看得见的行：展开的目录下面接着它的内容，还没读到时是一行「正在读取」，没读完时末尾一行「还有几项」。
    var treeRows: [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func add(_ path: String, depth: Int) {
            guard let listing = listings[path] else {
                if path != ".", loadingPaths.contains(path) { rows.append(FileTreeRow(id: "loading:" + path, depth: depth, kind: .loading)) }
                return
            }
            for entry in listing.entries {
                let open = entry.kind == "directory" && expanded.contains(entry.path)
                rows.append(FileTreeRow(id: entry.path, depth: depth, kind: .entry(entry, expanded: open)))
                if open { add(entry.path, depth: depth + 1) }
            }
            if let offset = listing.nextOffset {
                rows.append(FileTreeRow(id: "more:" + path, depth: depth, kind: .more(directory: path, remaining: listing.total - offset)))
            }
        }
        add(".", depth: 0)
        return rows
    }

    func read(offset: Int = 1) async {
        guard let path = selection.path else { return }
        let request = UUID()
        textRequest = request
        page = nil
        textError = nil
        loadingText = true
        defer { if textRequest == request { loadingText = false } }
        do {
            let value = try await operation("read", body: PathRequest(instanceId: instanceID, path: path, offset: offset), as: FilePage.self)
            guard textRequest == request, !Task.isCancelled else { return }
            if offset > 1 && offset > value.totalLines {
                await read(offset: 1)
                return
            }
            page = value
            contentRevision = UUID()
        } catch {
            guard textRequest == request, !Task.isCancelled else { return }
            // 太大或不是文本：不再当文本看，只列文件信息
            if let status = (error as? KitedError)?.status, status == 413 || status == 415, format == .text {
                format = .other
                infoNote = status == 413 ? "文件超过 2 MiB，不按文本显示" : "不是文本文件，也不是系统能预览的格式"
                await describe()
                return
            }
            textError = error.localizedDescription
        }
    }

    func loadSelection() async {
        if let id = selection.diffId { await loadDiff(id); return }
        switch format {
        case .text: await read(offset: focus?.startLine ?? 1)
        case .markdown, .html:
            if rendered { await fetch() } else { await read(offset: focus?.startLine ?? 1) }
        case .pdf, .quickLook: await fetch()
        case .other: await describe()
        }
    }

    /// 取整份文件到本机缓存，给渲染、系统预览和共享用。
    func fetch() async {
        guard let path = selection.path, let client else { return }
        let request = UUID()
        textRequest = request
        textError = nil
        loadingText = true
        defer { if textRequest == request { loadingText = false; download = nil } }
        do {
            let file = try await FileContentCache.shared.file(client: client, workspace: workspaceID, path: path) { [weak self] progress in
                Task { @MainActor in if self?.textRequest == request { self?.download = progress } }
            }
            guard textRequest == request, !Task.isCancelled else { return }
            if format == .markdown {
                // 太长的整篇排版很慢，只看原文
                guard file.info.size <= 1 << 20 else {
                    rendered = false
                    infoNote = "文件超过 1 MiB，只显示原文"
                    return
                }
                markdown = try String(contentsOf: file.url, encoding: .utf8)
            }
            content = file
            contentRevision = UUID()
        } catch {
            if textRequest == request && !Task.isCancelled { textError = error.localizedDescription }
        }
    }

    private func describe() async {
        guard let path = selection.path, let client else { return }
        let request = UUID()
        textRequest = request
        textError = nil
        loadingText = true
        defer { if textRequest == request { loadingText = false } }
        do {
            let value = try await FileContentCache.shared.info(client: client, workspace: workspaceID, path: path)
            guard textRequest == request, !Task.isCancelled else { return }
            info = value
        } catch {
            if textRequest == request && !Task.isCancelled { textError = error.localizedDescription }
        }
    }

    /// Markdown 里的图片：网址直接取，其他按相对这份 Markdown 的工作区路径取。
    func image(_ source: String) async throws -> PlatformImage {
        let data: Data
        if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased()) {
            data = try await URLSession.shared.data(from: url).0
        } else {
            guard let client, let path = selection.path else { throw KitedError(message: "请先连接工作机") }
            let file = try await FileContentCache.shared.file(client: client, workspace: workspaceID, path: Self.resolve(source, from: path))
            data = try Data(contentsOf: file.url)
        }
        guard let image = PlatformImage(data: data) else { throw KitedError(message: "不是能显示的图片") }
        return image
    }

    /// 相对路径按 file 所在目录解析，/ 开头的从工作区根算起；越出工作区的由工作机拒绝。
    static func resolve(_ source: String, from file: String) -> String {
        let raw = String(source.split(separator: "#", omittingEmptySubsequences: false)[0].split(separator: "?", omittingEmptySubsequences: false)[0])
        let path = raw.removingPercentEncoding ?? raw
        var parts = path.hasPrefix("/") ? [] : (file as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for part in path.split(separator: "/") where part != "." {
            if part == "..", let last = parts.last, last != ".." { parts.removeLast() }
            else { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    private func loadDiff(_ id: String) async {
        let request = UUID()
        textRequest = request
        loadingText = true
        textError = nil
        defer { if textRequest == request { loadingText = false } }
        do {
            let value = try await operation("diff", body: ["instanceId": instanceID, "diffId": id], as: FileDiffRecord.self)
            guard textRequest == request, !Task.isCancelled else { return }
            guard let file = value.files.first(where: { $0.path == selection.path }) else { throw KitedError(message: "这份差异中没有指定文件") }
            diff = value
            diffRows = FileDiffRow.rows(before: file.before ?? "", after: file.after ?? "")
            contentRevision = UUID()
        } catch {
            if textRequest == request && !Task.isCancelled { textError = error.localizedDescription }
        }
    }

    func navigate(_ reference: FileReference) async throws {
        // 读得出目录的是目录：打开目录栏、展开到它；读不出的（是文件、不存在）照文件选
        if reference.mayBeDirectory,
           let listing = try? await operation("list", body: PathRequest(instanceId: instanceID, path: reference.path, offset: 0), as: FileDirectory.self) {
            listings[reference.path] = listing
            showDirectory = true
            await reveal(reference.path)
            return
        }
        if selection.path != reference.path || selection.diffId != reference.diffID {
            guard await select(reference.path, diffID: reference.diffID) else { throw KitedError(message: directoryError ?? "无法选择文件") }
        }
        focus = reference
        focusID = UUID()
        showDirectory = false
        // 作为成果打开时先看渲染结果，指定了行就看原文
        rendered = reference.startLine == nil
    }

    func select(_ path: String, diffID: String? = nil) async -> Bool {
        guard !selecting else { return false }
        selecting = true
        directoryError = nil
        defer { selecting = false }
        let before = selection.revision
        let connection = connectionRevision
        do {
            var body = ["instanceId": instanceID, "operationId": UUID().uuidString, "expectedRevision": before, "path": path]
            if let diffID { body["diffId"] = diffID }
            let value = try await operation("select", body: body, as: FileSelection.self)
            guard connectionRevision == connection, !Task.isCancelled else { return false }
            // 工作区通知可能已经带来另一端的新选择，迟到的操作响应不能覆盖它。
            if selection.revision == before { receive(value) }
            guard selection.path == value.path, selection.diffId == value.diffId else { throw KitedError(message: "另一端已选择其他文件，请重新打开引用") }
            return true
        } catch {
            directoryError = error.localizedDescription
            return false
        }
    }
}

struct FileDiffRecord: Decodable {
    struct File: Decodable { let path: String; let before: String?; let after: String? }
    let id: String
    let files: [File]
}

struct FileDiffRow: Identifiable {
    enum Kind { case same, added, removed }
    let id: Int
    let oldLine: Int?
    let newLine: Int?
    let text: String
    let kind: Kind

    static func rows(before: String, after: String) -> [Self] {
        var oldLine = 1, newLine = 1
        return LineDiff(old: before, new: after).lines.enumerated().map { index, line in
            switch line {
            case .same(let text):
                defer { oldLine += 1; newLine += 1 }
                return Self(id: index, oldLine: oldLine, newLine: newLine, text: text, kind: .same)
            case .added(let text):
                defer { newLine += 1 }
                return Self(id: index, oldLine: nil, newLine: newLine, text: text, kind: .added)
            case .removed(let text):
                defer { oldLine += 1 }
                return Self(id: index, oldLine: oldLine, newLine: nil, text: text, kind: .removed)
            }
        }
    }
}

/// 目录树里的一行，见 FileBrowser.treeRows。
struct FileTreeRow: Identifiable {
    enum Kind {
        case entry(FileDirectory.Entry, expanded: Bool)
        case loading
        case more(directory: String, remaining: Int)
    }

    let id: String
    let depth: Int
    let kind: Kind
}

/// 按名字搜到的文件和目录，见 files.search。
struct FileSearchResults: Decodable {
    let query: String
    let entries: [FileDirectory.Entry]
    let truncated: Bool
}

/// 文件里找到的一处：在第几行（历史差异里是差异行的 id），是这一行里的第几个。
nonisolated struct FileMatch: Equatable, Sendable {
    let line: Int
    let occurrence: Int
}

/// 查找怎么算匹配：按字面、不分大小写，互不重叠，按先后。
nonisolated enum TextSearch {
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            found.append(range)
            start = range.upperBound
        }
        return found
    }
}
