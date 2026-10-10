#if os(macOS)
import AppKit
import SwiftUI

/// 标题信息区的系统提示由独立原生视图承接，随视图入窗、移除与尺寸变化更新。
/// SwiftUI 的悬停事件在换页后仍会到达，但 .help 曾不显示，切换桌面才恢复。
struct PaneHeaderHelp: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // 同一段说明不重复注册，避免内容刷新打断正在等待显示的提示。
        if view.toolTip != text { view.toolTip = text }
    }
}
#endif
