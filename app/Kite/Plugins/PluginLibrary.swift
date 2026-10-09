import SwiftUI
import UniformTypeIdentifiers

/// 只保留一份完整包；预览只包含界面需要的元数据。
private nonisolated struct ImportedPluginPackage: Decodable, Sendable {
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

/// 插件包随 Kite 账号保存在资源库，经当前连接的工作机导入；其他工作机首次用到时再下载安装。资源库一栏的单页，操作在标题栏。
struct PluginLibrary: View {
    private struct PendingPackage {
        let contents: ImportedPluginPackage
        let client: KitedClient
    }

    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var working = false
    @State private var error: String?
    @State private var pendingPackage: PendingPackage?
    @State private var importClient: KitedClient?

    var body: some View {
        SectionPage(header: PaneHeader(title: "插件", subtitle: SidebarSection.extensions.title)) {
            form
        } actions: {
            PaneHeaderButtonGroup {
                Button { perform { try await refresh() } } label: { PaneHeaderButtonLabel("刷新", systemImage: "arrow.clockwise") }
                    .help("刷新")
                    .disabled(working || !model.connected)
                Button {
                    do { importClient = try model.activeClient(); importing = true }
                    catch { self.error = error.localizedDescription }
                } label: { PaneHeaderButtonLabel("导入插件", systemImage: "plus") }
                    .help("导入插件")
                    .disabled(working || !model.connected)
            }
        }
    }

    private var form: some View {
        Form {
            if let package = pendingPackage?.contents.preview {
                Section("待安装") {
                    Text(package.title).font(.headline)
                    Text(package.id).font(.caption).foregroundStyle(.secondary)
                    Text(package.lifetime.explanation).font(.caption).foregroundStyle(.secondary)
                    ForEach(package.views ?? []) { Text($0.title) }
                    if (package.views ?? []).isEmpty { Text("后台插件，无窗口").foregroundStyle(.secondary) }
                    HStack {
                        Button("保存到资源库") { perform { try await install() } }
                            .disabled(!model.connected)
                        Button("取消") { pendingPackage = nil }
                    }
                }
            }
            Section("自定义插件") {
                let custom = model.definitions.filter { $0.runtime == "bun" }
                if custom.isEmpty { Text("资源库里还没有自定义插件").foregroundStyle(.secondary) }
                ForEach(custom) { definitionRow($0) }
            }
            Section("内置插件") {
                ForEach(model.definitions.filter { $0.runtime != "bun" }) { definitionRow($0) }
            }
            if let error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if working { ProgressView() }
        }
        .pageForm()
        .disabled(working)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                guard let client = importClient else { return }
                importClient = nil
                let url = try result.get()
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
                pendingPackage = PendingPackage(contents: contents, client: client)
            }
        }
        .task { do { try await refresh() } catch { self.error = error.localizedDescription } }
    }

    private func definitionRow(_ definition: RemotePluginDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(definition.title)
            Text(definition.lifetime.title).font(.caption).foregroundStyle(.secondary)
            Text(definition.views.isEmpty ? "后台运行" : definition.views.map(\.title).joined(separator: "、"))
                .font(.caption).foregroundStyle(.secondary)
            if definition.runtime == "bun" { Text(definition.id).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func refresh() async throws { try await model.refreshDefinitions(model.activeClient()) }

    private func install() async throws {
        guard let pendingPackage, pendingPackage.client == (try model.activeClient()) else {
            throw KitedError(message: "工作机已切换，请重新导入插件")
        }
        let _: RemotePluginDefinition = try await pendingPackage.client.request("/plugin-definitions", method: "POST", body: pendingPackage.contents.json, as: RemotePluginDefinition.self)
        self.pendingPackage = nil
        try await model.refreshDefinitions(pendingPackage.client)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
