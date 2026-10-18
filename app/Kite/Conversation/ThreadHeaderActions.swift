import SwiftUI

/// 模型入口和会话操作跟随当前窗口的实例，不依赖工作区中哪个线程先打开。
struct ThreadHeaderActions: View {
    @Environment(WorkThread.self) private var thread
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model
    @Environment(\.paneInstance) private var instance
    @Environment(\.paneOverflowActions) private var windowActions
    @State private var savingModel = false
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var showingDraftSettings = false
    /// 选了审批模式、工作机推回的实例配置还没跟上时先按它算。
    @State private var pendingApproval: ApprovalMode?
    @State private var approvalError: String?
    private var availableModels: [AgentCapabilities.Model] { thread.agentCapabilities?.models ?? [] }
    /// 草稿还没有实例，模型改的是本机选择，随第一条消息一起提交。
    private var choice: DraftAgentChoice? { instance == nil ? thread.draftChoice : nil }
    private var role: AgentRole? { model.newThreadRole(for: thread, in: area) }
    private var agentModel: AgentModelConfiguration? { model.agentModel(for: thread, instance: instance, in: area) }
    private var modelName: String? { agentModel?.model }

    private var modelTier: String {
        guard let modelName else { return "模型" }
        return availableModels.first { modelName == $0.id }?.title ?? modelName
    }
    private var modelLogo: ImageResource? {
        ThreadModelMenu.logo(vendor: availableModels.first { $0.id == modelName }?.vendor)
    }
    /// 重新读取期间沿用上次的能力显示模型名，但不凭它放开修改。
    private var canChangeModel: Bool {
        if choice != nil { return model.isConnected(area) && thread.agentCapabilities != nil }
        return instance != nil && model.isConnected(area) && !savingModel && !loadingModels
            && thread.agentCapabilities?.canEdit(thread.state) == true
    }
    private var canOpenModels: Bool { (instance != nil || choice != nil) && model.isConnected(area) }
    /// 审批模式：已有代理是工作机写在实例配置里的；草稿是本机选择，没选是角色的默认，角色也没给是工作机的默认。
    /// 都取不到（角色目录还没读到，或旧版工作机）时为空，菜单里不勾选。
    private var storedApproval: ApprovalMode? {
        guard let instance else { return thread.draftChoice?.approval ?? roleApproval }
        return area.instances.first { $0.id == instance.id }?.config?.approval
    }
    private var roleApproval: ApprovalMode? { role?.role.approval ?? model.roles(in: area)?.defaultApproval }
    private var approval: ApprovalMode? { pendingApproval ?? storedApproval }
    /// 换到另一厂商的模型就是换后端，运行中或有排队消息时不能换；待恢复时换后端连带确认恢复。
    private var canChangeVendor: Bool {
        if choice != nil { return canOpenModels }
        return canOpenModels && !savingModel && !loadingModels && !thread.showStop && thread.state?.capabilities.switchRuntime == true
    }

    var body: some View {
        menuGroup
            .sheet(isPresented: $showingDraftSettings) {
                DraftAgentSettings().environment(model).environment(area).environment(thread)
            }
            // 草稿的选项已含全部角色，换角色不重新读取；角色目录晚到时再按默认角色取一次能力。
            .task(id: "\(model.revision(for: area))-\(model.isConnected(area))-\(instance?.config?.agent?.runtime ?? "draft:\(role != nil)")") {
                if choice != nil { await loadDraftOptions(); return }
                guard model.isConnected(area), let instance else { return }
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
                    if !Task.isCancelled { modelError = error.localizedDescription }
                }
            }
            .alert("切换模型失败", isPresented: Binding(
                get: { modelError != nil }, set: { if !$0 { modelError = nil } }
            )) {
                Button("好", role: .cancel) { modelError = nil }
            } message: { Text(modelError ?? "") }
            .onChange(of: storedApproval) { _, value in if value == pendingApproval { pendingApproval = nil } }
            .alert("修改审批模式失败", isPresented: Binding(get: { approvalError != nil }, set: { if !$0 { approvalError = nil } })) {
                Button("好", role: .cancel) { approvalError = nil }
            } message: { Text(approvalError ?? "") }
    }

    private var menuGroup: some View {
        #if os(iOS)
        PhoneThreadHeaderMenus(modelTitle: modelTier, modelLogo: modelLogo, modelName: modelName,
            modelEnabled: canOpenModels, models: modelMenu, commands: moreCommands)
            .fixedSize()
            .modifier(PhoneThreadMenuGlass())
        #else
        MacThreadHeaderMenus(modelTitle: modelTier, modelLogo: modelLogo, modelName: modelName,
            modelEnabled: canOpenModels, models: modelMenu, commands: moreCommands)
            .fixedSize()
        #endif
    }

    /// 每个厂商一节，当前模型打勾；换厂商受限时其他厂商的模型置灰，并在末尾说明原因。
    private var modelMenu: ThreadModelMenu {
        let status = savingModel ? "正在切换…" : loadingModels ? "正在读取模型…" : availableModels.isEmpty ? "暂无可用模型" : nil
        let vendors = thread.agentCapabilities?.vendors ?? []
        let current = availableModels.first { $0.id == modelName }?.vendor
        let sections = ThreadModelMenu.sections(vendors: vendors, models: availableModels, selected: modelName) { model in
            canChangeModel && (model.vendor == current || canChangeVendor)
        }
        let locked = !canChangeVendor && thread.state?.capabilities.switchRuntime == false && sections.count > 1
        return ThreadModelMenu(vendors: status == nil ? sections : [], status: status,
                               note: status == nil && locked ? "运行中或有排队消息时不能换厂商" : nil,
                               select: selectModel)
    }

    /// 两端菜单使用相同的可用状态和业务动作；卡片太窄时窗口操作也收在这里，排最前。
    private var moreCommands: [[ThreadHeaderCommand]] {
        var general: [ThreadHeaderCommand] = []
        if let instance {
            general += InstanceAction.managing(instance, in: area, model: model).map { action in
                ThreadHeaderCommand(title: action.title, symbol: action.symbol, enabled: action.enabled, destructive: action.destructive, action: action.perform)
            }
        }
        if choice != nil {
            general.append(.init(title: "配置", symbol: "slider.horizontal.3",
                                 enabled: thread.agentCapabilities != nil) { showingDraftSettings = true })
        }
        // 审批模式紧跟配置
        if instance != nil || choice != nil {
            general.insert(.choice("审批模式", symbol: approval?.symbol ?? "shield", enabled: model.isConnected(area) && pendingApproval == nil,
                                   options: ApprovalMode.allCases.map { mode in .init(title: mode.title, selected: mode == approval) { chooseApproval(mode) } }),
                           at: min(1, general.count))
        }
        // 调试：对话区和原始记录来回换，单独一节放最后
        let debug: [ThreadHeaderCommand] = instance == nil ? [] : [
            .init(title: thread.raw == nil ? "原始记录" : "返回对话",
                  symbol: thread.raw == nil ? "curlybraces" : "bubble.left.and.bubble.right") {
                thread.raw = thread.raw == nil ? RawTranscript() : nil
            },
        ]
        // 停止、继续和恢复确认都归输入区：待恢复时发送或继续即确认。
        return [windowActions?.commands ?? [], general, debug].filter { !$0.isEmpty }
    }

    /// 审批模式：越界请求（连名单外的主机、申请出沙箱）怎么处理。已有代理改工作机上的实例，运行中也能改，下一次越界时生效；
    /// 草稿改本机选择，随第一条消息提交，和角色默认一样时不提交。
    private func chooseApproval(_ mode: ApprovalMode) {
        guard mode != approval else { return }
        guard let instance else {
            thread.draftChoice?.approval = mode == roleApproval ? nil : mode
            return
        }
        pendingApproval = mode
        let model = model, area = area
        Task {
            struct Update: Encodable { let mode: ApprovalMode }
            do {
                _ = try await model.activeClient(in: area).request("/instances/\(instance.id)/approval-mode", method: "PUT",
                                                                   body: Update(mode: mode), as: InstanceApprovalMode.self)
                if storedApproval == mode { pendingApproval = nil }
            } catch {
                pendingApproval = nil
                approvalError = error.localizedDescription
            }
        }
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
            if !Task.isCancelled { modelError = error.localizedDescription }
        }
    }

    private func selectModel(_ name: String) {
        let levels = thread.agentCapabilities?.model(name)?.reasoning ?? []
        if choice != nil {
            guard canChangeModel, availableModels.contains(where: { $0.id == name }), var selected = agentModel else { return }
            selected.selectModel(name, supportedReasoning: levels)
            thread.draftChoice?.model = selected
            return
        }
        guard canChangeModel, name != modelName, availableModels.contains(where: { $0.id == name }),
              let instance else { return }
        savingModel = true
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

extension ThreadModelMenu {
    /// 每个厂商一节，没有模型的厂商不列。
    static func sections(vendors: [AgentCapabilities.Vendor], models: [AgentCapabilities.Model], selected: String?,
                         enabled: (AgentCapabilities.Model) -> Bool) -> [Vendor] {
        vendors.map { vendor in
            Vendor(id: vendor.id, title: vendors.count > 1 ? vendor.title : nil,
                   models: models.filter { $0.vendor == vendor.id }.map { model in
                       Model(id: model.id, name: model.name, selected: model.id == selected, enabled: enabled(model))
                   })
        }.filter { !$0.models.isEmpty }
    }
}
