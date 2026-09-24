import SwiftUI

/// 会话窗口：标题栏是会话的标题和所在的项目，内容是对话，控制区是输入框和一行按钮，底下的状态信息是会话此刻的情况。
/// 人发的消息靠右、带气泡；agent 的话铺满这一栏；两段话之间 agent 做的事折成一行，点开看每一步。
struct SessionPane: View {
    @Environment(Session.self) private var session
    @State private var position = ScrollPosition(edge: .bottom)
    /// 跟着最底下：打开时是，往上翻就不是了，翻回最底下又是。
    @State private var following = true

    var body: some View {
        let items = session.transcript.items
        PaneWindow(header: session.header, status: session.status) {
            if items.isEmpty {
                Text("说说要做什么")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            } else {
                ScrollView {
                    TranscriptView(items: items)
                        .font(Theme.body)
                        .frame(maxWidth: Metrics.transcriptWidth)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                }
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // 跟着最底下时，内容变长、卡片变大小都停在最底下；翻到上面看的时候不动。
                // 打开时卡片还会变几次大小，只靠 initialOffset 停不住。
                // 不用 defaultScrollAnchor 的 sizeChanges：它不管停在哪，展开上面的某一步也会把内容往上推
                .onScrollGeometryChange(for: ScrollState.self, of: ScrollState.init) { old, new in
                    if old.content != new.content || old.container != new.container {
                        if following { position.scrollTo(edge: .bottom) }
                    } else {
                        following = new.atBottom
                    }
                }
                .onChange(of: items.count) {
                    // 自己发的消息总要看得到
                    if case .human = items.last?.kind {
                        withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
                    }
                }
            }
        } controls: { typing in
            ControlArea(typing: typing)
                .frame(maxWidth: Metrics.transcriptWidth)
        }
        .environment(\.workingDirectory, session.transcript.root)
    }
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

/// 一串记录排下来。主对话和子 agent 做的事都用它。
struct TranscriptView: View {
    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items) { item in
                ItemView(item: item)
                    // 新的一轮和上一轮之间多空一点
                    .padding(.top, item.startsTurn && item.id > 0 ? 12 : 0)
            }
        }
    }
}

private extension Item {
    var startsTurn: Bool {
        switch kind {
        case .human(_, let midTurn): !midTurn
        case .kite, .notification: true
        default: false
        }
    }
}

private struct ItemView: View {
    let item: Item

    var body: some View {
        switch item.kind {
        case .human(let text, let midTurn):
            HumanMessage(text: text, midTurn: midTurn)
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

private struct HumanMessage: View {
    let text: String
    let midTurn: Bool

    var body: some View {
        HStack {
            Spacer(minLength: Metrics.bubbleInset)
            VStack(alignment: .trailing, spacing: 4) {
                if midTurn {
                    Text("回合中插话").font(Theme.secondary).foregroundStyle(.secondary)
                }
                Text(text)
                    .font(Theme.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 18))
            }
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
private struct ControlArea: View {
    var typing: FocusState<Bool>.Binding
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        let running = session.transcript.running
        VStack(spacing: 2) {
            TextField(running ? "插话，agent 做完手上这一步就会看到" : "回复", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...8)
                .focused(typing)
                .onSubmit(send)
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
                        session.transcript.interrupt()
                    }
                    .padding(.leading, 4)
                }
                if !blank {
                    RoundButton(icon: "arrow.up", fill: .accentColor, action: send)
                        .padding(.leading, 4)
                }
            }
        }
        .padding(8)
    }

    private var blank: Bool {
        session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !blank else { return }
        session.transcript.send(session.draft.trimmingCharacters(in: .whitespacesAndNewlines))
        session.draft = ""
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
