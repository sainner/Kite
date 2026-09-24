import SwiftUI

/// 会话窗口：标题栏是会话的标题和所在的项目，内容是对话，控制区是输入框。
/// 人发的消息靠右、带气泡；agent 的话铺满这一栏；两段话之间 agent 做的事折成一行，点开看每一步。
struct SessionPane: View {
    @Environment(Session.self) private var session
    @State private var position = ScrollPosition(edge: .bottom)
    /// 跟着最底下：打开时是，往上翻就不是了，翻回最底下又是。
    @State private var following = true

    var body: some View {
        let items = session.transcript.items
        PaneWindow(header: session.header) {
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

/// 会话窗口的控制区：输入框和发送按钮。回合在跑时发出去的是插话，多一个打断按钮。
private struct ControlArea: View {
    var typing: FocusState<Bool>.Binding
    @Environment(Session.self) private var session

    var body: some View {
        @Bindable var session = session
        let running = session.transcript.running
        HStack(alignment: .bottom, spacing: 6) {
            TextField(running ? "插话，agent 做完手上这一步就会看到" : "回复", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...8)
                .padding(.vertical, 5)
                .focused(typing)
                .onSubmit(send)
            if running {
                RoundButton(icon: "stop.fill", fill: Theme.strongPlaceholder) {
                    session.transcript.interrupt()
                }
            }
            RoundButton(icon: "arrow.up", fill: .accentColor, action: send)
                .disabled(blank)
                .opacity(blank ? 0.4 : 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.rule))
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
