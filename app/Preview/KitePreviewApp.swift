import SwiftUI

/// 只装载共享视图；账号、工作机连接与正式 App 的偏好不进入预览进程。
@main
struct KitePreviewApp: App {
    var body: some Scene {
        Window("Kite 样式预览", id: "preview") {
            SubscriptionLoginPreview().toastHost().appAppearance()
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 760, height: 650)
        .commands {
            CommandGroup(after: .toolbar) {
                Menu("外观") { AppearancePicker() }
            }
        }
    }
}
