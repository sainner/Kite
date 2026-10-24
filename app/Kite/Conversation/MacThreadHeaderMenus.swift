#if os(macOS)
import AppKit
import SwiftUI

/// Mac 的模型用 SwiftUI 原生菜单，更多操作是按钮、松手弹出 AppKit 菜单（见 MoreMenu），两个按钮的玻璃由系统合成一组。
struct MacThreadHeaderMenus: View {
    let modelTitle: String
    let modelLogo: ImageResource?
    let modelName: String?
    let modelEnabled: Bool
    let models: ThreadModelMenu
    let commands: [[ThreadHeaderCommand]]
    @State private var more = MoreMenuSource()

    var body: some View {
        let _ = more.commands = commands
        PaneHeaderButtonGroup {
            modelMenu
            MoreMenu(source: more)
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

/// 更多操作不用 SwiftUI 的 Menu：它在按下时弹出，松手被菜单吞掉，交互玻璃停在按下的样子，一两秒后自己复位，
/// 复位时 SwiftUI 把开着的菜单重新同步一遍，展开的子菜单（审批模式）随之收起（2026-10-25 探针：玻璃不交互时不同步、不收起）；
/// 所在视图重算一次也会同步。所以是普通按钮，松手按当时传进来的各项现建 AppKit 菜单弹出，SwiftUI 不碰它。
private struct MoreMenu: View {
    let source: MoreMenuSource

    var body: some View {
        Button { source.popUp() } label: {
            PaneHeaderButtonLabel("更多操作", systemImage: "ellipsis")
                .background(MenuAnchor(source: source))
        }
        .help("更多操作")
    }
}

/// 最新一次传给更多菜单的各项和弹出的位置。菜单开着时实例可能换了快照，点了按标题到这里取最新的动作，不用弹出时留下的旧闭包。
@MainActor private final class MoreMenuSource {
    var commands: [[ThreadHeaderCommand]] = []
    weak var anchor: NSView?

    /// 位置同 SwiftUI 的菜单：菜单窗口比按钮左缘往左 7pt，上沿在按钮底边下 8pt；弹出点是第一项，窗口在它上面还有 5pt 的边。
    func popUp() {
        guard let anchor else { return }
        menu().popUp(positioning: nil, at: CGPoint(x: -7, y: anchor.bounds.height + 13), in: anchor)
    }

    /// 每组一节，节之间是分隔线；单选的一项是子菜单，当前的打勾。
    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in commands.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in group { menu.addItem(item(command)) }
        }
        return menu
    }

    private func item(_ command: ThreadHeaderCommand) -> NSMenuItem {
        let id = command.id
        let item: NSMenuItem
        if command.options.isEmpty {
            item = MenuAction.item(command.title, enabled: command.enabled, destructive: command.destructive) { [weak self] in
                self?.command(id)?.action()
            }
        } else {
            item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
            item.isEnabled = command.enabled
            let options = NSMenu()
            options.autoenablesItems = false
            for option in command.options {
                let optionID = option.id
                let choice = MenuAction.item(option.title, enabled: true) { [weak self] in
                    self?.command(id)?.options.first { $0.id == optionID }?.select()
                }
                choice.state = option.selected ? .on : .off
                options.addItem(choice)
            }
            item.submenu = options
        }
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
        return item
    }

    private func command(_ id: ThreadHeaderCommand.ID) -> ThreadHeaderCommand? {
        commands.joined().first { $0.id == id }
    }
}

/// 更多菜单从这里弹出：铺在按钮标签后面，只给位置，不接点击。
private struct MenuAnchor: NSViewRepresentable {
    let source: MoreMenuSource

    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) { source.anchor = view }

    private final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
