import SwiftUI

/// 点对话里的一行弹出的操作栏：一排只有图标的按钮，和标题栏的玻璃按钮组同一套尺寸与构件（PaneHeaderButtonGroup）。
/// 出现时整条从贴着这一行、靠 side 那边的角等比放大，带一点回弹，边放大边淡显；收起时缩回那个角，不回弹，边缩边淡出。
/// 关着时什么都不画。
/// 和系统的编辑菜单（UIEditMenuInteraction）一个做法：按原本的大小排好一次，动画只改整体的缩放，不改尺寸，
/// 玻璃和按钮当一整层放大，里面不重排，也就不抖。改尺寸的做法玻璃每一帧都要把按钮重排一遍，按钮会亚像素地抖。
struct ActionBar<Content: View>: View {
    let shown: Bool
    /// 和这一行哪一边对齐。
    let side: HorizontalEdge
    /// 贴着这一行的是哪条边：在这一行底下时是上边，在上面时是下边。
    let from: VerticalEdge
    @ViewBuilder let content: () -> Content

    var body: some View {
        // 外面垫一层 ZStack：放它的地方给的对齐参考线要加在不随 shown 变的这一层才认
        ZStack {
            if shown {
                PaneHeaderButtonGroup { content() }
                    .transition(.scale(scale: 0.3, anchor: corner).combined(with: .opacity))
            }
        }
        // 出现和收起用各自的动画，不管开关它的那一处用的是什么
        .animation(shown ? .spring(duration: 0.35, bounce: 0.3) : .snappy(duration: 0.2), value: shown)
    }

    private var corner: UnitPoint {
        switch (side, from) {
        case (.leading, .top): .topLeading
        case (.leading, .bottom): .bottomLeading
        case (.trailing, .top): .topTrailing
        case (.trailing, .bottom): .bottomTrailing
        }
    }
}

/// 操作栏上的一个按钮。名字不显示，Mac 上鼠标停在上面时提示，读屏时读出来。
struct ActionButton: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            PaneHeaderButtonLabel(title, systemImage: icon)
        }
        .foregroundStyle(role == .destructive ? Theme.danger : Color.primary)
        .help(title)
    }
}

/// 操作栏上点了再弹一层菜单的按钮，比如回退分三种。
struct ActionMenu<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        Menu {
            Section(title) { content }
        } label: {
            PaneHeaderButtonLabel(title, systemImage: icon)
        }
        .fixedSize()
        .help(title)
    }
}

/// 复制到剪贴板。
func copyToPasteboard(_ text: String, toast: ToastCenter?) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else {
        toast?.show("复制失败", systemImage: "exclamationmark.triangle")
        return
    }
    #else
    UIPasteboard.general.string = text
    #endif
    toast?.show("已复制", systemImage: "checkmark")
}
