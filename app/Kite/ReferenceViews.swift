import SwiftUI

#if os(macOS)
import AppKit
typealias ReferenceImage = NSImage
#else
import UIKit
typealias ReferenceImage = UIImage
#endif

private struct ReferenceScopeKey: EnvironmentKey {
    static let defaultValue = ReferenceScope(machineID: "", workspaceID: "")
}
extension EnvironmentValues {
    var referenceScope: ReferenceScope {
        get { self[ReferenceScopeKey.self] }
        set { self[ReferenceScopeKey.self] = newValue }
    }
}

/// 图标只属于展示缓存，既不写入消息，也不参与引用身份。
@Observable @MainActor final class ReferenceIcons {
    static let shared = ReferenceIcons()
    static let file = symbol("doc.text", size: 14)
    static let webpage = symbol("globe", size: 14)
    private var images: [String: ReferenceImage] = [:]
    private var attempted: Set<String> = []
    private var loading: [String: Task<Void, Never>] = [:]

    func image(for url: URL) -> ReferenceImage? { origin(url).flatMap { images[$0.absoluteString] } }

    /// 按实际图像高度缩放，避免把符号字号误当成图像高度；保留原有宽高比。
    static func scaled(_ image: ReferenceImage, to height: CGFloat, trailingSpace: CGFloat = 0) -> ReferenceImage {
        let imageSize = CGSize(width: image.size.width * height / image.size.height, height: height)
        let size = CGSize(width: imageSize.width + trailingSpace, height: height)
        let imageRect = CGRect(origin: .zero, size: imageSize)
        #if os(macOS)
        let scaled = NSImage(size: size, flipped: false) { _ in
            image.draw(in: imageRect)
            return true
        }
        scaled.isTemplate = image.isTemplate
        #else
        let scaled: UIImage
        if trailingSpace == 0, let pixels = image.cgImage {
            scaled = UIImage(cgImage: pixels, scale: image.scale * image.size.height / height, orientation: image.imageOrientation)
        } else {
            scaled = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: imageRect)
            }.withRenderingMode(image.renderingMode)
        }
        #endif
        return baselineAligned(scaled)
    }

    /// 图标底边作为基线；符号和站点图片使用同一规则，不跟随文本框底边对齐。
    private static func baselineAligned(_ image: ReferenceImage) -> ReferenceImage {
        #if os(macOS)
        let aligned = image.copy() as! NSImage
        aligned.alignmentRect = NSRect(origin: .zero, size: aligned.size)
        return aligned
        #else
        return image.withBaselineOffset(fromBottom: 0)
        #endif
    }

    private static func symbol(_ name: String, size: CGFloat) -> ReferenceImage {
        #if os(macOS)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))!
        return baselineAligned(trimmingTransparentEdges(image))
        #else
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))!
        return baselineAligned(image)
        #endif
    }

    #if os(macOS)
    /// AppKit 符号带有透明边距。缓存前裁到可见像素，使设定高度对应图形而不是画布。
    private static func trimmingTransparentEdges(_ image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return image }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var left = source.width, top = source.height, right = -1, bottom = -1
        for y in 0..<source.height {
            for x in 0..<source.width where bytes[y * context.bytesPerRow + x * 4 + 3] > 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top,
              let cropped = context.makeImage()?.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { return image }
        let scale = image.size.height / CGFloat(source.height)
        let trimmed = NSImage(cgImage: cropped, size: CGSize(width: CGFloat(cropped.width) * scale, height: CGFloat(cropped.height) * scale))
        trimmed.isTemplate = image.isTemplate
        return trimmed
    }
    #endif

    private func origin(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme), let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme; components.host = host; components.port = url.port
        return components.url
    }

    func load(_ urls: [URL]) async {
        for url in urls {
            guard let site = origin(url), !attempted.contains(site.absoluteString) else { continue }
            let key = site.absoluteString
            if let task = loading[key] { await task.value; continue }
            // 正文增量会取消视图的 task，站点图标请求仍由缓存持有并完成。
            let task = Task { await fetchIcon(site) }
            loading[key] = task
            await task.value
            loading[key] = nil
            attempted.insert(key)
        }
    }

    private func fetchIcon(_ site: URL) async {
            var candidates = [site.appendingPathComponent("favicon.ico")]
            // 站点声明的 icon 优先；不依赖第三方 favicon 聚合服务。
            if let data = await fetch(site, maximum: 256_000), let html = String(data: data, encoding: .utf8),
               let tags = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) {
                for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                    guard let range = Range(match.range, in: html) else { continue }
                    let tag = String(html[range])
                    func attribute(_ name: String) -> String? {
                        guard let regex = try? NSRegularExpression(pattern: "\\b" + name + #"\s*=\s*[\"']([^\"']+)[\"']"#, options: [.caseInsensitive]),
                              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                              let range = Range(match.range(at: 1), in: tag) else { return nil }
                        return String(tag[range])
                    }
                    if attribute("rel")?.lowercased().split(separator: " ").contains("icon") == true,
                       let href = attribute("href"), let icon = URL(string: href, relativeTo: site)?.absoluteURL,
                       ["http", "https"].contains(icon.scheme) { candidates.insert(icon, at: 0) }
                }
            }
            for candidate in candidates.prefix(4) {
                guard let data = await fetch(candidate, maximum: 512_000), let image = ReferenceImage(data: data) else { continue }
                let small = Self.scaled(image, to: 32)
                #if os(macOS)
                images[site.absoluteString] = Self.baselineAligned(Self.trimmingTransparentEdges(small))
                #else
                images[site.absoluteString] = small
                #endif
                break
            }
    }

    private func fetch(_ url: URL, maximum: Int) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.expectedContentLength <= maximum else { return nil }
            var data = Data()
            for try await byte in bytes { guard data.count < maximum else { return nil }; data.append(byte) }
            return data
        } catch { return nil }
    }
}

/// 原生内联文字继续负责换行和选择；两端按同一字号比例设置图标高度。
struct ReferenceLabel: View {
    let source: AttributedString
    var compact = true
    @Environment(\.referenceScope) private var scope
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    init(_ source: AttributedString) { self.source = source }
    init(_ source: String, compact: Bool = true) { self.source = AttributedString(source); self.compact = compact }

    var body: some View {
        let decorated = ReferenceText.decorate(source, scope: scope, compact: compact)
        let urls = decorated.runs.compactMap(\.link)
        inline(decorated).referencePointer()
            .task(id: urls) { await ReferenceIcons.shared.load(urls) }
    }

    private func inline(_ value: AttributedString) -> Text {
        let resolved = (font ?? .body).resolve(in: fontContext)
        let height = resolved.pointSize * Metrics.referenceIconScale
        return value.runs[\.link].reduce(Text("")) { result, run in
            let (url, range) = run
            let text = Text(AttributedString(value[range])).referenceLink(url != nil)
            guard let url, compact else { return Text("\(result)\(text)") }
            let local = url.scheme == "kite"
            let image = local ? ReferenceIcons.file : ReferenceIcons.shared.image(for: url) ?? ReferenceIcons.webpage
            let scaled = ReferenceIcons.scaled(image, to: height, trailingSpace: Metrics.referenceIconGap)
            #if os(macOS)
            let rendered = Image(nsImage: scaled)
            #else
            let rendered = Image(uiImage: scaled)
            #endif
            let icon = (local ? Text(rendered.renderingMode(.template)).foregroundStyle(.tint) : Text(rendered))
                .baselineOffset(Metrics.referenceIconBaselineOffset)
            return Text("\(result)\(icon)\(text)")
        }
    }

}

/// 宿主处理链接，消息与 JSON 组件不持有窗口或文件服务。
struct ReferenceNavigation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var error: String?

    func body(content: Content) -> some View {
        let scope = ReferenceScope(machineID: area.remote?.machine.id ?? "", workspaceID: area.id)
        content.environment(\.referenceScope, scope)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "kite" else { return .systemAction }
                guard let file = FileReference(url: url), FileReference.scope(of: url) == scope else {
                    error = "引用不属于当前工作机和工作区，或暂不支持此引用类型。"
                    return .handled
                }
                Task {
                    do { try await model.openFileReference(file, in: area) }
                    catch { self.error = error.localizedDescription }
                }
                return .handled
            })
            .alert("无法打开引用", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }
}

struct ToolReferenceSummary: View {
    let references: [FileReference]
    @Environment(\.referenceScope) private var scope
    var body: some View {
        let text = references.enumerated().reduce(Text("")) { result, entry in
            let separator = entry.offset > 0 ? " · " : ""
            var label = AttributedString(entry.element.label)
            label.link = entry.element.url(in: scope)
            label.swiftUI.underlineStyle = .init(pattern: .solid)
            let link = Text(label).referenceLink()
            return Text("\(result)\(separator)\(link)")
        }
        text.referencePointer().truncationMode(.middle)
    }
}
