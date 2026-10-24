import SwiftUI

/// 资源库里自定义插件（Bun 插件包）的窗口：标题是插件名，副行「自定义」；上面是基本信息，下面是定义级的协作授权，
/// 这个插件以后新建的实例带上的起点，新建实例时拷进实例（docs/Agent与插件契约.md §3.2）。定义级不能指向具体实例，只有「工作区」那一组。
/// 授权是开关，改了即时存到工作机，同角色的初始配置：先按改后的显示，一次只发一个请求；存不上时重读工作机上的这份，开关回到实际状态，
/// 原因报在信息区。别处改了经 library.changed 推过来，没有在存的修改时重读，不用手动刷新。
struct CustomPluginPane: View {
    let definition: RemotePluginDefinition
    @Environment(AppModel.self) private var model
    @State private var client: KitedClient?
    @State private var saved: InstanceGrants?
    @State private var operations: [RemoteOperation] = []
    /// 开关改后的样子，还没存好时按它显示；存到与它一致时清掉。
    @State private var desired: PluginGrantDraft?
    @State private var writing = false
    /// 每存好一次加一：在这之前发出的读取回来时已经旧了，不再拿它覆盖，见 load。
    @State private var writes = 0
    @State private var error: String?

    private var path: String { "/plugins/\(definition.id.pathComponent)/grants" }
    private var available: Bool { model.connected && model.definitions.contains { $0.id == definition.id && $0.runtime == "bun" } }

    /// 授权开关看的草稿：有没存好的修改时是改后的样子，否则是工作机上的那份；改了就去存。
    private var draft: Binding<PluginGrantDraft?> {
        Binding {
            desired ?? saved.map(PluginGrantDraft.init(snapshot:))
        } set: { value in
            guard let value, saved != nil else { return }
            desired = value
            write()
        }
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: definition.title, subtitle: "自定义"), notice: error.map(PaneNotice.failure)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PluginInfoSection(definition)
                    if saved != nil {
                        CardSection("协作授权", note: "这个插件新建的实例能经宿主调用工作区里的哪些操作；默认都没有。新建实例时拷进实例，之后修改这里不改变已有实例；"
                            + "已有实例的授权和对具体实例的授权在实例的配置里改。")
                        WorkspaceGrants(caller: "plugin", draft: draft, operations: operations, roles: model.roleCatalog?.roles ?? [])
                            .disabled(!available)
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            EmptyView()
        }
        // 换了工作机重新读
        .task(id: model.connectionRevision) {
            client = nil
            reload()
        }
        // 别处改了（library.changed 的 plugin）：没有在存的修改就重读；有的话存的时候由版本核对拦下，再重读。
        .onChange(of: model.connection()?.pluginGrantsRevision) { if !writing && desired == nil { reload() } }
    }

    /// 一次只发一个请求：发出去的那次回来以后，开关又改过就接着把最新的样子存上去，每次都带着上一次存回来的版本，
    /// 后发的不会被先发的盖掉。存不上（版本冲突、请求无效、网络断了）时丢掉没存的修改，重读工作机上的这份；
    /// 重读期间又改了的，按重读来的版本接着存。
    private func write() {
        guard !writing else { return }
        writing = true
        error = nil
        Task {
            defer { writing = false }
            while let target = desired, let current = saved {
                guard target.grants != current.grants else { desired = nil; break }
                do {
                    let client = try boundClient()
                    let value = try await client.request(path, method: "PUT", body: GrantUpdate(expectedRevision: current.revision, grants: target.grants),
                                                         as: InstanceGrants.self)
                    _ = try boundClient()
                    saved = value
                    writes += 1
                    // 存的期间没再改过就到此为止；工作机可能整理过存回来的授权，不拿它和发出去的比
                    if desired?.grants == target.grants { desired = nil }
                } catch {
                    desired = nil
                    self.error = "保存失败：\(error.localizedDescription)"
                    do { try await load() } catch { self.error = "保存失败，也没能重新读取：\(error.localizedDescription)" }
                }
            }
        }
    }

    private func reload() {
        Task {
            do { try await load() } catch { self.error = "读取失败：\(error.localizedDescription)" }
        }
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient()
        guard available, client == nil || client == current else {
            throw KitedError(message: "工作机或插件已变化")
        }
        return current
    }

    private func load() async throws {
        let client = try boundClient()
        self.client = client
        let started = writes
        async let snapshot = client.request(path, as: InstanceGrants.self)
        async let catalog = client.request("/operations", as: [RemoteOperation].self)
        let (value, definitions) = try await (snapshot, catalog)
        _ = try boundClient()
        operations = definitions
        if writes == started { saved = value }
        // 「按角色创建代理」列出的是工作机上的角色。
        try await model.ensureRoles()
    }
}
