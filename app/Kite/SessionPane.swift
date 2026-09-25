import SwiftUI

/// 会话窗口：标题栏是会话的标题和所在的项目，内容是对话，控制区是输入框和一行按钮，底下的状态信息是会话此刻的情况。
/// 人发的消息靠右、带气泡；agent 的话铺满这一栏；两段话之间 agent 做的事折成一行，点开看每一步。
struct SessionPane: View {
    @Environment(Session.self) private var session
    /// 对话怎么滚：跟不跟着最底下、发送后滑到哪、底下留多少空白。
    @State private var scroll = TranscriptScroll()
    /// 刚发出、气泡还在下面、没开始往上浮的消息。
    @State private var arriving: Set<UUID> = []
    /// 点开了操作栏的那一行。
    @State private var selected: RowID?

    var body: some View {
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
                // 可见区多高在排版时当场算出来（GeometryReader），留白和它同一次排好。这里的尺寸已经扣掉了
                // 标题栏、控制区和键盘让出的那一截，滚动视图照样伸到它们后面（实测）
                GeometryReader { proxy in
                    ScrollView {
                        TranscriptView(items: items, pending: pending, actionable: true, tail: scroll.tail(visible: proxy.size.height))
                            .font(Theme.body)
                            .frame(maxWidth: Metrics.transcriptWidth)
                            .padding(.horizontal, 16)
                            .padding(.vertical, Metrics.transcriptPadding)
                            .frame(maxWidth: .infinity)
                            // 操作栏开着时，点对话里别的地方收起；点到按钮、别的气泡由它们自己接
                            .contentShape(Rectangle())
                            .gesture(TapGesture().onEnded { $selected.close() }, isEnabled: selected != nil)
                    }
                    // 手指一滚就收起操作栏
                    .transcriptScroll(scroll, visibleHeight: proxy.size.height) {
                        if selected != nil { $selected.close() }
                    }
                }
            }
        } controls: { typing in
            ControlArea(typing: typing, send: send)
                .frame(maxWidth: Metrics.transcriptWidth)
        }
        .environment(\.workingDirectory, session.transcript.root)
        .environment(\.arrivingMessages, arriving)
        .environment(\.selectedRow, $selected)
    }

    /// 发一条消息：先排进队里，对话滑过去（见 TranscriptScroll.send），气泡同时从下往上浮进来。
    private func send(_ message: Message) {
        arriving.insert(message.id)
        scroll.send { session.send(message) } alongside: { arriving.remove(message.id) }
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
    /// 点 agent 的话弹出操作栏。主对话里是；子 agent 做的事里不是，它们的序号和主对话的会撞。
    var actionable = false
    /// 主对话给：最后一轮底下的留白（见 TranscriptStack）。发送后滚到最后一轮顶上的标记（TailSpace.marker），
    /// 这条消息正好停在可见区顶上，上一段内容刚好滚出去，回复往下面的空白里填；回复长过一屏就照常跟着最底下。
    /// 排在后面的消息（回合在跑、或者前面还排着别的时发的）不开启新的一轮：它接在那一轮后面，
    /// 顶到最上面的话 agent 接着写的内容就在屏幕外了。
    var tail: TailSpace?
    @Environment(\.selectedRow) private var selection

    var body: some View {
        let rows = rows
        TranscriptStack(spacing: Metrics.rowSpacing, tailIndex: tail == nil ? nil : rows.lastIndex(where: \.startsHumanTurn),
                        tailHeight: tail?.height) {
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
            if let tail {
                Color.clear.frame(height: 0).layoutValue(key: StackMarker.self, value: .tail).id(TailSpace.marker)
                TailEnd(tail: tail).layoutValue(key: StackMarker.self, value: .end)
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
            append(.message(message.id), .message(message, queued: true), startsTurn: !message.midTurn)
        }
        return rows
    }
}

/// 对话一行一行往下排，靠左，行间空 spacing，和 VStack 一样。给了 tailHeight 时，最后一轮（从 tailIndex 那一行上面、
/// 上一行的底边算起）至少这么高，不够就在底下留白；标着 .tail 的空视图摆在最后一轮的顶上，发送后滚到它，
/// 标着 .end 的摆在最后一行的底边，用来看底下的空白露没露出来。
/// 留白要在排版里和新消息一次算出来：量出来再补会晚一次排版，发送时滚动那一刻底下还没有留白，滚不到位。
private struct TranscriptStack: Layout {
    let spacing: CGFloat
    let tailIndex: Int?
    let tailHeight: CGFloat?

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
        return max(tailTop + tailHeight - natural, 0)
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
/// 发出去的字在输入框里模糊、淡掉，同时气泡在对话里从下往上浮进来（见 SessionPane.send）。
private struct ControlArea: View {
    var typing: FocusState<Bool>.Binding
    let send: (Message) -> Void
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

/// 选 effort。平时只显示当前档位；iPhone 上按下它、Mac 上鼠标移上去，刻度线（见 EffortTicks）展开在档位名前面，档位名让到右边。
/// iPhone 上一按下档位名就展开，刻度线挪到当前档位落在手指下面，左边放不下就贴着左边。没拖就松手，留着展开，再点一下档位名收起；
/// 按下以后横着拖是在调档位，手指在哪一格就是哪一格，松手就是松手处那一档，收起。按下时手指所在的那一格要等手指离开它才算：
/// 刻度线贴着左边时手指下面不是当前档位，按下去、手抖一下不会就换。展开以后点一下刻度直接选那一档、收起，从刻度上拖也一样调。
/// 竖着拖留给拉 action 栏，刻度线收起。Mac 上鼠标移上去在原地展开，不跟着指针挪，鼠标离开就收起；在上面点、拖和 iPhone 一样调档位。
private struct EffortPicker: View {
    @Binding var effort: Effort
    /// 按下时展开的，松手后留着还是收起见 onEnded。
    @State private var open = false
    /// Mac 上鼠标在上面。
    @State private var hovering = false
    /// 刻度线的左边在哪，从这个控件的左边算。
    @State private var origin: CGFloat = 0
    @State private var touch: Touch?
    /// 手指按着。松手、被系统打断都会自己变回 false；打断时不调 onEnded，靠它收尾。
    @GestureState private var down = false

    /// 这一次按下。
    private struct Touch: Equatable {
        /// 起手那一格：按在刻度上是按着的那一档，按在档位名上是展开后手指下面那一档。
        /// 手指离开过它就是 nil，之后手指在哪一格就是哪一格。
        var start: Effort?
        /// 按在刻度上：没离开起手那一格就松手，是点了那一档。
        let onTicks: Bool
        /// 这次按下时才展开的：没离开起手那一格就松手，留着展开。
        let opened: Bool
        /// 挪开以后定下：横着拖是在调档位，竖着拖留给拉 action 栏。还没挪开是 nil。
        var sliding: Bool?
        /// 横着拖时手指到过的最右一根刻度。
        var farthest: Int?

        /// 没离开起手那一格就松手，算点。
        var tapped: Bool { start != nil && sliding != false }
    }

    /// 手指按着在调档位：按下还没挪开，或者在横着拖。
    private var adjusting: Bool {
        if let touch { touch.sliding != false } else { false }
    }

    private var showsTicks: Bool { open || hovering || adjusting }

    var body: some View {
        HStack(spacing: 0) {
            EffortTicks(effort: effort, origin: origin, shown: showsTicks, adjusting: adjusting, reached: touch?.farthest)
            Text(effort.name)
                .font(Theme.secondary)
                .foregroundStyle(showsTicks ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 32)
        }
        .contentShape(Rectangle())
        .gesture(press)
        .onChange(of: down) { _, down in
            // 松手时 onEnded 已经收过尾；被系统打断时不调它，在这里收
            if !down, touch != nil {
                withAnimation(.snappy) {
                    touch = nil
                    open = false
                }
            }
        }
        .onHover { hovering in
            withAnimation(.snappy) { self.hovering = hovering }
        }
        .sensoryFeedback(.selection, trigger: effort)
    }

    /// 按、点、拖都在这一个手势里，位置都从这个控件的左边算：展开时档位名会让到右边，按它自己的坐标算不准。
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($down) { _, down, _ in down = true }
            .onChanged { value in
                guard var touch else {
                    begin(at: value.startLocation.x)
                    return
                }
                let x = value.location.x
                if touch.sliding == nil {
                    let moved = value.translation
                    guard hypot(moved.width, moved.height) >= Metrics.dragThreshold else { return }
                    touch.sliding = DrawerPull.isHorizontal(moved)
                    if touch.sliding == false {
                        withAnimation(.snappy) {
                            self.touch = touch
                            open = false
                        }
                        return
                    }
                }
                guard touch.sliding == true else { return }
                let level = level(at: x)
                if level != touch.start { touch.start = nil }
                let tick = EffortTicks.tick(at: x - origin)
                touch.farthest = max(tick, touch.farthest ?? tick)
                if touch != self.touch { self.touch = touch }
                if touch.start == nil, level != effort { effort = level }
            }
            .onEnded { _ in
                guard let touch else { return }
                withAnimation(.snappy) {
                    self.touch = nil
                    if touch.tapped, touch.onTicks, let start = touch.start { effort = start }
                    // 点档位名展开的留着；点了刻度、点档位名收起、拖完了都收起
                    if !(touch.tapped && touch.opened) { open = false }
                }
            }
    }

    /// 按下：记下起手那一格。收着的话马上展开，刻度线挪到当前档位的主刻度落在手指下面，左边放不下就贴着左边。
    private func begin(at x: CGFloat) {
        let opened = !showsTicks
        // 展开以前算：展开以后手指下面就是刻度了
        let onTicks = !opened && (0...EffortTicks.width).contains(x - origin)
        withAnimation(.snappy) {
            if opened {
                origin = max(x - EffortTicks.center(of: effort), 0)
                open = true
            }
            touch = Touch(start: level(at: x), onTicks: onTicks, opened: opened)
        }
    }

    /// x 处（从这个控件的左边算）是哪一档。
    private func level(at x: CGFloat) -> Effort {
        EffortTicks.level(at: x - origin)
    }
}

/// effort 的刻度线：一档一根主刻度，中间是装饰刻度，粗细、高度一样，垂直居中；主刻度淡主题色，装饰刻度灰色，当前档位主题色、稍宽。
/// 一档占 effortTick 宽，每一档的格子以它的主刻度为中心。手指按着的时候当前档位附近的刻度略微拉长，越近越长。
/// 展开、收起都是一道先快后慢扫过去的线：展开时档位名往右让开，扫过哪根刻度，哪根就淡显出来，是个小圆点，再长到正常高度；
/// 收起时从右往左扫，扫到的刻度缩回圆点、淡出，档位名跟在它后面回到左边，不会压着还没收掉的刻度。
/// 半路掉头，每根刻度、档位名从当时的样子接着变。展开时手指往右拖得比扫的线快，直接快进到手指处那根刻度刚淡显出来，再接着播完：
/// 手指拖到哪，哪里的刻度就已经在了。收着时也在，不占宽度、看不见。
private struct EffortTicks: View {
    let effort: Effort
    /// 刻度线的左边在哪，从这个控件的左边算。
    let origin: CGFloat
    /// 展开着。
    let shown: Bool
    /// 手指按着在调档位。
    let adjusting: Bool
    /// 手指横着拖到过的最右一根刻度；没在拖是 nil。
    let reached: Int?
    @State private var sweep = Sweep()
    /// 在播，要一帧帧画。
    @State private var playing = false

    /// 相邻两根主刻度之间几根装饰刻度。
    private static let minors = 2
    private static let perLevel = minors + 1
    /// 一共几根刻度。
    private static let count = (Effort.allCases.count - 1) * perLevel + 1
    /// 相邻两根刻度的间距。
    private static let step = Metrics.effortTick / CGFloat(perLevel)
    /// 刻度线两头各留的半格，每一档的格子正好以它的主刻度为中心。
    private static let inset = (Metrics.effortTick - step) / 2
    /// 刻度线多宽。
    static let width = Metrics.effortTick * CGFloat(Effort.allCases.count)

    /// 扫的线从一头走到另一头、档位名让开或回来用多久。
    private static let slide = 0.3
    /// 展开时一根刻度被扫到以后：淡显用多久，多久开始长高、长多久。
    private static let fadeIn = 0.1
    private static let growDelay = 0.05
    private static let grow = 0.25
    /// 收起时一根刻度被扫到以后：缩回圆点用多久，多久开始淡出、淡出用多久。
    private static let shrink = 0.1
    private static let fadeOutDelay = 0.05
    private static let fadeOut = 0.07
    /// 收起时一根刻度被扫到以后多久没了，档位名在扫的线后面落这么久。
    private static let vanish = fadeOutDelay + fadeOut
    /// 一段播完要多久：展开时最后一根刻度被扫到以后长完；收起时档位名落在扫的线后面，回到左边。
    private static let unfoldDuration = slide + growDelay + grow
    private static let foldDuration = slide + vanish
    private static let easeOut = UnitCurve.easeOutCubic

    /// 第 index 根刻度的中心，从刻度线左边算。
    private static func center(_ index: Int) -> CGFloat {
        inset + step * (CGFloat(index) + 0.5)
    }

    /// 某一档的主刻度的中心，从刻度线左边算。
    static func center(of level: Effort) -> CGFloat {
        center(level.rawValue * perLevel)
    }

    /// 刻度线上 x 处（从刻度线左边算）是第几根刻度的格子，两头之外算第一根、最后一根。
    static func tick(at x: CGFloat) -> Int {
        min(max(Int(((x - inset) / step).rounded(.down)), 0), count - 1)
    }

    /// 刻度线上 x 处（从刻度线左边算）是哪一档，两头之外算最低、最高档。
    static func level(at x: CGFloat) -> Effort {
        let index = Int((x / Metrics.effortTick).rounded(.down))
        return Effort.allCases[min(max(index, 0), Effort.allCases.count - 1)]
    }

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            strip(look(at: context.date))
        }
        // 刻度线会伸出自己占的宽度；点、拖都由外面整个控件接
        .allowsHitTesting(false)
        .onChange(of: shown) {
            let now = Date.now
            sweep = Sweep(unfolding: shown, start: now, from: look(at: now))
        }
        .onChange(of: reached) {
            guard let reached, sweep.unfolding else { return }
            // 手指处那根刻度刚淡显出来的时候
            let target = Self.reach((origin + Self.center(reached)) / fullWidth, in: Self.slide) + Self.fadeIn
            let now = Date.now
            if target > sweep.time(at: now) { sweep.skip += target - sweep.time(at: now) }
        }
        // 播完就停下，不再一帧帧画；多等一点，最后一帧落在播完以后
        .task(id: sweep) {
            playing = sweep.end > .now
            guard playing, (try? await Task.sleep(for: .seconds(sweep.end.timeIntervalSinceNow + 0.05))) != nil else { return }
            playing = false
        }
    }

    /// 刻度线连同左边空出来的那段，展开时一共多宽。
    private var fullWidth: CGFloat {
        origin + Self.width
    }

    /// now 这一刻的样子。
    private func look(at now: Date) -> Look {
        let t = sweep.time(at: now)
        var look = sweep.from
        if sweep.unfolding {
            // 扫的线跟档位名一起往右，先快后慢；比开始时的样子只增不减
            look.slide = max(look.slide, Self.eased(t / Self.slide))
            for i in 0..<Self.count {
                let own = t - Self.reach((origin + Self.center(i)) / fullWidth, in: Self.slide)
                look.fade[i] = max(look.fade[i], Self.eased(own / Self.fadeIn))
                look.grow[i] = max(look.grow[i], Self.eased((own - Self.growDelay) / Self.grow))
            }
        } else {
            // 扫的线从右往左，先快后慢；档位名落在它后面 vanish 秒，扫到的刻度那时刚好没了。从开始时的样子按比例收
            look.slide *= 1 - Self.eased((t - Self.vanish) / Self.slide)
            for i in 0..<Self.count {
                let own = t - Self.reach(1 - (origin + Self.center(i)) / fullWidth, in: Self.slide)
                look.grow[i] *= 1 - Self.eased(own / Self.shrink)
                look.fade[i] *= 1 - Self.eased((own - Self.fadeOutDelay) / Self.fadeOut)
            }
        }
        return look
    }

    private func strip(_ look: Look) -> some View {
        let current = effort.rawValue * Self.perLevel
        return HStack(spacing: 0) {
            ForEach(0..<Self.count, id: \.self) { index in
                // 按着的时候离当前档位两档以内的略微拉长，越近越长，照余弦平滑过渡
                let distance = CGFloat(abs(index - current)) * Self.step / (Metrics.effortTick * 2)
                let near = distance < 1 ? (1 + cos(.pi * distance)) / 2 : 0
                let width: CGFloat = index == current ? 3 : 1.5
                let height = 14 + (adjusting ? 5 * near : 0)
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint)
                          : index % Self.perLevel == 0 ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.tertiary))
                    // 没长时高度等于宽度，是个小圆点
                    .frame(width: width, height: width + (height - width) * look.grow[index])
                    .opacity(look.fade[index])
                    .frame(width: Self.step, height: 32)
            }
        }
        .padding(.horizontal, Self.inset)
        .animation(.snappy(duration: 0.2), value: effort)
        .animation(.snappy(duration: 0.2), value: adjusting)
        .padding(.leading, origin)
        // 占的宽度跟着档位名让开、回来；刻度线靠左画，多出来的伸到右边
        .frame(width: fullWidth * look.slide, alignment: .leading)
    }

    /// x 截到 0 到 1 之间，按 easeOut 走了几成。
    private static func eased(_ x: Double) -> Double {
        easeOut.value(at: min(max(x, 0), 1))
    }

    /// 按 easeOut 走 duration 秒，走到 fraction 处是第几秒。
    private static func reach(_ fraction: Double, in duration: Double) -> Double {
        duration * easeOut.inverse.value(at: min(max(fraction, 0), 1))
    }

    /// 某一刻的样子，都在 0 到 1 之间：每根刻度淡显了几成、长高了几成，档位名让开了几成。
    private struct Look: Equatable {
        var fade = Array(repeating: 0.0, count: EffortTicks.count)
        var grow = Array(repeating: 0.0, count: EffortTicks.count)
        var slide = 0.0
    }

    /// 这一段在展开还是收起，从哪一刻、什么样子开始。
    private struct Sweep: Equatable {
        var unfolding = false
        var start = Date.distantPast
        var from = Look()
        /// 展开时被手指快进了多少秒。
        var skip = 0.0

        /// 这一段播到第几秒。
        func time(at now: Date) -> Double {
            now.timeIntervalSince(start) + skip
        }

        /// 播完的那一刻。
        var end: Date {
            start + (unfolding ? EffortTicks.unfoldDuration : EffortTicks.foldDuration) - skip
        }
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
