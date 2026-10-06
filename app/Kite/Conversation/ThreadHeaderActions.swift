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
    @State private var confirmingRecovery = false
    private let catalog = AgentModelCatalog.bundled
    private var availableModels: [AgentCapabilities.Model] {
        if let capabilities = thread.agentCapabilities { return capabilities.models }
        guard area.isSample else { return [] }
        return (runtime == .claude ? catalog.claude : catalog.models).map {
            .init(id: $0.id, title: $0.tier, reasoning: Effort.allCases.map(\.name))
        }
    }

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
        return availableModels.first { modelName == $0.id || modelName == $0.resolvedModel }?.title ?? modelName
    }
    private var canChangeModel: Bool {
        instance != nil && (area.isSample || model.isConnected(area)) && !savingModel
            && (area.isSample || thread.agentCapabilities?.canEdit(thread.state) == true)
    }

    var body: some View {
        menuGroup
            .task(id: "\(model.revision(for: area))-\(model.isConnected(area))") {
                guard !area.isSample, model.isConnected(area), let instance else { return }
                do {
                    let client = try model.activeClient(in: area)
                    let revision = model.revision(for: area)
                    let capabilities = try await client.request("/instances/\(instance.id)/agent-capabilities", as: AgentCapabilities.self)
                    guard revision == model.revision(for: area), !Task.isCancelled else { return }
                    thread.agentCapabilities = capabilities
                } catch { modelError = error.localizedDescription }
            }
            .alert("切换模型失败", isPresented: Binding(
                get: { modelError != nil }, set: { if !$0 { modelError = nil } }
            )) {
                Button("好", role: .cancel) { modelError = nil }
            } message: { Text(modelError ?? "") }
            .alert("确认恢复会话", isPresented: $confirmingRecovery) {
                Button("取消", role: .cancel) {}
                Button("已核查，解除阻塞") { thread.control("recover") }
            } message: {
                Text("请先核查旧执行已经停止及其产生的改动。确认后只解除恢复阻塞。交接未知的消息会保留在待发送区；请核查后选择继续重发或撤回编辑。")
            }
    }

    private var menuGroup: some View {
        #if os(iOS)
        PhoneThreadHeaderMenus(modelTitle: modelTier, modelName: modelName,
            modelIDs: availableModels.map(\.id), modelEnabled: canChangeModel,
            commands: moreCommands, onSelectModel: selectModel)
            .fixedSize()
        #else
        MacThreadHeaderMenus(modelTitle: modelTier, modelName: modelName,
            modelIDs: availableModels.map(\.id), modelEnabled: canChangeModel,
            commands: moreCommands, onSelectModel: selectModel)
            .fixedSize()
        #endif
    }

    /// 两端菜单使用相同的可用状态和业务动作。
    private var moreCommands: [[ThreadHeaderCommand]] {
        var general: [ThreadHeaderCommand] = []
        if let instance {
            general.append(.init(title: "实例设置与授权", symbol: "slider.horizontal.3",
                                 enabled: !area.isSample && model.isConnected(area)) { area.settingsInstance = instance })
        }
        general.append(.init(title: "复制工作目录", symbol: "folder", enabled: !thread.transcript.root.isEmpty) {
            copyToPasteboard(thread.transcript.root, toast: toast)
        })
        if thread.isStreamingPreview {
            general.append(.init(title: "重播会话", symbol: "arrow.clockwise") { thread.previewRun += 1 })
        }
        var execution: [ThreadHeaderCommand] = []
        if !area.isSample {
            if thread.state?.recovery != nil {
                execution.append(.init(title: "确认恢复", symbol: "arrow.clockwise",
                                       enabled: model.isConnected(area) && thread.state?.busy != true) { confirmingRecovery = true })
            }
            if thread.showStop {
                execution.append(.init(title: "停止执行", symbol: "stop", enabled: thread.canStop) { thread.stop() })
            }
            if thread.state?.capabilities.resume == true {
                execution.append(.init(title: "继续执行", symbol: "play", enabled: thread.canResume) { thread.control("resume") })
            }
        }
        return [general, execution].filter { !$0.isEmpty }
    }

    private func selectModel(_ name: String) {
        guard canChangeModel, name != modelName, availableModels.contains(where: { $0.id == name }),
              let instance else { return }
        savingModel = true
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
                    try await model.updateAgent(in: area, id: instance.id) { agent in
                        agent.model.selectModel(name, supportedReasoning: thread.agentCapabilities?.model(name)?.reasoning ?? [])
                    }
                    return
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
