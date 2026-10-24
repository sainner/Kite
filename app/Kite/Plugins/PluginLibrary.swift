import SwiftUI
import UniformTypeIdentifiers

/// 只保留一份完整包；预览只包含界面需要的元数据。
nonisolated struct ImportedPluginPackage: Decodable, Sendable {
    let preview: PluginPackagePreview
    let json: JSON

    init(from decoder: Decoder) throws {
        preview = try PluginPackagePreview(from: decoder)
        // 保留全部字段，交给宿主做严格校验。
        json = try JSON(from: decoder)
        guard let bundle = json["bundle"]?.string else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "插件代码须为字符串"))
        }
        guard bundle.utf8.count <= 4 * 1024 * 1024 else {
            throw NSError(domain: "KitePluginImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "插件代码超过 4 MiB"])
        }
    }
}

/// 导入了还没保存到资源库的插件包，经导入时连着的那台工作机保存。
struct PendingPlugin {
    let package: ImportedPluginPackage
    let client: KitedClient
}

/// 资源库插件页里的一项：一个插件定义，或导入了还没保存的插件包。
nonisolated enum PluginItem: Hashable {
    case definition(String)
    case pending
}

extension AppModel {
    /// 资源库里的插件，侧栏分两组：自定义的是 Bun 插件包，其余是内置的。
    var customPlugins: [RemotePluginDefinition] { definitions.filter { $0.runtime == "bun" } }
    var builtinPlugins: [RemotePluginDefinition] { definitions.filter { $0.runtime != "bun" } }

    /// 插件页里的各项，按侧栏里的先后排：自定义的、待安装的、内置的。
    private var pluginItems: [PluginItem] {
        customPlugins.map { .definition($0.id) } + (pendingPlugin == nil ? [] : [.pending]) + builtinPlugins.map { .definition($0.id) }
    }

    /// 插件页显示的那项：侧栏选中的，没选过或已不在时是第一项。
    var pluginItem: PluginItem? {
        let items = pluginItems
        if let selectedPlugin, items.contains(selectedPlugin) { return selectedPlugin }
        return items.first
    }

    var pluginGroup: PaneGroup? { pluginItem.map { .plugin($0, pluginWindows) } }

    /// 定义列表没读过才读：连上工作机时读一次，之后由 library.changed 的 plugin 重读（见 libraryChanged）。内置插件总有，空着就是还没读到。
    func ensureDefinitions() async throws {
        guard let connection = activeConnection, connection.connected else { throw KitedError(message: "所属工作机未连接") }
        if connection.definitions.isEmpty { try await refreshDefinitions(connection.client) }
    }

    /// 读选好的插件包文件，成为待安装的一项并选中；已有待安装的换成这个。client 是选文件前连着的工作机，保存时核对。
    func importPlugin(_ url: URL, via client: KitedClient) async throws {
        let contents = try await Task.detached {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let maximum = 32 * 1024 * 1024
            guard let bytes = try file.read(upToCount: maximum + 1), bytes.count <= maximum else {
                throw NSError(domain: "KitePluginImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "插件包文件超过 32 MiB"])
            }
            return try JSONDecoder().decode(ImportedPluginPackage.self, from: bytes)
        }.value
        pendingPlugin = PendingPlugin(package: contents, client: client)
        extensionPage = .plugins
        selectedPlugin = .pending
    }

    /// 把待安装的插件包保存到资源库（同时装到这台工作机），读到新的定义列表后选中它。
    func installPendingPlugin() async throws {
        guard let pending = pendingPlugin, pending.client == (try activeClient()) else {
            throw KitedError(message: "工作机已切换，请重新导入插件")
        }
        let definition = try await pending.client.request("/plugin-definitions", method: "POST", body: pending.package.json,
                                                          as: RemotePluginDefinition.self)
        try await refreshDefinitions(pending.client)
        pendingPlugin = nil
        if selectedPlugin == .pending { selectedPlugin = .definition(definition.id) }
    }
}

/// 资源库的插件页：侧栏里选中的插件在固定排布的窗口里显示，一个插件一个窗口，同 Skill 页；定义列表还没读到时是说明页。
/// 导入插件在侧栏「自定义」一组的小标题上。定义列表随 library.changed 的 plugin 重读，没有手动刷新。
struct PluginLibrary: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        Group {
            if let group = model.pluginGroup {
                TilesLayer(group: group).id(group.id)
            } else {
                SectionPage(header: PaneHeader(title: ExtensionLibrary.plugins.title, subtitle: SidebarSection.extensions.title)) {
                    Group {
                        if let error { Text(error).foregroundStyle(Theme.danger) } else { ProgressView() }
                    }
                    .font(Theme.body)
                    .padding(Metrics.padding)
                }
            }
        }
        .task(id: model.connectionRevision) {
            error = nil
            do { try await model.ensureDefinitions() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 插件页的窗口：按选中的一项换成自定义插件、内置插件或待安装的插件包。
struct PluginLibraryPane: View {
    let item: PluginItem
    @Environment(AppModel.self) private var model

    var body: some View {
        switch item {
        case .pending:
            if let pending = model.pendingPlugin { PendingPluginPane(pending: pending) }
        case .definition(let id):
            if let definition = model.definitions.first(where: { $0.id == id }) {
                if definition.runtime == "bun" { CustomPluginPane(definition: definition) }
                else { BuiltinPluginPane(definition: definition) }
            }
        }
    }
}

/// 插件的基本信息：生存期（说明写在下面）、有哪些视图（没有就是后台运行），自定义插件还有 ID。
/// 资源库里插件的窗口与待安装的插件包共用。
struct PluginInfoSection: View {
    let lifetime: PluginLifetime
    let views: [String]
    /// 只有自定义插件给。
    var id: String?

    var body: some View {
        CardSection("插件", note: lifetime.explanation) {
            LabeledContent("生存期") { Text(lifetime.title).foregroundStyle(.secondary) }
            LabeledContent("视图") { Text(views.isEmpty ? "后台运行" : views.joined(separator: "、")).foregroundStyle(.secondary) }
            if let id { LabeledContent("ID") { Text(id).foregroundStyle(.secondary).textSelection(.enabled) } }
        }
    }
}

extension PluginInfoSection {
    init(_ definition: RemotePluginDefinition) {
        self.init(lifetime: definition.lifetime, views: definition.views.map(\.title), id: definition.runtime == "bun" ? definition.id : nil)
    }
}

/// 内置插件的窗口：标题是插件名，副行「内置」，只有基本信息。
private struct BuiltinPluginPane: View {
    let definition: RemotePluginDefinition

    var body: some View {
        PaneWindow(header: PaneHeader(title: definition.title, subtitle: "内置")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { PluginInfoSection(definition) }
                    .agentContextColumn()
            }
        } controls: { _ in
            EmptyView()
        }
    }
}

/// 导入了还没保存的插件包的窗口：标题是插件名，副行「待安装」，正文是包里的基本信息；保存到资源库、取消导入在标题栏，
/// 同 Skill 新建的草稿。经导入时连着的那台工作机保存，换了工作机要重新导入。
private struct PendingPluginPane: View {
    let pending: PendingPlugin
    @Environment(AppModel.self) private var model
    @State private var progress = CardPhase.idle

    var body: some View {
        let package = pending.package.preview
        PaneWindow(header: PaneHeader(title: package.title, subtitle: "待安装"), notice: progress.error.map(PaneNotice.failure),
                   actions: PaneHeaderActions(groups: [[
                       PaneHeaderAction(title: "取消导入", systemImage: "xmark", disabled: progress.working) { model.pendingPlugin = nil },
                       PaneHeaderAction(title: "保存到资源库", systemImage: "checkmark", help: model.connected ? "保存到资源库" : "工作机未连接",
                                        busy: progress.working, disabled: progress.working || !model.connected) {
                           $progress.run { try await model.installPendingPlugin() }
                       },
                   ]])) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PluginInfoSection(lifetime: package.lifetime, views: (package.views ?? []).map(\.title), id: package.id)
                }
                .agentContextColumn()
            }
        } controls: { _ in
            EmptyView()
        }
    }
}
