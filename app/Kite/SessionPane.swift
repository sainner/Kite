import SwiftUI

/// 会话窗口：标题栏是会话的标题和所在的项目，内容是对话，控制区是输入框和一行按钮，底下的状态信息是会话此刻的情况。
/// 人发的消息靠右、带气泡；agent 的话铺满这一栏；两段话之间 agent 做的事折成一行，点开看每一步。
struct SessionPane: View {
    @Environment(Session.self) private var session
    @State private var position = ScrollPosition(edge: .bottom)
    /// 跟着最底下：打开时是，往上翻就不是了，翻回最底下又是。
    @State private var following = true
    /// 刚发出、融球还在飞的消息。
    @State private var flying: Set<UUID> = []
    /// 其中气泡还藏着、没开始展开的。融球飞到一多半气泡就开始展开，落下时正好并进去。
    @State private var arriving: Set<UUID> = []
    /// 点开了操作栏的那一行。
    @State private var selected: RowID?
    /// 发送后往最底下滑到什么时候。滑的这一阵子，跟着最底下也用同一个动画，不一下跳过去；滑的过程也不算人往上翻。
    @State private var glideUntil = Date.distantPast
    /// 离滑到最底下还差多远。融球飞的时候要用：气泡还在往上滑，融球直接飞到它停下的地方。
    @State private var remaining: CGFloat = 0
    /// 发送后底下留的空白，人往上翻时裁掉了多少（见 TranscriptView 的 tailHeight）。下一次发送清零。
    @State private var trim: CGFloat = 0
    /// 底下的空白这会儿露在可见区里。
    @State private var blankShown = false
    /// 人正在拖着滚或者松手后还在滑；程序滚的不算。
    @State private var userScrolling = false
    /// 这会儿滚到哪，按 scrollTo(y:) 的算法。只在发送时读，放在不触发重画的盒子里，滚动时不用每一帧重画。
    @State private var offset = ScrollOffset()
    /// 键盘升起、收起时对话按底部对齐：那一刻正停在最底下，最后几行跟着键盘顶上去。不然按顶部对齐，对话不动。
    @State private var bottomAligned = false

    var body: some View {
        // 整个窗口放进一个玻璃容器：发送时的融球和控制区那张玻璃卡片在同一个容器里才会融在一起（见 FlyingBlob）
        GlassEffectContainer(spacing: Metrics.blobMerge) {
            pane
        }
    }

    private var pane: some View {
        let items = session.transcript.items
        let pending = session.transcript.pending
        return PaneWindow(header: session.header, status: session.status) {
            if items.isEmpty && pending.isEmpty {
                Text("说说要做什么")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            } else {
                // 可见区多高要在排版时当场算出来，和最后一轮底下的留白同一次排好：等滚动视图报上来要晚一次排版，
                // 键盘升起、底栏拉开时可见区变矮，留白晚一帧才缩，对话先往上窜再退回来。这里的尺寸已经扣掉了
                // 标题栏、控制区和键盘让出的那一截，滚动视图照样伸到它们后面（实测）
                GeometryReader { proxy in
                    ScrollView {
                        TranscriptView(items: items, pending: pending, running: session.transcript.running, actionable: true,
                                       tailHeight: proxy.size.height - Metrics.transcriptPadding, trim: trim,
                                       blankShown: { blankShown = $0 })
                            .font(Theme.body)
                            .frame(maxWidth: Metrics.transcriptWidth)
                            .padding(.horizontal, 16)
                            .padding(.vertical, Metrics.transcriptPadding)
                            .frame(maxWidth: .infinity)
                            // 操作栏开着时，点对话里别的地方收起；点到按钮、别的气泡由它们自己接
                            .contentShape(Rectangle())
                            .gesture(TapGesture().onEnded { withAnimation(.actionBar) { selected = nil } }, isEnabled: selected != nil)
                    }
                    .scrollPosition($position)
                    // 手指一滚就收起操作栏；跟着最底下的自动滚动不算
                    .onScrollPhaseChange { _, phase in
                        userScrolling = phase == .interacting || phase == .decelerating
                        if phase == .interacting, selected != nil { withAnimation(.actionBar) { selected = nil } }
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    // 跟着最底下时，内容变长、卡片变大小都停在最底下；翻到上面看的时候不动。
                    // 打开时卡片还会变几次大小，只靠 initialOffset 停不住。
                    // 不用 defaultScrollAnchor 的 sizeChanges：它不管停在哪，展开上面的某一步也会把内容往上推
                    // scrollTo(y:) 比 contentOffset 少算标题栏让出的那一截（实测）
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { offset.y = $1 }
                    .onScrollGeometryChange(for: ScrollState.self, of: ScrollState.init) { old, new in
                        // 发送后滑的这一阵子交给那一下滚动，这里不插手，不然会把滑到一半的一下子跳过去
                        guard Date.now >= glideUntil else { return }
                        // 可见区变高变矮（键盘、底栏）时，打字前正停在最底下就贴着最底下，不然按顶部对齐：顶上不变，对话就不动
                        guard old.container == new.container else {
                            if bottomAligned { position.scrollTo(edge: .bottom) }
                            return
                        }
                        if old.content != new.content {
                            // 人手还在滚的时候不跟：往上翻裁空白时内容一直在变短，跟过去会和手抢
                            if following && !userScrolling { position.scrollTo(edge: .bottom) }
                        } else {
                            following = new.atBottom
                        }
                    }
                    // 融球飞的时候才记，平时滚动不用每一帧重画
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        max(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY, 0)
                    } action: { _, distance in
                        if !flying.isEmpty || remaining != 0 { remaining = flying.isEmpty ? 0 : distance }
                        // 人往上翻、底下的空白还露着：翻上去多少就裁掉多少，内容的底边一直贴着可见区的底边，
                        // 直到最后一条内容到了底边，空白裁完。裁掉的不再长回来
                        if userScrolling, blankShown, distance > 0.5 { trim += distance }
                    }
                    .onChange(of: items.count) {
                        // 自己发的消息总要看得到
                        if case .human = items.last?.kind {
                            withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
                        }
                    }
                    .environment(\.visibleHeight, proxy.size.height)
                }
            }
        } controls: { typing in
            ControlArea(typing: typing, send: send, typingChanged: keyboardMoving)
                .frame(maxWidth: Metrics.transcriptWidth)
                .anchorPreference(key: FlightAnchors.self, value: .bounds) { FlightAnchors.Value(card: $0) }
        }
        .environment(\.workingDirectory, session.transcript.root)
        .environment(\.arrivingMessages, arriving)
        .environment(\.flyingMessages, flying)
        .environment(\.selectedRow, $selected)
        .overlayPreferenceValue(FlightAnchors.self) { anchors in
            GeometryReader { proxy in
                ForEach(Array(flying), id: \.self) { id in
                    if let bubble = anchors.bubbles[id] {
                        // 气泡还在跟着对话往上滑，融球飞到它滑完停下的地方
                        let target = proxy[bubble].offsetBy(dx: 0, dy: -remaining)
                        // 起点压在卡片上边缘、靠右的圆角那里，一开始和卡片融在一起；取不到卡片就从窗口底边
                        let card = anchors.card.map { proxy[$0] }
                        FlyingBlob(start: CGPoint(x: card.map { $0.maxX - Metrics.controlRadius } ?? target.maxX,
                                                  y: card?.minY ?? proxy.size.height),
                                   end: CGPoint(x: target.maxX - Metrics.sendBlob / 2, y: target.maxY - Metrics.sendBlob / 2),
                                   opening: { arriving.remove(id) }, landed: { landed(id) })
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 输入框拿到或者丢了焦点，键盘马上要升起或收起：这时正停在最底下，就按底部对齐，最后几行跟着键盘顶上去；
    /// 不然先钉在当前位置、按顶部对齐。要钉：滚动位置里可能还留着「滚到最底下」，它会贴着底边走，键盘一动对话就跟着窜。
    /// 底下还露着发送后留的空白时也按顶部对齐：留白和可见区一起缩，两种对齐结果一样，按底部对齐反而会先窜一下再回来。
    private func keyboardMoving() {
        bottomAligned = following && !blankShown
        if bottomAligned {
            position.scrollTo(edge: .bottom)
        } else {
            position.scrollTo(y: offset.y)
        }
    }

    /// 发一条消息：先排进队里，气泡藏着。对话往上滑到最底下，开启新一轮的消息停在可见区顶上（见 TranscriptView 的 tailHeight），
    /// 融球同时从控制区飞过去，落下后气泡展开。
    private func send(_ message: Message) {
        flying.insert(message.id)
        arriving.insert(message.id)
        following = true
        trim = 0
        glideUntil = .now + 0.6
        // 先钉在当前位置：滚动位置里可能还留着「贴着最底下」，内容一变长就会没有动画地一下跟过去（实测）
        position.scrollTo(y: offset.y)
        // 不带动画地加：带动画加进去的话，紧接着的滚动整个不动，要等下一次滚动才动（实测）。气泡本来就藏着
        session.transcript.send(message)
        // 等新消息和它底下的留白排好再滚；回合在跑时的插话不开启新的一轮，标记还在正在跑的这一轮顶上，照常滚到最底下
        let startsTurn = !session.transcript.running
        DispatchQueue.main.async {
            withAnimation(.glide) {
                if startsTurn {
                    position.scrollTo(id: TranscriptView.tailMarker, anchor: .top)
                } else {
                    position.scrollTo(edge: .bottom)
                }
            }
        }
    }

    /// 融球落下了，气泡从那里展开。回合没在跑时 agent 马上就收到；在跑时要等它做完手上这一步，
    /// 假数据里一直排着，直到打断或者立即发送。
    private func landed(_ id: UUID) {
        flying.remove(id)
        arriving.remove(id)
        guard !session.transcript.running else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.easeInOut(duration: 0.3)) { session.transcript.receive(id) }
        }
    }
}

/// 滚动位置的盒子：改了它不触发重画。
private final class ScrollOffset {
    var y: CGFloat = 0
}

private extension Animation {
    /// 发送后对话往上滑，和融球飞的时间一样长。
    static let glide = Animation.smooth(duration: 0.5)
}

/// 滚动时要看的几样：只有它们变了才回调，不是每滚一帧都回调。
private struct ScrollState: Equatable {
    let content: CGSize
    let container: CGSize
    let atBottom: Bool

    init(_ geometry: ScrollGeometry) {
        content = geometry.contentSize
        container = geometry.containerSize
        // 可见区域的底边在控制区后面，要减掉控制区让出的那一截
        atBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 1
    }
}

extension EnvironmentValues {
    /// 会话的工作目录，工具参数里的路径按它显示成相对路径。
    @Entry var workingDirectory = ""
}

/// 一串记录排下来，排队中的消息接在最后。主对话和子 agent 做的事都用它。
struct TranscriptView: View {
    let items: [Item]
    var pending: [Message] = []
    /// 有回合在跑：排队的消息收到后是并进这一轮的插话，不是新的一轮。
    var running = false
    /// 点 agent 的话弹出操作栏。主对话里是；子 agent 做的事里不是，它们的序号和主对话的会撞。
    var actionable = false
    /// 主对话给：最后一轮（从最近一条开启新一轮的人发的消息算起）至少占多高，不够就在底下留白（见 TranscriptStack）。
    /// 发送后滚到最后一轮顶上的标记（tailMarker），这条消息正好停在可见区顶上，上一段内容刚好滚出去，回复往下面的空白里填；
    /// 回复长过一屏就照常跟着最底下。回合在跑时发的插话不算：它接在正在跑的这一轮后面，顶到最上面的话 agent 接着写的内容就在屏幕外了。
    var tailHeight: CGFloat?
    /// 底下的空白裁掉多少：人往上翻多少就裁多少，裁完为止（SessionPane 记着）。
    var trim: CGFloat = 0
    /// 底下的空白露没露在可见区里：最后一条内容的底边在可见区底边上面就是露着。
    var blankShown: ((Bool) -> Void)?
    @Environment(\.selectedRow) private var selection

    /// 最后一轮顶上那个标记的 id。
    static let tailMarker = "transcript.tail"

    var body: some View {
        let rows = rows
        TranscriptStack(spacing: Metrics.rowSpacing, tailIndex: tailHeight == nil ? nil : rows.lastIndex(where: \.startsHumanTurn),
                        tailHeight: tailHeight, trim: trim) {
            ForEach(rows) { row in
                Group {
                    switch row.content {
                    case .item(let item):
                        if actionable, case .text(let text) = item.kind {
                            AgentText(id: row.id, text: text)
                        } else {
                            ItemView(item: item)
                        }
                    case .message(let message, let queued): MessageBubble(message: message, queued: queued)
                    }
                }
                .padding(.top, row.gap)
                // 开着操作栏的那一行垫在最上面：操作栏浮出这一行，压在前后的行上（自己的排版容器里也管用，实测）
                .zIndex(selection.wrappedValue == row.id ? 1 : 0)
            }
            if let tailHeight {
                Color.clear.frame(height: 0).layoutValue(key: StackMarker.self, value: .tail).id(Self.tailMarker)
                // .scrollView 的原点在标题栏底下，可见区到 tailHeight 再加对话底下的留白（实测）
                Color.clear.frame(height: 0).layoutValue(key: StackMarker.self, value: .end)
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < tailHeight - 1 } action: { blankShown?($0) }
            }
        }
    }

    /// 人发的消息按消息的 id 认，排队中和收到了走同一个分支：从排队中变成收到，还是同一个气泡，底色直接填进来。
    private var rows: [Row] {
        var rows: [Row] = []
        func append(_ id: RowID, _ content: Row.Content, startsTurn: Bool) {
            let humanTurn = startsTurn && content.isMessage
            guard let last = rows.last else {
                rows.append(Row(id: id, content: content, gap: 0, startsHumanTurn: humanTurn))
                return
            }
            // 人发的消息和前后的内容之间多空一样多，连着的几条消息之间不加；它开启的新一轮不再另加，上下才一样。
            // Kite 发来的、后台任务通知开启的新一轮，和上一轮之间多空一点
            let gap = if last.isMessage != content.isMessage { Metrics.messageGap }
                else if startsTurn && !content.isMessage { Metrics.turnGap }
                else { CGFloat(0) }
            rows.append(Row(id: id, content: content, gap: gap, startsHumanTurn: humanTurn))
        }
        for item in items {
            if case .human(let message) = item.kind {
                append(.message(message.id), .message(message, queued: false), startsTurn: item.startsTurn)
            } else {
                append(.item(item.id), .item(item), startsTurn: item.startsTurn)
            }
        }
        for message in pending {
            append(.message(message.id), .message(message, queued: true), startsTurn: !running)
        }
        return rows
    }
}

/// 对话一行一行往下排，靠左，行间空 spacing，和 VStack 一样。给了 tailHeight 时，最后一轮（从 tailIndex 那一行上面、
/// 上一行的底边算起）至少这么高，不够就在底下留白，再减去已经裁掉的 trim；标着 .tail 的空视图摆在最后一轮的顶上，发送后滚到它，
/// 标着 .end 的摆在最后一行的底边，用来看底下的空白露没露出来。
/// 留白要在排版里和新消息一次算出来：量出来再补会晚一次排版，发送时滚动那一刻底下还没有留白，滚不到位。
private struct TranscriptStack: Layout {
    let spacing: CGFloat
    let tailIndex: Int?
    let tailHeight: CGFloat?
    let trim: CGFloat

    struct Cache {
        var width: CGFloat?
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? rows(subviews).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let (natural, tailTop) = arrange(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: natural + extra(natural: natural, tailTop: tailTop))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let (natural, tailTop) = arrange(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (index, subview) in rows(subviews).enumerated() {
            let height = cache.heights[index]
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
        for marker in subviews {
            guard let kind = marker[StackMarker.self] else { continue }
            let at = kind == .tail ? tailTop : natural
            marker.place(at: CGPoint(x: bounds.minX, y: bounds.minY + at), proposal: ProposedViewSize(width: bounds.width, height: 0))
        }
    }

    private func rows(_ subviews: Subviews) -> [LayoutSubview] {
        subviews.filter { $0[StackMarker.self] == nil }
    }

    /// 不留白时多高，最后一轮的顶（上一行的底边）在哪。每行多高按宽度记下来，排的时候不再量一遍。
    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) -> (natural: CGFloat, tailTop: CGFloat) {
        let rows = rows(subviews)
        if cache.width != width || cache.heights.count != rows.count {
            cache.width = width
            cache.heights = rows.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        }
        var y: CGFloat = 0
        var tailTop: CGFloat = 0
        for (index, height) in cache.heights.enumerated() {
            if index == tailIndex { tailTop = index == 0 ? 0 : y - spacing }
            y += height + spacing
        }
        return (max(y - spacing, 0), tailTop)
    }

    private func extra(natural: CGFloat, tailTop: CGFloat) -> CGFloat {
        guard tailIndex != nil, let tailHeight, tailHeight.isFinite else { return 0 }
        return max(tailTop + tailHeight - natural - trim, 0)
    }
}

/// TranscriptStack 里不是一行、是个标记的空视图：最后一轮的顶，最后一行的底边。
private nonisolated struct StackMarker: LayoutValueKey {
    enum Kind {
        case tail
        case end
    }

    static let defaultValue: Kind? = nil
}

private struct Row: Identifiable {
    enum Content {
        case item(Item)
        case message(Message, queued: Bool)

        var isMessage: Bool {
            if case .message = self { true } else { false }
        }
    }

    let id: RowID
    let content: Content
    /// 和上一行之间在 VStack 的间距之外多空多少。
    let gap: CGFloat
    /// 人发的消息开启新的一轮（不是并进正在跑的这一轮的插话）。
    let startsHumanTurn: Bool

    var isMessage: Bool { content.isMessage }
}

private extension Item {
    var startsTurn: Bool {
        switch kind {
        case .human(let message): !message.midTurn
        case .kite, .notification: true
        default: false
        }
    }
}

/// agent 说的一段话，铺满这一栏。iPhone 上点它、Mac 上右键，在左下方弹出操作栏：复制、翻译、从这里分叉（翻译、分叉还没做）。
/// iPhone 上长按以后接着拖是选字（SelectableMarkdown），Mac 上左键选字。
private struct AgentText: View {
    let id: RowID
    let text: String
    @Environment(\.selectedRow) private var selection

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .actionBar(id, side: .leading) { actions }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        SelectableMarkdown(source: text, tapped: { selection.toggle(id) }, selecting: { selection.close() })
        #else
        MarkdownView(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opensActionBar(id)
        #endif
    }

    @ViewBuilder
    private var actions: some View {
        ActionButton("复制", icon: "doc.on.doc") {
            copyToPasteboard(text)
            selection.close()
        }
        // 翻译成另一种语言，还没做
        ActionButton("翻译", icon: "translate") { selection.close() }
        // 分出一个新会话，从这段话之后接着说；还没做
        ActionButton("从这里分叉", icon: "arrow.triangle.branch") { selection.close() }
    }
}

private struct ItemView: View {
    let item: Item

    var body: some View {
        switch item.kind {
        case .human:
            // 人发的消息由 TranscriptView 直接排，和排队中的走同一个分支
            EmptyView()
        case .kite(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label("Kite 发给 agent", systemImage: "arrow.triangle.merge").font(Theme.secondary)
                Text(text).font(Theme.body).textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.rule))
        case .notification(let text):
            EventLabel(text: text, icon: "bell")
        case .text(let text):
            MarkdownView(text)
        case .work(let work):
            WorkRow(work: work)
        case .interrupted:
            EventLabel(text: "已打断", icon: "hand.raised")
        case .compacted(let summary):
            CompactedDivider(summary: summary)
        case .apiError(let message):
            EventLabel(text: message, icon: "exclamationmark.triangle", tint: .red)
        }
    }
}

/// 会话里发生的事，不是谁说的话：后台任务结束、打断、出错。
private struct EventLabel: View {
    let text: String
    let icon: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: icon)
            .font(Theme.secondary)
            .foregroundStyle(tint)
            .textSelection(.enabled)
    }
}

/// 压缩的分界：之前的对话收成了一段摘要，点开看摘要。
private struct CompactedDivider: View {
    let summary: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Rectangle().fill(Theme.rule).frame(height: 1)
                    Text(expanded ? "收起摘要" : "之前的对话已压缩成摘要").fixedSize()
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                MarkdownView(summary).font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
    }
}

private extension Session {
    /// 控制区底下的状态信息：在不在干活、上下文用了几成、工作区改了多少行。
    var status: Text {
        var parts = [Text(transcript.running ? "正在工作" : "空闲")]
        if let context {
            parts.append(Text("上下文 \(context.formatted(.percent.precision(.fractionLength(0))))"))
        }
        if changes.added + changes.removed > 0 {
            parts.append(Text("\(Text("+\(changes.added)").foregroundStyle(.green)) \(Text("−\(changes.removed)").foregroundStyle(.red))"))
        }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0) · \($1)") }
    }
}

/// 会话窗口的控制区：上面一行输入框，下面一行按钮。左边是 effort，右边是附件、斜杠命令、语音输入，
/// 有字时多一个发送；回合在跑时发出去的是插话，多一个打断。附件、斜杠命令、语音输入还没做，点了没反应。
/// 发出去的字在输入框里模糊、淡掉，同时融球从卡片上飞向对话（见 SessionPane.send）。
private struct ControlArea: View {
    var typing: FocusState<Bool>.Binding
    let send: (Message) -> Void
    /// 输入框拿到或者丢了焦点，键盘马上要升起或收起。
    let typingChanged: () -> Void
    @Environment(Session.self) private var session
    /// 刚发出去的字正在淡掉。
    @State private var leaving = false

    var body: some View {
        @Bindable var session = session
        let running = session.transcript.running
        VStack(spacing: 2) {
            TextField(running ? "插话，agent 做完手上这一步就会看到" : "回复", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...8)
                .focused(typing)
                .onChange(of: typing.wrappedValue) { typingChanged() }
                .onSubmit(submit)
                .blur(radius: leaving ? 6 : 0)
                .opacity(leaving ? 0 : 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            HStack(spacing: 0) {
                EffortPicker(effort: $session.effort)
                Spacer(minLength: 0)
                IconButton(icon: "paperclip") {}
                IconButton(icon: "slash.circle") {}
                IconButton(icon: "mic") {}
                if running {
                    RoundButton(icon: "stop.fill", fill: Theme.strongPlaceholder) {
                        withAnimation(.snappy) { session.transcript.interrupt() }
                    }
                    .padding(.leading, 4)
                }
                if !blank && !leaving {
                    RoundButton(icon: "arrow.up", fill: .accentColor, action: submit)
                        .padding(.leading, 4)
                }
            }
        }
        .padding(8)
    }

    private var blank: Bool {
        session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard !blank, !leaving else { return }
        let sent = session.draft
        send(Message(typed: sent.trimmingCharacters(in: .whitespacesAndNewlines)))
        // 淡完才清空，输入框不在淡的时候变矮。淡的时候又打了字的，只去掉发出去的那一截
        withAnimation(.easeOut(duration: 0.3)) {
            leaving = true
        } completion: {
            if session.draft.hasPrefix(sent) { session.draft.removeFirst(sent.count) }
            leaving = false
        }
    }
}

/// 选 effort。平时只显示当前档位；iPhone 上点它或者从它往右滑、Mac 上鼠标移上去，刻度线展开在档位名前面，档位名让到右边。
/// 一档一根主刻度，中间是装饰刻度，粗细、高度一样，垂直居中；主刻度淡主题色，装饰刻度灰色，当前档位主题色、稍宽。
/// 在刻度上左右拖调档位，拖的时候当前档位附近的刻度略微拉长，越近越长；点一下刻度直接选那一档。
/// 手指一直在当前档位上：iPhone 上点开、滑开时，刻度线挪到当前档位落在手指下面（左边放不下就贴着左边）；从刻度上拖起时，
/// 手指在哪一档就是哪一档；从滑动展开的话手不用抬，接着滑就是在调。Mac 上鼠标移上去在原地展开，不跟着指针挪。
/// iPhone 上选完收起，再点一下档位名也收起；Mac 上鼠标离开就收起。
private struct EffortPicker: View {
    @Binding var effort: Effort
    /// iPhone 上点开了；Mac 上鼠标在上面。
    @State private var open = false
    /// 刻度线的左边在哪，从这个控件的左边算。
    @State private var origin: CGFloat = 0
    @State private var drag: Drag?

    /// 这一次拖。
    private enum Drag {
        /// 在调档位：手指的位置减去 from 算档位。from 一般就是刻度线的左边；左边放不下、刻度线贴着左边时，
        /// 按没贴过去的位置算，手指和当前档位的相对位置不变，起手不跳档。
        case adjusting(from: CGFloat)
        /// 竖着拖，留给拉 action 栏。
        case ignored
    }

    /// 相邻两根主刻度之间几根装饰刻度。
    private static let minors = 2

    private var adjusting: Bool {
        if case .adjusting = drag { true } else { false }
    }

    var body: some View {
        let showsTicks = open || adjusting
        HStack(spacing: 0) {
            if showsTicks {
                ticks
                    .padding(.leading, origin)
                    .transition(.opacity)
            }
            Text(effort.name)
                .font(Theme.secondary)
                .foregroundStyle(showsTicks ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
                #if os(iOS)
                // 收着时档位名在最左边，点的位置就是控件里的位置
                .onTapGesture { location in
                    withAnimation(.snappy) {
                        if !open { origin = max(stripOrigin(centering: location.x), 0) }
                        open.toggle()
                    }
                }
                #endif
        }
        .contentShape(Rectangle())
        .gesture(slide)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.snappy) {
                if hovering { origin = 0 }
                open = hovering
            }
        }
        #endif
    }

    private var ticks: some View {
        let perLevel = Self.minors + 1
        let step = Metrics.effortTick / CGFloat(perLevel)
        let current = effort.rawValue * perLevel
        return HStack(spacing: 0) {
            ForEach(0...(Effort.allCases.count - 1) * perLevel, id: \.self) { index in
                // 拖的时候离当前档位两档以内的略微拉长，越近越长，照余弦平滑过渡
                let distance = CGFloat(abs(index - current)) * step / (Metrics.effortTick * 2)
                let near = distance < 1 ? (1 + cos(.pi * distance)) / 2 : 0
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint)
                          : index % perLevel == 0 ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.tertiary))
                    .frame(width: index == current ? 3 : 1.5, height: 14 + (adjusting ? 5 * near : 0))
                    .frame(width: step, height: 32)
            }
        }
        // 两头各留半格，每一档的格子正好以它的主刻度为中心
        .padding(.horizontal, (Metrics.effortTick - step) / 2)
        .contentShape(Rectangle())
        .onTapGesture { location in select(level(at: location.x)) }
        .animation(.snappy(duration: 0.2), value: effort)
        .animation(.snappy(duration: 0.2), value: adjusting)
    }

    private var slide: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if drag == nil {
                    guard abs(value.translation.width) >= abs(value.translation.height) else {
                        drag = .ignored
                        return
                    }
                    let start = value.startLocation.x
                    let onTicks = open && start >= origin && start <= origin + Metrics.effortTick * CGFloat(Effort.allCases.count)
                    let from = onTicks ? origin : stripOrigin(centering: start)
                    withAnimation(.snappy) {
                        origin = max(from, 0)
                        drag = .adjusting(from: from)
                    }
                }
                guard case .adjusting(let from) = drag else { return }
                let level = level(at: value.location.x - from)
                if level != effort { effort = level }
            }
            .onEnded { _ in
                withAnimation(.snappy) {
                    #if os(iOS)
                    if adjusting { open = false }
                    #endif
                    drag = nil
                }
            }
    }

    /// 当前档位的主刻度落在 x 下面时，刻度线的左边在哪；是负的就是左边放不下。
    private func stripOrigin(centering x: CGFloat) -> CGFloat {
        x - Metrics.effortTick * (CGFloat(effort.rawValue) + 0.5)
    }

    /// 刻度线上 x 处（从刻度线左边算）是哪一档，两头之外算最低、最高档。
    private func level(at x: CGFloat) -> Effort {
        let index = Int((x / Metrics.effortTick).rounded(.down))
        return Effort.allCases[min(max(index, 0), Effort.allCases.count - 1)]
    }

    private func select(_ level: Effort) {
        effort = level
        #if os(iOS)
        withAnimation(.snappy) { open = false }
        #endif
    }
}

/// 控制区里只有图标的按钮。
private struct IconButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RoundButton: View {
    let icon: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.secondary.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
