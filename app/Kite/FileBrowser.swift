import Foundation
import Observation

/// 一个文件实例共用选择；目录位置和文本页码只属于当前设备。
@Observable
final class FileBrowser {
    let instanceID: String
    let workspaceID: String
    let sample: Bool
    private var client: KitedClient?
    private var directoryRequest = UUID()
    private var textRequest = UUID()
    private(set) var connectionRevision = UUID()
    private(set) var selection = FileSelection(path: nil, revision: "initial")
    private(set) var directory: FileDirectory?
    private(set) var page: FilePage?
    private(set) var directoryPath = "."
    private(set) var directoryOffset = 0
    private(set) var loadingDirectory = false
    private(set) var loadingText = false
    private(set) var contentRevision = UUID()
    private(set) var selecting = false
    private(set) var diff: FileDiffRecord?
    private(set) var diffRows: [FileDiffRow] = []
    private(set) var focus: FileReference?
    private(set) var focusID = UUID()
    var showDirectory = true
    var rendered = false
    var requestKey: String { connectionRevision.uuidString + selection.revision + focusID.uuidString }
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

    init(instanceID: String, workspaceID: String, client: KitedClient?, sample: Bool) {
        self.instanceID = instanceID
        self.workspaceID = workspaceID
        self.client = client
        self.sample = sample
    }

    func update(_ instance: RemotePluginInstance, client: KitedClient?) {
        if self.client != client {
            self.client = client
            connectionRevision = UUID()
            directoryRequest = UUID()
            textRequest = UUID()
            directory = nil
            page = nil
            diff = nil
            diffRows = []
            focus = nil
            loadingDirectory = false
            loadingText = false
        }
        if !sample { receive(FileSelection(path: instance.state?.path, revision: instance.state?.revision ?? "initial", diffId: instance.state?.diffId)) }
    }

    private func receive(_ value: FileSelection) {
        guard selection != value else { return }
        if selection.path != value.path || selection.diffId != value.diffId { focus = nil }
        selection = value
        diff = nil
        diffRows = []
        textRequest = UUID()
        page = nil
        textError = nil
        loadingText = false
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

    func list(_ path: String? = nil, offset: Int? = nil) async {
        let path = path ?? directoryPath
        let offset = offset ?? (path == directoryPath ? directoryOffset : 0)
        let request = UUID()
        directoryRequest = request
        directoryPath = path
        directoryOffset = offset
        directory = nil
        directoryError = nil
        loadingDirectory = true
        defer { if directoryRequest == request { loadingDirectory = false } }
        do {
            let value: FileDirectory
            if sample { value = SampleFiles.list(path) }
            else { value = try await operation("list", body: PathRequest(instanceId: instanceID, path: path, offset: offset), as: FileDirectory.self) }
            guard directoryRequest == request, !Task.isCancelled else { return }
            directory = value
            directoryPath = value.path
        } catch {
            if directoryRequest == request && !Task.isCancelled { directoryError = error.localizedDescription }
        }
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
            let value: FilePage
            if sample { value = try SampleFiles.read(path, offset: offset) }
            else { value = try await operation("read", body: PathRequest(instanceId: instanceID, path: path, offset: offset), as: FilePage.self) }
            guard textRequest == request, !Task.isCancelled else { return }
            if offset > 1 && offset > value.totalLines {
                await read(offset: 1)
                return
            }
            page = value
            contentRevision = UUID()
        } catch {
            if textRequest == request && !Task.isCancelled { textError = error.localizedDescription }
        }
    }

    func loadSelection() async {
        guard let id = selection.diffId else { await read(offset: focus?.startLine ?? 1); return }
        let request = UUID()
        textRequest = request
        loadingText = true
        textError = nil
        defer { if textRequest == request { loadingText = false } }
        do {
            let value: FileDiffRecord
            if sample { value = try SampleFiles.diff(id) }
            else { value = try await operation("diff", body: ["instanceId": instanceID, "diffId": id], as: FileDiffRecord.self) }
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
        if selection.path != reference.path || selection.diffId != reference.diffID {
            guard await select(reference.path, diffID: reference.diffID) else { throw KitedError(message: directoryError ?? "无法选择文件") }
        }
        focus = reference
        focusID = UUID()
        showDirectory = false
        rendered = false
    }

    func select(_ path: String, diffID: String? = nil) async -> Bool {
        guard !selecting else { return false }
        selecting = true
        directoryError = nil
        defer { selecting = false }
        let before = selection.revision
        let connection = connectionRevision
        do {
            let value: FileSelection
            if sample {
                if let diffID {
                    guard try SampleFiles.diff(diffID).files.contains(where: { $0.path == path }) else { throw KitedError(message: "这份差异中没有指定文件") }
                } else { _ = try SampleFiles.read(path) }
                value = FileSelection(path: path, revision: UUID().uuidString, diffId: diffID)
            }
            else {
                var body = ["instanceId": instanceID, "operationId": UUID().uuidString, "expectedRevision": before, "path": path]
                if let diffID { body["diffId"] = diffID }
                value = try await operation("select", body: body, as: FileSelection.self)
            }
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

/// 样本文件和历史差异可实际打开；当前文本已经是第二次修改后的版本。
enum SampleFiles {
    static let original = "# Kite\n\n个人 agent 工作台。\n\n先阅读文件。\n"
    static let first = "# Kite\n\n个人 agent 工作台。\n\n文件与预览共用一个窗口。\n"
    static let current = "# Kite\n\n个人 agent 工作台。\n\n文件、预览和 diff 共用一个窗口。\n历史引用可以回看每次修改。\n"
    static let texts = ["README.md": current, "docs/窗口.md": "# 工作区窗口\n\n窗口集合由工作机保存。\n布局、滚动和焦点由当前设备管理。\n"]
    static func list(_ path: String) -> FileDirectory {
        let entries: [FileDirectory.Entry] = path == "." ? [
            .init(name: "docs", path: "docs", kind: "directory"), .init(name: "README.md", path: "README.md", kind: "file"),
        ] : [.init(name: "窗口.md", path: "docs/窗口.md", kind: "file")]
        return .init(path: path, entries: entries, total: entries.count, nextOffset: nil)
    }
    static func read(_ path: String, offset: Int = 1) throws -> FilePage {
        guard let text = texts[path] else { throw KitedError(message: "样本中没有这个文件：" + path) }
        let lines = text.components(separatedBy: "\n")
        let end = min(lines.count, offset - 1 + 200)
        return .init(path: path, text: lines.dropFirst(offset - 1).prefix(200).joined(separator: "\n"), offset: offset,
                     totalLines: lines.count, nextOffset: end < lines.count ? end + 1 : nil, version: "sample")
    }
    static func diff(_ id: String) throws -> FileDiffRecord {
        switch id {
        case "diff_sample1": .init(id: id, files: [.init(path: "README.md", before: original, after: first)])
        case "diff_sample2": .init(id: id, files: [.init(path: "README.md", before: first, after: current)])
        default: throw KitedError(message: "这份历史差异已不存在")
        }
    }
}
