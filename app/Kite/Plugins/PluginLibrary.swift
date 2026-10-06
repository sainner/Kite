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

/// 插件定义属于工作机；安装后可在各工作区创建实例。
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
        Form {
            if let machine = model.machine { Text("工作机：\(machine.name)").foregroundStyle(.secondary) }
            if let package = pendingPackage?.contents.preview {
                Section("待安装") {
                    Text(package.title).font(.headline)
                    Text(package.id).font(.caption).foregroundStyle(.secondary)
                    Text(package.lifetime.explanation).font(.caption).foregroundStyle(.secondary)
                    ForEach(package.views ?? []) { Text($0.title) }
                    if (package.views ?? []).isEmpty { Text("后台插件，无窗口").foregroundStyle(.secondary) }
                    HStack {
                        Button("安装到当前工作机") { perform { try await install() } }
                            .disabled(!model.connected)
                        Button("取消") { pendingPackage = nil }
                    }
                }
            }
            Section("自定义插件") {
                let custom = model.definitions.filter { $0.runtime == "bun" }
                if custom.isEmpty { Text("尚未安装自定义插件").foregroundStyle(.secondary) }
                ForEach(custom) { definitionRow($0) }
            }
            Section("内置插件") {
                ForEach(model.definitions.filter { $0.runtime != "bun" }) { definitionRow($0) }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if working { ProgressView() }
        }
        .formStyle(.grouped)
        .navigationTitle("插件")
        .disabled(working)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") { perform { try await refresh() } }
                    .disabled(working || !model.connected)
                Button("导入插件", systemImage: "plus") {
                    do { importClient = try model.activeClient(); importing = true }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(working || !model.connected)
            }
        }
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
