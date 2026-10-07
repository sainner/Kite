#if os(macOS)
import SwiftUI

/// Mac 使用 SwiftUI 原生菜单，并由系统把两个按钮的玻璃合成一组。
struct MacThreadHeaderMenus: View {
    let modelTitle: String
    let modelName: String?
    let modelIDs: [String]
    let modelEnabled: Bool
    let commands: [[ThreadHeaderCommand]]
    let onSelectModel: (String) -> Void
    @Environment(\.paneOverflowActions) private var windowActions
    var body: some View {
        PaneHeaderButtonGroup {
            modelMenu
            moreMenu
        }
    }

    private var modelMenu: some View {
        Menu {
            Picker("模型", selection: Binding(
                get: { modelName },
                set: { name in
                    guard modelEnabled, let name else { return }
                    onSelectModel(name)
                }
            )) {
                ForEach(modelIDs, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PaneHeaderButtonLabel(modelTitle)
        }
        .disabled(!modelEnabled)
        .help(modelName ?? "执行环境与模型")
        .accessibilityLabel("模型")
        .accessibilityValue(modelName ?? modelTitle)
    }

    private var moreMenu: some View {
        Menu {
            if let windowActions {
                Button("缩小窗口", systemImage: "minus", action: windowActions.minimize)
                if let expand = windowActions.expand {
                    Button("展开窗口", systemImage: "arrow.up.left.and.arrow.down.right", action: expand)
                }
                Button("关闭窗口", systemImage: "xmark", action: windowActions.close)
                    .disabled(!windowActions.canClose)
                Divider()
            }
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
            PaneHeaderButtonLabel("更多会话操作", systemImage: "ellipsis")
        }
        .help("更多会话操作")
    }
}
#endif
