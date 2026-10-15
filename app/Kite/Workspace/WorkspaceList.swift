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
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        SidebarTreeRow(selected: current) {
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
                .frame(maxWidth: .infinity, minHeight: metrics.workspaceRowHeight)
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
                                               size: metrics.workspaceRowHeight))
                .modifier(SidebarRevealedControl())
            }
        }
        .help(workspace.remote.map { "\($0.machine.name) · \($0.workspace.cwd)" } ?? workspace.title)
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
        let line = lineArea?.id
        for area in workspaces {
            // Line 的工作区从侧栏顶部的标志进，不列在空间里
            guard let remote = area.remote, area.id != line else { continue }
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
    @Environment(\.sidebarMetrics) private var metrics
    @State private var isExpanded = true
    @State private var hoveringIcon = false

    private var theme: ProjectTheme {
        ProjectTheme(rawValue: model.account.projectAppearances[group.id]?.color ?? "primary") ?? .primary
    }
    private var tint: Color { theme.color }
    private var highlight: Color { theme == .primary ? .accentColor : tint }

    var body: some View {
        let checkouts = group.checkouts
        let current = model.current?.id
        let selected = model.selectedProjectID == group.id || group.workspaces.contains { $0.id == current }
        SidebarStickySection(headerHeight: metrics.rowHeight) {
            SidebarListRow(selected: selected) { foreground in
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
                        .frame(width: metrics.labelExtent, height: metrics.rowHeight)
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
                .buttonStyle(SidebarButtonStyle(foreground: foreground, size: metrics.control))
                .help("创建工作区")
                .accessibilityLabel("在\(group.title ?? "项目")中创建工作区")
                .modifier(SidebarRevealedControl())
                SidebarDisclosureButton(title: group.title ?? "项目", noun: "项目", isExpanded: $isExpanded, foreground: foreground)
            }
        } content: {
            if isExpanded {
                SidebarSubgroups(linked: checkouts.count > 1) {
                    ForEach(checkouts) { checkout in
                        let workspaces = checkout.workspaces
                        let selectedIndex = workspaces.firstIndex { $0.id == current }
                        let checkoutSelected = selectedIndex != nil || (current != nil && checkout.root?.id == current)
                        SidebarStickySection(enabled: checkoutSelected && checkouts.count > 1,
                                             topInset: metrics.rowHeight,
                                             headerHeight: checkouts.count > 1 ? metrics.subheaderHeight : 0) {
                            if checkouts.count > 1 {
                                SidebarSubheader(title: (checkout.root ?? workspaces.first)?.remote?.machine.name ?? "工作机",
                                                 selected: checkoutSelected, help: "打开现场",
                                                 open: checkout.root.map { root in { selectRoot(root) } },
                                                 add: SidebarSubheaderAdd(help: "创建工作区", label: "在此检出中创建工作区") {
                                                     model.newWorkspace = .checkout(checkout.id)
                                                 }) {
                                    if let root = checkout.root { WorkspaceGitActions(workspace: root) }
                                }
                            }
                        } content: {
                            SidebarTreeRows(items: workspaces, selectedIndex: selectedIndex,
                                            hasCheckout: checkouts.count > 1, tint: tint, row: row)
                        }
                        .zIndex(checkoutSelected ? 1 : 0)
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
