import SwiftUI

@main
struct KiteApp: App {
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace)
        }
        #if os(macOS)
        // 去掉标题栏，底色铺满整个窗口；拖动侧边栏等空白处移动窗口，卡片上不行（见 MouseDragArea）
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 800)
        #endif
        .commands {
            CommandGroup(before: .toolbar) {
                Button(workspace.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏") {
                    withAnimation(.snappy) { workspace.sidebarCollapsed.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            CommandMenu("排布") {
                ForEach(Array(Arrangement.allCases.enumerated()), id: \.element) { index, arrangement in
                    Button(arrangement.rawValue) { workspace.arrange(arrangement) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }
    }
}
