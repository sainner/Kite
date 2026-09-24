import SwiftUI

@main
struct KiteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        Window("Kite", id: "main") {
            MainWindow().environment(model)
        }
        .kiteWindowStyle()
        .defaultSize(width: 1280, height: 800)
        .commands { KiteCommands(model: model) }

        // 从侧边栏分离出来的会话，放在松手的地方
        WindowGroup("会话", id: "session", for: Int.self) { $id in
            if let id {
                DetachedSession(id: id).environment(model)
            }
        }
        .kiteWindowStyle()
        .defaultSize(width: 1000, height: 700)
        .defaultWindowPlacement { _, _ in
            guard let frame = model.pendingPlacement else { return WindowPlacement() }
            return WindowPlacement(frame.origin, size: frame.size)
        }
        #else
        WindowGroup {
            PhoneLayout().environment(model)
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
    @FocusedValue(Workspace.self) private var workspace

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏") {
                withAnimation(.snappy) { model.sidebarCollapsed.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
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
