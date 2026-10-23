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
    var workspaceRowHeight: CGFloat { isTouch ? 44 : 24 }
    /// 侧栏行首到图标的留白：触屏与图标在行高里的上下空白相同，Mac 稍宽。
    var sidebarItemInset: CGFloat { isTouch ? 13 : 10 }
    /// 卡片里输入框与选择框的高度。
    var fieldHeight: CGFloat { isTouch ? 48 : 36 }
    /// 卡片底部与空白页主操作按钮的尺寸。
    var actionControlSize: ControlSize { isTouch ? .large : .extraLarge }
    /// 卡片里开关的尺寸。
    var toggleControlSize: ControlSize { isTouch ? .regular : .small }
}

/// 按当前窗口可用空间选择布局，键盘只压缩内容，不改变布局类别。
enum WorkspacePresentation: Equatable {
    case tiled, compact

    init(size: CGSize) {
        self = size.width >= 720 && size.height >= 480 ? .tiled : .compact
    }

    /// 窄屏触控：空控制区接上拉与横滑只在这时。
    var isCompactTouch: Bool { self == .compact && InputMode.current.isTouch }

    /// 平铺布局里窗口窄于这个宽度时，内容按窄排，见 EnvironmentValues.narrowPane。
    static let narrowPaneWidth: CGFloat = 600
}

extension EnvironmentValues {
    @Entry var workspacePresentation: WorkspacePresentation = .tiled
    /// 平铺布局里这个窗口窄于 narrowPaneWidth，由卡片设上（PaneHeaderEnvironment）。窗口内容读 narrowPane，不直接读它。
    @Entry var narrowTile = false
    /// 窗口内容按窄排：紧凑布局里的窗口，和平铺布局里窄的窗口，两种排出来一模一样（docs/视觉风格.md）。
    /// 窗口内容里分宽窄的地方都读它；横滑换窗口、上拉 action 栏、共用标题栏这些外壳的行为仍按 workspacePresentation。
    var narrowPane: Bool { workspacePresentation == .compact || narrowTile }
}
