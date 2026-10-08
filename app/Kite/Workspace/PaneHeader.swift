import SwiftUI

/// 窗口标题，两端共用。
struct PaneHeader {
    var title: String
    var subtitle: String?
    var titleRefresh: TitleRefresh?

    /// 由主标题尾部的刷新图标触发，生成期间保持原题。
    struct TitleRefresh {
        var actionLabel: String
        var progressLabel: String
        var isRefreshing: Bool
        var enabled: Bool
        var action: () -> Void
    }
}

/// 卡片标题栏按容器排列标题、侧栏入口与窗口菜单。标题前是信息区；容器给出侧栏入口时，
/// 入口与信息区合成一块标题栏玻璃；紧凑触屏布局直接点击信息区打开侧栏。
struct PaneHeaderBar<Status: View, Actions: View>: View {
    let header: PaneHeader
    let status: Status
    let actions: Actions
    @Environment(\.paneHeaderControlsInset) private var controlsInset
    @Environment(\.paneHeaderMinHeight) private var controlsHeight
    @Environment(\.workspacePresentation) private var presentation
    let openSidebar: (@MainActor () -> Void)?

    private var statusOpensSidebar: Bool { InputMode.current.isTouch && presentation == .compact }

    var body: some View {
        // 合进玻璃的信息缩小；环境要在拆分子视图之前给出
        Group(subviews: status.environment(\.paneHeaderStatusGrouped, openSidebar != nil && !statusOpensSidebar)) { statusViews in
            let showsSidebarButton = openSidebar != nil && (!statusOpensSidebar || statusViews.isEmpty)
            HStack(spacing: 0) {
                if let openSidebar, statusOpensSidebar, !statusViews.isEmpty {
                    Button(action: openSidebar) {
                        HStack(spacing: 0) {
                            ForEach(statusViews) { $0 }
                        }
                        .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开侧边栏")
                    .reportsHeaderInteraction()
                } else if let openSidebar {
                    PaneHeaderButtonGroup {
                        Button(action: openSidebar) {
                            PaneHeaderButtonLabel("侧边栏", systemImage: "sidebar.left")
                        }
                        .reportsHeaderInteraction()
                        ForEach(statusViews) { $0 }
                    }
                } else {
                    ForEach(statusViews) { statusView in
                        statusView.fixedSize()
                    }
                }
                HStack(spacing: Metrics.paneButtonGap) {
                    PaneHeaderTitle(header: header)
                    // 标题前统一留一个按钮间距；单独显示的信息按圆环方框计算，扣掉方框里已有的空白
                    .padding(.leading, statusViews.isEmpty || showsSidebarButton
                             ? Metrics.paneButtonGap : Metrics.paneButtonGap - Metrics.statusRingMargin)
                    // 窗口操作出现时由标题区让出宽度，不能让内容的最小宽度把右侧菜单推出窗口。
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .clipped()
                    actions
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: PaneHeaderActionsWidth.self, value: proxy.size.width)
                            }
                        }
                        .padding(.leading, controlsInset)
                        .layoutPriority(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, Metrics.paneMargin)
            .frame(minHeight: controlsHeight)
        }
    }

}

/// 主标题与下方的窗口类型左对齐，主标题可带尾部刷新图标。
struct PaneHeaderTitle: View {
    let header: PaneHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.titleRefreshGap) {
                Text(header.title)
                    .id(header.title)
                    .transition(.blurReplace)
                if let refresh = header.titleRefresh {
                    PaneTitleRefreshButton(refresh: refresh, title: header.title)
                }
            }
            .font((InputMode.current.isTouch ? Theme.secondary : Theme.title).weight(.semibold))
            if let subtitle = header.subtitle {
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .id(subtitle)
                    .transition(.blurReplace)
            }
        }
        .lineLimit(1)
        .animation(.snappy, value: header.title)
        .animation(.snappy, value: header.subtitle)
    }
}

/// 标题尾部的刷新图标是唯一的触发入口，悬停与按压只作用在图标上；生成期间保持原题并转动图标。
/// 命中范围向外扩出一圈，不改变标题行的排版。
private struct PaneTitleRefreshButton: View {
    let refresh: PaneHeader.TitleRefresh
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: refresh.action) {
            Image(systemName: "arrow.clockwise")
                .imageScale(.small)
                .symbolEffect(.rotate, options: .repeating, isActive: refresh.isRefreshing && !reduceMotion)
        }
        .buttonStyle(PaneTitleIconButtonStyle())
        .disabled(!refresh.enabled)
        .help(refresh.isRefreshing ? refresh.progressLabel : refresh.actionLabel)
        .accessibilityLabel(refresh.actionLabel)
        .accessibilityValue(title)
    }
}

private struct PaneTitleIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private var outset: CGFloat { Metrics.titleRefreshOutset }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .padding(outset)
            .modifier(PaneButtonHover(inset: 0, isPressed: configuration.isPressed))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .clickPointer()
            .reportsHeaderInteraction()
            .padding(-outset)
    }
}

private extension View {
    /// 卡片的拖动层在这块范围上挖空，点击交给标题栏里的控件。
    @ViewBuilder
    func reportsHeaderInteraction() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: PaneHeaderInteractiveRects.self,
                    value: [proxy.frame(in: .named("pane-header"))])
            }
        }
    }
}

/// 标题栏与更多菜单共用当前卡片的窗口动作。
struct PaneWindowActions {
    let minimize: @MainActor () -> Void
    let expand: (@MainActor () -> Void)?
    let close: @MainActor () -> Void
    let canClose: Bool
}

extension EnvironmentValues {
    /// 卡片宽度不足时，把窗口操作交给更多菜单。
    @Entry var paneOverflowActions: PaneWindowActions?
    /// 窗口操作按钮位于标题与菜单之间，出现时在菜单前留出的宽度。
    @Entry var paneHeaderControlsInset: CGFloat = 0
    /// 隐藏的窗口操作组仍为标题栏保留系统按钮需要的高度，悬停时标题栏不跳动。
    @Entry var paneHeaderMinHeight: CGFloat = 0
    /// 信息区与侧栏入口合在一块玻璃里，信息缩到按钮图标的尺度。
    @Entry var paneHeaderStatusGrouped = false
}

/// 卡片拖动层按菜单的实际宽度留空，菜单接收自己的点击。
nonisolated struct PaneHeaderActionsWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 标题栏高度跟随系统控件，卡片拖动范围使用同一实际高度。
nonisolated struct PaneHeaderHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 标题栏中可点击控件的范围，卡片拖动层在这些范围上挖空，其余部分都可拖动。
nonisolated struct PaneHeaderInteractiveRects: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
