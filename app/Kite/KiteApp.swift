import SwiftUI

@main
struct KiteApp: App {
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace)
        }
        #if os(macOS)
        // 去掉标题栏，底色铺满整个窗口；拖动空白处移动窗口
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 800)
        #endif
        .commands {
            CommandMenu("排布") {
                ForEach(Array(Arrangement.allCases.enumerated()), id: \.element) { index, arrangement in
                    Button(arrangement.rawValue) { workspace.arrange(arrangement) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }
    }
}
