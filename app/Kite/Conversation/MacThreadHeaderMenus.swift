#if os(macOS)
import SwiftUI

/// Mac 的模型入口打开分段选择弹窗，更多操作沿用原生菜单。
struct MacThreadHeaderMenus: View {
    let modelTitle: String
    let modelName: String?
    let modelEnabled: Bool
    let commands: [[ThreadHeaderCommand]]
    let onOpenModel: () -> Void
    var body: some View {
        PaneHeaderButtonGroup {
            modelMenu
            moreMenu
        }
    }

    private var modelMenu: some View {
        Button(action: onOpenModel) {
            PaneHeaderButtonLabel(modelTitle)
        }
        .disabled(!modelEnabled)
        .help(modelName ?? "执行环境与模型")
        .accessibilityLabel("模型")
        .accessibilityValue(modelName ?? modelTitle)
    }

    private var moreMenu: some View {
        Menu {
            ForEach(commands.indices, id: \.self) { index in
                Section {
                    ForEach(commands[index]) { command in
                        Button(action: command.action) {
                            Label(command.title, systemImage: command.symbol)
                        }
                        .disabled(!command.enabled)
                    }
                }
            }
        } label: {
            PaneHeaderButtonLabel("更多操作", systemImage: "ellipsis")
        }
        .help("更多操作")
    }
}
#endif
