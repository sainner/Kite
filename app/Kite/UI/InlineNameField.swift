import SwiftUI

/// 原地改名的输入框：出现就放光标，回车、失焦（含按到外面）结束一次，Esc 放弃；清空或没改不算改名。
/// 窗口标题和侧栏的工作区名称共用，新名字交给调用方在 end 里提交。
struct InlineNameField: View {
    let label: String
    let original: String
    /// 编辑结束时调一次；name 是新名字，放弃、清空或没改时为 nil。
    let end: (_ name: String?) -> Void
    @State private var draft = ""
    @State private var ended = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .endsEditingOnOutsideTap(focused)
            .onSubmit { finish(keep: true) }
            #if os(macOS)
            .onExitCommand { finish(keep: false) }
            #endif
            .onChange(of: focused) { _, focused in if !focused { finish(keep: true) } }
            .onAppear { draft = original; focused = true }
    }

    private func finish(keep: Bool) {
        guard !ended else { return }
        ended = true
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        end(keep && !name.isEmpty && name != original ? name : nil)
    }
}
