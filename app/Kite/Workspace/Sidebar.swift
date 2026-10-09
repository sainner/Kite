import SwiftUI

private let sidebarRowShape = RoundedRectangle(cornerRadius: 8)

/// 点击与拖动只覆盖文字区，右侧操作保留独立的命中范围。
struct WorkspaceRow<Interaction: View>: View {
    let workspace: WorkArea
    let current: Bool
    var detached = false
    @ViewBuilder var interaction: () -> Interaction

    @Environment(AppModel.self) private var model
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight

    var body: some View {
        SidebarTreeRow(selected: current) { hovered in
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(workspace.title)
                        .lineLimit(1).truncationMode(.middle)
                    let status = model.deviceStatus(model.connection(for: workspace))
                    if !status.ready {
                        Text(status.title).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if detached { TablerIcon(.tablerAppWindow).font(Theme.caption) }
                }
                .frame(maxWidth: .infinity, minHeight: InputMode.current.workspaceRowHeight)
                .contentShape(Rectangle())
                .overlay { interaction() }
                .contextMenu { WorkspaceGitActions(workspace: workspace, showsWorkspaceMenu: !InputMode.current.isTouch) }
                HStack(spacing: 0) {
                    if InputMode.current.isTouch {
                        Menu {
                            WorkspaceGitActions(workspace: workspace)
                        } label: {
                            TablerIcon(.tablerGitBranch)
                        }
                        .help("版本操作")
                        .accessibilityLabel("版本操作")
                        Menu {
                            Button("创建工作区…") {
                                if let checkout = workspace.remote?.checkout { model.newWorkspace = .checkout(checkout.id) }
                            }
                            Divider()
                            WorkspaceGitActions(workspace: workspace)
                        } label: {
                            TablerIcon(.tablerDots)
                        }
                        .help("更多操作")
                        .accessibilityLabel("更多操作")
                    } else {
                        Button { model.archiveRequest = workspace } label: {
                            TablerIcon(.tablerArchive, size: 14)
                        }
                        .disabled(workspace.remote?.workspace.kind != .worktree || !model.isConnected(workspace))
                        .help("归档工作区")
                        .accessibilityLabel("归档工作区")
                        Menu {
                            WorkspaceGitActions(workspace: workspace, showsWorkspaceMenu: true)
                        } label: {
                            TablerIcon(.tablerDots, size: 14)
                        }
                        .help("更多操作")
                        .accessibilityLabel("更多操作")
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(SidebarButtonStyle(foreground: current ? highlight : tint,
                                               size: InputMode.current.workspaceRowHeight))
                .modifier(SidebarRevealedControl(shown: current || InputMode.current.revealsControls(hovered: hovered)))
            }
        }
        .help(workspace.remote.map { "\($0.machine.name) · \($0.workspace.cwd)" } ?? workspace.title)
    }
}

private extension EnvironmentValues {
    @Entry var sidebarProjectTint: Color = .primary
    /// 选中与悬停的强调色：项目内用项目主题色，项目用默认文字色或在项目之外时用 App 主题色。
    @Entry var sidebarHighlight: Color = .accentColor
    @Entry var sidebarButtonHovered = false
}

/// 侧栏悬停只改变图标颜色，保留按钮的尺寸与点击范围。
private struct SidebarButtonStyle: ButtonStyle {
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

private struct SidebarIconTint: ViewModifier {
    var foreground: Color
    var allowsHover = true
    @Environment(\.sidebarButtonHovered) private var hovered
    @Environment(\.sidebarHighlight) private var highlight

    func body(content: Content) -> some View {
        content.foregroundStyle(hovered && allowsHover ? highlight : foreground)
    }
}

/// 行尾操作只在悬停或触屏时出现，隐藏时同时让出点击与辅助功能。
private struct SidebarRevealedControl: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// 一级行末尾展开或收起树状子项。
private struct SidebarDisclosureButton: View {
    let title: String
    let noun: String
    @Binding var isExpanded: Bool
    let foreground: Color

    var body: some View {
        Button { isExpanded.toggle() } label: {
            TablerIcon(isExpanded ? .tablerChevronDown : .tablerChevronRight)
        }
        .buttonStyle(SidebarButtonStyle(foreground: foreground, size: InputMode.current.workspaceRowHeight))
        .help(isExpanded ? "收起\(noun)" : "展开\(noun)")
        .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(title)")
    }
}

/// 各栏的一级列表行共用字重、尺寸与反馈；操作按钮由各自的内容提供。
private struct SidebarListRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: (_ foreground: Color, _ hovered: Bool) -> Content
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let hovering = hovered && isEnabled && !InputMode.current.isTouch
        let foreground = selected || hovering ? highlight : tint
        HStack(spacing: 0) {
            content(foreground, hovering)
        }
        .foregroundStyle(foreground)
        .padding(.leading, Metrics.sidebarItemInset)
        .padding(.trailing, InputMode.current.isTouch ? 8 : 4)
        .frame(height: InputMode.current.rowHeight)
        .background(selected ? highlight.opacity(0.12) : tint.opacity(hovering ? 0.06 : 0), in: sidebarRowShape)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovered = $0 }
    }
}

/// 树状子项共用文字、行尾留白与悬停反馈，选中时只突出文字和外部连线。
private struct SidebarTreeRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: (_ hovered: Bool) -> Content
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        content(hovered)
            .font(Theme.sidebarWorkspace)
            .foregroundStyle(selected ? highlight : tint.opacity(hovered ? 1 : 0.78))
            .fontWeight(.regular)
            .padding(.trailing, 4)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 && isEnabled }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarListLabel: View {
    let title: String
    var icon: TablerSymbol?
    var selected = false
    var note: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                TablerIcon(icon, selected: selected)
                    .opacity(0.65)
                    .frame(width: InputMode.current.labelExtent)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if let note {
                Text(note).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .font(Theme.sidebarHeading.weight(.semibold))
        .frame(height: InputMode.current.rowHeight)
        .contentShape(sidebarRowShape)
    }
}

/// 项目内保留检出归属，根工作区和独立工作区都可直接进入。
struct WorkspaceGroup: Identifiable {
    struct Checkout: Identifiable {
        let id: String
        var root: WorkArea?
        var workspaces: [WorkArea]
    }
    let id: String
    let title: String?
    var checkouts: [Checkout]

    var workspaces: [WorkArea] { checkouts.flatMap { [$0.root].compactMap { $0 } + $0.workspaces } }
}

extension AppModel {
    /// 沿用工作区列表的顺序，项目和检出排在其中第一个工作区出现的位置。草稿不是工作区，不列出。
    var workspaceGroups: [WorkspaceGroup] {
        var groups: [WorkspaceGroup] = []
        for area in workspaces {
            guard let remote = area.remote else { continue }
            if !groups.contains(where: { $0.id == remote.project.id }) {
                groups.append(.init(id: remote.project.id, title: projectLabel(remote.project), checkouts: []))
            }
            let group = groups.firstIndex { $0.id == remote.project.id }!
            if let checkout = groups[group].checkouts.firstIndex(where: { $0.id == remote.checkout.id }) {
                if remote.workspace.kind == .root { groups[group].checkouts[checkout].root = area }
                else { groups[group].checkouts[checkout].workspaces.append(area) }
            } else {
                groups[group].checkouts.append(.init(id: remote.checkout.id, root: remote.workspace.kind == .root ? area : nil, workspaces: remote.workspace.kind == .root ? [] : [area]))
            }
        }
        return groups
    }

}

/// 项目、机器与工作区共享一根树干，文字起点保持一致。
struct WorkspaceList<Row: View>: View {
    var onSelect: () -> Void = {}
    @ViewBuilder let row: (WorkArea) -> Row
    @Environment(AppModel.self) private var model
    @Environment(\.workspacePresentation) private var presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.workspaceGroups) { group in
                WorkspaceProjectSection(group: group, onSelect: onSelect, row: row)
            }
        }
        .padding(.top, presentation == .compact ? 12 : 0)
        .padding(.bottom, 12)
    }
}

private struct WorkspaceProjectSection<Row: View>: View {
    let group: WorkspaceGroup
    var onSelect: () -> Void = {}
    @ViewBuilder let row: (WorkArea) -> Row
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isExpanded = true
    @State private var hoveredCheckoutID: String?
    @State private var hoveringIcon = false

    private var theme: ProjectTheme {
        ProjectTheme(rawValue: model.account.projectAppearances[group.id]?.color ?? "primary") ?? .primary
    }
    private var tint: Color { theme.color }
    private var highlight: Color { theme == .primary ? .accentColor : tint }
    private var checkoutLinkColor: Color { tint.mix(with: Theme.background, by: 0.92) }

    var body: some View {
        let checkouts = group.checkouts
        let current = model.current?.id
        let selected = model.selectedProjectID == group.id || group.workspaces.contains { $0.id == current }
        SidebarStickySection(headerHeight: InputMode.current.rowHeight) {
            SidebarListRow(selected: selected) { foreground, hovered in
                Button {
                    model.selectProject(group.id)
                    onSelect()
                } label: {
                    Group {
                        if hoveringIcon {
                            Image(systemName: "info.circle")
                        } else {
                            TablerIcon(ProjectIcon.symbol(for: model.account.projectAppearances[group.id]?.icon), selected: selected)
                        }
                    }
                        .opacity(0.65)
                        .font(Theme.sidebarHeading.weight(.semibold))
                        .frame(width: InputMode.current.labelExtent, height: InputMode.current.rowHeight)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground))
                .onHover { hoveringIcon = $0 }
                .help("项目配置")
                .accessibilityLabel("\(group.title ?? "项目")的配置")
                Button {
                    if checkouts.count == 1, let root = checkouts.first?.root {
                        selectRoot(root)
                    } else {
                        isExpanded.toggle()
                    }
                } label: {
                    SidebarListLabel(title: group.title ?? "项目", selected: selected)
                        .padding(.leading, 8)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground))
                .help(checkouts.count == 1 ? "打开现场" : (isExpanded ? "收起项目" : "展开项目"))
                .contextMenu {
                    if checkouts.count == 1, let root = checkouts.first?.root {
                        WorkspaceGitActions(workspace: root)
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
                Button {
                    if let checkout = group.checkouts.first(where: { checkout in
                        (checkout.root.map { model.isConnected($0) } ?? false)
                            || checkout.workspaces.contains(where: { model.isConnected($0) })
                    }) ?? group.checkouts.first {
                        model.newWorkspace = .checkout(checkout.id)
                    }
                } label: {
                    TablerIcon(.tablerPlus)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground, size: InputMode.current.sidebarControl))
                .help("创建工作区")
                .accessibilityLabel("在\(group.title ?? "项目")中创建工作区")
                .modifier(SidebarRevealedControl(shown: InputMode.current.revealsControls(hovered: hovered)))
                SidebarDisclosureButton(title: group.title ?? "项目", noun: "项目", isExpanded: $isExpanded, foreground: foreground)
            }
        } content: {
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(checkouts) { checkout in
                        let workspaces = checkout.workspaces
                        let selectedIndex = workspaces.firstIndex { $0.id == current }
                        let checkoutSelected = selectedIndex != nil || (current != nil && checkout.root?.id == current)
                        SidebarStickySection(enabled: checkoutSelected && checkouts.count > 1,
                                             topInset: InputMode.current.rowHeight,
                                             headerHeight: checkouts.count > 1 ? 8 + InputMode.current.workspaceRowHeight : 0) {
                            if checkouts.count > 1 {
                                HStack(spacing: 8) {
                                    Button {
                                        if let root = checkout.root { selectRoot(root) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Circle().fill(checkoutSelected ? highlight : tint.mix(with: Theme.background, by: 0.6))
                                                .frame(width: checkoutSelected ? 8 : 6, height: checkoutSelected ? 8 : 6)
                                                .frame(width: InputMode.current.labelExtent)
                                            Text((checkout.root ?? workspaces.first)?.remote?.machine.name ?? "工作机")
                                                .font(Theme.sidebarCheckout)
                                                .foregroundStyle(checkoutSelected ? highlight : tint.opacity(0.5)).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .frame(height: InputMode.current.workspaceRowHeight)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(SidebarButtonStyle(foreground: checkoutSelected ? highlight : tint))
                                    .disabled(checkout.root == nil)
                                    .help("打开现场")
                                    .contextMenu {
                                        if let root = checkout.root { WorkspaceGitActions(workspace: root) }
                                    }
                                    if !InputMode.current.isTouch {
                                        Button { model.newWorkspace = .checkout(checkout.id) } label: {
                                            TablerIcon(.tablerPlus)
                                        }
                                        .buttonStyle(SidebarButtonStyle(foreground: checkoutSelected ? highlight : tint, size: InputMode.current.workspaceRowHeight))
                                        .help("创建工作区")
                                        .accessibilityLabel("在此检出中创建工作区")
                                        .modifier(SidebarRevealedControl(shown: hoveredCheckoutID == checkout.id))
                                    }
                                }
                                .padding(.leading, Metrics.sidebarItemInset)
                                .padding(.trailing, InputMode.current.isTouch ? 0 : 4)
                                .frame(height: InputMode.current.workspaceRowHeight)
                                .accessibilityAddTraits(checkoutSelected ? .isSelected : [])
                                .onHover { hovering in
                                    if hovering { hoveredCheckoutID = checkout.id }
                                    else if hoveredCheckoutID == checkout.id { hoveredCheckoutID = nil }
                                }
                                .padding(.top, 8)
                            }
                        } content: {
                            SidebarTreeRows(items: workspaces, selectedIndex: selectedIndex,
                                            hasCheckout: checkouts.count > 1, tint: tint, row: row)
                        }
                        .zIndex(checkoutSelected ? 1 : 0)
                    }
                }
                .background(alignment: .leading) {
                    if checkouts.count > 1 {
                        Rectangle().fill(checkoutLinkColor).frame(width: 1)
                            .padding(.leading, SidebarTree.treeInset - 0.5)
                            // 在末行弯折的起点结束，避免直线穿过弯折露出尾巴。
                            .padding(.bottom, InputMode.current.workspaceRowHeight / 2 + 10)
                            .allowsHitTesting(false)
                            .modifier(SidebarScrollingClip(topOverflow: 0))
                    }
                }
            }
        }
        .environment(\.sidebarProjectTint, tint)
        .environment(\.sidebarHighlight, highlight)
    }

    private func selectRoot(_ root: WorkArea) {
        if model.detached.contains(root.id) {
            openWindow(id: "workspace", value: root.id)
        } else {
            model.selectWorkspace(root.id)
        }
        onSelect()
    }
}

/// 树状子项的文字起点与树干位置，与一级行的图标列对齐。
private enum SidebarTree {
    static var textInset: CGFloat { Metrics.sidebarItemInset + 8 + InputMode.current.labelExtent }
    static var treeInset: CGFloat { Metrics.sidebarItemInset + InputMode.current.labelExtent / 2 }
}

/// 一级行下的树状子项，须放在 SidebarStickySection 的内容里，所属标题取最近一层分区。
/// 普通行共用裁切，选中行独立吸顶；占位保留列表高度，连接线随选中行置于最上层。
private struct SidebarTreeRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedIndex: Int?
    var hasCheckout = false
    /// 树线的颜色由它淡到底色里，项目分区用项目色。
    var tint = Color.primary
    @ViewBuilder let row: (Item) -> Row
    @Environment(\.sidebarStickyRegions) private var regions

    private var selectedRegion: SidebarStickyRegion? {
        guard let selectedIndex, let parent = regions.last else { return nil }
        let rowHeight = InputMode.current.workspaceRowHeight
        return SidebarStickyRegion(space: parent.space,
                                   start: parent.height + CGFloat(selectedIndex) * rowHeight,
                                   height: rowHeight,
                                   topInset: parent.topInset + parent.height)
    }

    var body: some View {
        let rowHeight = InputMode.current.workspaceRowHeight
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
            .padding(.leading, SidebarTree.textInset)
            .background(alignment: .leading) {
                SidebarTreeLink(index: index, hasCheckout: hasCheckout,
                                checkoutSelected: selectedIndex != nil,
                                selected: selected, color: tint.mix(with: Theme.background, by: 0.8))
                    .frame(width: SidebarTree.textInset - SidebarTree.treeInset + 6)
                    .padding(.leading, SidebarTree.treeInset)
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

    var body: some View {
        let rowHeight = InputMode.current.workspaceRowHeight
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

/// 一级导航的各栏。没接通的置灰，不能选。
enum SidebarSection: CaseIterable, Identifiable {
    case workspaces, drive, extensions, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .workspaces: "空间"
        case .drive: "设备"
        case .extensions: "资源库"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: "cube"
        case .drive: "externaldrive"
        case .extensions: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }

    var available: Bool { true }
    /// 设置不在一级导航里，从用户栏末尾的设置按钮进入。
    var navigable: Bool { self != .settings }

    /// 导航行尾的数字：工作区数量，设备一栏是在线的机器数。
    @MainActor func count(in model: AppModel) -> Int? {
        switch self {
        case .workspaces: model.workspaces.count
        case .drive: model.availableWorkers.count
        case .extensions, .settings: nil
        }
    }
}

/// 一级栏里的一页：侧栏里一行，内容区一张卡片。
protocol SidebarPage: Hashable, Identifiable, CaseIterable where AllCases == [Self] {
    var title: String { get }
    var icon: TablerSymbol { get }
    var available: Bool { get }
}

/// 一级菜单使用主题色背景，列表行使用 SidebarListRow。
private struct SidebarNavigationStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let hovering = hovered && isEnabled
        let highlight = Color.gray.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.2 : hovering ? 0.1 : 0)
        configuration.label
            .environment(\.sidebarButtonHovered, !InputMode.current.isTouch && hovered && isEnabled && !selected)
            .padding(.leading, Metrics.sidebarItemInset)
            // 行尾数字自己占一个与行同高的方格，见 SidebarNavigationLabel。
            .frame(height: InputMode.current.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(sidebarRowShape)
            .background {
                sidebarRowShape.fill(selected ? Color.accentColor : highlight)
                    .overlay {
                        sidebarRowShape.fill(Color.black.opacity(!selected ? 0 : configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
                    }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .clickPointer()
    }
}

/// 一级菜单的图标、标题与数量。
private struct SidebarNavigationLabel: View {
    let title: String
    let systemImage: String
    var note: String?
    /// 选中时图标换实心，白字配合主题色背景。
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: InputMode.current.labelExtent - 4, weight: .bold))
                .symbolVariant(selected ? .fill : .none)
                .opacity(0.65)
                .frame(width: InputMode.current.labelExtent)
            Text(title).font(Theme.sidebarHeading).lineLimit(1)
            Spacer(minLength: 0)
            if let note {
                Text(note).font(Theme.caption).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .frame(minWidth: InputMode.current.rowHeight)
            }
        }
        .modifier(SidebarIconTint(foreground: selected ? Color.white : Color.primary, allowsHover: !selected))
    }
}

/// 一级导航：标志栏下面一列全宽按钮，选中项用主题色背景配白字；没接通的置灰。两端相同，iPhone 放在侧栏抽屉顶部。
/// 设置不在这里，入口是用户栏末尾的设置按钮。
/// 收起的侧栏里只留图标竖着排。
struct SidebarNavigation: View {
    /// 收起的图标栏里只要图标。
    var iconsOnly = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: iconsOnly ? 12 : 4) {
            ForEach(SidebarSection.allCases.filter(\.navigable)) { section in
                let selected = model.sidebarSection == section
                let button = Button {
                    withAnimation(.snappy) { model.sidebarSection = section }
                } label: {
                    if iconsOnly {
                        Image(systemName: section.symbol)
                            .font(.system(size: InputMode.current.labelExtent - 4, weight: .bold))
                            .symbolVariant(selected ? .fill : .none)
                            .modifier(SidebarIconTint(foreground: selected ? Color.white : Color.primary, allowsHover: !selected))
                            .opacity(0.65)
                            .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                            .background(selected ? Color.accentColor : .clear, in: sidebarRowShape)
                            .contentShape(sidebarRowShape)
                            .opacity(section.available ? 1 : 0.45)
                    } else {
                        SidebarNavigationLabel(title: section.title, systemImage: section.symbol,
                                               note: section.count(in: model).map(String.init), selected: selected)
                    }
                }
                .disabled(!section.available)
                .help(section.available ? section.title : "\(section.title)（尚未接通）")
                .accessibilityAddTraits(selected ? .isSelected : [])
                if iconsOnly { button.buttonStyle(SidebarButtonStyle()) }
                else { button.buttonStyle(SidebarNavigationStyle(selected: selected)) }
            }
        }
    }
}

/// 侧栏底部的用户栏：左边账号信息，末尾的按钮进入设置。
struct SidebarUserBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.workspacePresentation) private var presentation

    private var user: AccountUser? { model.account.user }

    var body: some View {
        let quotas = model.subscriptionQuotas
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.email ?? "未登录")
                    .font(Theme.body).lineLimit(1).truncationMode(.middle)
                    // 宽屏侧栏里邮箱比额度再往里缩一点
                    .padding(.leading, presentation == .tiled ? 2 : 0)
                HStack(spacing: 4) {
                    // 账号层的错误比额度更上游，出现时替换额度，点开看 Kite 账号页。
                    if let error = model.account.error {
                        Button { withAnimation(.snappy) { model.openSettings(.account) } } label: {
                            chip {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                Text(error)
                            }
                        }
                        .buttonStyle(.plain)
                        .clickPointer()
                        .help(error)
                        .accessibilityLabel(error)
                        .accessibilityHint("打开 Kite 账号设置")
                    } else if quotas.isEmpty {
                        chip { Text("额度未获取") }
                            .help("在设备的账号页查看登录和查询状态")
                    } else {
                        ForEach(quotas) { quota($0) }
                    }
                }
            }
            .padding(.leading, presentation == .tiled ? 3 : 6)
            Spacer(minLength: 0)
            SidebarSettingsButton()
        }
        // 设置按钮贴着侧栏右边缘，底边与旁边窗口的底边对齐
        .padding(.top, 10)
    }

    /// 圆环显示这家厂商各账号合计的剩余额度，不到两成时换成警示色；悬停列出各账号。
    private func quota(_ quota: SubscriptionQuota) -> some View {
        let percent = { (value: Double) in value.formatted(.percent.precision(.fractionLength(0))) }
        let total = quota.accounts.count > 1 ? "\(quota.accounts.count) 个账号合计剩余" : "剩余"
        let detail = (["\(quota.provider) · \(total) \(percent(quota.remaining))"]
            + quota.accounts.map { "\($0.name) · \($0.quota) · 剩余 \(percent($0.remaining))" }).joined(separator: "\n")
        let tint = quota.remaining < 0.2 ? Theme.warning : Color.accentColor
        return chip {
            ZStack {
                Circle().stroke(Theme.rule, lineWidth: 1.5)
                Circle().trim(from: 0, to: quota.remaining)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 8, height: 8)
            Text(quota.provider)
        }
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
    }

    private func chip(@ViewBuilder _ content: () -> some View) -> some View {
        // iPhone 的 caption2 比 Mac 大一号，胶囊跟着放大
        #if os(iOS)
        let (inset, height): (CGFloat, CGFloat) = (6, 16)
        #else
        let (inset, height): (CGFloat, CGFloat) = (5, 14)
        #endif
        return HStack(spacing: 3) { content() }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, inset)
            .frame(height: height)
            .background(Theme.selection, in: Capsule())
    }
}

/// 用户头像，显示邮箱首字母。
struct SidebarAvatar: View {
    @Environment(AppModel.self) private var model

    private var user: AccountUser? { model.account.user }

    var body: some View {
        Text(user?.email.first.map { String($0).uppercased() } ?? "?")
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: Metrics.paneHeaderButton, height: Metrics.paneHeaderButton)
            .background(Color.accentColor, in: Circle())
            .accessibilityLabel("用户头像")
    }
}

/// 用户栏与收起的侧栏共用设置入口；在设置一栏里时变成返回，回到进入设置前的一栏。
struct SidebarSettingsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.sidebarSection == .settings
        let title = selected ? "返回" : "设置"
        PaneHeaderButtonGroup(selected: selected) {
            Button { withAnimation(.snappy) { selected ? model.closeSettings() : model.openSettings() } } label: {
                PaneHeaderButtonLabel(title, systemImage: selected ? "chevron.backward" : "gearshape")
            }
            .help(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

struct SidebarListHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sidebarSection != .drive {
            Text(model.sidebarSection == .workspaces ? "项目" : model.sidebarSection.title)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.sidebarItemInset)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// 一级栏的侧栏：各页一行，选中的一页在内容区打开；没接通的置灰。
struct SidebarPageList<Page: SidebarPage>: View {
    @Binding var selection: Page
    /// 选了一页之后；紧凑布局用它收起侧栏。
    var onSelect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Page.allCases) { page in
                SidebarPageRow(selection: $selection, page: page, onSelect: onSelect)
            }
        }
    }
}

private struct SidebarPageRow<Page: SidebarPage>: View {
    @Binding var selection: Page
    let page: Page
    var onSelect: () -> Void

    var body: some View {
        SidebarListRow(selected: selection == page) { foreground, _ in
            Button {
                selection = page
                onSelect()
            } label: {
                SidebarListLabel(title: page.title, icon: page.icon, selected: selection == page,
                                 note: page.available ? nil : "尚未接通")
            }
            .buttonStyle(SidebarButtonStyle(foreground: foreground))
            .accessibilityAddTraits(selection == page ? .isSelected : [])
        }
        .disabled(!page.available)
    }
}

/// 资源库的侧栏：各个角色像空间里的工作区一样，用树状子项列在「角色」一行下面；其余各页一行。
private struct ExtensionSidebar: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model
    @State private var rolesExpanded = true

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ExtensionLibrary.allCases) { page in
                if page == .roles { roles }
                else { SidebarPageRow(selection: $model.extensionPage, page: page, onSelect: onSelect) }
            }
        }
        // 角色页没打开时也要列出角色。
        .task(id: model.connectionRevision) { try? await model.ensureRoles() }
    }

    private var roles: some View {
        let page = ExtensionLibrary.roles
        let selected = model.extensionPage == page
        let roles = model.libraryRoles
        let current = selected ? model.libraryRoleID : nil
        return SidebarStickySection(headerHeight: InputMode.current.rowHeight) {
            SidebarListRow(selected: selected) { foreground, hovered in
                Button { open(nil) } label: {
                    SidebarListLabel(title: page.title, icon: page.icon, selected: selected)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground))
                .accessibilityAddTraits(selected ? .isSelected : [])
                Button {
                    model.newLibraryRole()
                    onSelect()
                } label: {
                    TablerIcon(.tablerPlus)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground, size: InputMode.current.sidebarControl))
                .disabled(model.roleCatalog?.defaultRole == nil)
                .help("新建角色")
                .accessibilityLabel("新建角色")
                .modifier(SidebarRevealedControl(shown: InputMode.current.revealsControls(hovered: hovered)))
                SidebarDisclosureButton(title: page.title, noun: page.title, isExpanded: $rolesExpanded, foreground: foreground)
            }
        } content: {
            if rolesExpanded {
                SidebarTreeRows(items: roles, selectedIndex: roles.firstIndex { $0.id == current }) { role in
                    SidebarTreeRow(selected: role.id == current) { _ in
                        Button { open(role.id) } label: {
                            HStack(spacing: 6) {
                                Text(role.title.isEmpty ? "未命名角色" : role.title)
                                    .lineLimit(1).truncationMode(.middle)
                                if model.roleDraft(role.id) != nil {
                                    Text("未保存").font(Theme.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: InputMode.current.workspaceRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .clickPointer()
                    }
                }
            }
        }
    }

    /// 打开角色页；没指定角色时显示上次选中的那个。
    private func open(_ role: String?) {
        model.extensionPage = .roles
        if let role { model.selectedLibraryRole = role }
        onSelect()
    }
}

/// 一级栏的侧栏内容：工作区以外的栏列出各页。
struct SectionPages: View {
    var onSelect: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        switch model.sidebarSection {
        case .drive: DeviceSidebar(onSelect: onSelect)
        case .extensions: ExtensionSidebar(onSelect: onSelect)
        case .settings: SidebarPageList(selection: $model.settingsPage, onSelect: onSelect)
        case .workspaces: EmptyView()
        }
    }
}

/// 在线、等待连接和离线同时用颜色与符号区分，状态说明保留在悬停与辅助功能中。
private struct DeviceStatusIcon: View {
    @Environment(AppModel.self) private var model
    let device: AccountDevice
    let connection: WorkerConnection?

    private var status: DeviceStatus { DeviceStatus(device: device, connection: connection) }

    var body: some View {
        Group {
            switch device.id == model.account.deviceID ? KiteAccount.localDeviceKind : device.kind ?? "unknown" {
            case "phone": Image(systemName: "iphone")
            case "tablet": Image(systemName: "ipad")
            case "computer": TablerIcon(.desktop, selected: status.ready)
            default: TablerIcon(.appWindow, selected: status.ready)
            }
        }
        .foregroundStyle(status.tint)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: status.symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(status.tint)
                .background(Theme.background, in: Circle())
                .offset(x: 3, y: 3)
        }
        .help("\(device.role == "worker" ? "工作机" : "控制端") · \(status.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.title)
    }
}

/// 每台工作机下并列账号、文件，与空间共用吸顶分区和树状子项。状态色只用在设备图标上，文字与选中沿用侧栏默认颜色。
private struct DeviceSidebar: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<String> = []
    @State private var removing: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            deviceList("工作机", devices: model.account.devices.filter { $0.role == "worker" })
            deviceList("控制端", devices: model.account.devices.filter { $0.role != "worker" })
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                    .padding(.horizontal, Metrics.sidebarItemInset)
            }
        }
    }

    private func deviceList(_ title: String, devices: [AccountDevice]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.sidebarItemInset)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(devices) { device in
                let connection = model.connections.values.first { $0.deviceID == device.id }
                let selected = connection.map { model.accountWorker?.id == $0.id } ?? false
                let isExpanded = expanded(device.id)
                SidebarStickySection(headerHeight: InputMode.current.rowHeight) {
                    SidebarListRow(selected: selected) { foreground, hovered in
                        DeviceStatusIcon(device: device, connection: connection)
                            .frame(width: InputMode.current.labelExtent)
                        if connection != nil {
                            Button { isExpanded.wrappedValue.toggle() } label: {
                                SidebarListLabel(title: device.name, selected: selected).padding(.leading, 8)
                            }
                            .buttonStyle(SidebarButtonStyle(foreground: foreground))
                        } else {
                            SidebarListLabel(title: device.name, selected: selected).padding(.leading, 8)
                        }
                        if device.id != model.account.deviceID {
                            Button(role: .destructive) { remove(device) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(SidebarButtonStyle(foreground: foreground, size: InputMode.current.sidebarControl))
                            .help("删除设备")
                            .accessibilityLabel("删除\(device.name)")
                            .disabled(removing.contains(device.id))
                            .modifier(SidebarRevealedControl(shown: InputMode.current.revealsControls(hovered: hovered)))
                        }
                        if connection != nil {
                            SidebarDisclosureButton(title: device.name, noun: "设备", isExpanded: isExpanded, foreground: foreground)
                        }
                    }
                } content: {
                    if let connection, isExpanded.wrappedValue {
                        pages(connection)
                    }
                }
            }
            if devices.isEmpty {
                Text("暂无\(title)").font(Theme.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, Metrics.sidebarItemInset)
            }
        }
    }

    private func remove(_ device: AccountDevice) {
        guard device.id != model.account.deviceID, removing.insert(device.id).inserted else { return }
        error = nil
        Task {
            defer { removing.remove(device.id) }
            do {
                try await model.account.remove(device.id)
                model.mergeDirectory()
            } catch { self.error = "删除\(device.name)失败：\(error.localizedDescription)" }
        }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding {
            !collapsed.contains(id)
        } set: { expanded in
            if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    private func pages(_ connection: WorkerConnection) -> some View {
        let current = model.accountWorker?.id == connection.id
        return SidebarTreeRows(items: DrivePage.allCases,
                               selectedIndex: current ? DrivePage.allCases.firstIndex(of: model.drivePage) : nil) { page in
            let selected = current && model.drivePage == page
            SidebarTreeRow(selected: selected) { hovered in
                HStack(spacing: 0) {
                    Button {
                        model.accountMachineID = connection.id
                        model.drivePage = page
                        onSelect()
                    } label: {
                        HStack(spacing: 6) {
                            Text(page.title).lineLimit(1)
                            Spacer(minLength: 0)
                            if !page.available { Text("尚未接通").font(Theme.caption).opacity(0.65) }
                        }
                        .frame(maxWidth: .infinity, minHeight: InputMode.current.workspaceRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clickPointer()
                    if page == .accounts {
                        refreshAccounts(connection, foreground: selected ? .accentColor : .primary)
                            .modifier(SidebarRevealedControl(shown: selected || connection.readingModelAccounts
                                                             || InputMode.current.revealsControls(hovered: hovered)))
                    }
                }
            }
            .disabled(!page.available)
        }
    }

    /// 工作机一次查询自己的全部订阅与 API 账号，结果经目录事件推回。
    private func refreshAccounts(_ connection: WorkerConnection, foreground: Color) -> some View {
        Button {
            Task { await model.refreshModelAccounts(connection) }
        } label: {
            if connection.readingModelAccounts { CardSpinner() } else { TablerIcon(.tablerRefresh, size: 14) }
        }
        .buttonStyle(SidebarButtonStyle(foreground: foreground, size: InputMode.current.sidebarControl))
        .disabled(!connection.connected || connection.readingModelAccounts)
        .help("刷新这台工作机所有账号的额度")
        .accessibilityLabel("刷新\(connection.machine.name)的账号额度")
    }
}

/// 工作区以外的栏在内容区显示侧栏选中的那一页。
struct SectionContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.sidebarSection {
        case .drive: DriveContent()
        case .extensions: ExtensionContent()
        case .settings: SettingsContent()
        case .workspaces: EmptyView()
        }
    }
}

/// 资源库一栏的内容区：侧栏选中的那一页。
struct ExtensionContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.extensionPage {
            case .plugins: PluginLibrary()
            case .roles: RoleLibrary()
            case .contexts: ContextTemplateLibrary()
            case .credentials: CredentialsLibrary()
            case .skills: EmptyView()
            }
        }
        // 凭据属于 Kite 账号，切换工作机不应重置正在编辑的内容。
        .id(model.extensionPage == .credentials
            ? "credentials:\(model.account.user?.id ?? "")"
            : "\(model.extensionPage.rawValue):\(model.connectionRevision)")
    }
}

/// 资源库一栏里的各页。
nonisolated enum ExtensionLibrary: String, SidebarPage {
    case plugins, roles, contexts, credentials, skills

    var id: Self { self }

    var title: String {
        switch self {
        case .plugins: "插件"
        case .roles: "角色"
        case .contexts: "上下文模板"
        case .credentials: "凭据"
        case .skills: "Skill"
        }
    }

    var icon: TablerSymbol {
        switch self {
        case .plugins: .puzzle
        case .roles: .user
        case .contexts: .fileText
        case .credentials: .link
        case .skills: .sparkles
        }
    }

    var available: Bool { self != .skills }
}

/// 侧栏顶部保持硬边，下方还有内容时底部渐隐。
private struct ScrollEdgeFade: ViewModifier {
    @State private var below = false
    private static let length: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY < geometry.contentSize.height - 0.5
            } action: { _, hasMoreBelow in
                withAnimation(.easeOut(duration: 0.15)) {
                    below = hasMoreBelow
                }
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(below ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.length)
                }
            }
    }
}

extension View {
    func fadesScrollEdges() -> some View { modifier(ScrollEdgeFade()) }
}

/// 标志栏：Kite 字标，右端一组标题栏玻璃按钮，搜索在前，宽屏后面跟侧边栏按钮。字标与侧栏行的文字左对齐，宽屏时与按钮底对齐；底下一道分割线。
/// 两端都有，窄布局放在侧栏抽屉顶部。搜索展开时用输入框替换侧栏按钮。
struct SidebarLogoBar<Buttons: View>: View {
    @ViewBuilder var buttons: Buttons
    @Environment(\.workspacePresentation) private var presentation
    @State private var searchPresented = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var glass

    var body: some View {
        // 宽屏侧栏里字标与按钮底部对齐，窄布局的抽屉里垂直居中
        let tiled = presentation == .tiled
        return VStack(spacing: Metrics.sidebarRuleGap) {
            HStack(alignment: tiled ? .bottom : .center, spacing: Metrics.paneButtonGap) {
                Text("Kite").font(Theme.wordmark)
                controlPanel
                    .padding(.leading, tiled && searchPresented ? Metrics.padding : 0)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.leading, 8)
            .frame(height: Metrics.paneHeaderButton)
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }

    private var controlPanel: some View {
        // 玻璃间距与控件间距一致，让关闭按钮从面板分裂出来，停稳后仍是两块玻璃。
        // 面板始终是同一个视图，只随状态伸缩；拆进两个分支会变成移除再插入，iOS 上只剩模糊淡入。
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                searchPanel
                if searchPresented {
                    PaneHeaderButtonGroup {
                        closeSearchButton
                    }
                    .glassEffectID("search-close", in: glass)
                    .glassEffectTransition(.matchedGeometry)
                }
            }
        }
    }

    private var searchPanel: some View {
        searchPanelContent
            .glassEffectID("search-panel", in: glass)
            .glassEffectTransition(.matchedGeometry)
    }

    private var searchPanelContent: some View {
        PaneHeaderButtonGroup(expands: searchPresented) {
            searchControls
        }
    }

    @ViewBuilder private var searchControls: some View {
        Button {
            // 面板展开停稳后再把焦点交给输入框。
            withAnimation {
                searchPresented = true
            } completion: {
                if searchPresented { searchFocused = true }
            }
        } label: {
            PaneHeaderButtonLabel("搜索", systemImage: "magnifyingglass")
        }
        .help("搜索")
        if searchPresented {
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.paneHeaderButton)
                .focused($searchFocused)
                #if os(macOS)
                .onExitCommand(perform: closeSearch)
                #endif
        } else {
            buttons
        }
    }

    private var closeSearchButton: some View {
        Button(action: closeSearch) {
            PaneHeaderButtonLabel("关闭搜索", systemImage: "xmark")
        }
        .help("关闭搜索")
    }

    private func closeSearch() {
        searchFocused = false
        searchText = ""
        withAnimation { searchPresented = false }
    }
}

/// 宽屏侧边栏。展开时顶部是标志栏，下面是一级导航，再往下是当前一栏的内容，底部是用户栏；收起时只留一列图标。
/// 工作区一栏里一行就是一个工作区和它的窗口组：点一下在内容区显示，拖到主窗口外面就分离成独立窗口。
struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @Environment(\.windowChrome) private var chrome
    #endif

    var body: some View {
        let current = model.current?.id
        if model.sidebarCollapsed { rail(current) } else { expanded(current) }
    }

    private func expanded(_ current: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            logoBar.padding(.bottom, Metrics.sidebarRuleGap)
            // 标志栏下面是一级导航，再下面是当前一栏的列表
            if model.sidebarSection != .settings {
                SidebarNavigation()
                    .padding(.bottom, Metrics.sidebarRuleGap)
                Rectangle().fill(Theme.rule).frame(height: 1)
                    .padding(.bottom, Metrics.sidebarRuleGap)
            }
            SidebarListHeader()
            ScrollView(.vertical, showsIndicators: false) {
                switch model.sidebarSection {
                case .workspaces:
                    WorkspaceList { workspace in
                        WorkspaceRow(workspace: workspace, current: current == workspace.id, detached: model.detached.contains(workspace.id)) {
                            source(workspace)
                        }
                    }
                case .drive, .extensions, .settings:
                    SectionPages()
                }
            }
            .fadesScrollEdges()
            SidebarUserBar()
        }
    }

    /// 顶部标志栏与卡片标题栏同高同位：卡片在内容区顶边留白之下再留卡片边距。避开上方的红绿灯按钮。
    private var logoBar: some View {
        SidebarLogoBar { sidebarToggle }
        .padding(.top, Metrics.padding + Metrics.paneMargin)
        #if os(macOS)
        // 整条连同上方留白都可以拖动窗口，按钮仍接自己的点击
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        #endif
    }

    /// 收起时侧栏按钮移到第一个窗口的标题栏，见 PaneHeaderBar。列出当前一栏的图标：工作区按项目分组，组间隔一道短线；底部是设置按钮。
    private func rail(_ current: String?) -> some View {
        @Bindable var model = model
        return VStack(spacing: Metrics.gap) {
            if model.sidebarSection != .settings {
                SidebarNavigation(iconsOnly: true)
                Capsule().fill(Theme.rule).frame(width: 16, height: 2)
                    .padding(.vertical, 4)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    switch model.sidebarSection {
                    case .drive: deviceRail
                    case .extensions: railPages(selection: $model.extensionPage)
                    case .settings: railPages(selection: $model.settingsPage)
                    case .workspaces: EmptyView()
                    }
                    ForEach(Array((model.sidebarSection == .workspaces ? model.workspaceGroups : []).enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Capsule().fill(Theme.rule).frame(width: 16, height: 2).padding(.vertical, 4)
                        }
                        ForEach(group.workspaces) { workspace in
                            // 已经分离成独立窗口的画淡一点
                            Circle().fill(workspace.tint).frame(width: 24, height: 24)
                                .opacity(model.detached.contains(workspace.id) ? 0.35 : 1)
                                .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                                .background(current == workspace.id ? Theme.selection : .clear, in: sidebarRowShape)
                                .overlay { source(workspace) }
                                .help(workspace.title)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .fadesScrollEdges()
            // 设置的入口，底边与旁边窗口的底边对齐
            SidebarSettingsButton()
        }
        .frame(maxWidth: .infinity)
        // 只让开系统红绿灯按钮所在的区域。
        #if os(macOS)
        .padding(.top, chrome.top)
        #else
        .padding(.top, Metrics.padding)
        #endif
    }

    private var deviceRail: some View {
        VStack(spacing: 8) {
            ForEach(model.accountWorkers) { connection in
                let selected = model.drivePage == .accounts && model.accountWorker?.id == connection.id
                Button {
                    model.accountMachineID = connection.id
                    model.drivePage = .accounts
                } label: {
                    Group {
                        if let device = model.account.devices.first(where: { $0.id == connection.deviceID }) {
                            DeviceStatusIcon(device: device, connection: connection)
                        } else { TablerIcon(.desktop, selected: selected) }
                    }
                        .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                        .background(selected ? Theme.selection : .clear, in: sidebarRowShape)
                }
                .buttonStyle(SidebarButtonStyle(foreground: selected ? .accentColor : .secondary))
                .help("\(connection.machine.name) · 账号")
                .accessibilityLabel("\(connection.machine.name) · 账号")
            }
        }
    }

    /// 收起时工作区以外的栏只列各页图标，点一下切页。
    private func railPages<Page: SidebarPage>(selection: Binding<Page>) -> some View {
        ForEach(Page.allCases.filter(\.available)) { page in
            Button { selection.wrappedValue = page } label: {
                TablerIcon(page.icon, selected: selection.wrappedValue == page)
                    .font(Theme.body)
                    .modifier(SidebarIconTint(foreground: selection.wrappedValue == page ? Color.accentColor : Color.secondary))
                    .opacity(0.65)
                    .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                    .background(selection.wrappedValue == page ? Theme.selection : .clear, in: sidebarRowShape)
                    .contentShape(sidebarRowShape)
            }
            .buttonStyle(SidebarButtonStyle())
            .help(page.title)
        }
    }

    private var sidebarToggle: some View {
        let title = model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏"
        return Button {
            withAnimation(.snappy) { model.sidebarCollapsed.toggle() }
        } label: {
            PaneHeaderButtonLabel(title, systemImage: "sidebar.left")
        }
        .help(title)
    }

    private func source(_ workspace: WorkArea) -> some View {
        #if os(macOS)
        WorkspaceDragSource(tint: workspace.tint) {
            // 已经分离的，点一下把它的窗口提到前面
            if model.detached.contains(workspace.id) {
                openWindow(id: "workspace", value: workspace.id)
            } else {
                model.selectWorkspace(workspace.id)
            }
        } onDetach: { point in
            guard !workspace.isDraft, !model.detached.contains(workspace.id) else { return }
            // 独立窗口里的卡片和主窗口内容区一样大；窗口左上角放在指针左上方，指针落在标题那一条上。AppKit 的屏幕坐标 y 朝上
            let size = DetachedWorkspace.windowSize(content: model.contentSize, chrome: chrome)
            model.pendingPlacement = CGRect(x: point.x - 60, y: point.y + 16 - size.height, width: size.width, height: size.height)
            openWindow(id: "workspace", value: workspace.id)
        }
        #else
        Color.clear.contentShape(Rectangle())
            .onTapGesture { model.selectWorkspace(workspace.id) }
        #endif
    }
}
