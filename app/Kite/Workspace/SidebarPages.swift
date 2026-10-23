import SwiftUI

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
        SidebarListRow(selected: selection == page) { foreground in
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

/// 资源库的侧栏：代理上下文像项目一栏里的项目一样，分类作小标题、各项作树状子项列在下面；其余各页一行。
private struct ExtensionSidebar: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ExtensionLibrary.allCases) { page in
                if page == .contexts { AgentContextSection(onSelect: onSelect) }
                else if page == .skills { SkillSection(onSelect: onSelect) }
                else { SidebarPageRow(selection: $model.extensionPage, page: page, onSelect: onSelect) }
            }
        }
        // 代理上下文页没打开时也要列出角色与模板。
        .task(id: model.connectionRevision) { try? await model.ensureRoles() }
        .task(id: model.connectionRevision) { try? await model.ensureContextTemplates() }
        .task(id: model.connectionRevision) { try? await model.ensureSkills() }
    }
}

/// Skill 页的分区：自建的和随 Kite 提供的各一组，改过没保存的标「未保存」，还没存过的标「新建」。
private struct SkillSection: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = [
            LibraryGroup(title: "自建", help: "打开自建的 skill", items: items(builtin: false),
                         add: SidebarSubheaderAdd(help: "新建 Skill", label: "新建 Skill", action: newSkill)),
            LibraryGroup(title: "随 Kite 提供", help: "打开随 Kite 提供的 skill", items: items(builtin: true)),
        ].filter { !$0.items.isEmpty || $0.add != nil }
        LibrarySection(page: .skills, groups: groups, current: model.skillItem, open: open)
    }

    private func items(builtin: Bool) -> [LibraryItem<String>] {
        let saved = (model.skillCatalog?.skills ?? []).filter { $0.isBuiltin == builtin }
            .map { LibraryItem(id: $0.id, title: $0.id, note: model.skillDraft($0.id) != nil ? "未保存" : nil) }
        guard !builtin else { return saved }
        return saved + model.skillDrafts.filter(\.isNew).map { LibraryItem(id: $0.id, title: $0.id, note: "新建") }
    }

    /// 打开 Skill 页；给了哪个就选中它，没给时显示上次选中的。
    private func open(_ name: String?) {
        model.extensionPage = .skills
        if let name { model.selectedSkill = name }
        onSelect()
    }

    private func newSkill() {
        model.newLibrarySkill()
        onSelect()
    }
}

/// 代理上下文的各类，改过没保存的项标「未保存」。还没有内容的类不列出。
private struct AgentContextSection: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = AgentContextCategory.allCases.map { category in
            LibraryGroup(title: category.title, help: "打开\(category.title)", items: items(category),
                         add: category == .role && model.roleCatalog?.defaultRole != nil
                            ? SidebarSubheaderAdd(help: "新建角色", label: "新建角色", action: newRole) : nil)
        }.filter { !$0.items.isEmpty }
        LibrarySection(page: .contexts, groups: groups, current: model.agentContextItem, open: open)
    }

    private func items(_ category: AgentContextCategory) -> [LibraryItem<AgentContextItem>] {
        if let kind = category.templateKind {
            return model.libraryTemplates(kind).map {
                LibraryItem(id: AgentContextItem(category: category, id: $0.id), title: $0.title.isEmpty ? "未命名模板" : $0.title,
                            note: model.templateDraft($0.id) != nil ? "未保存" : nil)
            }
        }
        return model.libraryRoles.map {
            LibraryItem(id: AgentContextItem(category: category, id: $0.id), title: $0.title.isEmpty ? "未命名角色" : $0.title,
                        note: model.roleUnsaved($0.id) ? "未保存" : nil)
        }
    }

    /// 打开代理上下文页；给了哪项就选中它，没给时显示上次选中的。
    private func open(_ item: AgentContextItem?) {
        model.extensionPage = .contexts
        if let item { model.selectedAgentContext = item }
        onSelect()
    }

    private func newRole() {
        model.newLibraryRole()
        onSelect()
    }
}

/// 资源库侧栏里分组列出的一项；note 是名字后面的灰字（「未保存」「新建」）。
private struct LibraryItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let note: String?
}

/// 资源库侧栏里的一组：小标题点开第一项，add 是小标题上的新建按钮。
private struct LibraryGroup<ID: Hashable>: Identifiable {
    let title: String
    /// 小标题的提示。
    let help: String
    let items: [LibraryItem<ID>]
    var add: SidebarSubheaderAdd? = nil
    var id: String { title }
}

/// 资源库侧栏里分组的一页（代理上下文、Skill），像项目一栏里的项目一样：页名一行可收起，各组作小标题、各项作树状子项列在下面。
/// current 是这一页选中的项，页没打开时不标；open 给 nil 是只打开这一页。
private struct LibrarySection<ID: Hashable>: View {
    let page: ExtensionLibrary
    let groups: [LibraryGroup<ID>]
    let current: ID?
    let open: (ID?) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarMetrics) private var metrics
    @State private var expanded = true

    var body: some View {
        let selected = model.extensionPage == page
        let current = selected ? current : nil
        SidebarStickySection(headerHeight: metrics.rowHeight) {
            SidebarListRow(selected: selected) { foreground in
                Button { open(nil) } label: {
                    SidebarListLabel(title: page.title, icon: page.icon, selected: selected)
                }
                .buttonStyle(SidebarButtonStyle(foreground: foreground))
                .accessibilityAddTraits(selected ? .isSelected : [])
                SidebarDisclosureButton(title: page.title, noun: page.title, isExpanded: $expanded, foreground: foreground)
            }
        } content: {
            if expanded {
                SidebarSubgroups(linked: true) {
                    ForEach(groups) { group in
                        let selectedIndex = group.items.firstIndex { $0.id == current }
                        SidebarStickySection(enabled: selectedIndex != nil, topInset: metrics.rowHeight, headerHeight: metrics.subheaderHeight) {
                            SidebarSubheader(title: group.title, selected: selectedIndex != nil, help: group.help,
                                             open: group.items.first.map { first in { open(first.id) } }, add: group.add)
                        } content: {
                            SidebarTreeRows(items: group.items, selectedIndex: selectedIndex, hasCheckout: true) { item in
                                SidebarTreeRow(selected: item.id == current) {
                                    Button { open(item.id) } label: {
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .lineLimit(1).truncationMode(.middle)
                                            if let note = item.note {
                                                Text(note).font(Theme.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: metrics.workspaceRowHeight)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.pointingPlain)
                                }
                            }
                        }
                        .zIndex(selectedIndex != nil ? 1 : 0)
                    }
                }
            }
        }
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
struct DeviceStatusIcon: View {
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

/// 每台工作机下并列账号、文件，与项目一栏共用吸顶分区和树状子项。状态色只用在设备图标上，文字与选中沿用侧栏默认颜色。
private struct DeviceSidebar: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarMetrics) private var metrics
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            deviceList("工作机", devices: model.account.devices.filter { $0.role == "worker" })
            deviceList("控制端", devices: model.account.devices.filter { $0.role != "worker" })
        }
    }

    private func deviceList(_ title: String, devices: [AccountDevice]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
                .padding(.horizontal, metrics.itemInset)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(devices) { device in
                let connection = model.connections.values.first { $0.deviceID == device.id }
                let selected = connection.map { model.accountWorker?.id == $0.id } ?? false
                let isExpanded = expanded(device.id)
                SidebarStickySection(headerHeight: metrics.rowHeight) {
                    SidebarListRow(selected: selected) { foreground in
                        DeviceStatusIcon(device: device, connection: connection)
                            .frame(width: metrics.labelExtent)
                        if connection != nil {
                            Button { isExpanded.wrappedValue.toggle() } label: {
                                SidebarListLabel(title: device.name, selected: selected).padding(.leading, 8)
                            }
                            .buttonStyle(SidebarButtonStyle(foreground: foreground))
                        } else {
                            SidebarListLabel(title: device.name, selected: selected).padding(.leading, 8)
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
                    .padding(.horizontal, metrics.itemInset)
            }
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
            SidebarTreeRow(selected: selected) {
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
                        .frame(maxWidth: .infinity, minHeight: metrics.workspaceRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointingPlain)
                    if page == .accounts {
                        refreshAccounts(connection, foreground: selected ? .accentColor : .primary)
                            .modifier(SidebarRevealedControl(pinned: connection.readingModelAccounts))
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
        .buttonStyle(SidebarButtonStyle(foreground: foreground, size: metrics.control))
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
            case .contexts: AgentContextLibrary()
            case .credentials: TilesLayer(group: .credentials(model.credentialWindows))
            case .skills: SkillLibrary()
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
    case credentials, plugins, contexts, skills

    var id: Self { self }

    var title: String {
        switch self {
        case .plugins: "插件"
        case .contexts: "代理上下文"
        case .credentials: "凭据"
        case .skills: "Skill"
        }
    }

    var icon: TablerSymbol {
        switch self {
        case .plugins: .puzzle
        case .contexts: .fileText
        case .credentials: .key
        case .skills: .sparkles
        }
    }

    var available: Bool { true }
}
