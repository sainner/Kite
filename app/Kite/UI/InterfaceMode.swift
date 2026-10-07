import SwiftUI

/// 输入能力与布局独立。触屏设备接上鼠标后仍保留触控尺寸和可发现的操作入口。
enum InputMode {
    case pointer, touch

    static var current: Self {
        #if os(macOS)
        .pointer
        #else
        .touch
        #endif
    }

    var isTouch: Bool { self == .touch }
    /// 用于缺少独立触屏交互的悬停操作入口。
    func revealsControls(hovered: Bool) -> Bool { isTouch || hovered }
    var button: CGFloat { isTouch ? 44 : 28 }
    var headerButton: CGFloat { isTouch ? 48 : 36 }
    var labelExtent: CGFloat { isTouch ? 18 : 16 }
    var paneMargin: CGFloat { isTouch ? 14 : 6 }
    var titleOutset: CGFloat { isTouch ? 12 : 4 }
    var dockItem: CGFloat { isTouch ? 48 : 36 }
    var controlRadius: CGFloat { isTouch ? 28 : 18 }
    var rowHeight: CGFloat { isTouch ? 44 : 32 }
}

/// 按当前窗口可用空间选择布局，键盘只压缩内容，不改变布局类别。
enum WorkspacePresentation: Equatable {
    case tiled, compact

    init(size: CGSize) {
        self = size.width >= 720 && size.height >= 480 ? .tiled : .compact
    }
}

extension EnvironmentValues {
    @Entry var workspacePresentation: WorkspacePresentation = .tiled
}
