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
    @State private var showingDraftSettings = false
    private var availableModels: [AgentCapabilities.Model] { thread.agentCapabilities?.models ?? [] }
    /// 草稿还没有实例，模型改的是本机选择，随第一条消息一起提交。
    private var choice: DraftAgentChoice? { instance == nil ? thread.draftChoice : nil }
    private var role: AgentRole? { model.newThreadRole(for: thread, in: area) }
    /// 草稿没改过模型时用角色的默认模型。
    private var draftModel: AgentModelConfiguration? { choice.flatMap { $0.model ?? role?.role.model } }
    private var modelName: String? { instance?.config?.agent?.model.model ?? draftModel?.model }

    private var modelTier: String {
        guard let modelName else { return "模型" }
        return availableModels.first { modelName == $0.id }?.title ?? modelName
    }
    private var canChangeModel: Bool {
        if choice != nil { return model.isConnected(area) && thread.agentCapabilities != nil }
        return instance != nil && model.isConnected(area) && !savingModel
            && thread.agentCapabilities?.canEdit(thread.state) == true
    }
    private var canOpenModels: Bool { (instance != nil || choice != nil) && model.isConnected(area) }
    /// 换到另一厂商的模型就是换后端，运行中、有排队消息或等待恢复确认时不能换。
    private var canChangeVendor: Bool {
        if choice != nil { return canOpenModels }
        return canOpenModels && !savingModel && !thread.showStop && thread.state?.capabilities.switchRuntime == true
    }

    var body: some View {
        menuGroup
            .popover(isPresented: $showingModels, arrowEdge: .top) {
                ThreadModelMenu(modelName: modelName, vendors: thread.agentCapabilities?.vendors ?? [], models: availableModels,
                    vendorEnabled: canChangeVendor, modelEnabled: canChangeModel, saving: savingModel,
                    loading: loadingModels,
                    vendorExplanation: thread.state?.capabilities.switchRuntime == false
                        ? "运行中、有排队消息或等待恢复确认时不能换到其他厂商的模型。" : nil,
                    onSelectModel: selectModel)
                    .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: $showingDraftSettings) {
                DraftAgentSettings().environment(model).environment(area).environment(thread)
            }
            .task(id: "\(model.revision(for: area))-\(model.isConnected(area))-\(instance?.config?.agent?.runtime ?? "draft:\(role?.id ?? "")")") {
                if choice != nil { await loadDraftOptions(); return }
                guard model.isConnected(area), let instance else { return }
                thread.agentCapabilities = nil
                loadingModels = true
                defer { if !Task.isCancelled { loadingModels = false } }
                do {
                    let client = try model.activeClient(in: area)
                    let revision = model.revision(for: area)
                    let runtime = instance.config?.agent?.runtime
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
            .alert("确认恢复代理", isPresented: $confirmingRecovery) {
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
            general.append(.init(title: "归档代理", symbol: "archivebox",
                                 enabled: model.isConnected(area)) { area.archiveRequest = instance })
        }
        if choice != nil {
            general.append(.init(title: "代理配置", symbol: "slider.horizontal.3",
                                 enabled: thread.agentCapabilities != nil) { showingDraftSettings = true })
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

    /// 草稿按工作区读取模型目录与各角色可开的工具，再按所选角色给出能力。
    private func loadDraftOptions() async {
        guard model.isConnected(area) else { return }
        loadingModels = true
        defer { if !Task.isCancelled { loadingModels = false } }
        do {
            let client = try model.activeClient(in: area)
            let options = try await client.request("/workspaces/\(area.id)/agent-options", as: AgentOptions.self)
            guard !Task.isCancelled, thread.draftChoice != nil else { return }
            thread.agentOptions = options
            if let role { thread.agentCapabilities = options.capabilities(for: role.id) }
        } catch {
            if !Task.isCancelled { showingModels = false; modelError = error.localizedDescription }
        }
    }

    private func selectModel(_ name: String) {
        let levels = thread.agentCapabilities?.model(name)?.reasoning ?? []
        if choice != nil {
            guard canChangeModel, availableModels.contains(where: { $0.id == name }), var selected = draftModel else { return }
            selected.selectModel(name, supportedReasoning: levels)
            thread.draftChoice?.model = selected
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
                // 换厂商即换后端，由工作机按模型推出。
                try await model.updateAgent(in: area, id: instance.id) { agent in
                    agent.model.selectModel(name, supportedReasoning: levels)
                }
            } catch { modelError = error.localizedDescription }
        }
    }
}

/// 模型弹出菜单：系统分段选择器按厂商分类，列出该厂商的模型；后端随所选模型确定，不单独出现。
private struct ThreadModelMenu: View {
    let modelName: String?
    let vendors: [AgentCapabilities.Vendor]
    let models: [AgentCapabilities.Model]
    let vendorEnabled: Bool
    let modelEnabled: Bool
    let saving: Bool
    let loading: Bool
    let vendorExplanation: String?
    let onSelectModel: (String) -> Void
    /// 正在浏览的厂商；没翻过时停在当前模型所属的厂商。
    @State private var browsing: String?

    private var current: String? { models.first { $0.id == modelName }?.vendor }
    private var vendor: String { browsing ?? current ?? vendors.first?.id ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vendors.count > 1 {
                Picker("厂商", selection: Binding(get: { vendor }, set: { browsing = $0 })) {
                    ForEach(vendors) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if vendor != current, !vendorEnabled, let vendorExplanation {
                Text(vendorExplanation).font(.caption).foregroundStyle(.secondary)
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
                ForEach(models.filter { $0.vendor == vendor }) { model in
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
                    .disabled(!modelEnabled || (model.vendor != current && !vendorEnabled))
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
