import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// 文件按什么方式呈现，看扩展名。认不出的先当文本读，读不成再只显示文件信息。
enum FileFormat: Equatable {
    case text, markdown, html, pdf
    /// 交给系统的通用预览：图片、音视频、幻灯片与文档、表格。
    case quickLook
    /// 不是文本，系统也预览不了。
    case other

    private static let documents: Set<String> = [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text",
        "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages",
    ]

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { self = .text; return }
        if ["md", "markdown", "mdown", "mkd"].contains(ext) { self = .markdown }
        else if type.conforms(to: .html) { self = .html }
        else if type.conforms(to: .pdf) { self = .pdf }
        // CSV、RTF 也是文本，系统预览排成表格和版式，比原文好看
        else if [.commaSeparatedText, .tabSeparatedText, .rtf, .image, .audiovisualContent, .presentation, .spreadsheet, .threeDContent]
            .contains(where: type.conforms) || Self.documents.contains(type.identifier) { self = .quickLook }
        else if type.conforms(to: .text) || type.conforms(to: .sourceCode) { self = .text }
        else { self = .other }
    }

    /// 有原文与渲染两种看法的格式。
    var renderable: Bool { self == .markdown || self == .html }

    var symbol: String {
        switch self {
        case .text, .markdown, .html: "doc.text"
        case .pdf: "doc.richtext"
        case .quickLook: "doc.viewfinder"
        case .other: "doc"
        }
    }
}

/// 文件信息：类型、大小与修改时间；不下载时也能取到。
nonisolated struct FileInfo: Codable, Equatable, Sendable {
    let type: String
    let size: Int
    let modified: Date?
    /// 太大没进工作区快照，没有历史版本。
    let unversioned: Bool
}

/// 设备上缓存的一份文件内容；version 是工作机给的版本，文件没变时重新打开不再下载。
struct CachedFile: Equatable, Sendable {
    let url: URL
    let version: String
    let info: FileInfo
}

/// 文件内容按「工作机、工作区、路径」各留最新一版，打开时带版本向工作机校验。总量超过上限时删最久没用的。
final class FileContentCache {
    static let shared = FileContentCache()
    private nonisolated static let limit = 1 << 30
    private let root = URL.cachesDirectory.appending(path: "FileContent", directoryHint: .isDirectory)
    private var loading: [String: Task<CachedFile, Error>] = [:]
    /// 清理同一时刻只跑一次；跑的时候又有下载完的，结束后带上它们再清一次。
    private var trimming = false
    private var trimKeeping: Set<String> = []

    private struct Meta: Codable {
        let name: String
        let version: String
        let info: FileInfo
    }

    /// 同一文件同时只下载一次；后来的请求等同一个结果，进度只报给第一个。
    func file(client: KitedClient, workspace: String, path: String,
              progress: (@Sendable (Progress) -> Void)? = nil) async throws -> CachedFile {
        let key = Self.key(client.machineID ?? client.address, workspace, path)
        if let task = loading[key] { return try await task.value }
        let task = Task { try await fetch(key: key, client: client, workspace: workspace, path: path, progress: progress) }
        loading[key] = task
        defer { loading[key] = nil }
        return try await task.value
    }

    /// 只取大小、类型和修改时间，不下载。
    func info(client: KitedClient, workspace: String, path: String) async throws -> FileInfo {
        let (_, response) = try await client.download(Self.contentPath(workspace, path), method: "HEAD")
        return Self.info(response)
    }

    private func fetch(key: String, client: KitedClient, workspace: String, path: String,
                       progress: (@Sendable (Progress) -> Void)?) async throws -> CachedFile {
        let directory = root.appending(path: key, directoryHint: .isDirectory)
        let metaURL = directory.appending(path: "meta.json")
        let cached = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        let cachedURL = cached.map { directory.appending(path: "file").appending(path: $0.name) }
        var headers: [String: String] = [:]
        if let cached, let cachedURL, FileManager.default.fileExists(atPath: cachedURL.path(percentEncoded: false)) {
            headers["If-None-Match"] = cached.version
        }
        let (file, response) = try await client.download(Self.contentPath(workspace, path), headers: headers, progress: progress)
        if let cached, let cachedURL, response.statusCode == 304 {
            // 修改时间当作最近使用时间，清理时按它排
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path(percentEncoded: false))
            return CachedFile(url: cachedURL, version: cached.version, info: cached.info)
        }
        guard let file else { throw KitedError(message: "工作机没有返回文件内容") }
        let name = (path as NSString).lastPathComponent
        let meta = Meta(name: name.isEmpty ? "file" : name, version: response.value(forHTTPHeaderField: "ETag") ?? "", info: Self.info(response))
        let target = directory.appending(path: "file").appending(path: meta.name)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: target)
        try JSONEncoder().encode(meta).write(to: metaURL)
        scheduleTrim(keeping: key)
        return CachedFile(url: target, version: meta.version, info: meta.info)
    }

    private func scheduleTrim(keeping key: String) {
        trimKeeping.insert(key)
        guard !trimming else { return }
        trimming = true
        let keeping = trimKeeping
        trimKeeping = []
        Task.detached(priority: .background) { [root] in
            Self.trim(root, keeping: keeping)
            await self.trimFinished()
        }
    }

    private func trimFinished() {
        trimming = false
        if let key = trimKeeping.popFirst() { scheduleTrim(keeping: key) }
    }

    private nonisolated static func trim(_ root: URL, keeping: Set<String>) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        func size(_ directory: URL) -> Int {
            (manager.enumerator(at: directory, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? [])
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0) }
        }
        var sized = entries.map { ($0, size($0), (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.2 < $1.2 }
        var total = sized.reduce(0) { $0 + $1.1 }
        while total > Self.limit, let (oldest, bytes, _) = sized.first {
            sized.removeFirst()
            guard !keeping.contains(oldest.lastPathComponent) else { continue }
            try? manager.removeItem(at: oldest)
            total -= bytes
        }
    }

    static func contentPath(_ workspace: String, _ path: String) -> String {
        "/workspaces/\(workspace.pathComponent)/files/content?path=\(path.pathComponent)"
    }

    private static func key(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func info(_ response: HTTPURLResponse) -> FileInfo {
        FileInfo(type: response.mimeType ?? "", size: Int(response.expectedContentLength), modified: modified(response),
                 unversioned: response.value(forHTTPHeaderField: "X-Kite-Snapshot") == "skipped")
    }

    private static func modified(_ response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
