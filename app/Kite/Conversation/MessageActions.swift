import SwiftUI

/// 对话里的一行认谁：人发的消息按消息的 id（排队中和收到了是同一行），其余按记录派生出来的序号。
/// 点开了操作栏的那一行也这样认。
nonisolated enum RowID: Hashable {
    case item(Int)
    case message(String)
}

extension EnvironmentValues {
    /// 对话里点开了操作栏的那一行，一次只有一行。会话窗口给出（ThreadPaneSupport），点别处、滚动时收起。
    @Entry var selectedRow: Binding<RowID?> = .constant(nil)
}

extension Binding where Value == RowID? {
    /// 长按显示这一行的操作栏；继续拖动选字时由文本组件收起。
    func show(_ id: RowID) {
        withAnimation(.actionBar) { wrappedValue = id }
    }

    /// 点了这一行：没开就打开它的操作栏（别的收起），开着就收起。
    func toggle(_ id: RowID) {
        withAnimation(.actionBar) { wrappedValue = wrappedValue == id ? nil : id }
    }

    /// 收起操作栏。
    func close() {
        withAnimation(.actionBar) { wrappedValue = nil }
    }
}

extension Animation {
    /// 开关操作栏时别处跟着变的（比如这一行垫到最上面）。操作栏自己的出现、收起见 ActionBar。
    static let actionBar = Animation.snappy(duration: 0.25)
}

#if os(iOS)
/// agent 说的一段话的操作栏：复制、翻译、从这里分叉（翻译、分叉还没做）。iPhone、iPad 的原生列表托管它（PhoneProseRowSlot.actionBar）；
/// Mac 的见 ProseRowSlot.actionItems。
struct AgentTextActions: View {
    let text: String
    @Environment(\.selectedRow) private var selection
    @Environment(\.toast) private var toast

    var body: some View {
        ActionButton("复制", icon: "doc.on.doc") {
            copyToPasteboard(text, toast: toast)
            selection.close()
        }
        // 翻译成另一种语言，还没做
        ActionButton("翻译", icon: "translate") { selection.close() }.disabled(true)
        // 分出一个新会话，从这段话之后接着说；还没做
        ActionButton("从这里分叉", icon: "arrow.triangle.branch") { selection.close() }.disabled(true)
    }
}

/// 人发的消息的操作栏：排队中的是重试、编辑、取消发送；收到了的是压缩起点和终点。都有复制，折起来的还有展开全文。
/// iPhone、iPad 的原生列表托管它（PhoneBubbleRowSlot.actionBar）；Mac 的见 BubbleRowSlot.actionItems，按钮和这里一一对应，改的时候两处一起改。
struct MessageActionButtons: View {
    let message: Message
    let queued: Bool
    let foldable: Bool
    @Binding var expanded: Bool
    @Environment(WorkThread.self) private var thread
    @Environment(\.selectedRow) private var selection
    @Environment(\.toast) private var toast

    var body: some View {
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
#endif
