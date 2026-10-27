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

/// 标题栏的窗口操作与会话菜单共用一块玻璃，与 iPhone 的组合菜单按钮同一规则：
/// 相邻内容之间隔一个按钮间距，两端留出图标在按钮高度里的空白，单个图标入口仍是圆形。
/// 选中时玻璃使用主题色，内容统一为白色。在一行玻璃里并进了旁边那块时（GlassRow）缩成一个按钮大的圆，内容藏起来。
struct PaneHeaderButtonGroup<Content: View>: View {
    var expands = false
    var selected = false
    @ViewBuilder var content: Content
    @Environment(\.glassMerged) private var merged

    var body: some View {
        HStack(spacing: 0) {
            if selected {
                content.foregroundStyle(.white)
            } else {
                content
            }
        }
        .opacity(merged ? 0 : 1)
        .frame(width: merged ? Metrics.paneHeaderButton - 2 * Metrics.paneHeaderGroupInset : nil)
        .padding(.horizontal, Metrics.paneHeaderGroupInset)
        .frame(maxWidth: expands && !merged ? .infinity : nil)
        .menuStyle(.button)
        .buttonStyle(PaneHeaderButtonStyle())
        .controlSize(.large)
        .menuIndicator(.hidden)
        .glassEffect(.regular.tint(selected ? .accentColor : nil).interactive(), in: .capsule)
        .fixedSize(horizontal: !expands || merged, vertical: true)
    }
}

/// 窗口标题栏的右组：前面可以有一块菜单和视图切换器，后面几组图标按钮（每组一块玻璃），最后可以有窗口自己的一块控件。窗口只交数据，由 PaneWindow 统一画，
/// 原生会话窗口交给紧凑布局外壳的也是它：所有窗口的右组是同一种视图，iPhone 紧凑布局里几个窗口共用一条标题栏，
/// 换窗口时各组、各按钮按位置原地更新，玻璃形变、图标替换走系统自带的过渡。各窗口各写一套时右组的视图类型不同，
/// 只能整块换掉，过渡是硬切或淡入淡出（2026-10-14 iPhone，角色上下文和签名之间；见 CompactPaneHeaderBar 的右组）。
/// 切换器和各组排在一行玻璃里（GlassRow）：出现时从右边那块分出来，收起时并回去，右边没有就是左边那块。
struct PaneHeaderActions: View {
    var groups: [[PaneHeaderAction]] = []
    /// 菜单：会话的模型与更多操作、角色初始配置的默认模型与思考强度、辅助生成模板的模型。放在各组前面。
    var menus: AnyView?
    /// 实例有几个视图时由 PaneWindow 加上，放在菜单后面、各组前面。
    var switcher: PaneViewSwitcher?
    /// 窗口自己的控件，放在各组后面、最右边：浏览的侧栏开关，打开时伸成搜索框。
    var trailing: AnyView?
    @State private var lingering = LingeringActions()
    /// 并回去走完时加一，重算一遍拿掉留着的那几块，见 LingeringActions.settle。
    @State private var settled = 0

    var body: some View {
        // 收起的切换器、按钮组留着并进旁边那块，并完就拿掉；旁边没有开着的玻璃就直接拿掉
        let _ = settled
        let fixed = menus != nil || trailing != nil
        let shownSwitcher = lingering.switcher(switcher, keeps: fixed || !groups.isEmpty)
        let shownGroups = lingering.groups(groups, keeps: fixed || switcher != nil || !groups.isEmpty)
        if fixed || switcher != nil || !groups.isEmpty {
            GlassRow(spacing: Metrics.paneButtonGap) {
                if let menus { menus }
                if let shownSwitcher {
                    PaneViewSwitcherGroup(switcher: shownSwitcher)
                        .glassMerge(switcher == nil ? .merged(.trailing) : .open)
                        .transition(GlassMergeTransition(edge: .trailing))
                }
                ForEach(Array(shownGroups.enumerated()), id: \.offset) { index, group in
                    PaneHeaderActionGroup(actions: group)
                        .glassMerge(index < groups.count ? .open : .merged(.trailing))
                    .transition(GlassMergeTransition(edge: .trailing))
                }
                if let trailing { trailing }
            }
            .modifier(PaneGlassContainer())
            .transaction(value: [switcher != nil ? 1 : 0, groups.count]) { transaction in
                if !transaction.disablesAnimations { transaction.animation = .snappy }
                let change = lingering.changed()
                transaction.addAnimationCompletion(criteria: .removed) {
                    if lingering.settle(after: change) { settled += 1 }
                }
            }
        }
    }
}

/// 一组图标按钮，一块玻璃；整组都是开着的开关或能按的确认动作时整块用选中样式。标题栏右组的各组是它，控制区里的开关（预览的指认）也用它。
struct PaneHeaderActionGroup: View {
    let actions: [PaneHeaderAction]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        PaneHeaderButtonGroup(selected: !actions.isEmpty && actions.allSatisfy(highlighted)) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                PaneHeaderActionButton(action: action)
            }
        }
    }

    /// 开着的开关，或能按的确认动作；确认动作在忙时虽不能按，转圈仍留在主题色上。
    private func highlighted(_ action: PaneHeaderAction) -> Bool {
        action.on || action.prominent && (action.busy || isEnabled && !action.disabled)
    }
}

/// 右组里收起了还留着的切换器和按钮组，见 PaneHeaderActions。在 body 里记，不观察。
/// 只留到并回去走完：并着的玻璃叠在旁边那块的端头，那块被系统拿走时就露出一个空圆
/// （iPhone 点模型、更多，菜单从胶囊的玻璃变形出来；共用的标题栏从带按钮组的窗口换回会话时，几组一直留着）。
private final class LingeringActions {
    private var lastSwitcher: PaneViewSwitcher?
    private var lastGroups: [[PaneHeaderAction]] = []
    private var shownSwitcher = false
    private var shownGroups = 0
    /// 每收开一次加一，只有最后那次走完才拿掉。
    private var generation = 0

    func switcher(_ current: PaneViewSwitcher?, keeps: Bool) -> PaneViewSwitcher? {
        shownSwitcher = current != nil
        if let current { lastSwitcher = current } else if !keeps { lastSwitcher = nil }
        return lastSwitcher
    }

    /// 现在的各组，后面接着上次多出来的那几组。
    func groups(_ current: [[PaneHeaderAction]], keeps: Bool) -> [[PaneHeaderAction]] {
        shownGroups = current.count
        lastGroups = keeps ? current + lastGroups.dropFirst(current.count) : current
        return lastGroups
    }

    func changed() -> Int {
        generation += 1
        return generation
    }

    /// 那次收开走完了，之后没再变：拿掉留着的。拿掉了返回 true，要重算一遍。
    func settle(after change: Int) -> Bool {
        let switcher = lastSwitcher != nil && !shownSwitcher
        guard change == generation, switcher || lastGroups.count > shownGroups else { return false }
        if switcher { lastSwitcher = nil }
        lastGroups.removeLast(lastGroups.count - shownGroups)
        return true
    }
}

/// 标题栏右组的一个图标按钮，见 PaneHeaderActions。
struct PaneHeaderAction {
    let title: String
    /// 不给时按钮显示文字。
    let systemImage: String?
    /// 悬停说明，不给时同标题。
    var help: String?
    /// 在忙（保存、生成中）：图标换成转圈。
    var busy = false
    var disabled = false
    /// 开关开着。开关单独成组，开着时整组用选中样式（主题色玻璃、白色图标），同侧栏的设置按钮。
    var on = false
    /// 弹窗里保存、创建这类确认动作，用文字不用图标，单独成组，样式同开着的开关；不能按时退回普通玻璃。
    var prominent = false
    /// 图标颜色，不给时随组；停止这类结束动作用 Theme.danger。
    var tint: Color?
    let action: () -> Void
}

/// 实例几个视图之间的切换器：一块玻璃里并排各视图的图标，当前的垫一块半透明的主题色小胶囊、图标用主题色的实心版，换视图时小胶囊滑过去。
struct PaneViewSwitcher {
    struct Item {
        let id: String
        let title: String
        let systemImage: String
    }
    let items: [Item]
    let current: String
    let select: (String) -> Void
}

private struct PaneViewSwitcherGroup: View {
    let switcher: PaneViewSwitcher
    @Namespace private var thumb

    var body: some View {
        PaneHeaderButtonGroup {
            ForEach(switcher.items, id: \.id) { item in
                let current = item.id == switcher.current
                Button { if !current { switcher.select(item.id) } } label: {
                    PaneHeaderButtonLabel(item.title, systemImage: item.systemImage)
                        .symbolVariant(current ? .fill : .none)
                        .foregroundStyle(current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                        .background {
                            // 和悬停的高亮同一块地方
                            if current {
                                Capsule().fill(Color.accentColor.opacity(0.15))
                                    .padding(.vertical, PaneHeaderHover.inset)
                                    .padding(.horizontal, PaneHeaderHover.horizontalInset)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                }
                .help(current ? "正在显示\(item.title)" : "显示\(item.title)")
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .animation(.smooth(duration: 0.25), value: switcher.current)
    }
}

private struct PaneHeaderActionButton: View {
    let action: PaneHeaderAction

    var body: some View {
        Button(action: action.action) {
            Group {
                if let tint = action.tint {
                    PaneHeaderButtonLabel(action.title, systemImage: action.systemImage).foregroundStyle(tint)
                } else {
                    PaneHeaderButtonLabel(action.title, systemImage: action.systemImage)
                }
            }
            .opacity(action.busy ? 0 : 1)
            .overlay { if action.busy { CardSpinner().scaleEffect(0.6) } }
        }
        .help(action.help ?? action.title)
        .disabled(action.disabled)
        .accessibilityAddTraits(action.on ? .isSelected : [])
    }
}

/// 标题栏按钮悬停高亮的内缩，见 Metrics.paneHeaderHighlightInset；视图切换器的小胶囊画在同一块地方。
private enum PaneHeaderHover {
    static var inset: CGFloat { Metrics.paneHeaderHighlightInset }
    static var horizontalInset: CGFloat { Metrics.paneHeaderHighlightSideInset }
}

/// 原生菜单展开时沿用按钮的按下状态，背景随菜单收起自动清除。
/// 按钮只带半个间距，反馈向两侧多出一点，图标入口的反馈仍是圆形。
/// 触屏上按压反馈由可交互的玻璃负责，不再叠灰色背景。禁用时内容变暗，与 PaneButtonStyle 相同。
private struct PaneHeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if InputMode.current.isTouch {
                configuration.label
            } else {
                configuration.label
                    .modifier(PaneButtonHover(inset: PaneHeaderHover.inset, horizontalInset: PaneHeaderHover.horizontalInset,
                                              isPressed: configuration.isPressed))
                    .clickPointer()
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 标题栏按钮按输入方式选择高度；左右各带半个按钮间距，两端由所在的组补齐。
struct PaneHeaderButtonLabel: View {
    let title: String
    var systemImage: String?
    /// 文字前的标志，随文字颜色着色。
    var logo: ImageResource?
    @ScaledMetric(relativeTo: .body) private var logoSize = Metrics.paneHeaderLogo

    init(_ title: String, systemImage: String? = nil, logo: ImageResource? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.logo = logo
    }

    var body: some View {
        HStack(spacing: Metrics.paneHeaderLogoGap) {
            if let logo {
                Image(logo).resizable().scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)
            }
            PaneButtonLabel(title, systemImage: systemImage)
        }
        .padding(.horizontal, Metrics.paneHeaderButtonGap / 2)
        .frame(height: Metrics.paneHeaderButton)
        .contentShape(.capsule)
    }
}

/// 控制区和工具条共用尺寸、字体、命中范围和交互反馈；玻璃由所属容器提供。Mac 宽屏输入区的原生按钮（PaneButtonView）照这里复刻，改一处两处一起改。
struct PaneButtonStyle: ButtonStyle {
    var text = false
    var fill: Color?
    var foreground: Color = .secondary
    var size: CGFloat?
    /// 次级按钮：半透明灰底，字仍按 foreground，和不带底的图标按钮区分开（审批、密钥请求的拒绝和次级的决定）。
    var secondary = false
    /// 次级按钮的灰底，原生的 PaneButtonView 同。
    static let secondaryFill = Color.gray.opacity(0.16)
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.fontResolutionContext) private var fontContext

    func makeBody(configuration: Configuration) -> some View {
        let size = size ?? Metrics.paneButton
        return configuration.label
            .font(font)
            .foregroundStyle(fill == nil ? foreground : .white)
            .lineLimit(1)
            .fixedSize(horizontal: text, vertical: false)
            .padding(.horizontal, text ? Metrics.paneToolbarInset : 0)
            .frame(width: text ? nil : size, height: size)
            .frame(minWidth: size)
            .modifier(PaneButtonHover(inset: 2, fill: secondary ? Self.secondaryFill : fill, isPressed: configuration.isPressed))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .clickPointer()
    }

    private var font: Font {
        guard fill != nil else { return Theme.body }
        #if os(macOS)
        // 同 Mac 的原生按钮（PaneButtonView）：实心的图标按钮（发送、停止）图标小一号，填色圆里留出更多边距
        if !text { return .system(size: (Theme.body.resolve(in: fontContext).ctFont as NSFont).pointSize - 3, weight: .bold) }
        #endif
        return Theme.body.weight(.bold)
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
