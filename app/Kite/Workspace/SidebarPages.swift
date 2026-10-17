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
                else { SidebarPageRow(selection: $model.extensionPage, page: page, onSelect: onSelect) }
            }
        }
        // 代理上下文页没打开时也要列出角色与模板。
        .task(id: model.connectionRevision) { try? await model.ensureRoles() }
        .task(id: model.connectionRevision) { try? await model.ensureContextTemplates() }
    }
}

/// 代理上下文的各类，改过没保存的项标「未保存」。还没有内容的类不列出。
private struct AgentContextSection: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarMetrics) private var metrics
    @State private var expanded = true

    private struct Item: Identifiable {
        let id: String
        let title: String
        let unsaved: Bool
    }

    var body: some View {
        let page = ExtensionLibrary.contexts
        let selected = model.extensionPage == page
        let current = selected ? model.agentContextItem : nil
        let categories = AgentContextCategory.allCases.map { ($0, items($0)) }.filter { !$0.1.isEmpty }
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
                    ForEach(categories, id: \.0) { category, items in
                        let currentID = current?.category == category ? current?.id : nil
                        let selectedIndex = items.firstIndex { $0.id == currentID }
                        SidebarStickySection(enabled: selectedIndex != nil, topInset: metrics.rowHeight,
                                             headerHeight: metrics.subheaderHeight) {
                            SidebarSubheader(title: category.title, selected: selectedIndex != nil, help: "打开\(category.title)",
                                             open: items.first.map { first in { open(AgentContextItem(category: category, id: first.id)) } },
                                             add: category == .role && model.roleCatalog?.defaultRole != nil
                                                ? SidebarSubheaderAdd(help: "新建角色", label: "新建角色", action: newRole) : nil)
                        } content: {
                            SidebarTreeRows(items: items, selectedIndex: selectedIndex, hasCheckout: true) { item in
                                SidebarTreeRow(selected: item.id == currentID) {
                                    Button { open(AgentContextItem(category: category, id: item.id)) } label: {
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .lineLimit(1).truncationMode(.middle)
                                            if item.unsaved {
                                                Text("未保存").font(Theme.caption).foregroundStyle(.secondary)
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

    private func items(_ category: AgentContextCategory) -> [Item] {
        if let kind = category.templateKind {
            return model.libraryTemplates(kind).map {
                Item(id: $0.id, title: $0.title.isEmpty ? "未命名模板" : $0.title, unsaved: model.templateDraft($0.id) != nil)
            }
        }
        return model.libraryRoles.map {
            Item(id: $0.id, title: $0.title.isEmpty ? "未命名角色" : $0.title, unsaved: model.roleUnsaved($0.id))
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
    case plugins, contexts, credentials, skills

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

    var available: Bool { self != .skills }
}
