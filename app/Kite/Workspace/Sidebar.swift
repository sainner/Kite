import SwiftUI

/// 点击与拖动只覆盖文字区，右侧操作保留独立的命中范围。
struct WorkspaceRow<Interaction: View>: View {
    let workspace: WorkArea
    let current: Bool
    var detached = false
    @ViewBuilder var interaction: () -> Interaction

    @Environment(AppModel.self) private var model
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(workspace.title).font(Theme.sidebarWorkspace)
                    .fontWeight(current ? .bold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                if !model.isConnected(workspace) {
                    Text("离线").font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if detached { Image(systemName: "macwindow").font(Theme.caption) }
            }
            .frame(maxWidth: .infinity, minHeight: InputMode.current.workspaceRowHeight)
            .contentShape(Rectangle())
            .overlay { interaction() }
            .contextMenu { WorkspaceGitActions(workspace: workspace, showsWorkspaceMenu: !InputMode.current.isTouch) }
            HStack(spacing: 0) {
                #if os(macOS)
                Button { model.archiveRequest = workspace } label: {
                    Image(systemName: "archivebox")
                }
                .disabled(workspace.remote?.workspace.kind != .worktree || !model.isConnected(workspace))
                .help("归档工作区")
                .accessibilityLabel("归档工作区")
                Menu {
                    WorkspaceGitActions(workspace: workspace, showsWorkspaceMenu: true)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help("更多操作")
                .accessibilityLabel("更多操作")
                #else
                Menu {
                    WorkspaceGitActions(workspace: workspace)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
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
                    Image(systemName: "ellipsis")
                }
                .help("更多操作")
                .accessibilityLabel("更多操作")
                #endif
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(SidebarButtonStyle(foreground: tint,
                                           size: InputMode.current.workspaceRowHeight))
            .opacity(current || InputMode.current.revealsControls(hovered: hovered) ? 1 : 0)
            .allowsHitTesting(current || InputMode.current.revealsControls(hovered: hovered))
            .accessibilityHidden(!current && !InputMode.current.revealsControls(hovered: hovered))
        }
        .foregroundStyle(current && !InputMode.current.isTouch ? highlight : tint.opacity(current || hovered ? 1 : 0.78))
        .fontWeight(current && InputMode.current.isTouch ? .medium : .regular)
        .padding(.trailing, 4)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(current ? .isSelected : [])
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
        #if os(macOS)
        configuration.label
            .font(Theme.body)
            .frame(width: size, height: size)
            .foregroundStyle(hovered && isEnabled ? highlight : foreground)
            .environment(\.sidebarButtonHovered, hovered && isEnabled)
            .contentShape(Capsule())
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .onHover { hovered = $0 }
            .clickPointer()
        #else
        if let size {
            PaneButtonStyle(foreground: foreground, size: size).makeBody(configuration: configuration)
        } else {
            configuration.label
                .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
                .clickPointer()
        }
        #endif
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
    var onSelectProject: () -> Void = {}
    @ViewBuilder let row: (WorkArea) -> Row
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.workspaceGroups) { group in
                WorkspaceProjectSection(group: group, onSelect: onSelectProject, row: row)
            }
        }
        #if os(iOS)
        .padding(.top, 12)
        #endif
        .padding(.bottom, 12)
    }
}

private struct WorkspaceProjectSection<Row: View>: View {
    let group: WorkspaceGroup
    var onSelect: () -> Void = {}
    @ViewBuilder let row: (WorkArea) -> Row
    @Environment(AppModel.self) private var model
    @State private var hovered = false
    @State private var isExpanded = true
    @State private var hoveredCheckoutID: String?
    @State private var editingAppearance = false

    private var theme: ProjectTheme {
        ProjectTheme(rawValue: model.account.projectAppearances[group.id]?.color ?? "primary") ?? .primary
    }
    private var tint: Color { theme.color }
    private var highlight: Color { theme == .primary ? .accentColor : tint }
    private var treeColor: Color { tint.mix(with: Theme.background, by: 0.8) }
    private var checkoutLinkColor: Color { tint.mix(with: Theme.background, by: 0.92) }

    var body: some View {
        let checkouts = group.checkouts
        let current = InputMode.current.isTouch ? nil : model.current?.id
        let selected = model.selectedProjectID == group.id || group.workspaces.contains { $0.id == current }
        let weight: Font.Weight = selected ? .bold : .semibold
        let foreground = selected || (!InputMode.current.isTouch && hovered) ? highlight : tint
        let textInset: CGFloat = Metrics.sidebarItemInset + 8 + InputMode.current.labelExtent
        let treeInset: CGFloat = Metrics.sidebarItemInset + InputMode.current.labelExtent / 2
        SidebarStickySection(headerHeight: InputMode.current.rowHeight) {
            HStack(spacing: 0) {
                #if os(macOS)
                Button { editingAppearance = true } label: {
                    Image(systemName: model.account.projectAppearances[group.id]?.icon ?? "folder")
                        .font(Theme.sidebarHeading.weight(weight))
                        .frame(width: InputMode.current.labelExtent, height: InputMode.current.rowHeight)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground))
                .help("编辑图标与主题颜色")
                .accessibilityLabel("编辑\(group.title ?? "项目")的图标与主题颜色")
                .popover(isPresented: $editingAppearance) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("项目外观").font(Theme.body)
                        ProjectAppearanceOptions(projectID: group.id)
                    }
                    .padding(12)
                    .frame(width: 232)
                }
                #endif
                Button {
                    model.selectProject(group.id)
                    onSelect()
                } label: {
                    HStack(spacing: 8) {
                        #if os(iOS)
                        Image(systemName: model.account.projectAppearances[group.id]?.icon ?? "folder")
                            .font(Theme.sidebarHeading.weight(weight))
                            .frame(width: InputMode.current.labelExtent)
                        #endif
                        Text(group.title ?? "项目")
                            .font(Theme.sidebarHeading.weight(weight)).lineLimit(1)
                            .foregroundStyle(foreground)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, InputMode.current.isTouch ? 0 : 8)
                    .frame(height: InputMode.current.rowHeight)
                    .contentShape(Capsule())
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground))
                .help("项目配置")
                .accessibilityAddTraits(selected ? .isSelected : [])
                Button {
                    if let checkout = group.checkouts.first(where: { checkout in
                        (checkout.root.map { model.isConnected($0) } ?? false)
                            || checkout.workspaces.contains(where: { model.isConnected($0) })
                    }) ?? group.checkouts.first {
                        model.newWorkspace = .checkout(checkout.id)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground, size: InputMode.current.isTouch ? Metrics.paneButton : InputMode.current.workspaceRowHeight))
                .help("创建工作区")
                .accessibilityLabel("在\(group.title ?? "项目")中创建工作区")
                .opacity(InputMode.current.revealsControls(hovered: hovered) ? 1 : 0)
                .allowsHitTesting(InputMode.current.revealsControls(hovered: hovered))
                .accessibilityHidden(!InputMode.current.revealsControls(hovered: hovered))
                #if os(macOS)
                Button { isExpanded.toggle() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground, size: Metrics.paneButton))
                .help(isExpanded ? "收起项目" : "展开项目")
                .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(group.title ?? "项目")")
                #endif
            }
            .foregroundStyle(foreground)
            .padding(.leading, Metrics.sidebarItemInset)
            .padding(.trailing, InputMode.current.isTouch ? 8 : 4)
            .frame(height: InputMode.current.rowHeight)
            .background(selected ? highlight.opacity(0.12) : tint.opacity(hovered ? 0.06 : 0), in: Capsule())
            .onHover { hovered = $0 }
        } content: {
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(checkouts) { checkout in
                        let workspaces = [checkout.root].compactMap { $0 } + checkout.workspaces
                        let selectedIndex = workspaces.firstIndex { $0.id == current }
                        SidebarStickySection(enabled: selectedIndex != nil && checkouts.count > 1,
                                             topInset: InputMode.current.rowHeight,
                                             headerHeight: checkouts.count > 1 ? 8 + InputMode.current.workspaceRowHeight : 0) {
                            if checkouts.count > 1 {
                                HStack(spacing: 8) {
                                    Circle().fill(selectedIndex == nil ? tint.mix(with: Theme.background, by: 0.6) : highlight)
                                        .frame(width: selectedIndex == nil ? 6 : 8, height: selectedIndex == nil ? 6 : 8)
                                        .frame(width: InputMode.current.labelExtent)
                                    Text(workspaces.first?.remote?.machine.name ?? "工作机").font(Theme.sidebarCheckout)
                                        .fontWeight(selectedIndex == nil ? .regular : .bold)
                                        .foregroundStyle(selectedIndex == nil ? tint.opacity(0.5) : highlight).lineLimit(1)
                                    Spacer(minLength: 0)
                                    #if os(macOS)
                                    Button { model.newWorkspace = .checkout(checkout.id) } label: {
                                        Image(systemName: "plus")
                                    }
                                    .buttonStyle(SidebarButtonStyle(foreground: selectedIndex == nil ? tint : highlight, size: InputMode.current.workspaceRowHeight))
                                    .help("创建工作区")
                                    .accessibilityLabel("在此检出中创建工作区")
                                    .opacity(hoveredCheckoutID == checkout.id ? 1 : 0)
                                    .allowsHitTesting(hoveredCheckoutID == checkout.id)
                                    .accessibilityHidden(hoveredCheckoutID != checkout.id)
                                    #endif
                                }
                                .padding(.leading, Metrics.sidebarItemInset)
                                .padding(.trailing, InputMode.current.isTouch ? 0 : 4)
                                .frame(height: InputMode.current.workspaceRowHeight)
                                .accessibilityAddTraits(selectedIndex == nil ? [] : .isSelected)
                                .onHover { hovering in
                                    if hovering { hoveredCheckoutID = checkout.id }
                                    else if hoveredCheckoutID == checkout.id { hoveredCheckoutID = nil }
                                }
                                .padding(.top, 8)
                            }
                        } content: {
                            SidebarWorkspaceRows(workspaces: workspaces, selectedIndex: selectedIndex,
                                                 hasCheckout: checkouts.count > 1, color: treeColor,
                                                 textInset: textInset, treeInset: treeInset, row: row)
                        }
                        .zIndex(selectedIndex != nil ? 1 : 0)
                    }
                }
                .background(alignment: .leading) {
                    if checkouts.count > 1 {
                        Rectangle().fill(checkoutLinkColor).frame(width: 1)
                            .padding(.leading, treeInset - 0.5)
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
}

/// 普通行共用裁切，选中行独立吸顶；占位保留列表高度，连接线随选中行置于最上层。
private struct SidebarWorkspaceRows<Row: View>: View {
    let workspaces: [WorkArea]
    let selectedIndex: Int?
    let hasCheckout: Bool
    let color: Color
    let textInset: CGFloat
    let treeInset: CGFloat
    @ViewBuilder let row: (WorkArea) -> Row
    @Environment(\.sidebarStickyRegions) private var regions

    private var selectedRegion: SidebarStickyRegion? {
        guard let selectedIndex, let checkout = regions.last else { return nil }
        let rowHeight = InputMode.current.workspaceRowHeight
        return SidebarStickyRegion(space: checkout.space,
                                   start: checkout.height + CGFloat(selectedIndex) * rowHeight,
                                   height: rowHeight,
                                   topInset: InputMode.current.rowHeight + checkout.height)
    }

    var body: some View {
        let rowHeight = InputMode.current.workspaceRowHeight
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                if index == selectedIndex {
                    Color.clear.frame(height: rowHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    connectedRow(workspace, index: index, selected: false)
                }
            }
        }
        .modifier(SidebarScrollingClip(topOverflow: hasCheckout ? rowHeight / 2 : 0,
                                      additionalRegions: selectedRegion.map { [$0] } ?? []))
        .overlay(alignment: .topLeading) {
            if let selectedIndex, let selectedRegion {
                connectedRow(workspaces[selectedIndex], index: selectedIndex, selected: true)
                    .modifier(SidebarStickyHeader(region: selectedRegion,
                                                  topOverflow: CGFloat(selectedIndex + 1) * rowHeight))
                    .padding(.top, CGFloat(selectedIndex) * rowHeight)
            }
        }
    }

    private func connectedRow(_ workspace: WorkArea, index: Int, selected: Bool) -> some View {
        row(workspace)
            .padding(.leading, textInset)
            .background(alignment: .leading) {
                SidebarWorkspaceLink(index: index, hasCheckout: hasCheckout,
                                     checkoutSelected: selectedIndex != nil,
                                     selected: selected, color: color)
                    .frame(width: textInset - treeInset + 6)
                    .padding(.leading, treeInset)
                    .allowsHitTesting(false)
            }
    }
}

/// 每行直接连接所属标题，固定后缩短到吸顶标题；整条连接随该行一起参与层叠与裁切。
private struct SidebarWorkspaceLink: View {
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
        case .workspaces: "工作空间"
        case .drive: "设备与文件"
        case .extensions: "自定义资产"
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

    /// 导航行尾的数字：工作区数量，设备与文件一栏是在线的机器数。
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
    var symbol: String { get }
    var available: Bool { get }
}

/// 侧栏里的一行入口，与工作区行同高；Mac 悬停时图标和标题一起变色，并显示淡色背景反馈。
private struct SidebarRowStyle: ButtonStyle {
    var selected = false
    var capsule = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let hovering = hovered && isEnabled
        let highlight = Color.gray.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.2 : hovering ? 0.1 : 0)
        configuration.label
            .environment(\.sidebarButtonHovered, !InputMode.current.isTouch && hovered && isEnabled && !selected)
            .padding(.leading, Metrics.sidebarItemInset)
            // 胶囊行的行尾数字自己占一个与行同高的方格，见 SidebarRowLabel
            .padding(.trailing, capsule ? 0 : 8)
            .frame(height: InputMode.current.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if capsule {
                    Capsule().fill(selected ? Color.accentColor : highlight)
                        .overlay {
                            Capsule().fill(Color.black.opacity(!selected ? 0 : configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(highlight)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .clickPointer()
    }
}

/// 一行入口的内容：图标列、标题，没接通的在行尾注明。
private struct SidebarRowLabel: View {
    let title: String
    let systemImage: String
    var note: String?
    /// 行尾注释居中在与行同高的方格里，与胶囊的圆头同心。
    var concentricNote = false
    /// 选中时图标换实心，白字配合主题色胶囊。
    var selected = false
    var weight: Font.Weight = .bold

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(Theme.sidebarHeading.weight(weight))
                .symbolVariant(selected ? .fill : .none)
                .frame(width: InputMode.current.labelExtent)
            Text(title).font(Theme.sidebarHeading.weight(weight)).lineLimit(1)
            Spacer(minLength: 0)
            if let note {
                Text(note).font(Theme.caption).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .frame(minWidth: concentricNote ? InputMode.current.rowHeight : nil)
            }
        }
        .modifier(SidebarIconTint(foreground: selected ? Color.white : Color.primary, allowsHover: !selected))
    }
}

/// 一级导航：标志栏下面一列全宽按钮，选中项用主题色胶囊配白字；没接通的置灰。两端相同，iPhone 放在侧栏抽屉顶部。
/// 设置不在这里，入口是用户栏末尾的设置按钮。
/// 收起的侧栏里只留图标竖着排。
struct SidebarNavigation: View {
    /// 收起的图标栏里只要图标。
    var iconsOnly = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: iconsOnly ? 8 : 0) {
            ForEach(SidebarSection.allCases.filter(\.navigable)) { section in
                let selected = model.sidebarSection == section
                let button = Button {
                    withAnimation(.snappy) { model.sidebarSection = section }
                } label: {
                    if iconsOnly {
                        Image(systemName: section.symbol)
                            .font(Theme.sidebarHeading)
                            .symbolVariant(selected ? .fill : .none)
                            .modifier(SidebarIconTint(foreground: selected ? Color.white : Color.primary, allowsHover: !selected))
                            .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                            .background(selected ? Color.accentColor : .clear, in: Capsule())
                            .contentShape(Rectangle())
                            .opacity(section.available ? 1 : 0.45)
                    } else {
                        SidebarRowLabel(title: section.title, systemImage: section.symbol, note: section.count(in: model).map(String.init),
                                        concentricNote: true, selected: selected)
                    }
                }
                .disabled(!section.available)
                .help(section.available ? section.title : "\(section.title)（尚未接通）")
                .accessibilityAddTraits(selected ? .isSelected : [])
                if iconsOnly { button.buttonStyle(SidebarButtonStyle()) }
                else { button.buttonStyle(SidebarRowStyle(selected: selected, capsule: true)) }
            }
        }
    }
}

/// 侧栏底部的用户栏：左边头像和账号信息，末尾的按钮进入设置。
struct SidebarUserBar: View {
    @Environment(AppModel.self) private var model

    private var user: AccountUser? { model.account.user }

    var body: some View {
        HStack(spacing: 10) {
            SidebarAvatar()
            VStack(alignment: .leading, spacing: 6) {
                Text(user?.email ?? "未登录")
                    .font(Theme.body).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if model.subscriptionQuotas.isEmpty {
                        chip { Text("无账号") }
                            .help("没有关联的模型订阅账号")
                    } else {
                        ForEach(model.subscriptionQuotas) { quota($0) }
                    }
                }
            }
            Spacer(minLength: 0)
            SidebarSettingsButton()
        }
        // 左右贴着侧栏边缘，底边与旁边窗口的底边对齐
        .padding(.top, 10)
    }

    /// 圆环是本周剩余的比例，不到两成时换成警示色。
    private func quota(_ quota: SubscriptionQuota) -> some View {
        let percent = quota.remaining.formatted(.percent.precision(.fractionLength(0)))
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
        .help("\(quota.provider) 账号本周剩余 \(percent)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(quota.provider) 本周剩余 \(percent)")
    }

    private func chip(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 3) { content() }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
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

/// 一级栏的侧栏：各页一行，选中的一页在内容区打开；没接通的置灰。
struct SidebarPageList<Page: SidebarPage>: View {
    @Binding var selection: Page
    /// 选了一页之后；紧凑布局用它收起侧栏。
    var onSelect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Page.allCases) { page in
                Button {
                    selection = page
                    onSelect()
                } label: {
                    SidebarRowLabel(title: page.title, systemImage: page.symbol, note: page.available ? nil : "尚未接通")
                }
                .disabled(!page.available)
                .background(selection == page ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(SidebarRowStyle())
    }
}

/// 一级栏的侧栏内容：工作区以外的栏列出各页。
struct SectionPages: View {
    var onSelect: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        switch model.sidebarSection {
        case .drive: SidebarPageList(selection: $model.drivePage, onSelect: onSelect)
        case .extensions: SidebarPageList(selection: $model.extensionPage, onSelect: onSelect)
        case .settings: SidebarPageList(selection: $model.settingsPage, onSelect: onSelect)
        case .workspaces: EmptyView()
        }
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

/// 自定义资产一栏的内容区：侧栏选中的那一页。
struct ExtensionContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.extensionPage {
            case .plugins: PluginLibrary()
            case .contexts: ContextTemplateLibrary()
            case .skills: EmptyView()
            }
        }
        .id("\(model.extensionPage.rawValue):\(model.connectionRevision)")
    }
}

/// 自定义资产一栏里的各页。
nonisolated enum ExtensionLibrary: String, SidebarPage {
    case plugins, contexts, skills

    var id: Self { self }

    var title: String {
        switch self {
        case .plugins: "插件"
        case .contexts: "上下文模板"
        case .skills: "Skill"
        }
    }

    var symbol: String {
        switch self {
        case .plugins: "puzzlepiece.extension"
        case .contexts: "text.document"
        case .skills: "sparkles"
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

/// 标志栏：Kite 字标，右端一组标题栏玻璃按钮，搜索在前，宽屏后面跟侧边栏按钮。字标与侧栏行的文字左对齐，与按钮底对齐。
/// 两端都有，iPhone 放在侧栏抽屉顶部。搜索展开时用输入框替换侧栏按钮。
struct SidebarLogoBar<Buttons: View>: View {
    @ViewBuilder var buttons: Buttons
    @State private var searchPresented = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var glass

    var body: some View {
        // Mac 上字标与按钮底部对齐，iPhone 上垂直居中
        #if os(iOS)
        let alignment = VerticalAlignment.center
        #else
        let alignment = VerticalAlignment.bottom
        #endif
        return HStack(alignment: alignment, spacing: Metrics.paneButtonGap) {
            Text("Kite").font(Theme.wordmark)
            controlPanel
                #if os(macOS)
                .padding(.leading, searchPresented ? Metrics.padding : 0)
                #endif
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 8)
        .frame(height: Metrics.paneHeaderButton)
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
            logoBar.padding(.bottom, Metrics.gap)
            // 标志栏下面是一级导航，再下面是当前一栏的列表
            SidebarNavigation()
                .padding(.bottom, 8)
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
            SidebarNavigation(iconsOnly: true)
            Capsule().fill(Theme.rule).frame(width: 16, height: 2)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    switch model.sidebarSection {
                    case .drive: railPages(selection: $model.drivePage)
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
                                .background(current == workspace.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
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

    /// 收起时工作区以外的栏只列各页图标，点一下切页。
    private func railPages<Page: SidebarPage>(selection: Binding<Page>) -> some View {
        ForEach(Page.allCases.filter(\.available)) { page in
            Button { selection.wrappedValue = page } label: {
                Image(systemName: page.symbol)
                    .font(Theme.body)
                    .modifier(SidebarIconTint(foreground: selection.wrappedValue == page ? Color.accentColor : Color.secondary))
                    .frame(width: max(36, Metrics.paneButton), height: max(36, Metrics.paneButton))
                    .background(selection.wrappedValue == page ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
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
