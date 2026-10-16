#if os(macOS)
import SwiftUI

/// Mac 的模型与更多操作都用 SwiftUI 原生菜单，由系统把两个按钮的玻璃合成一组。
struct MacThreadHeaderMenus: View {
    let modelTitle: String
    let modelLogo: ImageResource?
    let modelName: String?
    let modelEnabled: Bool
    let models: ThreadModelMenu
    let commands: [[ThreadHeaderCommand]]
    var body: some View {
        PaneHeaderButtonGroup {
            modelMenu
            moreMenu
        }
    }

    private var modelMenu: some View {
        Menu {
            ThreadModelMenuItems(models: models)
        } label: {
            PaneHeaderButtonLabel(modelTitle, logo: modelLogo)
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
                        Button(role: command.destructive ? .destructive : nil, action: command.action) {
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
