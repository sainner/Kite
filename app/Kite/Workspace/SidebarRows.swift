import SwiftUI

let sidebarRowShape = RoundedRectangle(cornerRadius: 8)

/// 侧栏的行高、图标列与行首留白，以两端的尺寸为基准，由 SidebarScaledMetrics 按系统字号换算。
struct SidebarMetrics {
    var rowHeight = InputMode.current.rowHeight
    var workspaceRowHeight = InputMode.current.workspaceRowHeight
    var labelExtent = InputMode.current.labelExtent
    var itemInset = InputMode.current.sidebarItemInset
    var rowRadius: CGFloat = 8

    /// 一级行的底色与点击范围。
    var rowShape: RoundedRectangle { RoundedRectangle(cornerRadius: rowRadius) }

    /// 树状子项的文字起点，与一级行的标题对齐。
    var textInset: CGFloat { itemInset + 8 + labelExtent }
    /// 树干位置，与一级行的图标列中线对齐。
    var treeInset: CGFloat { itemInset + labelExtent / 2 }
    /// 小标题连同上方留白的高度。
    var subheaderHeight: CGFloat { 8 + workspaceRowHeight }
    /// 行尾的小按钮（添加、刷新），触屏保留触控尺寸。
    var control: CGFloat { InputMode.current.isTouch ? InputMode.current.button : workspaceRowHeight }

    /// 取整到点，免得树线落在半个点上发虚。
    func scaled(by factor: CGFloat) -> Self {
        let scale = { (value: CGFloat) in (value * factor).rounded() }
        return Self(rowHeight: scale(rowHeight), workspaceRowHeight: scale(workspaceRowHeight),
                    labelExtent: scale(labelExtent), itemInset: scale(itemInset), rowRadius: rowRadius)
    }
}

/// 放在侧栏根部：留白和行高跟着侧栏标题的字号一起缩放，默认字号下保持基准尺寸。
struct SidebarScaledMetrics: ViewModifier {
    /// 当前系统字号相对默认字号的百分比。
    @ScaledMetric(relativeTo: .headline) private var percent: CGFloat = 100
    @Environment(\.workspacePresentation) private var presentation

    func body(content: Content) -> some View {
        var metrics = SidebarMetrics()
        // 窄屏触控的小标题与树状子项比一级行矮一档，保留层级。
        // 圆角也大一档，配 44 点高的行。
        if presentation.isCompactTouch {
            metrics.workspaceRowHeight = 36
            metrics.rowRadius = 12
        }
        return content.environment(\.sidebarMetrics, metrics.scaled(by: percent / 100))
    }
}

extension EnvironmentValues {
    @Entry var sidebarMetrics = SidebarMetrics()
    @Entry var sidebarProjectTint: Color = .primary
    /// 选中与悬停的强调色：项目内用项目主题色，项目用默认文字色或在项目之外时用 App 主题色。
    @Entry var sidebarHighlight: Color = .accentColor
    @Entry var sidebarButtonHovered = false
    /// 所在行是否露出行尾操作，由 sidebarRowControls 写入，SidebarRevealedControl 读取。
    @Entry fileprivate var sidebarRowControlsShown = false
}

private extension View {
    /// 侧栏各种行共用的显隐规则：选中的行固定露出行尾操作，其余在悬停或触屏时露出。
    func sidebarRowControls(selected: Bool, hovered: Bool) -> some View {
        environment(\.sidebarRowControlsShown, selected || InputMode.current.revealsControls(hovered: hovered))
    }
}

/// 侧栏悬停只改变图标颜色，保留按钮的尺寸与点击范围。
struct SidebarButtonStyle: ButtonStyle {
    var foreground: Color = .secondary
    var size: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.sidebarHighlight) private var highlight
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        if !InputMode.current.isTouch {
            configuration.label
                .font(Theme.body)
                .frame(width: size, height: size)
                .foregroundStyle(hovered && isEnabled ? highlight : foreground)
                .environment(\.sidebarButtonHovered, hovered && isEnabled)
                .contentShape(sidebarRowShape)
                .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
                .onHover { hovered = $0 }
                .clickPointer()
        } else if let size {
            PaneButtonStyle(foreground: foreground, size: size).makeBody(configuration: configuration)
        } else {
            configuration.label
                .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
                .clickPointer()
        }
    }
}

struct SidebarIconTint: ViewModifier {
    var foreground: Color
    var allowsHover = true
    @Environment(\.sidebarButtonHovered) private var hovered
    @Environment(\.sidebarHighlight) private var highlight

    func body(content: Content) -> some View {
        content.foregroundStyle(hovered && allowsHover ? highlight : foreground)
    }
}

/// 行尾操作跟随所在行显隐，隐藏时同时让出点击与辅助功能；进行中的操作不收起。
struct SidebarRevealedControl: ViewModifier {
    var pinned = false
    @Environment(\.sidebarRowControlsShown) private var rowShown

    func body(content: Content) -> some View {
        let shown = pinned || rowShown
        return content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// 一级行末尾展开或收起树状子项。
struct SidebarDisclosureButton: View {
    let title: String
    let noun: String
    @Binding var isExpanded: Bool
    let foreground: Color
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        Button { isExpanded.toggle() } label: {
            TablerIcon(isExpanded ? .tablerChevronDown : .tablerChevronRight)
        }
        .buttonStyle(SidebarButtonStyle(foreground: foreground, size: metrics.workspaceRowHeight))
        .help(isExpanded ? "收起\(noun)" : "展开\(noun)")
        .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(title)")
    }
}

/// 各栏的一级列表行共用字重、尺寸与反馈；操作按钮由各自的内容提供。
struct SidebarListRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: (_ foreground: Color) -> Content
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.sidebarMetrics) private var metrics
    @State private var hovered = false

    var body: some View {
        let hovering = hovered && isEnabled && !InputMode.current.isTouch
        let foreground = selected || hovering ? highlight : tint
        HStack(spacing: 0) {
            content(foreground)
        }
        .sidebarRowControls(selected: selected, hovered: hovering)
        .foregroundStyle(foreground)
        .padding(.leading, metrics.itemInset)
        .padding(.trailing, 4)
        .frame(height: metrics.rowHeight)
        .background(selected ? highlight.opacity(0.12) : tint.opacity(hovering ? 0.06 : 0), in: metrics.rowShape)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = $0 }
    }
}

/// 树状子项共用文字、行尾留白与悬停反馈，选中时只突出文字和外部连线。
struct SidebarTreeRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        content()
            .sidebarRowControls(selected: selected, hovered: hovered)
            .font(Theme.sidebarWorkspace)
            .foregroundStyle(selected ? highlight : tint.opacity(hovered ? 1 : 0.78))
            .fontWeight(.regular)
            .padding(.trailing, 4)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 && isEnabled }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SidebarListLabel: View {
    let title: String
    var icon: TablerSymbol?
    var selected = false
    var note: String?
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                TablerIcon(icon, selected: selected)
                    .opacity(0.65)
                    .frame(width: metrics.labelExtent)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if let note {
                Text(note).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .font(Theme.sidebarHeading.weight(.semibold))
        .frame(height: metrics.rowHeight)
        .contentShape(metrics.rowShape)
    }
}

/// 一级行下再分一层的小标题：圆点加名称，所在组有选中项时突出；加号像其他行尾操作一样跟随选中与悬停，触屏上不显示。
/// 项目一栏里项目下的检出与资源库里代理上下文的分类共用。
struct SidebarSubheader<Menu: View>: View {
    let title: String
    let selected: Bool
    let help: String
    /// 为 nil 时标题不可点。
    let open: (() -> Void)?
    var add: SidebarSubheaderAdd?
    @ViewBuilder var menu: Menu
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.sidebarMetrics) private var metrics
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            if Menu.self == EmptyView.self { label } else { label.contextMenu { menu } }
            if let add, !InputMode.current.isTouch {
                Button(action: add.action) {
                    TablerIcon(.tablerPlus)
                }
                .buttonStyle(SidebarButtonStyle(foreground: selected ? highlight : tint, size: metrics.workspaceRowHeight))
                .help(add.help)
                .accessibilityLabel(add.label)
                .modifier(SidebarRevealedControl())
            }
        }
        .sidebarRowControls(selected: selected, hovered: hovered)
        .padding(.leading, metrics.itemInset)
        .padding(.trailing, 4)
        .frame(height: metrics.workspaceRowHeight)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovered = $0 }
        .padding(.top, 8)
    }

    private var label: some View {
        Button { open?() } label: {
            HStack(spacing: 8) {
                Circle().fill(selected ? highlight : tint.mix(with: Theme.background, by: 0.6))
                    .frame(width: selected ? 8 : 6, height: selected ? 8 : 6)
                    .frame(width: metrics.labelExtent)
                Text(title)
                    .font(Theme.sidebarCheckout)
                    .foregroundStyle(selected ? highlight : tint.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: metrics.workspaceRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(foreground: selected ? highlight : tint))
        .disabled(open == nil)
        .help(help)
    }
}

extension SidebarSubheader where Menu == EmptyView {
    init(title: String, selected: Bool, help: String, open: (() -> Void)?, add: SidebarSubheaderAdd? = nil) {
        self.init(title: title, selected: selected, help: help, open: open, add: add) { EmptyView() }
    }
}

struct SidebarSubheaderAdd {
    let help: String
    let label: String
    let action: () -> Void
}

/// 小标题分组的容器：linked 时各组的小标题与树线由左侧一条竖线连起来。
struct SidebarSubgroups<Content: View>: View {
    let linked: Bool
    @ViewBuilder var content: Content
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(alignment: .leading) {
            if linked {
                Rectangle().fill(tint.mix(with: Theme.background, by: 0.92)).frame(width: 1)
                    .padding(.leading, metrics.treeInset - 0.5)
                    // 在末行弯折的起点结束，避免直线穿过弯折露出尾巴。
                    .padding(.bottom, metrics.workspaceRowHeight / 2 + 10)
                    .allowsHitTesting(false)
                    .modifier(SidebarScrollingClip(topOverflow: 0))
            }
        }
    }
}

/// 一级行下的树状子项，须放在 SidebarStickySection 的内容里，所属标题取最近一层分区。
/// 普通行共用裁切，选中行独立吸顶；占位保留列表高度，连接线随选中行置于最上层。
struct SidebarTreeRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedIndex: Int?
    var hasCheckout = false
    /// 树线的颜色由它淡到底色里，项目分区用项目色。
    var tint = Color.primary
    @ViewBuilder let row: (Item) -> Row
    @Environment(\.sidebarStickyRegions) private var regions
    @Environment(\.sidebarMetrics) private var metrics

    private var selectedRegion: SidebarStickyRegion? {
        guard let selectedIndex, let parent = regions.last else { return nil }
        let rowHeight = metrics.workspaceRowHeight
        return SidebarStickyRegion(space: parent.space,
                                   start: parent.height + CGFloat(selectedIndex) * rowHeight,
                                   height: rowHeight,
                                   topInset: parent.topInset + parent.height)
    }

    var body: some View {
        let rowHeight = metrics.workspaceRowHeight
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index == selectedIndex {
                    Color.clear.frame(height: rowHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    connectedRow(item, index: index, selected: false)
                }
            }
        }
        .modifier(SidebarScrollingClip(topOverflow: hasCheckout ? rowHeight / 2 : 0,
                                      additionalRegions: selectedRegion.map { [$0] } ?? []))
        .overlay(alignment: .topLeading) {
            if let selectedIndex, let selectedRegion {
                connectedRow(items[selectedIndex], index: selectedIndex, selected: true)
                    .modifier(SidebarStickyHeader(region: selectedRegion,
                                                  topOverflow: CGFloat(selectedIndex + 1) * rowHeight))
                    .padding(.top, CGFloat(selectedIndex) * rowHeight)
            }
        }
    }

    private func connectedRow(_ item: Item, index: Int, selected: Bool) -> some View {
        row(item)
            .padding(.leading, metrics.textInset)
            .background(alignment: .leading) {
                SidebarTreeLink(index: index, hasCheckout: hasCheckout,
                                checkoutSelected: selectedIndex != nil,
                                selected: selected, color: tint.mix(with: Theme.background, by: 0.8))
                    .frame(width: metrics.textInset - metrics.treeInset + 6)
                    .padding(.leading, metrics.treeInset)
                    .allowsHitTesting(false)
            }
    }
}

/// 每行直接连接所属标题，固定后缩短到吸顶标题；整条连接随该行一起参与层叠与裁切。
private struct SidebarTreeLink: View {
    let index: Int
    let hasCheckout: Bool
    let checkoutSelected: Bool
    let selected: Bool
    let color: Color
    @Environment(\.sidebarStickyRegions) private var regions
    @Environment(\.sidebarStickyHeader) private var movingHeader
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        let rowHeight = metrics.workspaceRowHeight
        let checkoutExtension = hasCheckout ? rowHeight / 2 - (checkoutSelected ? 4 : 3) : 0
        let fullExtension = CGFloat(index) * rowHeight + checkoutExtension
        if selected {
            GeometryReader { proxy in
                let topExtension: CGFloat = {
                    #if os(macOS)
                    if let parent = regions.last(where: { $0.height > 0 }), let frame = parent.renderedFrame(in: proxy) {
                        let top = proxy.frame(in: .scrollView(axis: .vertical)).minY + (movingHeader?.offset(in: proxy) ?? 0)
                        return max(0, top - frame.maxY + checkoutExtension)
                    }
                    #endif
                    return fullExtension
                }()
                branch(topExtension)
            }
        } else {
            branch(fullExtension)
        }
    }

    private func branch(_ topExtension: CGFloat) -> some View {
        SidebarTreeBranch(topExtension: topExtension)
            .stroke(selected ? highlight : color, style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}

private nonisolated struct SidebarTreeBranch: Shape {
    var topExtension: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let middle = rect.midY
        let radius = min(10, middle)
        path.move(to: CGPoint(x: 0, y: -topExtension))
        path.addLine(to: CGPoint(x: 0, y: middle - radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: middle), control: CGPoint(x: 0, y: middle))
        path.addLine(to: CGPoint(x: rect.maxX - 12, y: middle))
        return path
    }
}
