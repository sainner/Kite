import SwiftUI

/// 独立玻璃按钮共用字体、标签占位与辅助功能：图标占正方形，文字同高，同组按钮尺寸一致；
/// 触屏模式保留触控尺寸，玻璃与交互由系统负责。
struct PaneButtonLabel: View {
    let title: String
    var systemImage: String?
    @ScaledMetric(relativeTo: .body) private var extent: CGFloat = InputMode.current.labelExtent

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                Text(title).lineLimit(1)
            }
        }
        .font(Theme.body)
        .frame(width: systemImage == nil ? nil : extent, height: extent)
        .accessibilityLabel(title)
    }
}

/// 两端共用系统玻璃按钮，尺寸和交互由原生组件负责。
struct PaneButtonGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                content
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.large)
            .buttonSizing(.fitted)
        }
        .fixedSize()
    }
}

/// 标题栏的窗口操作与会话菜单共用一块玻璃，与 iPhone 的组合菜单按钮同一规则：
/// 相邻内容之间隔一个按钮间距，两端留出图标在按钮高度里的空白，单个图标入口仍是圆形。
struct PaneHeaderButtonGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, Metrics.paneHeaderGroupInset)
        .menuStyle(.button)
        .buttonStyle(PaneHeaderButtonStyle())
        .controlSize(.large)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
    }
}

/// 原生菜单展开时沿用按钮的按下状态，背景随菜单收起自动清除。
/// 按钮只带半个间距，反馈向两侧多出一点，图标入口的反馈仍是圆形。
private struct PaneHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PaneButtonHover(inset: 4, horizontalInset: -1, isPressed: configuration.isPressed))
    }
}

/// 标题栏按钮按输入方式选择高度；左右各带半个按钮间距，两端由所在的组补齐。
struct PaneHeaderButtonLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        PaneButtonLabel(title, systemImage: systemImage)
            .padding(.horizontal, Metrics.paneButtonGap / 2)
            .frame(height: Metrics.paneHeaderButton)
            .contentShape(.capsule)
    }
}

/// 控制区和工具条共用尺寸、字体、命中范围和交互反馈；玻璃由所属容器提供。
struct PaneButtonStyle: ButtonStyle {
    var text = false
    var fill: Color?
    var foreground: Color = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(fill == nil ? Theme.body : Theme.body.weight(.bold))
            .foregroundStyle(fill == nil ? foreground : .white)
            .lineLimit(1)
            .fixedSize(horizontal: text, vertical: false)
            .padding(.horizontal, text ? Metrics.paneToolbarInset : 0)
            .frame(width: text ? nil : Metrics.paneButton, height: Metrics.paneButton)
            .frame(minWidth: Metrics.paneButton)
            .modifier(PaneButtonHover(inset: 2, fill: fill, isPressed: configuration.isPressed))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .clickPointer()
    }
}

/// 控制区和工具条共用圆形／药丸的完整命中范围和禁用、悬停处理。
struct PaneButtonHover: ViewModifier {
    var inset: CGFloat = 2
    /// 左右与上下不同时给出。
    var horizontalInset: CGFloat?
    var fill: Color?
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    private var feedback: Color {
        if isPressed && isEnabled { return Color.gray.opacity(0.20) }
        return Color.gray.opacity(hovered && isEnabled ? 0.10 : 0)
    }

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(fill ?? feedback)
                    .padding(.vertical, inset)
                    .padding(.horizontal, horizontalInset ?? inset)
                    .allowsHitTesting(false)
            }
            .overlay {
                if fill != nil {
                    Capsule()
                        .fill(feedback)
                        .padding(.vertical, inset)
                        .padding(.horizontal, horizontalInset ?? inset)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}
