import SwiftUI

/// 窗口标题与第二行次级信息，两端共用。
struct PaneHeader {
    var title: String
    var detail: Detail?
    var titleRefresh: TitleRefresh?

    /// 主标题与尾部刷新图标共用点击范围，生成期间保持原题。
    struct TitleRefresh {
        var actionLabel: String
        var progressLabel: String
        var isRefreshing: Bool
        var enabled: Bool
        var action: () -> Void
    }

    enum Detail {
        case text(String)
        /// 路径相对于工作区；目录可点击，末尾文件名只展示。
        case path(root: String, directory: String, file: String?, open: (String) -> Void)
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

/// 所有窗口共用同一套标题排版，次级信息可为文字或目录导航。
struct PaneHeaderTitle: View {
    let header: PaneHeader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.paneTitleSpacing) {
            title
            detail
        }
        .lineLimit(1)
    }

    private var title: some View {
        Group {
            if let refresh = header.titleRefresh {
                Button(action: refresh.action) {
                    HStack(spacing: 4) {
                        Text(header.title)
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                            .symbolEffect(.rotate, options: .repeating, isActive: refresh.isRefreshing && !reduceMotion)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pointingPlain)
                .disabled(!refresh.enabled)
                .help(refresh.isRefreshing ? refresh.progressLabel : "点击\(refresh.actionLabel)")
                .accessibilityLabel(refresh.actionLabel)
                .accessibilityValue(header.title)
                .background { interactiveBoundary }
            } else {
                Text(header.title)
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
        if let detail = header.detail {
            Group {
                switch detail {
                case .text(let text):
                    Text(text)
                case .path(let root, let directory, let file, let open):
                    PaneHeaderPath(root: root, directory: directory, file: file, open: open)
                        .background { interactiveBoundary }
                }
            }
            .font(Theme.status)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var interactiveBoundary: some View {
        #if os(macOS)
        GeometryReader { proxy in
            Color.clear.preference(key: PaneHeaderNavigationBounds.self,
                value: proxy.frame(in: .named("pane-header")))
        }
        #endif
    }
}

private struct PaneHeaderPath: View {
    let root: String
    let directory: String
    let file: String?
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
                if let file {
                    Text("/").foregroundStyle(.tertiary)
                    Text(file)
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

/// 标题栏中可点击文字的范围，Mac 的拖动把手避开这一行。
nonisolated struct PaneHeaderNavigationBounds: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
