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
    @State private var latest = LatestCommands()

    var body: some View {
        let _ = latest.commands = commands
        PaneHeaderButtonGroup {
            modelMenu
            MoreMenu(commands: commands, latest: latest)
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
}

/// 更多菜单开着时，只要这一层重算，哪怕内容没变，展开的子菜单（审批模式）也会被系统收起；标题栏随线程状态、实例推送经常重算，
/// 所以只按菜单上看得见的内容比较，没变就不重算。点了按标题到 latest 里取最新传进来的动作，不用重算前留下的旧闭包。
private struct MoreMenu: View, Equatable {
    let commands: [[ThreadHeaderCommand]]
    let latest: LatestCommands

    static func == (a: Self, b: Self) -> Bool {
        a.latest === b.latest && a.commands.map { $0.map(Shown.init) } == b.commands.map { $0.map(Shown.init) }
    }

    var body: some View {
        Menu {
            ForEach(commands.indices, id: \.self) { index in
                Section {
                    ForEach(commands[index]) { command in
                        Group {
                            if command.options.isEmpty {
                                MenuButton(command.title, systemImage: command.symbol, role: command.destructive ? .destructive : nil) {
                                    latest.perform(command.id)
                                }
                            } else {
                                Menu {
                                    ForEach(command.options) { option in
                                        Toggle(option.title, isOn: Binding(get: { option.selected },
                                                                           set: { _ in latest.choose(option.id, in: command.id) }))
                                    }
                                } label: {
                                    Label(command.title, systemImage: command.symbol)
                                }
                            }
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

    /// 一项在菜单上看得见的部分。
    private struct Shown: Equatable {
        let title: String
        let symbol: String
        let enabled: Bool
        let destructive: Bool
        let options: [String]
        let selected: [Bool]

        init(_ command: ThreadHeaderCommand) {
            title = command.title
            symbol = command.symbol
            enabled = command.enabled
            destructive = command.destructive
            options = command.options.map(\.title)
            selected = command.options.map(\.selected)
        }
    }
}

/// 最新一次传给更多菜单的各项，菜单不重算时动作从这里取。
private final class LatestCommands {
    var commands: [[ThreadHeaderCommand]] = []

    func perform(_ id: ThreadHeaderCommand.ID) {
        command(id)?.action()
    }

    func choose(_ option: ThreadHeaderCommand.Option.ID, in id: ThreadHeaderCommand.ID) {
        command(id)?.options.first { $0.id == option }?.select()
    }

    private func command(_ id: ThreadHeaderCommand.ID) -> ThreadHeaderCommand? {
        commands.joined().first { $0.id == id }
    }
}
#endif
