import SwiftUI

/// 模型入口和会话操作跟随当前窗口的实例，不依赖工作区中哪个线程先打开。
struct ThreadHeaderActions: View {
    @Environment(WorkThread.self) private var thread
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model
    @Environment(\.paneInstance) private var instance
    @Environment(\.toast) private var toast
    @State private var savingModel = false
    @State private var modelError: String?
    private let catalog = AgentModelCatalog.bundled

    private var runtime: RemoteRuntime {
        area.remote?.threads.first { $0.instanceId == thread.id }?.runtime
            ?? instance.flatMap { area.definition(of: $0)?.agent?.runtime } ?? .harness
    }
    private var modelName: String? {
        if let name = instance?.config?.agent?.model.model { return name }
        if area.isSample || thread.isDraft {
            return area.definitions.first { $0.id == (instance?.definitionId ?? "kite.agent.coding") }?.agent?.model?.model
        }
        return nil
    }

    private var modelTier: String {
        guard let modelName else { return "模型" }
        return catalog.models.first { modelName.hasSuffix("-" + $0.tier) }?.tier ?? "模型"
    }
    private var canChangeModel: Bool {
        runtime == .harness && instance != nil && (area.isSample || model.connected) && !savingModel
    }

    var body: some View {
        menuGroup
            .alert("切换模型失败", isPresented: Binding(
                get: { modelError != nil }, set: { if !$0 { modelError = nil } }
            )) {
                Button("好", role: .cancel) { modelError = nil }
            } message: { Text(modelError ?? "") }
    }

    private var menuGroup: some View {
        #if os(iOS)
        PhoneThreadHeaderMenus(modelTitle: modelTier, modelName: modelName,
            modelIDs: catalog.models.map(\.id), modelEnabled: canChangeModel,
            commands: moreCommands, onSelectModel: selectModel)
            .fixedSize()
        #else
        MacThreadHeaderMenus(modelTitle: modelTier, modelName: modelName,
            modelIDs: catalog.models.map(\.id), modelEnabled: canChangeModel,
            commands: moreCommands, onSelectModel: selectModel)
            .fixedSize()
        #endif
    }

    /// 两端菜单使用相同的可用状态和业务动作。
    private var moreCommands: [[ThreadHeaderCommand]] {
        var general: [ThreadHeaderCommand] = []
        if let instance {
            general.append(.init(title: "实例设置与授权", symbol: "slider.horizontal.3",
                                 enabled: !area.isSample && model.connected) { area.settingsInstance = instance })
        }
        general.append(.init(title: "复制工作目录", symbol: "folder", enabled: !thread.transcript.root.isEmpty) {
            copyToPasteboard(thread.transcript.root, toast: toast)
        })
        if thread.isStreamingPreview {
            general.append(.init(title: "重播会话", symbol: "arrow.clockwise") { thread.previewRun += 1 })
        }
        var execution: [ThreadHeaderCommand] = []
        if !area.isSample {
            if thread.showStop {
                execution.append(.init(title: "停止执行", symbol: "stop", enabled: thread.canStop) { thread.stop() })
            }
            if thread.state?.capabilities.resume == true {
                execution.append(.init(title: "继续执行", symbol: "play", enabled: thread.canSend) { thread.control("resume") })
            }
        }
        return [general, execution].filter { !$0.isEmpty }
    }

    private func selectModel(_ name: String) {
        guard canChangeModel, name != modelName, catalog.models.contains(where: { $0.id == name }),
              let instance else { return }
        savingModel = true
        let revision = model.connectionRevision
        Task {
            defer { savingModel = false }
            do {
                let config: InstanceAgentConfig
                if area.isSample {
                    guard var current = area.instances.first(where: { $0.id == instance.id })?.config,
                          current.agent != nil else { throw KitedError(message: "此样本没有模型配置") }
                    current.agent?.model.model = name
                    config = current
                } else {
                    let client = try model.activeClient()
                    @MainActor func requireCurrentInstance() throws {
                        guard model.connectionRevision == revision, model.connected,
                              client == (try model.activeClient()), client.machineID == area.remote?.machine.id,
                              area.remote?.workspace.status == .open,
                              area.instances.contains(where: { $0.id == instance.id && $0.status == .open }) else {
                            throw KitedError(message: "工作机或实例已变化，请重新选择模型")
                        }
                    }
                    try requireCurrentInstance()
                    let path = "/instances/\(instance.id)/agent-config"
                    let snapshot = try await client.request(path, as: AgentConfigurationSnapshot.self)
                    try requireCurrentInstance()
                    guard var agent = snapshot.instance.config.agent else { throw KitedError(message: "实例没有 agent 配置") }
                    agent.model.model = name
                    let updated = try await client.request(path, method: "PUT",
                        body: AgentConfigurationUpdate(expectedRevision: snapshot.revision, agent: agent),
                        as: AgentConfigurationSnapshot.self)
                    try requireCurrentInstance()
                    config = updated.instance.config
                }
                if let index = area.instances.firstIndex(where: { $0.id == instance.id }) {
                    area.instances[index].config = config
                }
            } catch { modelError = error.localizedDescription }
        }
    }
}

struct ThreadHeaderCommand: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    var enabled = true
    let action: @MainActor () -> Void
}
