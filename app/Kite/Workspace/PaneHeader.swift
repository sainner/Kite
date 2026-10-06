import SwiftUI

/// 窗口标题与第二行次级信息，两端共用。
struct PaneHeader {
    var title: String
    /// 次级信息由各窗口自定，例如会话的层级；不给时显示窗口类型。
    var detail: Detail?
    var titleRefresh: TitleRefresh?

    enum Detail {
        case text(String)
        /// 路径相对于工作区，每一级目录都可点击。
        case path(root: String, directory: String, open: (String) -> Void)
    }

    /// 由主标题尾部的刷新图标触发，生成期间保持原题。
    struct TitleRefresh {
        var actionLabel: String
        var progressLabel: String
        var isRefreshing: Bool
        var enabled: Bool
        var action: () -> Void
    }
}

/// 卡片标题栏按平台排列标题、侧栏入口与窗口菜单。
struct PaneHeaderBar<Actions: View>: View {
    let header: PaneHeader
    let actions: Actions
    @Environment(\.paneHeaderControlsInset) private var controlsInset
    @Environment(\.paneHeaderMinHeight) private var controlsHeight
    let openSidebar: (@MainActor () -> Void)?
    var body: some View {
        #if os(macOS)
        HStack(spacing: Metrics.paneButtonGap) {
            PaneHeaderTitle(header: header)
                .padding(.leading, Metrics.paneTitleInset)
            Spacer(minLength: 0)
            actions
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PaneHeaderActionsWidth.self, value: proxy.size.width)
                    }
                }
                .padding(.leading, controlsInset)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.paneMargin)
            .frame(minHeight: controlsHeight)
        #else
        HStack(spacing: Metrics.paneButtonGap) {
            sidebarButton
            PaneHeaderTitle(header: header)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, Metrics.paneMargin)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var sidebarButton: some View {
        if let openSidebar {
            PaneButtonGroup {
                Button(action: openSidebar) {
                    PaneButtonLabel("侧边栏", systemImage: "sidebar.left")
                }
                .buttonBorderShape(.circle)
            }
        }
    }
    #endif
}

/// 所有窗口共用同一套标题排版：主标题下面是次级信息。
struct PaneHeaderTitle: View {
    let header: PaneHeader
    @Environment(\.paneAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.paneTitleSpacing) {
            detail
            title
        }
        .lineLimit(1)
    }

    private var title: some View {
        HStack(spacing: Metrics.titleRefreshGap) {
            Text(header.title)
            if let refresh = header.titleRefresh {
                PaneTitleRefreshButton(refresh: refresh, title: header.title)
            }
        }
        #if os(macOS)
        .font(Theme.title.weight(.semibold))
        #else
        .font(Theme.secondary.weight(.semibold))
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        if let detail = header.detail ?? appearance.map({ .text($0.kind) }) {
            Group {
                switch detail {
                case .text(let text):
                    Text(text)
                case .path(let root, let directory, let open):
                    PaneHeaderPath(root: root, directory: directory, open: open)
                        .reportsHeaderInteraction()
                }
            }
            .font(Theme.status)
            .foregroundStyle(.secondary)
        }
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
    /// Mac 卡片的拖动层在这块范围上挖空，点击交给标题栏里的控件。
    @ViewBuilder
    func reportsHeaderInteraction() -> some View {
        #if os(macOS)
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: PaneHeaderInteractiveRects.self,
                    value: [proxy.frame(in: .named("pane-header"))])
            }
        }
        #else
        self
        #endif
    }
}

private struct PaneHeaderPath: View {
    let root: String
    let directory: String
    let open: (String) -> Void

    private var components: [String] {
        directory.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                directoryButton(root, path: ".")
                ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                    Text("/").foregroundStyle(.tertiary)
                    directoryButton(name, path: components.prefix(index + 1).joined(separator: "/"))
                }
            }
            .fixedSize()
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
        .defaultScrollAnchor(.leading, for: .alignment)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func directoryButton(_ title: String, path: String) -> some View {
        Button { open(path) } label: {
            Text(title)
                #if os(iOS)
                .padding(.vertical, 2)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .help("打开目录：\(title)")
    }
}

extension EnvironmentValues {
    /// Mac 窗口操作按钮位于标题与菜单之间，出现时在菜单前留出的宽度。
    @Entry var paneHeaderControlsInset: CGFloat = 0
    /// 隐藏的窗口操作组仍为标题栏保留系统按钮需要的高度，悬停时标题栏不跳动。
    @Entry var paneHeaderMinHeight: CGFloat = 0
    /// 窗口外观，给出默认的次级信息（窗口类型）；PaneBody 给出。
    @Entry var paneAppearance: WindowAppearance?
}

/// 卡片拖动层按菜单的实际宽度留空，菜单接收自己的点击。
nonisolated struct PaneHeaderActionsWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 标题栏高度跟随系统控件，Mac 的拖动和悬停范围使用同一实际高度。
nonisolated struct PaneHeaderHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 标题栏中可点击控件的范围，Mac 的拖动层在这些范围上挖空，其余部分都可拖动。
nonisolated struct PaneHeaderInteractiveRects: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
