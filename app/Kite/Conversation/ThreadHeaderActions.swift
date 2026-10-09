import SwiftUI

/// 模型入口和会话操作跟随当前窗口的实例，不依赖工作区中哪个线程先打开。
struct ThreadHeaderActions: View {
    @Environment(WorkThread.self) private var thread
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model
    @Environment(\.paneInstance) private var instance
    @Environment(\.toast) private var toast
    @State private var savingModel = false
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var confirmingRecovery = false
    @State private var showingModels = false
    private var availableModels: [AgentCapabilities.Model] { thread.agentCapabilities?.models ?? [] }
    /// 草稿还没有实例，模型与后端改的是本机选择，随第一条消息一起提交。
    private var choice: DraftAgentChoice? { instance == nil ? thread.draftChoice : nil }
    private var modelName: String? {
        if let name = instance?.config?.agent?.model.model { return name }
        if let choice { return choice.model?.model }
        if thread.isDraft {
            return area.definitions.first { $0.id == (instance?.definitionId ?? "kite.agent.coding") }?.agent?.model?.model
        }
        return nil
    }

    private var modelTier: String {
        guard let modelName else { return "模型" }
        return availableModels.first { modelName == $0.id }?.title ?? modelName
    }
    private var canChangeModel: Bool {
        if choice != nil { return model.isConnected(area) && thread.agentCapabilities != nil }
        return instance != nil && model.isConnected(area) && !savingModel
            && thread.agentCapabilities?.canEdit(thread.state) == true
    }
    private var runtimeName: String { instance?.config?.agent?.runtime ?? choice?.runtime ?? "harness" }
    private var canOpenModels: Bool { (instance != nil || choice != nil) && model.isConnected(area) }
    private var canChangeRuntime: Bool {
        if choice != nil { return canOpenModels }
        return canOpenModels && !savingModel && !thread.showStop && thread.state?.capabilities.switchRuntime == true
    }

    var body: some View {
        menuGroup
            .popover(isPresented: $showingModels, arrowEdge: .top) {
                ThreadModelMenu(runtime: runtimeName, modelName: modelName, models: availableModels,
                    runtimeEnabled: canChangeRuntime, modelEnabled: canChangeModel, saving: savingModel,
                    loading: loadingModels,
                    runtimeExplanation: thread.state?.capabilities.switchRuntime == false
                        ? "运行中、有排队消息或等待恢复确认时不能切换。" : nil,
                    onSelectRuntime: selectRuntime, onSelectModel: selectModel)
                    .presentationCompactAdaptation(.popover)
            }
            .task(id: "\(model.revision(for: area))-\(model.isConnected(area))-\(runtimeName)-\(choice?.definitionId ?? "")") {
                if let choice { await loadDraftCapabilities(choice); return }
                guard model.isConnected(area), let instance else { return }
                thread.agentCapabilities = nil
                loadingModels = true
                defer { if !Task.isCancelled { loadingModels = false } }
                do {
                    let client = try model.activeClient(in: area)
                    let revision = model.revision(for: area)
                    let runtime = runtimeName
                    let capabilities = try await client.request("/instances/\(instance.id)/agent-capabilities", as: AgentCapabilities.self)
                    guard revision == model.revision(for: area), !Task.isCancelled,
                          area.instances.first(where: { $0.id == instance.id })?.config?.agent?.runtime == runtime else { return }
                    thread.agentCapabilities = capabilities
                } catch {
                    if !Task.isCancelled { showingModels = false; modelError = error.localizedDescription }
                }
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
            modelEnabled: canOpenModels, commands: moreCommands, onOpenModel: { showingModels = true })
            .fixedSize()
        #else
        MacThreadHeaderMenus(modelTitle: modelTier, modelName: modelName,
            modelEnabled: canOpenModels, commands: moreCommands, onOpenModel: { showingModels = true })
            .fixedSize()
        #endif
    }

    /// 两端菜单使用相同的可用状态和业务动作。
    private var moreCommands: [[ThreadHeaderCommand]] {
        var general: [ThreadHeaderCommand] = []
        if let instance {
            general.append(.init(title: "实例设置与授权", symbol: "slider.horizontal.3",
                                 enabled: model.isConnected(area)) { area.settingsInstance = instance })
            general.append(.init(title: "归档会话", symbol: "archivebox",
                                 enabled: model.isConnected(area)) { area.archiveRequest = instance })
        }
        general.append(.init(title: "复制工作目录", symbol: "folder", enabled: !thread.transcript.root.isEmpty) {
            copyToPasteboard(thread.transcript.root, toast: toast)
        })
        var execution: [ThreadHeaderCommand] = []
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
        return [general, execution].filter { !$0.isEmpty }
    }

    private func loadDraftCapabilities(_ choice: DraftAgentChoice) async {
        guard model.isConnected(area) else { return }
        thread.agentCapabilities = nil
        loadingModels = true
        defer { if !Task.isCancelled { loadingModels = false } }
        do {
            let client = try model.activeClient(in: area)
            let capabilities = try await client.request(
                "/plugin-definitions/\(choice.definitionId)/agent-capabilities?runtime=\(choice.runtime)", as: AgentCapabilities.self)
            guard !Task.isCancelled, thread.draftChoice?.definitionId == choice.definitionId,
                  thread.draftChoice?.runtime == choice.runtime else { return }
            thread.agentCapabilities = capabilities
        } catch {
            if !Task.isCancelled { showingModels = false; modelError = error.localizedDescription }
        }
    }

    private func selectModel(_ name: String) {
        if choice != nil {
            guard canChangeModel, availableModels.contains(where: { $0.id == name }) else { return }
            let levels = thread.agentCapabilities?.model(name)?.reasoning ?? []
            if thread.draftChoice?.model == nil { thread.draftChoice?.model = .init(model: name, reasoning: "medium") }
            thread.draftChoice?.model?.selectModel(name, supportedReasoning: levels)
            showingModels = false
            return
        }
        guard canChangeModel, name != modelName, availableModels.contains(where: { $0.id == name }),
              let instance else { return }
        savingModel = true
        showingModels = false
        Task {
            defer { savingModel = false }
            do {
                try await model.updateAgent(in: area, id: instance.id) { agent in
                    agent.model.selectModel(name, supportedReasoning: thread.agentCapabilities?.model(name)?.reasoning ?? [])
                }
            } catch { modelError = error.localizedDescription }
        }
    }

    private func selectRuntime(_ runtime: String) {
        if choice != nil {
            guard canChangeRuntime, runtime != runtimeName else { return }
            thread.draftChoice?.runtime = runtime
            thread.draftChoice?.model = area.definitions.first(where: { $0.agent?.runtime.rawValue == runtime })?.agent?.model
            return
        }
        guard canChangeRuntime, runtime != runtimeName, let instance,
              let defaults = area.definitions.first(where: { $0.agent?.runtime.rawValue == runtime })?.agent?.model else { return }
        savingModel = true
        Task {
            defer { savingModel = false }
            do {
                try await model.updateAgent(in: area, id: instance.id) { agent in
                    agent.runtime = runtime
                    agent.model = defaults
                }
            } catch { modelError = error.localizedDescription }
        }
    }
}

/// 模型弹出菜单共用系统分段选择器；切换后按当前后端重新读取模型目录。
private struct ThreadModelMenu: View {
    let runtime: String
    let modelName: String?
    let models: [AgentCapabilities.Model]
    let runtimeEnabled: Bool
    let modelEnabled: Bool
    let saving: Bool
    let loading: Bool
    let runtimeExplanation: String?
    let onSelectRuntime: (String) -> Void
    let onSelectModel: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("执行后端", selection: Binding(get: { runtime }, set: onSelectRuntime)) {
                Text("Kite").tag("harness")
                Text("Claude").tag("claude")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!runtimeEnabled)
            if let runtimeExplanation {
                Text(runtimeExplanation).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if saving || loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(saving ? "正在切换…" : "正在读取模型…").foregroundStyle(.secondary)
                }
            } else if models.isEmpty {
                Text("暂无可用模型").foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    Button { onSelectModel(model.id) } label: {
                        HStack {
                            Text(model.name)
                            Spacer()
                            if modelName == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.pointingPlain)
                    .disabled(!modelEnabled)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

struct ThreadHeaderCommand: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    var enabled = true
    let action: @MainActor () -> Void
}
