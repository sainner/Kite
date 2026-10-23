import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 附件从哪台工作机、哪个工作区取。
struct AttachmentSource: Equatable {
    let client: KitedClient
    let workspace: String

    func path(_ id: String) -> String { "/workspaces/\(workspace.pathComponent)/attachments/\(id.pathComponent)" }
}

extension EnvironmentValues {
    /// 对话里的附件到哪去取，会话窗口按所属工作区给。
    @Entry var attachmentSource: AttachmentSource? = nil
}

/// 附件的缩略图与原件，按附件 ID 缓存。刚从本机传上去的附件先放本机做的缩略图，气泡里不用再去工作机取。
@MainActor final class AttachmentContent {
    static let shared = AttachmentContent()
    /// 缩略图长边多少像素：气泡里的缩略图高 attachmentHeight、最宽两倍高，3 倍屏也够。
    nonisolated static let thumbnailEdge = 640

    private let thumbnails = NSCache<NSString, PlatformImage>()
    private var loading: [String: Task<PlatformImage?, Never>] = [:]
    private var originals: [String: Task<URL, any Error>] = [:]

    func cached(_ id: String) -> PlatformImage? { thumbnails.object(forKey: id as NSString) }
    func seed(_ id: String, _ image: PlatformImage) { thumbnails.setObject(image, forKey: id as NSString) }

    /// 图片附件的缩略图；不是图片、没有来源或取不到时为 nil。
    func thumbnail(_ attachment: Attachment, from source: AttachmentSource?) async -> PlatformImage? {
        if let image = cached(attachment.id) { return image }
        guard attachment.isImage, let source else { return nil }
        if let task = loading[attachment.id] { return await task.value }
        let task = Task<PlatformImage?, Never> {
            guard let (file, _) = try? await source.client.download(source.path(attachment.id) + "?size=\(Self.thumbnailEdge)"),
                  let file else { return nil }
            defer { try? FileManager.default.removeItem(at: file) }
            return PlatformImage(contentsOfFile: file.path)
        }
        loading[attachment.id] = task
        let image = await task.value
        loading[attachment.id] = nil
        if let image { seed(attachment.id, image) }
        return image
    }

    /// 原件下载到临时目录，文件名照原名，交给系统预览。同一个附件同时只下载一次，下过的文件还在就直接给。
    func original(_ attachment: Attachment, from source: AttachmentSource) async throws -> URL {
        if let task = originals[attachment.id] {
            if let url = try? await task.value, FileManager.default.fileExists(atPath: url.path) { return url }
            // 上次没下成，或者文件被系统清掉了：已经有人在重下就等它的
            if let retry = originals[attachment.id], retry != task { return try await retry.value }
        }
        let task = Task { try await Self.download(attachment, from: source) }
        originals[attachment.id] = task
        return try await task.value
    }

    private static func download(_ attachment: Attachment, from source: AttachmentSource) async throws -> URL {
        let (file, _) = try await source.client.download(source.path(attachment.id), segmented: true)
        guard let file else { throw KitedError(message: "附件下载失败") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "KiteAttachments/\(attachment.id)")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: attachment.name)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// 本机文件的缩略图，长边 edge 像素；不是图片时为 nil。
    nonisolated static func localThumbnail(_ url: URL, edge: Int = thumbnailEdge) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: .zero)
        #else
        return UIImage(cgImage: image)
        #endif
    }
}

/// 输入框里待发的附件：选好就传到工作机，传完才能发。local 是暂存在本机的一份，重试时再传它；
/// 撤回、停止时退回输入框的已经传好，没有本机的那份。
@MainActor @Observable final class DraftAttachment: Identifiable {
    let id: String
    let name: String
    let isImage: Bool
    @ObservationIgnored let local: URL?
    /// 缩略图：本机选的从本机文件做，退回来的从工作机取。
    var preview: PlatformImage?
    /// 已经发出去的比例。
    private(set) var progress: Double = 0
    private(set) var uploaded: Attachment?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private(set) var source: AttachmentSource?

    var uploading: Bool { uploaded == nil && error == nil }

    /// 本机选的文件：先拷进临时目录（选文件面板、照片给的位置不一定一直能读）。
    convenience init(staging file: URL) throws {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        // 拖进来、粘贴的可能是文件夹：整个拷一遍又慢，也传不上去
        if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            throw KitedError(message: "\(file.lastPathComponent) 是文件夹，只能添加文件")
        }
        try self.init(name: file.lastPathComponent) { try FileManager.default.copyItem(at: file, to: $0) }
    }

    /// 粘贴、拍下的图片这类只有数据的。
    convenience init(data: Data, name: String) throws {
        try self.init(name: name) { try data.write(to: $0) }
    }

    /// 暂存在本机的：write 把内容写到暂存目录里给的位置。
    private init(name: String, write: (URL) throws -> Void) throws {
        id = UUID().uuidString.lowercased()
        self.name = name
        let directory = Self.staging.appending(path: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: name)
        try write(target)
        local = target
        let preview = AttachmentContent.localThumbnail(target)
        isImage = preview != nil
        self.preview = preview
    }

    /// 退回输入框的、已经在工作机上的附件。
    init(restoring attachment: Attachment, source: AttachmentSource?) {
        id = attachment.id
        name = attachment.name
        isImage = attachment.isImage
        local = nil
        uploaded = attachment
        progress = 1
        self.source = source
        preview = AttachmentContent.shared.cached(attachment.id)
        if preview == nil, attachment.isImage {
            Task { preview = await AttachmentContent.shared.thumbnail(attachment, from: source) }
        }
    }

    private static var staging: URL { FileManager.default.temporaryDirectory.appending(path: "KiteUploads") }

    /// 传到 source 那个工作区；ID 不变，重传同样的内容工作机认得出。
    func upload(to source: AttachmentSource) {
        guard let local, uploaded == nil else { return }
        self.source = source
        error = nil
        progress = 0
        task?.cancel()
        task = Task {
            do {
                let result = try await source.client.upload(source.path(id) + "?name=\(name.pathComponent)", file: local, as: Attachment.self, segmented: true) { [weak self] fraction in
                    // 大文件回调上千次，涨够 1% 才更新，免得一直重画
                    Task { @MainActor in
                        guard let self, fraction - self.progress >= 0.01 || fraction == 1 else { return }
                        self.progress = fraction
                    }
                }
                guard !Task.isCancelled else { return }
                uploaded = result
                progress = 1
                if let preview, result.isImage { AttachmentContent.shared.seed(result.id, preview) }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func retry() {
        guard let source, error != nil else { return }
        upload(to: source)
    }

    /// 从输入框里拿掉：停下上传，删掉本机暂存的那份；已经传好、还没发的，工作机上的也删掉（删不掉的留到项目删除）。
    func discard() {
        task?.cancel()
        if let local { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        if let source, uploaded != nil {
            let path = source.path(id)
            Task { let _: JSON? = try? await source.client.request(path, method: "DELETE", as: JSON.self) }
        }
    }

    /// 随消息发出以后，本机暂存的那份不再要了。
    func sent() {
        if let local { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
    }
}
