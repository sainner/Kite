import SwiftUI

/// 人发的一条消息：靠右的气泡，右下角圆角小一点，靠它看出是谁说的，所以长消息左边不留白，可以占满整栏。两种状态：排队中（agent 还没收到）只描边，收到了填上底色；
/// 从排队中到收到，底色直接填进来，气泡大小不变。
/// 正文原样显示，不解析 Markdown，只把 ``` 围起来的一段排成等宽；斜杠命令开头的命令名用主题色等宽字。
/// 太长的折起来，底下渐隐。图片和文件排在气泡上面，靠右。
/// 气泡里不放按钮，大小固定。iPhone 上点它、Mac 上右键弹出操作栏（见 ActionBar.swift），再来一下收起，和消息右边对齐：
/// 排队中的是立即发送、编辑、取消发送；收到了的是编辑、回退、分叉。都有复制，折起来的还有展开全文。
/// 刚发出去时气泡先藏着，等控制区飞来的融球落在它右下角，再从那里往左上展开（见 FlyingBlob）。
struct MessageBubble: View {
    let message: Message
    let queued: Bool
    @Environment(Session.self) private var session
    @Environment(\.arrivingMessages) private var arriving
    @Environment(\.flyingMessages) private var flying
    @Environment(\.selectedRow) private var selection
    @State private var expanded = false
    /// 正文不折时有多高。
    @State private var height: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var foldHeight = Metrics.messageFold

    var body: some View {
        let landing = arriving.contains(message.id)
        // 只高出一点的不折，省得展开只多看两行
        let foldable = height > foldHeight * 1.4
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AttachmentRow(attachments: message.attachments)
                        .opacity(landing ? 0 : 1)
                        .animation(.easeOut(duration: 0.3).delay(0.2), value: landing)
                }
                bubble(folded: foldable && !expanded, landing: landing)
                    #if os(macOS)
                    .opensActionBar(.message(message.id))
                    #endif
            }
            .actionBar(.message(message.id), side: .trailing) { actions(foldable: foldable) }
        }
    }

    private func bubble(folded: Bool, landing: Bool) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(maxHeight: folded ? foldHeight : nil, alignment: .top)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: folded ? 0.7 : 1), .init(color: .black.opacity(folded ? 0 : 1), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .opacity(landing ? 0 : 1)
            .background { BubbleSurface(reveal: landing ? 0 : 1, filled: queued ? 0 : 1) }
            .clipShape(BubbleShape(reveal: landing ? 0 : 1))
            // 融球落下后从右下角展开；排队中到收到，底色填进来
            .animation(.spring(duration: 0.45, bounce: 0.15), value: landing)
            .animation(.easeInOut(duration: 0.3), value: queued)
            .contentShape(BubbleShape())
            // 融球还在飞就一直报自己在哪；气泡在它飞到一多半时就开始展开了，不能只在藏着的时候报
            .anchorPreference(key: FlightAnchors.self, value: .bounds) { anchor in
                FlightAnchors.Value(bubbles: flying.contains(message.id) ? [message.id: anchor] : [:])
            }
            // 融球还在飞的时候整个藏着；落下时直接出现，不跟着上面的动画淡入
            .opacity(landing ? 0 : 1)
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

/// 气泡的形状：右下角圆角小一点。reveal 从 0 到 1：从右下角一个融球大小的圆，往左上展开成整个气泡。
nonisolated struct BubbleShape: InsettableShape {
    var reveal: CGFloat = 1
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let blob = min(Metrics.sendBlob, rect.width, rect.height)
        let width = blob + (rect.width - blob) * reveal
        let height = blob + (rect.height - blob) * reveal
        let limit = min(width, height) / 2
        // reveal 为 0 时四个角都是半径 blob/2，正好是个圆
        let radius = min(Metrics.bubbleRadius - inset, limit)
        let tail = min(blob / 2 + (Metrics.bubbleTail - inset - blob / 2) * reveal, limit)
        return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius,
                                      bottomTrailingRadius: max(tail, 0), topTrailingRadius: radius, style: .continuous)
            .path(in: CGRect(x: rect.maxX - width, y: rect.maxY - height, width: width, height: height))
    }

    func inset(by amount: CGFloat) -> BubbleShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// 气泡的底色和描边。filled 从 0 到 1：排队中只描边，收到了填上底色。
/// 刚落下时是填了色的小圆，展开的同时底色褪掉，所以还在排队的气泡展开完只剩描边。
private struct BubbleSurface: View, Animatable {
    var reveal: CGFloat
    var filled: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(reveal, filled) }
        set { (reveal, filled) = (newValue.first, newValue.second) }
    }

    var body: some View {
        let shape = BubbleShape(reveal: reveal)
        ZStack {
            shape.fill(Theme.bubble).opacity(max(filled, 1 - reveal))
            shape.strokeBorder(Theme.bubbleStroke, lineWidth: 1).opacity(1 - filled)
        }
    }
}

// MARK: - 发送动画

extension EnvironmentValues {
    /// 刚发出、气泡还藏着的消息：融球飞到一多半，气泡从落点开始展开。SessionPane 给出。
    @Entry var arrivingMessages: Set<UUID> = []
    /// 融球还在飞的消息：它们的气泡报出自己在哪，融球往那里飞。SessionPane 给出。
    @Entry var flyingMessages: Set<UUID> = []
}

/// 发送动画的两头：控制区那张卡片，和融球要落到的气泡。
struct FlightAnchors: PreferenceKey {
    struct Value {
        var card: Anchor<CGRect>?
        var bubbles: [UUID: Anchor<CGRect>] = [:]
    }

    static var defaultValue: Value { Value() }

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.card = value.card ?? next.card
        value.bubbles.merge(next.bubbles) { $1 }
    }
}

/// 发送时的融球：一颗液态玻璃的小球，起点压在控制区卡片的上边缘、靠右的圆角那里，和卡片融在一起；
/// 往外飞时卡片上先鼓出一个包、拉出细颈，离远了颈断开，成一颗玻璃水滴飞到气泡的右下角，落下后气泡从那里往左上展开。
/// 鼓包、拉颈、断开都是玻璃容器（SessionPane 外面的 GlassEffectContainer）按两块玻璃的远近自己画的。
/// 起点、终点每一帧都重新取，对话在滚也落得准。
struct FlyingBlob: View {
    let start: CGPoint
    let end: CGPoint
    /// 飞到一多半：气泡开始从落点展开，落下时正好并进去。
    let opening: () -> Void
    let landed: () -> Void
    @State private var progress: CGFloat = 0
    private static let duration = 0.5

    var body: some View {
        Color.clear
            .modifier(BlobPath(progress: progress, start: start, end: end))
            .allowsHitTesting(false)
            .onAppear {
                // 和对话往上滑一样长，落下时气泡正好滑到位
                withAnimation(.smooth(duration: Self.duration)) {
                    progress = 1
                } completion: {
                    landed()
                }
                Task {
                    try? await Task.sleep(for: .seconds(Self.duration * 0.55))
                    opening()
                }
            }
    }
}

/// 融球走到哪、多大：前三成从卡片边上鼓出来、长到原大小，之后照原大小飞过去。
/// 改的是玻璃的尺寸，不用缩放：玻璃按尺寸融合，缩放只是画的时候放大（Keyo 的经验，见 ActionBar 的说明）。
private struct BlobPath: ViewModifier, Animatable {
    var progress: CGFloat
    let start: CGPoint
    let end: CGPoint

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let size = Metrics.sendBlob * (0.3 + 0.7 * min(progress / 0.3, 1))
        content
            .frame(width: size, height: size)
            .glassEffect(.regular, in: .circle)
            .position(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
    }
}
