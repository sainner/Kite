import SwiftUI

/// 人发的一条消息：靠右的气泡，右下角圆角小一点，靠它看出是谁说的，所以长消息左边不留白，可以占满整栏。两种状态：排队中（agent 还没收到）只描边，收到了填上底色；
/// 从排队中到收到，底色直接填进来，气泡大小不变。
/// 正文原样显示，不解析 Markdown，只把 ``` 围起来的一段排成等宽；斜杠命令开头的命令名用主题色等宽字。
/// 太长的折起来，底下渐隐。图片和文件排在气泡上面，靠右。
/// 气泡里不放按钮，大小固定。iPhone 上点它、Mac 上右键弹出操作栏（见 ActionBar.swift），再来一下收起，和消息右边对齐：
/// 排队中的是立即发送、编辑、取消发送；收到了的是编辑、回退、分叉。都有复制，折起来的还有展开全文。
/// 刚发出去时气泡连同附件在下面一点藏着，对话往上滑的同时从下往上浮进来、淡显（见 SessionPane.send）。
struct MessageBubble: View {
    let message: Message
    let queued: Bool
    @Environment(Session.self) private var session
    @Environment(\.arrivingMessages) private var arrivingMessages
    @Environment(\.selectedRow) private var selection
    @State private var expanded = false
    /// 正文不折时有多高。
    @State private var height: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var foldHeight = Metrics.messageFold

    var body: some View {
        let arriving = arrivingMessages.contains(message.id)
        // 只高出一点的不折，省得展开只多看两行
        let foldable = height > foldHeight * 1.4
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AttachmentRow(attachments: message.attachments)
                }
                bubble(folded: foldable && !expanded)
                    #if os(macOS)
                    .opensActionBar(.message(message.id))
                    #endif
            }
            // 动画跟着 SessionPane 发送时的那一下走，和对话往上滑同步
            .offset(y: arriving ? Metrics.bubbleRise : 0)
            .opacity(arriving ? 0 : 1)
            .actionBar(.message(message.id), side: .trailing) { actions(foldable: foldable) }
        }
    }

    private func bubble(folded: Bool) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(maxHeight: folded ? foldHeight : nil, alignment: .top)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: folded ? 0.7 : 1), .init(color: .black.opacity(folded ? 0 : 1), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .background { BubbleSurface(queued: queued) }
            .clipShape(BubbleShape())
            // 排队中到收到，底色填进来
            .animation(.easeInOut(duration: 0.3), value: queued)
            .contentShape(BubbleShape())
    }

    /// 气泡里的正文连同边距。iPhone 上点一下开关操作栏；长按以后接着拖是选字，操作栏自己收起。
    /// Mac 上右键开关操作栏（opensActionBar），左键选字。
    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        SelectableText(message: message, inset: Metrics.bubblePadding,
                       tapped: { selection.toggle(.message(message.id)) },
                       selecting: { selection.close() })
        #else
        MessageText(message: message)
            .padding(.horizontal, Metrics.bubblePadding.width)
            .padding(.vertical, Metrics.bubblePadding.height)
        #endif
    }

    @ViewBuilder
    private func actions(foldable: Bool) -> some View {
        if queued {
            ActionButton("立即发送", icon: "arrow.up") {
                done { session.transcript.sendNow() }
            }
            ActionButton("编辑", icon: "pencil") {
                if let message = done({ session.transcript.withdraw(message.id) }) {
                    session.restoreDraft(message)
                }
            }
            ActionButton("取消发送", icon: "xmark", role: .destructive) {
                done { _ = session.transcript.withdraw(message.id) }
            }
        } else {
            // 回合在跑时先打断才能回退
            Group {
                ActionButton("编辑", icon: "pencil") { rewind(restoring: true) }
                ActionMenu("回退到这条之前", icon: "arrow.uturn.backward") {
                    Button("对话和代码") { rewind() }
                    Button("只回退对话") { rewind() }
                    // 假数据没有代码，还没做
                    Button("只回退代码") { done {} }
                }
                // 分出一个新会话，从这条之前接着说；还没做
                ActionButton("从这里分叉", icon: "arrow.triangle.branch") { done {} }
            }
            .disabled(session.transcript.running)
        }
        ActionButton("复制", icon: "doc.on.doc") {
            copyToPasteboard(message.typed)
            done {}
        }
        if foldable {
            ActionButton(expanded ? "收起" : "展开全文",
                         icon: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                done { expanded.toggle() }
            }
        }
    }

    /// 点了操作栏上的一项：收起操作栏，再做这件事。
    @discardableResult
    private func done<Result>(_ body: () -> Result) -> Result {
        selection.close()
        return withAnimation(.snappy, body)
    }

    /// 对话回到这条之前。restoring：原文放回输入框，改了再发。
    private func rewind(restoring: Bool = false) {
        guard let message = done({ session.transcript.rewind(before: message.id) }) else { return }
        if restoring { session.restoreDraft(message) }
    }

}

private extension Session {
    /// 把一条消息的原文放回输入框。输入框里已经有字的话放在前面，另起一行接着原来的字。
    func restoreDraft(_ message: Message) {
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? message.typed : message.typed + "\n" + draft
    }
}

/// 气泡里的正文：原样显示，``` 围起来的一段排成等宽，斜杠命令的命令名在最前面。Mac 上用它；
/// iPhone 上要长按接着拖选字，用 UIKit 的文本视图排（SelectableText），样子照这里。
private struct MessageText: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.messageSegmentGap) {
            ForEach(Array(message.segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let text):
                    if index == 0, let command = message.command {
                        let name = Text(command).font(Theme.code).foregroundStyle(.tint)
                        text.isEmpty ? name : Text("\(name) \(text)")
                    } else {
                        Text(text)
                    }
                case .code(let code):
                    Text(code)
                        .font(Theme.code)
                        .padding(8)
                        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .font(Theme.body)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }
}

/// 气泡里的正文按 ``` 切成的一段：文字，或者等宽排的代码。
enum MessageSegment {
    case text(String)
    case code(String)
}

extension Message {
    /// 按 ``` 切开。没合上的 ``` 之后都算代码。只去掉每段文字开头结尾的空行，其余空格、换行照原样。
    /// 斜杠命令的命令名排在第一段文字最前面，所以有命令名时第一段总是文字。
    var segments: [MessageSegment] {
        var list: [MessageSegment] = []
        var lines: [Substring] = []
        var inCode = false
        func flush() {
            let joined = lines.joined(separator: "\n")
            if inCode {
                list.append(.code(joined))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                list.append(.text(joined.trimmingCharacters(in: .newlines)))
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        if command != nil {
            if case .text? = list.first {} else { list.insert(.text(""), at: 0) }
        }
        return list
    }
}

/// 消息上面的附件：图片是缩略图，其余文件是一张小卡片，靠右排，放不下换行。
private struct AttachmentRow: View {
    let attachments: [Attachment]

    var body: some View {
        TrailingFlow(spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                switch attachment {
                case .image(let name, let width, let height):
                    // 假数据没有图片本身，按尺寸画个框
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.codeBackground)
                        .frame(width: min(Metrics.attachmentHeight * CGFloat(width) / CGFloat(max(height, 1)), Metrics.attachmentHeight * 2),
                               height: Metrics.attachmentHeight)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                        .help(name)
                case .file(let name):
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(name)).foregroundStyle(.secondary)
                        Text(name).font(Theme.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.rule))
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

// MARK: - 形状

/// 气泡的形状：右下角圆角小一点。
nonisolated struct BubbleShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let limit = min(rect.width, rect.height) / 2
        let radius = min(Metrics.bubbleRadius - inset, limit)
        let tail = min(Metrics.bubbleTail - inset, limit)
        return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius,
                                      bottomTrailingRadius: tail, topTrailingRadius: radius, style: .continuous)
            .path(in: rect)
    }

    func inset(by amount: CGFloat) -> BubbleShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// 气泡的底色和描边：排队中只描边，收到了填上底色。
private struct BubbleSurface: View {
    let queued: Bool

    var body: some View {
        let shape = BubbleShape()
        ZStack {
            shape.fill(Theme.bubble).opacity(queued ? 0 : 1)
            shape.strokeBorder(Theme.bubbleStroke, lineWidth: 1).opacity(queued ? 1 : 0)
        }
    }
}

// MARK: - 发送动画

extension EnvironmentValues {
    /// 刚发出、气泡还在下面藏着的消息：对话往上滑的同时，气泡从下往上浮进来。SessionPane 给出。
    @Entry var arrivingMessages: Set<UUID> = []
}
