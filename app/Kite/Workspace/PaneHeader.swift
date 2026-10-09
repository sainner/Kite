import SwiftUI

/// 窗口标题，两端共用。
struct PaneHeader {
    var title: String
    var subtitle: String?
    /// 副标题后跟下拉箭头，点开是窗口给的菜单，例如新代理选用角色。
    var subtitleMenu: SubtitleMenu?
    var titleRefresh: TitleRefresh?
    /// 主标题右边的小标签，例如订阅账号的档位。
    var badge: String?

    /// 由主标题尾部的刷新图标触发，生成期间保持原题。
    struct TitleRefresh {
        var actionLabel: String
        var progressLabel: String
        var isRefreshing: Bool
        var enabled: Bool
        var action: () -> Void
    }

    /// 菜单处理期间箭头换成转圈，菜单不可点。
    struct SubtitleMenu {
        var label: String
        var isBusy: Bool
        var enabled: Bool
        var content: AnyView
    }
}

/// 标题前信息区的状态提示。信息区同时只展示一项：工作机连接这类上游提示优先于窗口自身的错误，
/// 二者都盖住平时的圆环信息，圆环虚化，状态图标叠在原处；没有圆环的窗口只显示图标。
struct PaneNotice: Equatable {
    var text: String
    var symbol: String
    var tint: Color

    static func failure(_ text: String) -> PaneNotice {
        PaneNotice(text: text, symbol: "exclamationmark.triangle.fill", tint: Theme.warning)
    }
}

/// 没有圆环的窗口出现提示时，信息区只有状态图标，位置和大小与圆环相同。
struct PaneNoticeIcon: View {
    let notice: PaneNotice

    var body: some View {
        Color.clear.paneHeaderRing(lineWidth: 0, status: notice.text)
    }
}

/// 卡片标题栏按容器排列标题、侧栏入口与窗口菜单。标题前是信息区；容器给出侧栏入口时，
/// 入口与信息区合成一块标题栏玻璃；紧凑触屏布局直接点击信息区打开侧栏。手指长按信息区弹出它的说明。
struct PaneHeaderBar<Status: View, Actions: View>: View {
    let header: PaneHeader
    let status: Status
    let actions: Actions
    @Environment(\.paneHeaderControlsInset) private var controlsInset
    @Environment(\.paneHeaderMinHeight) private var controlsHeight
    @Environment(\.workspacePresentation) private var presentation
    let openSidebar: (@MainActor () -> Void)?
    @State private var statusText: String?
    @State private var showsStatusText = false

    private var statusOpensSidebar: Bool { InputMode.current.isTouch && presentation == .compact }

    var body: some View {
        // 合进玻璃的信息缩小；环境要在拆分子视图之前给出
        Group(subviews: status.environment(\.paneHeaderStatusGrouped, openSidebar != nil && !statusOpensSidebar)) { statusViews in
            let showsSidebarButton = openSidebar != nil && (!statusOpensSidebar || statusViews.isEmpty)
            HStack(spacing: 0) {
                if let openSidebar, statusOpensSidebar, !statusViews.isEmpty {
                    Button {
                        // 长按弹出说明后松手，不再打开侧栏
                        guard !showsStatusText else { return }
                        openSidebar()
                    } label: {
                        HStack(spacing: 0) {
                            ForEach(statusViews) { $0 }
                        }
                        .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开侧边栏")
                    .reportsHeaderInteraction()
                    .modifier(PaneStatusTextPopover(text: statusText, presented: $showsStatusText))
                } else if let openSidebar {
                    PaneHeaderButtonGroup {
                        Button(action: openSidebar) {
                            PaneHeaderButtonLabel("侧边栏", systemImage: "sidebar.left")
                        }
                        .reportsHeaderInteraction()
                        ForEach(statusViews) { statusView in
                            // 信息区有悬停说明与长按，卡片拖动层在这里挖空
                            statusView.reportsHeaderInteraction()
                                .modifier(PaneStatusTextPopover(text: statusText, presented: $showsStatusText))
                        }
                    }
                } else {
                    ForEach(statusViews) { statusView in
                        statusView.fixedSize()
                            .reportsHeaderInteraction()
                            .modifier(PaneStatusTextPopover(text: statusText, presented: $showsStatusText))
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
            .onPreferenceChange(PaneHeaderStatusText.self) { statusText = $0 }
        }
    }

}

#if canImport(UIKit)
/// 文字按自身宽度排，最宽 maxWidth，高度按换行后的宽度量。直接给文字限宽时量出的理想高度仍是单行的，
/// 气泡按它定大小，换行后文字溢出贴到底边。
private struct FittedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let width = min(proposal.width ?? .infinity, maxWidth, text.sizeThatFits(.unspecified).width)
        return CGSize(width: width, height: text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// 说明按输入方式给出：指针悬停显示系统提示（见 paneHeaderStatusText），手指长按在信息区下方弹出系统气泡，文字相同。
private struct PaneStatusTextPopover: ViewModifier {
    let text: String?
    @Binding var presented: Bool

    func body(content: Content) -> some View {
        content
            .gesture(DirectTouchLongPress { if text != nil { presented = true } })
            .background(ArrowlessPopover(text: text ?? "", presented: $presented))
            .sensoryFeedback(.impact(weight: .light), trigger: presented) { _, shown in shown }
    }
}

/// 只认手指的长按；鼠标和触控板按住不算，它们用悬停看说明。和其他手势同时识别：紧凑布局里信息区是打开侧栏的按钮，
/// 独占的长按会被按钮先接住而识别不出；松手后按钮仍会收到点按，由标题栏在气泡开着时挡掉。
private struct DirectTouchLongPress: UIGestureRecognizerRepresentable {
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.4
        press.allowableMovement = 8
        press.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        press.delegate = context.coordinator
        return press
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began { action() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// 不带箭头的系统气泡，左边与信息区对齐，顶边在信息区下方。SwiftUI 的气泡必有箭头：信息区贴着窗口左边，
/// 箭头离屏幕边不到约 72pt 时系统会把左上圆角缩小给箭头让位（iOS 26 模拟器逐点实测）。
/// 没有箭头的气泡居中放在来源矩形上，所以先量出气泡大小，把来源矩形就设成气泡要占的位置。
private struct ArrowlessPopover: UIViewRepresentable {
    let text: String
    @Binding var presented: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.dismissed = { presented = false }
        if let shown = coordinator.controller {
            shown.rootView = Self.content(text)
            if !presented { shown.dismiss(animated: true); coordinator.controller = nil }
            return
        }
        guard presented, var host = view.window?.rootViewController else { return }
        while let top = host.presentedViewController { host = top }
        let controller = UIHostingController(rootView: Self.content(text))
        let width = min(320, (view.window?.bounds.width ?? 320) - 2 * Metrics.paneMargin)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        controller.preferredContentSize = size
        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: 0, y: view.bounds.maxY + Metrics.paneButtonGap, width: size.width, height: size.height)
            popover.permittedArrowDirections = []
            popover.delegate = coordinator
        }
        coordinator.controller = controller
        // 不在 SwiftUI 更新视图的过程中弹出
        DispatchQueue.main.async { host.present(controller, animated: true) }
    }

    private static func content(_ text: String) -> AnyView {
        AnyView(FittedWidth(maxWidth: 280) { Text(text).font(Theme.secondary) }.padding(14))
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var controller: UIHostingController<AnyView>?
        var dismissed: () -> Void = {}

        /// iPhone 上也保持气泡，不改成整页弹出。
        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            controller = nil
            dismissed()
        }
    }
}
#else
/// 没有触屏输入时只有指针悬停。
private struct PaneStatusTextPopover: ViewModifier {
    let text: String?
    @Binding var presented: Bool

    func body(content: Content) -> some View { content }
}
#endif

/// 主标题与下方的窗口类型左对齐，主标题可带尾部刷新图标。
struct PaneHeaderTitle: View {
    let header: PaneHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.titleRefreshGap) {
                Text(header.title)
                    .id(header.title)
                    .transition(.blurReplace)
                if let badge = header.badge {
                    Text(badge)
                        .font(Theme.status.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .padding(.leading, 6 - Metrics.titleRefreshGap)
                        .id(badge)
                        .transition(.blurReplace)
                }
                if let refresh = header.titleRefresh {
                    PaneTitleRefreshButton(refresh: refresh, title: header.title)
                }
            }
            .font((InputMode.current.isTouch ? Theme.secondary : Theme.title).weight(.semibold))
            if let subtitle = header.subtitle {
                Group {
                    if let menu = header.subtitleMenu { PaneSubtitleMenu(subtitle: subtitle, menu: menu) }
                    else { Text(subtitle) }
                }
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .id(subtitle)
                    .transition(.blurReplace)
            }
        }
        .lineLimit(1)
        .animation(.snappy, value: header.title)
        .animation(.snappy, value: header.subtitle)
        .animation(.snappy, value: header.badge)
    }
}

/// 副标题连同尾部箭头一起作为菜单入口，悬停范围与刷新图标一样向外扩出，不改变排版。
private struct PaneSubtitleMenu: View {
    let subtitle: String
    let menu: PaneHeader.SubtitleMenu

    var body: some View {
        Menu { menu.content } label: {
            HStack(spacing: Metrics.titleRefreshGap) {
                Text(subtitle)
                Group {
                    if menu.isBusy { CardSpinner().scaleEffect(0.6) }
                    else { Image(systemName: "chevron.down").imageScale(.small).fontWeight(.semibold) }
                }
                .frame(width: 10)
            }
        }
        .menuStyle(.button).buttonStyle(PaneTitleIconButtonStyle(fill: false)).menuIndicator(.hidden).fixedSize()
        .disabled(!menu.enabled)
        .help(menu.label)
        .accessibilityLabel(menu.label)
        .accessibilityValue(subtitle)
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
    /// 副标题菜单悬停、展开时不铺灰底，只保留按下变淡。
    var fill = true
    @Environment(\.isEnabled) private var isEnabled
    private var outset: CGFloat { Metrics.titleRefreshOutset }

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .foregroundStyle(.secondary)
            .padding(outset)
        Group {
            if fill { label.modifier(PaneButtonHover(inset: 0, isPressed: configuration.isPressed)) }
            else { label.contentShape(Rectangle()) }
        }
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

    /// 收进更多菜单时的菜单项。
    var commands: [ThreadHeaderCommand] {
        var items = [ThreadHeaderCommand(title: "缩小窗口", symbol: "minus", action: minimize)]
        if let expand { items.append(.init(title: "展开窗口", symbol: "arrow.up.left.and.arrow.down.right", action: expand)) }
        items.append(.init(title: "关闭窗口", symbol: "xmark", enabled: canClose, action: close))
        return items
    }
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
    /// 信息区当前展示的提示；圆环据此虚化，悬停说明换成提示。
    @Entry var paneNotice: PaneNotice?
    /// 窗口所属工作机的连接提示，由窗口外层按所属工作机给出。
    @Entry var paneConnectionNotice: PaneNotice?
}

/// 信息区的说明：指针悬停显示系统提示，手指长按弹出，读屏读到的也是这一段。
nonisolated struct PaneHeaderStatusText: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = value ?? nextValue() }
}

extension View {
    /// 信息区里的视图（圆环、提示图标）用它给出说明，见 PaneHeaderStatusText。
    func paneHeaderStatusText(_ text: String) -> some View {
        // 整块信息区都算悬停范围；圆环只是描边，不声明的话只有那一圈线算
        contentShape(Rectangle())
            .help(text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .preference(key: PaneHeaderStatusText.self, value: text)
    }

    /// 标题前的状态圆环（会话状态、账号额度）：单独时占一个按钮位，和侧栏入口合在一块玻璃里时缩小。
    /// 信息区有提示时圆环虚化，提示的图标叠在原处，说明也换成提示。
    func paneHeaderRing(lineWidth: CGFloat, status: String) -> some View { modifier(PaneHeaderRing(lineWidth: lineWidth, status: status)) }
}

private struct PaneHeaderRing: ViewModifier {
    let lineWidth: CGFloat
    let status: String
    @Environment(\.paneHeaderStatusGrouped) private var grouped
    @Environment(\.paneNotice) private var notice
    @ScaledMetric(relativeTo: .body) private var scaledDiameter = Metrics.paneHeaderButton
    private var diameter: CGFloat { InputMode.current.isTouch ? scaledDiameter : Metrics.paneHeaderButton }

    func body(content: Content) -> some View {
        // 和侧栏入口同在一块玻璃里时缩小，给玻璃边缘留出余量
        let ring = diameter * (grouped ? 0.6 : Metrics.statusRingScale)
        content
            .padding(lineWidth / 2)
            .frame(width: ring, height: ring)
            .blur(radius: notice == nil ? 0 : 2.5)
            .opacity(notice == nil ? 1 : 0.3)
            .overlay {
                if let notice {
                    Image(systemName: notice.symbol)
                        .font(.system(size: max(11, ring * 0.7), weight: .bold))
                        .foregroundStyle(notice.tint)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: notice)
            // 合进按钮组时排在组尾：前面同按钮一样带半个间距，后面让圆环与胶囊端头同心
            .padding(.leading, grouped ? Metrics.paneHeaderButtonGap / 2 : 0)
            .padding(.trailing, grouped ? (diameter - ring) / 2 - Metrics.paneHeaderGroupInset : 0)
            .frame(width: grouped ? nil : diameter, height: diameter)
            .paneHeaderStatusText(notice?.text ?? status)
    }
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
