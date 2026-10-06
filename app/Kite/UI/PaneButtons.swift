import SwiftUI

/// 独立玻璃按钮共用字体、标签占位与辅助功能：图标占正方形，文字同高，同组按钮尺寸一致；
/// iPhone 的占位保留触控尺寸，玻璃与交互由系统负责。
struct PaneButtonLabel: View {
    let title: String
    var systemImage: String?
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var extent: CGFloat = 16
    #else
    @ScaledMetric(relativeTo: .body) private var extent: CGFloat = 18
    #endif

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

#if os(macOS)
/// Mac 标题栏的窗口操作与会话菜单共用一块玻璃的分组规则。
struct PaneHeaderButtonGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { subview in
                        subview
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectUnion(id: "header-controls", namespace: glass)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(PaneHeaderButtonStyle())
            .controlSize(.large)
            .menuIndicator(.hidden)
        }
        .fixedSize()
    }
}

/// 原生菜单展开时沿用按钮的按下状态，背景随菜单收起自动清除。
private struct PaneHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PaneButtonHover(inset: 4, isPressed: configuration.isPressed))
    }
}

/// Mac 标题栏按钮统一为 36pt 高；文字两侧各留 8pt，图标入口使用正方形点击区。
struct PaneHeaderButtonLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        PaneButtonLabel(title, systemImage: systemImage)
            .padding(.horizontal, systemImage == nil ? Metrics.paneToolbarInset : 0)
            .frame(width: systemImage == nil ? nil : Metrics.paneHeaderButton, height: Metrics.paneHeaderButton)
            .frame(minWidth: Metrics.paneHeaderButton)
            .contentShape(.capsule)
    }
}
#endif

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
    var fill: Color?
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    private var feedback: Color {
        #if os(macOS)
        if isPressed && isEnabled { return Color.gray.opacity(0.20) }
        #endif
        return Color.gray.opacity(hovered && isEnabled ? 0.10 : 0)
    }

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(fill ?? feedback)
                    .padding(inset)
                    .allowsHitTesting(false)
            }
            .overlay {
                if fill != nil {
                    Capsule()
                        .fill(feedback)
                        .padding(inset)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}
