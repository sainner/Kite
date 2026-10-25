import SwiftUI

struct ExecutionGrantSettings: View {
    let instance: RemotePluginInstance
    let thread: WorkThread
    /// 回到实例设置。
    let back: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var client: KitedClient?
    @State private var saved: InstanceExecutionGrants?
    @State private var draft: ExecutionGrantDraft?
    @State private var state: RemoteState?
    @State private var approval: InstanceApprovalMode?
    @State private var phase = CardPhase.idle
    @State private var discardAction: DiscardAction?
    @FocusState private var focus: ExecutionScope.Key?

    private enum DiscardAction { case back, reload }
    private var changed: Bool { draft != saved.map(ExecutionGrantDraft.init(snapshot:)) }
    private var working: Bool { phase.working }
    private var available: Bool {
        model.isConnected(area) && area.remote.workspace.status == .open
            && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var canSave: Bool {
        available && !working && changed && draft != nil && state?.status == "open"
            && state?.busy == false && state?.phase != "stopping"
            && !thread.stopping && !thread.hasUnconfirmedStop
    }

    var body: some View {
        Group {
            CardSection("当前执行") {
                LabeledContent("状态") { Text(statusLabel).foregroundStyle(.secondary) }
                if thread.hasUnconfirmedStop || state?.capabilities.interrupt == true {
                    Button(thread.hasUnconfirmedStop ? "重试停止" : "停止执行") {
                        perform {
                            _ = try boundClient()
                            try await thread.stopAndWait()
                            try await readState()
                        }
                    }.disabled(!available || thread.stopping)
                }
                Button("刷新执行状态") { perform { try await readState() } }.disabled(!available)
            }
            if let approval {
                CardSection("越界请求", note: approvalNote(approval)) {
                    LabeledContent("审批模式") {
                        Picker("审批模式", selection: Binding(get: { approval.mode }, set: { mode in perform { try await setApproval(mode) } })) {
                            ForEach(ApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().clickPointer()
                    }
                }
            }
            if let draft {
                CardSection("工作区", note: draft.project.workspace == .read ? "项目定为只读，这里改不了。"
                            : "系统工具链保留基础读取权限；宿主数据和 Git 元数据仍受保护。") {
                    Text(area.remote.workspace.cwd).font(Theme.code).foregroundStyle(.secondary).textSelection(.enabled)
                    LabeledContent("访问权限") {
                        Picker("访问权限", selection: field(\.workspace, fallback: .read)) {
                            Text("只读").tag(WorkspaceAccess.read)
                            Text("读写").tag(WorkspaceAccess.write)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().clickPointer()
                        .disabled(draft.project.workspace == .read)
                    }
                }
                CardField(label: "额外只读路径", focused: focus == .read, note: projectNote(.read)) {
                    scopeField(.read, placeholder: "每行一个绝对路径")
                }
                CardField(label: "额外读写路径", focused: focus == .write,
                          note: "每行填写一个工作机上已存在的绝对路径，读写包含读取。命令可访问这些路径；文件读取和补丁工具仍限于工作区。" + (projectNote(.write).map { "\n" + $0 } ?? "")) {
                    scopeField(.write, placeholder: "每行一个绝对路径")
                }
                CardField(label: "允许访问的网络地址", focused: focus == .network,
                          note: "每行一个域名或 IP，可带端口，支持 *.example.com。留空禁止网络；不支持全网通配或本机回环地址。" + (projectNote(.network).map { "\n" + $0 } ?? "")) {
                    scopeField(.network, placeholder: "例如 registry.npmjs.org:443")
                }
                CardField(label: "沙箱外命令", focused: focus == .unsandboxed,
                          note: "每行一条，匹配的命令不进沙箱、以你的用户身份运行。以「 *」结尾表示带任意参数，例如 docker compose *；否则须一字不差。命令会执行工作区里的脚本（如 package.json），代理能修改它们。" + (projectNote(.unsandboxed).map { "\n" + $0 } ?? "")) {
                    scopeField(.unsandboxed, placeholder: "例如 npm run dev")
                }
                CardNote("先停止执行，再保存授权。保存后用于后续工具调用，并在下一次模型请求追加通知。")
            }
        }
        .disabled(working)
        .cardSheetPage("执行授权", subtitle: "设定代理能访问的路径、网络与沙箱外命令", error: phase.error, typing: focus != nil,
                       actions: [
                           [.sheet("重新读取", systemImage: "arrow.clockwise", disabled: working || !available) {
                               if changed { discardAction = .reload } else { perform { try await load() } }
                           }],
                           [.sheet("保存", busy: working, disabled: !canSave) { perform { try await save() } }],
                       ],
                       back: { if changed { discardAction = .back } else { back() } })
        .endsTyping(focus != nil) { focus = nil }
        .interactiveDismissDisabled(working || changed)
        .discardAlert("放弃未保存的执行授权修改？", item: $discardAction) { action in
            if action == .back { back() } else { perform { try await load() } }
        }
        .task { perform { try await load() } }
        .onChange(of: thread.state) { _, value in
            if thread.connected { state = value }
        }
    }

    private var statusLabel: String {
        if thread.stopping { return "正在停止" }
        if thread.hasUnconfirmedStop { return "停止尚未确认" }
        guard let state else { return "未读取" }
        switch state.phase {
        case "stopping": return "正在停止"
        case "finishing": return "正在收尾"
        default:
            if state.busy { return "运行中" }
            return state.waitingForResume ? "等待继续" : "空闲"
        }
    }

    /// 项目给的基础许可与禁止，写在对应的输入框下面。
    private func projectNote(_ key: ExecutionScope.Key) -> String? {
        guard let project = draft?.project else { return nil }
        let given = project.allow[key], denied = project.deny[key]
        let parts = [given.isEmpty ? nil : "项目给的：\(given.joined(separator: "、"))（去掉就从这里删）",
                     denied.isEmpty ? nil : "项目禁止：\(denied.joined(separator: "、"))"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func approvalNote(_ value: InstanceApprovalMode) -> String {
        let base = "命令连接网络许可之外的主机，或代理申请在沙箱外运行命令时怎么处理。运行中也能改，下一次越界时生效。"
        return value.effective == value.mode ? base : base + "项目上限是「\(value.max.title)」，实际按「\(value.effective.title)」处理。"
    }

    private func setApproval(_ mode: ApprovalMode) async throws {
        struct Update: Encodable { let mode: ApprovalMode }
        let value = try await boundClient().request("/instances/\(instance.id)/approval-mode", method: "PUT", body: Update(mode: mode), as: InstanceApprovalMode.self)
        _ = try boundClient()
        approval = value
    }

    private func field<Value>(_ keyPath: WritableKeyPath<ExecutionGrantDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: keyPath] ?? fallback }, set: { draft?[keyPath: keyPath] = $0 })
    }

    private func scopeField(_ key: ExecutionScope.Key, placeholder: String) -> some View {
        LinesField(placeholder: placeholder, values: Binding(get: { draft?.scope[key] ?? [] }, set: { draft?.scope[key] = $0 }))
            .lineLimit(2...5).focused($focus, equals: key)
            .scrollsOnlyWhileTyping(focus == key)
            .cardInput { focus = key }
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient(in: area)
        guard available, current.machineID == area.remote.machine.id, client == nil || client == current else {
            throw KitedError(message: "工作机或实例已变化，请重新打开实例设置")
        }
        return current
    }

    private func load() async throws {
        let client = try boundClient()
        self.client = client
        async let snapshot = client.request("/instances/\(instance.id)/execution-grants", as: InstanceExecutionGrants.self)
        async let execution = client.request("/threads/\(instance.id)/state", as: RemoteState.self)
        async let mode = client.request("/instances/\(instance.id)/approval-mode", as: InstanceApprovalMode.self)
        let (value, state, approval) = try await (snapshot, execution, mode)
        _ = try boundClient()
        self.approval = approval
        saved = value
        draft = ExecutionGrantDraft(snapshot: value)
        self.state = state
    }

    private func readState() async throws {
        let value = try await boundClient().request("/threads/\(instance.id)/state", as: RemoteState.self)
        _ = try boundClient()
        state = value
    }

    private func save() async throws {
        guard let draft else { return }
        let value = try await boundClient().request("/instances/\(instance.id)/execution-grants", method: "PUT", body: draft.request, as: InstanceExecutionGrants.self)
        _ = try boundClient()
        saved = value
        self.draft = ExecutionGrantDraft(snapshot: value)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        $phase.run(action)
    }
}
