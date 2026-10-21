import QuickLook
import SwiftUI

/// 气泡里的正文按 ``` 切成的一段：文字，或者等宽排的代码。source 是这段在 Message.text 里的位置，复制时对回原文：
/// 文字去掉了首尾空行，代码连着上下两行围栏。
enum MessageSegment {
    case text(String, source: Range<String.Index>)
    case code(String, language: String?, source: Range<String.Index>)
}

extension Message {
    /// 按 ``` 切开。没合上的 ``` 之后都算代码。只去掉每段文字开头结尾的空行，其余空格、换行照原样。
    /// 斜杠命令的命令名排在第一段文字最前面，所以有命令名时第一段总是文字。
    var segments: [MessageSegment] {
        var list: [MessageSegment] = []
        var lines: [Substring] = []
        var inCode = false
        var language: String?
        /// 正在收的代码块的开头围栏行。
        var fence: Substring?
        func flush(closing: Substring?) {
            let joined = lines.joined(separator: "\n")
            if inCode, let fence {
                list.append(.code(joined, language: language, source: fence.startIndex..<(closing?.endIndex ?? text.endIndex)))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = lines.first, let last = lines.last {
                let trimmed = joined.trimmingCharacters(in: .newlines)
                // 拆出来的行连着，拼回去就是原文里的一段；只去掉了首尾的换行，第一次出现的位置就是它
                let whole = first.startIndex..<last.endIndex
                list.append(.text(trimmed, source: text[whole].range(of: trimmed) ?? whole))
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush(closing: line)
                inCode.toggle()
                language = inCode ? trimmed.drop(while: { $0 == "`" }).split(whereSeparator: \.isWhitespace).first.map(String.init) : nil
                fence = inCode ? line : nil
            } else {
                lines.append(line)
            }
        }
        flush(closing: nil)
        if command != nil {
            if case .text? = list.first {} else { list.insert(.text("", source: text.startIndex..<text.startIndex), at: 0) }
        }
        return list
    }
}

#if os(iOS)
/// 消息上面的附件：图片是缩略图（取到之前是底色上一个照片图标），其余文件是一张小卡片，靠右排，放不下换行。点一下取原件，用快速查看打开。
/// iPhone、iPad 的原生气泡托管它（PhoneBubbleRowSlot）；Mac 的是原生的 AttachmentRowView。
struct MessageAttachmentRow: View {
    let attachments: [Attachment]
    @Environment(\.attachmentSource) private var source
    @State private var previewing: URL?
    @State private var failure: String?

    var body: some View {
        AttachmentFlow(spacing: 6, trailing: true) {
            ForEach(attachments) { attachment in
                Button { open(attachment) } label: { item(attachment) }
                    .buttonStyle(.pointingPlain)
                    .disabled(source == nil)
            }
        }
        .quickLookPreview($previewing)
        .alert("打不开附件", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    @ViewBuilder private func item(_ attachment: Attachment) -> some View {
        if let width = attachment.width, let height = attachment.height {
            AttachmentThumbnail(attachment: attachment, source: source)
                .frame(width: min(Metrics.attachmentHeight * CGFloat(width) / CGFloat(max(height, 1)), Metrics.attachmentHeight * 2),
                       height: Metrics.attachmentHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TranscriptSpeech.imageAttachment(attachment.name))
        } else {
            HStack(spacing: 8) {
                Image(systemName: attachment.icon).foregroundStyle(.secondary)
                Text(attachment.name).font(Theme.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).strokeBorder(Theme.rule))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TranscriptSpeech.fileAttachment(attachment.name))
        }
    }

    private func open(_ attachment: Attachment) {
        guard let source else { return }
        Task {
            do { previewing = try await AttachmentContent.shared.original(attachment, from: source) }
            catch { failure = error.localizedDescription }
        }
    }
}

/// 图片附件的缩略图，取到之前是底色上一个照片图标（AttachmentFace）。
struct AttachmentThumbnail: View {
    let attachment: Attachment
    let source: AttachmentSource?
    @State private var image: PlatformImage?

    /// 换了附件，或者换了来源（刚连上、流转到了别的工作机）时重新取；取过的在缓存里，不会重下。
    private struct Key: Equatable {
        let id: String
        let source: AttachmentSource?
    }

    var body: some View {
        AttachmentFace(image: image).task(id: Key(id: attachment.id, source: source)) {
            image = AttachmentContent.shared.cached(attachment.id)
            if image == nil { image = await AttachmentContent.shared.thumbnail(attachment, from: source) }
        }
    }
}

#endif
