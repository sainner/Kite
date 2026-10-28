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
    /// 子工作区比父工作区多缩进的一层。
    var childIndent: CGFloat { labelExtent / 2 + 4 }
    /// 小标题连同上方留白的高度。
    var subheaderHeight: CGFloat { subheaderGap + subheaderRowHeight }
    /// 小标题上方的留白。
    var subheaderGap: CGFloat { 4 }
    /// 小标题一行的高，比树状子项矮一档。
    var subheaderRowHeight: CGFloat { workspaceRowHeight - 4 }
    /// 行尾的小按钮（添加、刷新），触屏保留触控尺寸。
    var control: CGFloat { InputMode.current.isTouch ? InputMode.current.button : workspaceRowHeight }
    /// 收起的侧栏只露出的图标列：行首图标、树干和小标题的圆点都在它的中线上。
    var column: CGFloat { 2 * treeInset }
    /// 收起的侧栏在图标列两侧各多露出这么多：48pt 宽，第一个窗口落在红绿灯右边。
    static let railMargin: CGFloat = 6

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
    /// 侧栏收着时右边缘往里收了多少，展开时是 0。收起的侧栏仍按展开的宽排，只露出图标列（见 MainWindow 的 SidebarLiveWidth）：
    /// 图标列里的东西原地不动，跟着右边缘走的（行的底色、设置按钮）往里让这么多，其余的淡掉（sidebarExpandedOnly）。
    @Entry var sidebarTuck: CGFloat = 0
    /// 一级行在一组里（SidebarRailGroup 写入）：侧栏收起时这一行不画选中、悬停的底色，不和那一组的淡色底相交。
    @Entry var sidebarRailGrouped = false
    /// 侧栏滚动区的可见高，由滚动区写入（SidebarScrollArea），不在滚动区里是无穷大。列表比它高就要滚动（SidebarExpansionScope）。
    @Entry var sidebarScrollHeight: CGFloat = .infinity
    /// 所在列表各一级项的展开状态，见 SidebarExpansion。
    @Entry var sidebarExpansion: SidebarExpansion?
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

/// 行尾操作跟随所在行显隐，隐藏时同时让出点击与辅助功能；进行中的操作不收起，侧栏收着时都收起。
struct SidebarRevealedControl: ViewModifier {
    var pinned = false
    @Environment(\.sidebarRowControlsShown) private var rowShown
    @Environment(\.sidebarTuck) private var tuck

    func body(content: Content) -> some View {
        let shown = (pinned || rowShown) && tuck == 0
        return content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// 侧栏一个列表里各一级项（项目、资源库的各页、设备）的展开状态，默认都展开。列表长到要滚动时只留用户最后点开的那一项，
/// 还没点开过就留当前选中的东西所在的那一项，选中的不在哪一项里（资源库开着凭据）就全部收起：点开时已经在滚动的当场收起其他项，
/// 点开以后才变得要滚动、之后又变长的，等 SidebarExpansionScope 量出来再收。
@MainActor @Observable final class SidebarExpansion {
    private var collapsed: Set<AnyHashable> = []
    /// 用户最后点开的一项，点收起时清掉。
    @ObservationIgnored private var focus: AnyHashable?
    /// 当前选中的东西所在的一项：还没点开过哪一项时，列表长到要滚动就只留它。
    @ObservationIgnored private var selected: AnyHashable?
    /// 列表里出现过的项，收起其他项时用。
    @ObservationIgnored private var known: Set<AnyHashable> = []
    @ObservationIgnored private var overflowing = false

    /// selected 是当前选中的东西在这一项里。
    func binding(_ id: AnyHashable, selected: Bool) -> Binding<Bool> {
        known.insert(id)
        if selected { self.selected = id } else if self.selected == id { self.selected = nil }
        return Binding { !self.collapsed.contains(id) } set: { self.set(id, expanded: $0) }
    }

    func overflowed(_ overflowing: Bool) {
        self.overflowing = overflowing
        if overflowing { keepOne() }
    }

    private func set(_ id: AnyHashable, expanded: Bool) {
        if expanded {
            collapsed.remove(id)
            focus = id
            if overflowing { keepOne() }
        } else {
            collapsed.insert(id)
            if focus == id { focus = nil }
        }
    }

    private func keepOne() {
        let kept = (focus ?? selected).map { [$0] } ?? []
        collapsed.formUnion(known.subtracting(kept))
    }
}

/// 一个列表的范围：里面的一级项从 sidebarExpansion 取展开状态。要不要滚动拿这个列表自己的高去比滚动区的可见高：
/// 滚动区跨栏目留着，它的内容尺寸在换栏的头一下还是上一栏的。
struct SidebarExpansionScope: ViewModifier {
    @Environment(\.sidebarScrollHeight) private var available
    @State private var height: CGFloat = 0
    @State private var expansion = SidebarExpansion()

    func body(content: Content) -> some View {
        content
            .environment(\.sidebarExpansion, expansion)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onChange(of: height > available + 0.5) { _, overflowing in expansion.overflowed(overflowing) }
    }
}

extension Optional where Wrapped == SidebarExpansion {
    /// 一级项的展开状态，不在 SidebarExpansionScope 里时总是展开。
    func binding(_ id: AnyHashable, selected: Bool) -> Binding<Bool> { self?.binding(id, selected: selected) ?? .constant(true) }
}

/// 只在展开的侧栏里有的部分（名字、数字、行尾操作）：侧栏收起时淡掉，同时让出点击与辅助功能。
struct SidebarExpandedOnly: ViewModifier {
    @Environment(\.sidebarTuck) private var tuck

    func body(content: Content) -> some View {
        let shown = tuck == 0
        content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// 占满侧栏宽的（行的底色、分割线）：侧栏收起时跟着右边缘收进来，占满露出的那一列，即图标列两侧各多 railMargin。
private struct SidebarFullWidth: ViewModifier {
    @Environment(\.sidebarTuck) private var tuck

    func body(content: Content) -> some View {
        let margin = tuck > 0 ? SidebarMetrics.railMargin : 0
        content
            .padding(.leading, -margin)
            .padding(.trailing, tuck - margin)
    }
}

/// 侧栏收起时留下的短文字（栏名、设备的分组名）：挪到露出的那一列正中。leading 是它在侧栏里的起点。
private struct SidebarRailCentered: ViewModifier {
    let leading: CGFloat
    @Environment(\.sidebarTuck) private var tuck
    @Environment(\.sidebarMetrics) private var metrics
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .offset(x: tuck > 0 ? (metrics.column - width) / 2 - leading : 0)
    }
}

/// 侧栏收起时一级行连同它的子项放在一块淡色底上，一组一组分清；颜色同行的悬停底色，展开时没有。
private struct SidebarRailGroup: ViewModifier {
    @Environment(\.sidebarTuck) private var tuck
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.sidebarProjectTint) private var tint

    func body(content: Content) -> some View {
        content
            .environment(\.sidebarRailGrouped, true)
            .background {
            metrics.rowShape.fill(tint.opacity(0.06))
                .sidebarFullWidth()
                .opacity(tuck > 0 ? 1 : 0)
        }
    }
}

extension View {
    func sidebarExpandedOnly() -> some View { modifier(SidebarExpandedOnly()) }
    func sidebarRailGroup() -> some View { modifier(SidebarRailGroup()) }
    func sidebarFullWidth() -> some View { modifier(SidebarFullWidth()) }
    func sidebarRailCentered(leading: CGFloat) -> some View { modifier(SidebarRailCentered(leading: leading)) }
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
        .sidebarExpandedOnly()
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
    @Environment(\.sidebarTuck) private var tuck
    @Environment(\.sidebarRailGrouped) private var grouped
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
        .background {
            metrics.rowShape.fill(selected ? highlight.opacity(0.12) : tint.opacity(hovering ? 0.06 : 0))
                .sidebarFullWidth()
                // 收起时落在那一组的淡色底上，选中、悬停只靠文字和图标的颜色
                .opacity(tuck > 0 && grouped ? 0 : 1)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = $0 }
    }
}

/// 树状子项共用文字、行尾留白与悬停反馈，选中时只突出文字和外部连线。
/// 侧栏收起时整行淡掉，只剩树干上的圆点（SidebarTreeLink）；target 盖在圆点那一段上，点它等于点这一行。
struct SidebarTreeRow<Content: View, Target: View>: View {
    let selected: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var target: () -> Target
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.sidebarTuck) private var tuck
    @State private var hovered = false

    var body: some View {
        content()
            .sidebarExpandedOnly()
            .sidebarRowControls(selected: selected, hovered: hovered)
            .font(Theme.sidebarWorkspace)
            .foregroundStyle(selected ? highlight : tint.opacity(hovered ? 1 : 0.78))
            .fontWeight(.regular)
            .padding(.trailing, 4)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 && isEnabled }
            .overlay(alignment: .leading) {
                // 行首是 SidebarTreeRows 给的文字起点，往回挪到图标列
                if tuck > 0 {
                    target().frame(width: metrics.column).offset(x: -metrics.textInset)
                }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension SidebarTreeRow where Target == EmptyView {
    init(selected: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.init(selected: selected, content: content) { EmptyView() }
    }
}

/// 收起的侧栏里树状子项圆点上的点击区。
struct SidebarTreeTarget: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .help(title)
        .accessibilityLabel(title)
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
            Text(title).lineLimit(1).sidebarExpandedOnly()
            Spacer(minLength: 0)
            if let note {
                Text(note).font(Theme.caption).foregroundStyle(.secondary).sidebarExpandedOnly()
            }
        }
        .font(Theme.sidebarHeading.weight(.semibold))
        .frame(height: metrics.rowHeight)
        .contentShape(metrics.rowShape)
    }
}

/// 一级行下再分一层的小标题：圆点加名称，所在组有选中项时突出；加号像其他行尾操作一样跟随选中与悬停，触屏上常驻。
/// 项目一栏里项目下的检出与资源库里代理上下文的分类共用。侧栏收起时圆点淡掉，名称留在图标列正中，把树干隔成一段段。
struct SidebarSubheader: View {
    let title: String
    let selected: Bool
    let help: String
    /// 为 nil 时标题不可点。
    let open: (() -> Void)?
    var add: SidebarSubheaderAdd?
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.sidebarTuck) private var tuck
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            label
            if let add {
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
        .frame(height: metrics.subheaderRowHeight)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovered = $0 }
        .padding(.top, metrics.subheaderGap)
    }

    private var label: some View {
        Button { open?() } label: {
            HStack(spacing: 8) {
                // 收起时淡掉，免得和树状子项收成的圆点混在一起
                Circle().fill(selected ? highlight : tint.mix(with: Theme.background, by: 0.6))
                    .frame(width: selected ? 8 : 6, height: selected ? 8 : 6)
                    .frame(width: metrics.labelExtent)
                    .sidebarExpandedOnly()
                // 收起时比露出的那一列略窄，长的机器名截断
                Text(title)
                    .font(Theme.sidebarCheckout)
                    .foregroundStyle(selected ? highlight : tint.opacity(0.5)).lineLimit(1)
                    .sidebarRailCentered(leading: metrics.textInset)
                    .frame(maxWidth: tuck > 0 ? metrics.column + SidebarMetrics.railMargin : nil, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(height: metrics.subheaderRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle(foreground: selected ? highlight : tint))
        .disabled(open == nil)
        .help(help)
    }
}

struct SidebarSubheaderAdd {
    let help: String
    let label: String
    let action: () -> Void
}

/// 小标题分组的容器：linked 时各组的小标题与树线由左侧一条竖线连起来。侧栏收起时这条线收掉，树干在小标题处断开。
struct SidebarSubgroups<Content: View>: View {
    let linked: Bool
    @ViewBuilder var content: Content
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.sidebarTuck) private var tuck

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(alignment: .leading) {
            if linked {
                Rectangle().fill(tint.mix(with: Theme.background, by: 0.92)).frame(width: 1)
                    .opacity(tuck > 0 ? 0 : 1)
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
    /// 收起的侧栏里圆点画淡一点的项（已经分离成独立窗口的工作区）。
    var dimmed: (Item) -> Bool = { _ in false }
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
                    // 每行的树干往上连到标题，穿过前面的行：前面的行叠在上面，收起时圆点不被后面的树干压住
                    connectedRow(item, index: index, selected: false)
                        .zIndex(-Double(index))
                }
            }
        }
        .modifier(SidebarScrollingClip(topOverflow: hasCheckout ? metrics.subheaderRowHeight / 2 : 0,
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
                                selected: selected, dimmed: dimmed(item), color: tint.mix(with: Theme.background, by: 0.8),
                                bead: tint.mix(with: Theme.background, by: 0.6))
                    .frame(width: metrics.textInset - metrics.treeInset + 6)
                    .padding(.leading, metrics.treeInset)
                    .allowsHitTesting(false)
            }
    }
}

/// 每行直接连接所属标题，固定后缩短到吸顶标题；整条连接随该行一起参与层叠与裁切。
/// 侧栏收起时这一行的名字收成一个圆点，顺着树枝滑回树干，树枝跟着缩回去，只剩树干连着各行的圆点。
private struct SidebarTreeLink: View {
    let index: Int
    let hasCheckout: Bool
    let checkoutSelected: Bool
    let selected: Bool
    var dimmed = false
    let color: Color
    /// 收起时圆点的颜色，同小标题的圆点（SidebarSubheader）。
    let bead: Color
    @Environment(\.sidebarStickyRegions) private var regions
    @Environment(\.sidebarStickyHeader) private var movingHeader
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.sidebarTuck) private var tuck

    var body: some View {
        branches.overlay(alignment: .leading) { beadView }
    }

    @ViewBuilder private var branches: some View {
        let rowHeight = metrics.workspaceRowHeight
        // 往上伸到小标题的圆点；收起时小标题处断开，从这一组的第一行起
        let checkoutExtension = hasCheckout && tuck == 0 ? metrics.subheaderRowHeight / 2 - (checkoutSelected ? 4 : 3) : 0
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
        SidebarTreeBranch(topExtension: topExtension, retract: tuck > 0 ? 1 : 0)
            .stroke(selected ? highlight : color, style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    /// 展开时缩在树枝末端、看不见，收起时落在树干上。末端的位置按 SidebarTreeRows 给的宽，同 SidebarTreeBranch。
    private var beadView: some View {
        let collapsed = tuck > 0
        let size: CGFloat = selected ? 8 : 6
        let tip = metrics.textInset - metrics.treeInset + 6 - SidebarTreeBranch.endInset
        return Circle().fill(selected ? highlight : bead)
            .frame(width: size, height: size)
            .scaleEffect(collapsed ? 1 : 0.2)
            .opacity(collapsed ? (dimmed ? 0.35 : 1) : 0)
            .offset(x: (collapsed ? 0 : tip) - size / 2)
    }
}

private nonisolated struct SidebarTreeBranch: Shape {
    /// 树枝末端离右边的距离。
    static let endInset: CGFloat = 12
    var topExtension: CGFloat = 0
    /// 收回的进度：0 是展开时的树枝，1 时末端收回树干，只剩竖线。
    var retract: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(retract, topExtension) }
        set { (retract, topExtension) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let middle = rect.midY
        let radius = min(10, middle) * (1 - retract)
        path.move(to: CGPoint(x: 0, y: -topExtension))
        path.addLine(to: CGPoint(x: 0, y: middle - radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: middle), control: CGPoint(x: 0, y: middle))
        path.addLine(to: CGPoint(x: (rect.maxX - Self.endInset) * (1 - retract), y: middle))
        return path
    }
}
