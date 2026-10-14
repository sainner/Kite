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
/// 消息上面的附件：图片是缩略图，其余文件是一张小卡片，靠右排，放不下换行。iPhone、iPad 的原生气泡托管它（PhoneBubbleRowSlot）；
/// Mac 的是原生的 AttachmentRowView。
struct MessageAttachmentRow: View {
    let attachments: [Attachment]

    var body: some View {
        TrailingFlow(spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                switch attachment {
                case .image(let name, let width, let height):
                    // 假数据没有图片本身，按尺寸画个框
                    RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous)
                        .fill(Theme.codeBackground)
                        .frame(width: min(Metrics.attachmentHeight * CGFloat(width) / CGFloat(max(height, 1)), Metrics.attachmentHeight * 2),
                               height: Metrics.attachmentHeight)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                        .help(name)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(TranscriptSpeech.imageAttachment(name))
                case .file(let name):
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(name)).foregroundStyle(.secondary)
                        Text(name).font(Theme.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).strokeBorder(Theme.rule))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(TranscriptSpeech.fileAttachment(name))
                }
            }
        }
    }

    private static func icon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "csv", "xlsx", "xls", "numbers": "tablecells"
        case "zip": "doc.zipper"
        default: "doc"
        }
    }
}

/// 一行一行排，放不下就换行，每行靠右。
private struct TrailingFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.indices.last, rows[last].width + spacing + size.width <= width {
                rows[last].indices.append(index)
                rows[last].width += spacing + size.width
                rows[last].height = max(rows[last].height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
#endif
