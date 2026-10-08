import SwiftUI

@main
struct KiteApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if DirectoryVerification.isRequested {
            do {
                let model = AppModel(account: try DirectoryVerification.account())
                _model = State(initialValue: model)
                Task { await DirectoryVerification.run(model: model) }
                return
            } catch {
                print("目录验收启动失败：\(error)")
                exit(1)
            }
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        #if os(macOS)
        Window("Kite", id: "main") {
            AppRoot().connectsToService().cardActionsPreview()
                .environment(model).readsWindowChrome().toastHost().appAppearance()
        }
        .kiteWindowStyle()
        .defaultSize(width: 1272, height: 792)
        .commands { KiteCommands(model: model) }

        // 从侧边栏分离出来的工作区，放在松手的地方
        WindowGroup("工作区", id: "workspace", for: String.self) { $id in
            if let id {
                DetachedWorkspace(id: id).environment(model).readsWindowChrome().toastHost().appAppearance()
            }
        }
        .kiteWindowStyle()
        .defaultSize(width: 996, height: 696)

        #else
        WindowGroup {
            AppRoot().connectsToService().cardActionsPreview().environment(model).toastHost().appAppearance()
        }
        #endif
    }
}

#if os(macOS)
private extension Scene {
    /// 去掉标题栏，底色铺满整个窗口；拖侧边栏这些空白处移动窗口，卡片上不行（见 disablesWindowDragging）。
    func kiteWindowStyle() -> some Scene {
        windowStyle(.hiddenTitleBar).windowBackgroundDragBehavior(.enabled)
    }
}

struct KiteCommands: Commands {
    let model: AppModel
    /// 当前窗口里的窗口组，排布菜单作用在它上面。
    @FocusedValue(WindowLayout.self) private var workspace

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏") {
                withAnimation(.snappy) { model.sidebarCollapsed.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Menu("外观") { AppearancePicker() }
        }
        CommandMenu("排布") {
            ForEach(Array(Arrangement.allCases.enumerated()), id: \.element) { index, arrangement in
                Button(arrangement.rawValue) { workspace?.arrange(arrangement) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(workspace == nil)
            }
        }
    }
}
#endif
