#if os(macOS)
import SwiftUI

/// Mac 的模型与更多操作都用 SwiftUI 原生菜单，由系统把两个按钮的玻璃合成一组。
struct MacThreadHeaderMenus: View {
    let modelTitle: String
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
            if let status = models.status {
                Text(status)
            }
            ForEach(models.vendors) { vendor in
                if let title = vendor.title {
                    Section(title) { modelItems(vendor) }
                } else {
                    Section { modelItems(vendor) }
                }
            }
            if let note = models.note {
                Section { Text(note) }
            }
        } label: {
            PaneHeaderButtonLabel(modelTitle)
        }
        .disabled(!modelEnabled)
        .help(modelName ?? "执行环境与模型")
        .accessibilityLabel("模型")
        .accessibilityValue(modelName ?? modelTitle)
    }

    private func modelItems(_ vendor: ThreadModelMenu.Vendor) -> some View {
        ForEach(vendor.models) { model in
            Toggle(model.name, isOn: Binding(get: { model.selected }, set: { _ in models.select(model.id) }))
                .disabled(!model.enabled)
        }
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
