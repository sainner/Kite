import SwiftUI

/// 点击与拖动只覆盖文字区，右侧操作保留独立的命中范围。改名时名字原地换成输入框，交互区拿到进入改名的闭包（双击用）。
struct WorkspaceRow<Interaction: View>: View {
    let workspace: WorkArea
    let current: Bool
    var detached = false
    /// 从这一行建了工作区之后；紧凑布局用它收起侧栏。
    var onSelect: () -> Void = {}
    @ViewBuilder var interaction: (_ rename: @escaping () -> Void) -> Interaction

    @Environment(AppModel.self) private var model
    @Environment(\.sidebarProjectTint) private var tint
    @Environment(\.sidebarHighlight) private var highlight
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.toast) private var toast
    @State private var renaming = false

    var body: some View {
        SidebarTreeRow(selected: current) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if renaming {
                        InlineNameField(label: "工作区名称", original: workspace.title) { name in
                            renaming = false
                            if let name { model.nameWorkspace(workspace, to: name, toast: toast) }
                        }
                    } else {
                        Text(workspace.title)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    let status = model.deviceStatus(model.connection(for: workspace))
                    if !status.ready {
                        Text(status.title).font(Theme.caption).foregroundStyle(.secondary)
                    } else if let note = gitNote {
                        Text(note.title).font(Theme.caption).foregroundStyle(.secondary).help(note.help)
                    }
                    Spacer(minLength: 0)
                    if detached { TablerIcon(.tablerAppWindow).font(Theme.caption) }
                }
                .frame(maxWidth: .infinity, minHeight: metrics.workspaceRowHeight)
                .contentShape(Rectangle())
                .overlay { if !renaming { interaction(beginRenaming) } }
                .contextMenu {
                    WorkspaceNameActions(workspace: workspace, rename: beginRenaming)
                    Divider()
                    WorkspaceGitActions(workspace: workspace, showsWorkspaceMenu: !InputMode.current.isTouch)
                    if !InputMode.current.isTouch {
                        Divider()
                        WorkspaceTransferMenu(workspace: workspace)
                    }
                }
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
                            Button("创建工作区") {
                                model.createWorkspace(in: workspace.remote.project.id, toast: toast); onSelect()
                            }
                            Divider()
                            WorkspaceNameActions(workspace: workspace, rename: beginRenaming)
                            Divider()
                            WorkspaceGitActions(workspace: workspace)
                            Divider()
                            WorkspaceTransferMenu(workspace: workspace)
                        } label: {
                            TablerIcon(.tablerDots)
                        }
                        .help("更多操作")
                        .accessibilityLabel("更多操作")
                    } else {
                        Button { model.archiveRequest = workspace } label: {
                            TablerIcon(.tablerArchive, size: 14)
                        }
                        .disabled(!model.isConnected(workspace) || model.lineArea?.id == workspace.id)
                        .help("归档工作区")
                        .accessibilityLabel("归档工作区")
                        Menu {
                            WorkspaceNameActions(workspace: workspace, rename: beginRenaming)
                            Divider()
                            WorkspaceGitActions(workspace: workspace, showsWorkspaceMenu: true)
                            Divider()
                            WorkspaceTransferMenu(workspace: workspace)
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
        .help("\(workspace.remote.machine.name) · \(workspace.remote.workspace.cwd)")
    }

    /// 工作机连着才进改名，免得改完才说连不上。
    private func beginRenaming() {
        if model.isConnected(workspace) { renaming = true }
    }

    /// 行尾的版本提示：PR 合并了提示归档，主线有新提交时提示落后几个。
    private var gitNote: (title: String, help: String)? {
        let info = workspace.remote.workspace
        if info.pullRequest?.state == "merged" { return ("PR 已合并", "PR 已经合并，可以归档这个工作区") }
        if let behind = info.behind, behind > 0 { return ("落后 \(behind)", "主线有 \(behind) 个新提交，右键选同步主线") }
        return nil
    }
}

/// 工作区名称的菜单项。「自动重命名」当场按代理的标题重起，并恢复之后的自动命名。
/// 指针设备双击名字改名；触屏另给「重命名」，iPhone 侧栏轻点就切过去收起，双击不了。
private struct WorkspaceNameActions: View {
    let workspace: WorkArea
    let rename: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast

    var body: some View {
        if InputMode.current.isTouch {
            Button("重命名", action: rename)
                .disabled(!model.isConnected(workspace))
        }
        Button("自动重命名") { model.nameWorkspace(workspace, to: nil, toast: toast) }
            .disabled(!model.isConnected(workspace))
    }
}

/// 工作区的手动命名与切回自动，见 kited 的 PUT /workspaces/:id/name。
private struct WorkspaceNaming: Encodable {
    let mode: String
    var name: String?
}

extension AppModel {
    /// 手动命名（之后工作机不再自动改名），name 为 nil 时切回自动并当场重起。新名字随工作区的变化推过来；
    /// 手动的先在本机按新名显示，改不成就退回并提示。
    func nameWorkspace(_ area: WorkArea, to name: String?, toast: ToastCenter?) {
        let request = name.map(area.renameLocally)
        Task {
            do {
                let client = try activeClient(in: area)
                let _: JSON = try await client.request("/workspaces/\(area.remote.workspace.id)/name", method: "PUT",
                                                       body: WorkspaceNaming(mode: name == nil ? "auto" : "manual", name: name), as: JSON.self)
            } catch {
                if let request { area.settleRename(request) }
                toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle")
            }
        }
    }
}

/// 项目内按所在的工作机分组（每台一个检出）；还没有工作区的项目也列出，没有分组。
struct WorkspaceGroup: Identifiable {
    struct Checkout: Identifiable {
        let id: String
        var workspaces: [WorkArea]
    }
    let id: String
    let title: String?
    var checkouts: [Checkout]

    var workspaces: [WorkArea] { checkouts.flatMap(\.workspaces) }
}

extension AppModel {
    /// 沿用工作区列表的顺序，项目和检出排在其中第一个工作区出现的位置。
    var workspaceGroups: [WorkspaceGroup] {
        var groups: [WorkspaceGroup] = []
        let line = lineArea?.id
        let label = projectLabels()
        for area in workspaces {
            // Line 的工作区从侧栏顶部的标志进，不列在项目一栏里
            guard area.id != line else { continue }
            let remote = area.remote
            if !groups.contains(where: { $0.id == remote.project.id }) {
                groups.append(.init(id: remote.project.id, title: label(remote.project), checkouts: []))
            }
            let group = groups.firstIndex { $0.id == remote.project.id }!
            // 每台工作机上一个项目只有一个检出，按工作机归组（新建中的还没有检出）
            if let checkout = groups[group].checkouts.firstIndex(where: { $0.id == remote.machine.id }) {
                groups[group].checkouts[checkout].workspaces.append(area)
            } else {
                groups[group].checkouts.append(.init(id: remote.machine.id, workspaces: [area]))
            }
        }
        // 登记了还没有工作区的项目排在后面
        let lineProject = lineArea?.remote.project.id
        for project in account.registeredProjects where project.id != lineProject && !groups.contains(where: { $0.id == project.id }) {
            groups.append(.init(id: project.id, title: label(project.project), checkouts: []))
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
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.toast) private var toast
    @State private var isExpanded = true
    /// 确认删除时的说明，点「删除项目…」时才算。
    @State private var deletion: String?

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
                // 点项目进项目页，展开收起用行尾的箭头
                Button {
                    model.selectProject(group.id)
                    onSelect()
                } label: {
                    SidebarListLabel(title: group.title ?? "项目", icon: ProjectIcon.symbol(for: model.account.projectAppearances[group.id]?.icon),
                                     selected: selected)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground))
                .contextMenu {
                    Button("创建工作区") { create() }
                    Divider()
                    // Line 所在的项目不能删，Line 在别的工作机上时接请求的那台查不到，这里也拦着
                    MenuButton("删除项目…", role: .destructive) { deletion = deletionMessage }
                        .disabled(model.availableWorkers.isEmpty || model.lineArea?.remote.project.id == group.id)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
                Button {
                    create()
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
                        let checkoutSelected = selectedIndex != nil
                        SidebarStickySection(enabled: checkoutSelected && checkouts.count > 1,
                                             topInset: metrics.rowHeight,
                                             headerHeight: checkouts.count > 1 ? metrics.subheaderHeight : 0) {
                            if checkouts.count > 1 {
                                SidebarSubheader(title: workspaces.first?.remote.machine.name ?? "工作机",
                                                 selected: checkoutSelected, help: "工作机", open: nil,
                                                 add: SidebarSubheaderAdd(help: "在这台工作机上创建工作区", label: "在这台工作机上创建工作区") {
                                                     create(on: checkout.id)
                                                 })
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
        .alert("删除项目", isPresented: Binding { deletion != nil } set: { if !$0 { deletion = nil } }, presenting: deletion) { _ in
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    /// 删除会丢掉 Kite 检出里没集成的改动：列出还没归档的工作区；没有远程的项目，各工作机的检出就是全部副本。
    private var deletionMessage: String {
        let open = group.workspaces.map(\.title)
        let remote = model.knownProjects.first { $0.id == group.id }?.remote
        var lines = ["「\(group.title ?? "项目")」会从各台工作机上移除：停止其中的线程，删除工作区、对话、项目专用的密钥和 Kite 的检出。你自己的文件夹不受影响。"]
        if !open.isEmpty { lines.append("这些工作区里没集成的改动会一起丢失：\(open.joined(separator: "、"))。") }
        if remote == nil { lines.append("这个项目没有远程，各工作机的检出就是它的全部副本，删除后只剩导入时的原文件夹。") }
        return lines.joined(separator: "\n\n")
    }

    /// 直接建，建好就选中它；紧凑布局随之收起侧栏。checkout 的 ID 就是所在工作机的 ID。
    private func create(on machineID: String? = nil) {
        model.createWorkspace(in: group.id, on: machineID, toast: toast)
        onSelect()
    }

    /// 删除成功后项目从列表里消失，提示由外层的 toast 显示。
    private func delete() {
        let toast = toast
        Task {
            do { try await model.deleteProject(group.id); toast?.show("已删除项目") }
            catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
        }
    }

}
