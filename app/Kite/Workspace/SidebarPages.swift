import SwiftUI
import UniformTypeIdentifiers

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

/// 资源库的侧栏：插件、代理上下文与 Skill 像项目一栏里的项目一样，分类作小标题、各项作树状子项列在下面；凭据一行。
private struct ExtensionSidebar: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ExtensionLibrary.allCases) { page in
                if page == .contexts { AgentContextSection(onSelect: onSelect) }
                else if page == .skills { SkillSection(onSelect: onSelect) }
                else if page == .plugins { PluginSection(onSelect: onSelect) }
                else { SidebarPageRow(selection: $model.extensionPage, page: page, onSelect: onSelect) }
            }
        }
        // 各页没打开时也要列出角色、模板、skill 与插件。
        .task(id: model.connectionRevision) { try? await model.ensureRoles() }
        .task(id: model.connectionRevision) { try? await model.ensureContextTemplates() }
        .task(id: model.connectionRevision) { try? await model.ensureSkills() }
        .task(id: model.connectionRevision) { try? await model.ensureDefinitions() }
    }
}

/// 插件页的分区：自定义的（Bun 插件包）和内置的各一组。自定义一组的小标题上导入插件：
/// 选好文件先成「待安装」的一项排在这组末尾，在它的窗口里保存到资源库，同 Skill 的新建。
private struct PluginSection: View {
    var onSelect: () -> Void
    @Environment(AppModel.self) private var model
    @State private var importing = false
    /// 点导入时连着的工作机，待安装的插件包经它保存。
    @State private var importClient: KitedClient?
    @State private var failure: String?

    var body: some View {
        let groups = [
            LibraryGroup(title: "自定义", help: "打开自定义插件", items: customItems,
                         add: SidebarSubheaderAdd(help: "导入插件", label: "导入插件", action: startImport)),
            LibraryGroup(title: "内置", help: "打开内置插件",
                         items: model.builtinPlugins.map { LibraryItem(id: PluginItem.definition($0.id), title: $0.title, note: nil) }),
        ].filter { !$0.items.isEmpty || $0.add != nil }
        LibrarySection(page: .plugins, groups: groups, current: model.pluginItem, open: open)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard let client = importClient else { return }
                importClient = nil
                Task {
                    do {
                        try await model.importPlugin(result.get(), via: client)
                        onSelect()
                    } catch { failure = error.localizedDescription }
                }
            }
            .alert("没能导入插件", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }

    private var customItems: [LibraryItem<PluginItem>] {
        let saved = model.customPlugins.map {
            LibraryItem(id: PluginItem.definition($0.id), title: $0.title, note: nil)
        }
        guard let pending = model.pendingPlugin else { return saved }
        return saved + [LibraryItem(id: .pending, title: pending.package.preview.title, note: "待安装")]
    }

    /// 打开插件页；给了哪项就选中它，没给时显示上次选中的。
    private func open(_ item: PluginItem?) {
        model.extensionPage = .plugins
        if let item { model.selectedPlugin = item }
        onSelect()
    }

    private func startImport() {
        do {
            importClient = try model.activeClient()
            importing = true
        } catch { failure = error.localizedDescription }
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

/// 资源库侧栏里分组的一页（插件、代理上下文、Skill），像项目一栏里的项目一样：页名一行可收起，各组作小标题、各项作树状子项列在下面。
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

/// 一台设备的标记：形状认机器，颜色与动画说明状态。在线用主题色，待更新用警示色，等待连接在警示色上呼吸，离线只描边；
/// 自动更新期间拆成点阵按进度点亮，颜色仍按能不能用。设备列表、收起的侧栏和导航「设备」一行的行尾共用。
struct DeviceMark: View {
    let shape: String
    let status: DeviceStatus
    let size: CGFloat
    /// 画在主题色底上（选中的导航行）时，在线与离线换成白色，免得和底色混在一起。
    var onAccent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 形状按区分度排，设备不多时只用前几个。
    private static let symbols = ["circle", "triangle", "square", "diamond", "star", "heart",
                                  "hexagon", "shield", "seal", "pentagon", "octagon", "capsule.portrait"]

    /// 各设备的形状互不相同：按 ID 的哈希挑，撞了往后顺延。各端看到的是同一份设备列表，算出来一样；
    /// 增减设备只挪动撞上的那几台。超出形状数的设备重复用。
    static func shapes(for ids: [String]) -> [String: String] {
        let count = min(symbols.count, max(6, ids.count))
        var taken = Set<Int>()
        var shapes: [String: String] = [:]
        for id in ids.sorted() {
            // FNV-1a，不用 hashValue：它每次启动都换种子。
            let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            let start = Int(hash % UInt64(count))
            let index = (0..<count).map { (start + $0) % count }.first { !taken.contains($0) } ?? start
            taken.insert(index)
            shapes[id] = symbols[index]
        }
        return shapes
    }

    private var color: Color {
        onAccent && !status.waiting && !status.outdated ? Color.white.opacity(status.ready ? 1 : 0.7) : status.tint
    }

    var body: some View {
        let symbol = Image(systemName: shape)
            .symbolVariant(status.offline ? .none : .fill)
            .font(.system(size: size, weight: .semibold))
        if let progress = status.progress {
            // 占位与其他状态的符号一样大，点阵画在里面。
            // 小图标格子少些，点才不挤成一团；少于 5×5 圆和方、圆和菱形就分不出了。
            symbol.hidden().overlay { DeviceDotMatrix(shape: shape, grid: size >= 12 ? 6 : 5, progress: progress, color: color) }
        } else {
            symbol
                .foregroundStyle(color)
                .symbolEffect(.breathe, options: .repeating, isActive: status.waiting && !reduceMotion)
        }
    }
}

/// 更新中的设备标记：形状拆成点阵，按进度从下往上逐行点亮，正在点的那行闪烁；满了（换版中）有一行暗带往上扫。
private struct DeviceDotMatrix: View {
    let shape: String
    let grid: Int
    let progress: Double
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var covered: [String: Coverage] = [:]

    /// 形状盖住的格子；area 是点阵所在的正方形在符号里的位置，按比例。
    private struct Coverage {
        let cells: [Bool]
        let area: CGRect
    }

    /// 把实心符号画大，裁到笔画所在的正方形分成格，盖住四成以上的格子算在形状里。只取格子中心的话细的星角会丢。
    private static func coverage(_ shape: String, grid n: Int) -> Coverage {
        let key = "\(shape) \(n)"
        if let cached = covered[key] { return cached }
        var result = Coverage(cells: Array(repeating: true, count: n * n), area: CGRect(x: 0, y: 0, width: 1, height: 1))
        let renderer = ImageRenderer(content: Image(systemName: shape).symbolVariant(.fill)
            .font(.system(size: 128, weight: .semibold)).foregroundStyle(.black))
        if let image = renderer.cgImage,
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let width = image.width, height = image.height
            if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
                let alpha = { (x: Int, y: Int) in Double(pixels[(y * width + x) * 4 + 3]) / 255 }
                var minX = width, minY = height, maxX = -1, maxY = -1
                for y in 0..<height {
                    for x in 0..<width where alpha(x, y) > 0.5 {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
                if maxX >= 0 {
                    let side = Double(max(maxX - minX, maxY - minY) + 1)
                    let originX = Double(minX + maxX + 1) / 2 - side / 2, originY = Double(minY + maxY + 1) / 2 - side / 2
                    let step = side / Double(n)
                    var cells: [Bool] = []
                    for row in 0..<n {
                        for column in 0..<n {
                            var sum = 0.0
                            for y in Int(originY + Double(row) * step)..<Int(originY + Double(row + 1) * step) where (0..<height).contains(y) {
                                for x in Int(originX + Double(column) * step)..<Int(originX + Double(column + 1) * step) where (0..<width).contains(x) {
                                    sum += alpha(x, y)
                                }
                            }
                            cells.append(sum / (step * step) > 0.4)
                        }
                    }
                    result = Coverage(cells: cells, area: CGRect(x: originX / Double(width), y: originY / Double(height),
                                                                 width: side / Double(width), height: side / Double(height)))
                }
            }
        }
        covered[key] = result
        return result
    }

    var body: some View {
        let coverage = Self.coverage(shape, grid: grid)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let n = grid
                let area = CGRect(x: coverage.area.minX * size.width, y: coverage.area.minY * size.height,
                                  width: coverage.area.width * size.width, height: coverage.area.height * size.height)
                let cell = CGSize(width: area.width / CGFloat(n), height: area.height / CGFloat(n))
                let diameter = min(cell.width, cell.height) * 0.72
                // 从下往上数已点亮的行；满了以后换成往上扫的暗带。
                let lit = Int(progress * Double(n))
                let sweep = progress >= 1 && !reduceMotion ? Int(time * 6) % (n + 2) : -1
                for row in 0..<n {
                    let level = n - 1 - row
                    for column in 0..<n where coverage.cells[row * n + column] {
                        let opacity = if level == sweep { 0.35 }
                            else if level < lit { 1.0 }
                            else if level == lit { reduceMotion ? 0.6 : 0.6 + 0.25 * sin(time * 8 + Double(column) * 4) }
                            else { 0.22 }
                        let rect = CGRect(x: area.minX + (CGFloat(column) + 0.5) * cell.width - diameter / 2,
                                          y: area.minY + (CGFloat(row) + 0.5) * cell.height - diameter / 2, width: diameter, height: diameter)
                        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
                    }
                }
            }
        }
    }
}

/// 设备列表里的设备标记，状态说明保留在悬停与辅助功能中。
struct DeviceStatusIcon: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarMetrics) private var metrics
    let device: AccountDevice
    let connection: WorkerConnection?

    private var status: DeviceStatus { DeviceStatus(device: device, connection: connection) }

    var body: some View {
        DeviceMark(shape: model.account.deviceShapes[device.id] ?? "circle", status: status, size: metrics.labelExtent - 4)
            .help("\(device.role == "worker" ? "工作机" : "控制端") · \(status.detail)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.title)
    }
}

/// 导航「设备」一行的行尾：每台工作机一个标记，排法与设备列表相同；悬停列出各台的名字与状态。
struct DeviceMarks: View {
    var onAccent = false
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarMetrics) private var metrics

    static func size(_ metrics: SidebarMetrics) -> CGFloat { (metrics.labelExtent * 0.44).rounded() }

    var body: some View {
        let devices = model.account.workers
        let shapes = model.account.deviceShapes
        let summary = devices.map { "\($0.name) · \(model.deviceStatus($0).detail)" }.joined(separator: "\n")
        HStack(spacing: 3) {
            ForEach(devices) { device in
                DeviceMark(shape: shapes[device.id] ?? "circle", status: model.deviceStatus(device),
                           size: Self.size(metrics), onAccent: onAccent)
            }
        }
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
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
