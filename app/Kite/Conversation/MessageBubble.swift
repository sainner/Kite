import SwiftUI

/// 人发的一条消息：靠右的气泡，右下角圆角小一点，靠它看出是谁说的，所以长消息左边不留白，可以占满整栏。两种状态：排队中（agent 还没收到）只描边，收到了填上底色；
/// 从排队中到收到，底色直接填进来，气泡大小不变。
/// 正文原样显示，不解析 Markdown，只把 ``` 围起来的一段排成等宽；斜杠命令开头的命令名用等宽字。
/// 太长的折起来，底下短渐隐，并提供直接展开、收起的按钮。图片和文件排在气泡上面，靠右。
/// 代码块共用语言标题和操作按钮。iPhone 上长按、Mac 上右键弹出消息操作栏（见 ActionBar.swift），和消息右边对齐：
/// 排队中的是立即发送、编辑、取消发送；收到了的是编辑、回退、分叉。都有复制，折起来的还有展开全文。
/// 刚发出去时气泡连同附件在下面一点藏着，对话往上滑的同时从下往上浮进来、淡显（见 ThreadPane.send）。
struct MessageBubble: View {
    let message: Message
    let queued: Bool
    @Environment(WorkThread.self) private var thread
    @Environment(\.arrivingMessages) private var arrivingMessages
    @Environment(\.selectedRow) private var selection
    @Environment(\.toast) private var toast
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
                bubble(foldable: foldable)
                    #if os(macOS)
                    .opensActionBar(.message(message.id))
                    #endif
            }
            // 动画跟着 ThreadPane 发送时的那一下走，和对话往上滑同步
            .offset(y: arriving ? Metrics.bubbleRise : 0)
            .opacity(arriving ? 0 : 1)
            .actionBar(.message(message.id), side: .trailing) { actions(foldable: foldable) }
        }
    }

    private func bubble(foldable: Bool) -> some View {
        let folded = foldable && !expanded
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .frame(maxHeight: folded ? foldHeight : nil, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .mask {
                    GeometryReader { proxy in
                        // 单一遮罩没有拼接边界，避免弹簧动画中矩形与渐变分开过渡、露出底色。
                        let fadeStart = max(0, 1 - Metrics.messageFoldFade / max(proxy.size.height, 1))
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: fadeStart),
                            .init(color: folded ? .clear : .black, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
            if foldable {
                Button { done { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(expanded ? "收起" : "展开全文")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .font(Theme.secondary)
                    .foregroundStyle(queued ? Color.primary : .white)
                    .padding(.horizontal, Metrics.bubblePadding.width)
                    .padding(.vertical, Metrics.bubblePadding.height)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pointingPlain)
                // 底部按钮跟随正文宽度，不反过来把气泡撑满整栏。
                .gridCellUnsizedAxes(.horizontal)
            }
        }
        .background { BubbleSurface(queued: queued) }
        .clipShape(Theme.bubbleShape)
        // 排队中到收到，底色填进来
        .animation(.easeInOut(duration: 0.3), value: queued)
        .contentShape(Theme.bubbleShape)
    }

    /// 气泡里的正文连同边距。iPhone 上长按显示操作栏；接着拖是选字，操作栏自己收起。
    /// Mac 上右键开关操作栏（opensActionBar），左键选字。
    @ViewBuilder
    private var content: some View {
        MessageText(message: message, queued: queued)
            .padding(.horizontal, Metrics.bubblePadding.width)
            .padding(.vertical, Metrics.bubblePadding.height)
    }

    @ViewBuilder
    private func actions(foldable: Bool) -> some View {
        if queued {
            if thread.failed.contains(message.id) {
                ActionButton("重试发送", icon: "arrow.clockwise") { done { thread.retry(message) } }
                    .disabled(!thread.connected)
            }
            ActionButton("编辑", icon: "pencil") { done { thread.cancel(message, editing: true) } }
                .disabled(!thread.canCancel)
            ActionButton("取消发送", icon: "xmark", role: .destructive) { done { thread.cancel(message) } }
                .disabled(!thread.canCancel)
        }
        ActionButton("复制", icon: "doc.on.doc") {
            copyToPasteboard(message.typed, toast: toast)
            done {}
        }
        if !queued {
            if thread.compactionStart == nil {
                ActionButton("从这里开始压缩", icon: "arrow.down.to.line") {
                    done { thread.compactionStart = message.id }
                    toast?.show("已选起点，在这条或之后的消息上选「压缩到这里」", systemImage: "arrow.down.to.line")
                }
                .disabled(!thread.canCompact)
            } else {
                ActionButton("压缩到这里", icon: "rectangle.compress.vertical") { done { thread.compact(through: message.id) } }
                    .disabled(!thread.canCompact)
                ActionButton("取消压缩起点", icon: "xmark") { done { thread.compactionStart = nil } }
            }
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

}

/// 用户正文保持原样；独立代码块和 agent 共用 CodeBlock。
/// iPhone 的普通文字继续用 UIKit 处理长按与拖动选字。
private struct MessageText: View {
    let message: Message
    let queued: Bool
    @Environment(\.selectedRow) private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.messageSegmentGap) {
            ForEach(Array(message.segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let text):
                    #if os(iOS)
                    SelectableText(text: text, command: index == 0 ? message.command : nil,
                                   color: queued ? .label : .white,
                                   showActions: { selection.show(.message(message.id)) },
                                   dismissActions: { selection.close() })
                    #else
                    if index == 0, let command = message.command {
                        let name = Text(command).font(Theme.code)
                        text.isEmpty ? name : Text("\(name) \(text)")
                    } else {
                        Text(text)
                    }
                    #endif
                case .code(let code, let language):
                    // 整条消息统一折叠；代码不再单独截断，展开全文后一次看完。
                    CodeBlock(text: code, language: language, maxLines: nil, background: Theme.userCodeBackground,
                              radius: Metrics.nestedRadius(inset: Metrics.bubblePadding.height))
                        .foregroundStyle(Color.primary)
                        #if os(iOS)
                        .environment(\.blockCardLongPress) { selection.show(.message(message.id)) }
                        #endif
                }
            }
        }
        .font(Theme.body)
        // 已接收的实色气泡恒用白字；排队中的透明描边气泡仍跟随系统文字色。
        .foregroundStyle(queued ? Color.primary : .white)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }
}

/// 气泡里的正文按 ``` 切成的一段：文字，或者等宽排的代码。
enum MessageSegment {
    case text(String)
    case code(String, language: String?)
}

extension Message {
    /// 按 ``` 切开。没合上的 ``` 之后都算代码。只去掉每段文字开头结尾的空行，其余空格、换行照原样。
    /// 斜杠命令的命令名排在第一段文字最前面，所以有命令名时第一段总是文字。
    var segments: [MessageSegment] {
        var list: [MessageSegment] = []
        var lines: [Substring] = []
        var inCode = false
        var language: String?
        func flush() {
            let joined = lines.joined(separator: "\n")
            if inCode {
                list.append(.code(joined, language: language))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                list.append(.text(joined.trimmingCharacters(in: .newlines)))
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                inCode.toggle()
                language = inCode ? trimmed.drop(while: { $0 == "`" }).split(whereSeparator: \.isWhitespace).first.map(String.init) : nil
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
                    RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous)
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
                    .overlay(RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).strokeBorder(Theme.rule))
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

/// 气泡的底色和描边：排队中只描边，收到了填上底色。
private struct BubbleSurface: View {
    let queued: Bool

    var body: some View {
        let shape = Theme.bubbleShape
        ZStack {
            shape.fill(Theme.bubble).opacity(queued ? 0 : 1)
            shape.strokeBorder(Theme.bubbleStroke, lineWidth: 1).opacity(queued ? 1 : 0)
        }
    }
}

// MARK: - 发送动画

extension EnvironmentValues {
    /// 刚发出、气泡还在下面藏着的消息：对话往上滑的同时，气泡从下往上浮进来。ThreadPane 给出。
    @Entry var arrivingMessages: Set<String> = []
}
