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
    @State private var phase = CardPhase.idle
    @State private var discardAction: DiscardAction?
    @State private var confirmingRecovery = false
    @FocusState private var focus: Field?

    private enum Field { case read, write, network }

    private enum DiscardAction { case back, reload }
    private var changed: Bool { draft?.grants != saved?.grants }
    private var working: Bool { phase.working }
    private var available: Bool {
        model.isConnected(area) && area.remote?.workspace.status == .open
            && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var canSave: Bool {
        available && !working && changed && draft != nil && state?.status == "open"
            && state?.busy == false && state?.phase != "stopping" && state?.recovery == nil
            && !thread.stopping && !thread.hasUnconfirmedStop
    }

    var body: some View {
        CardSheet(title: "执行授权", subtitle: instance.title, typing: focus != nil, back: true, size: InstanceSettings.size,
                  close: { if changed { discardAction = .back } else { back() } }) {
            Group {
                CardSection("当前执行", note: state?.recovery?.message) {
                    LabeledContent("状态") { Text(statusLabel).foregroundStyle(.secondary) }
                    if state?.recovery != nil {
                        Button("确认上次执行结果…") { confirmingRecovery = true }
                            .disabled(!available || state?.busy == true || thread.stopping || thread.hasUnconfirmedStop)
                    }
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
                if draft != nil {
                    CardSection("工作区", note: "系统工具链保留基础读取权限；宿主数据和 Git 元数据仍受保护。") {
                        if let path = area.remote?.workspace.cwd {
                            Text(path).font(Theme.code).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        LabeledContent("访问权限") {
                            Picker("访问权限", selection: field(\.workspace, fallback: .read)) {
                                Text("只读").tag(ExecutionGrants.WorkspaceAccess.read)
                                Text("读写").tag(ExecutionGrants.WorkspaceAccess.write)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                    }
                    Group {
                        CardField(label: "额外只读路径", focused: focus == .read) {
                            TextField("每行一个绝对路径", text: field(\.readPaths, fallback: ""), axis: .vertical)
                                .lineLimit(2...5).focused($focus, equals: .read)
                                .cardInput { focus = .read }
                        }
                        CardField(label: "额外读写路径", focused: focus == .write,
                                  note: "每行填写一个工作机上已存在的绝对路径，读写包含读取。命令可访问这些路径；文件读取和补丁工具仍限于工作区。") {
                            TextField("每行一个绝对路径", text: field(\.writePaths, fallback: ""), axis: .vertical)
                                .lineLimit(2...5).focused($focus, equals: .write)
                                .cardInput { focus = .write }
                        }
                        CardField(label: "允许访问的网络地址", focused: focus == .network,
                                  note: "每行一个域名或 IP，可带端口，支持 *.example.com。留空禁止网络；不支持全网通配或本机回环地址。") {
                            TextField("例如 registry.npmjs.org:443", text: field(\.networkDomains, fallback: ""), axis: .vertical)
                                .lineLimit(2...5).focused($focus, equals: .network)
                                .cardInput { focus = .network }
                        }
                    }
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    CardNote("先停止执行并确认结果，再保存授权。保存后用于后续工具调用，并在下一次模型请求追加通知。")
                }
            }
            .disabled(working)
        } actions: {
            CardSheetAction(title: "重新读取", systemImage: "arrow.clockwise") {
                if changed { discardAction = .reload } else { perform { try await load() } }
            }
            .disabled(working || !available)
        } footer: {
            CardActions(primary: "保存", enabled: canSave, phase: $phase) { perform(succeeds: true) { try await save() } }
        }
        .endsTyping(focus != nil) { focus = nil }
        .interactiveDismissDisabled(working || changed)
        .confirmationDialog("放弃未保存的执行授权修改？", isPresented: Binding(
            get: { discardAction != nil }, set: { if !$0 { discardAction = nil } }
        ), titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                let action = discardAction
                discardAction = nil
                if action == .back { back() } else { perform { try await load() } }
            }
        }
        .confirmationDialog("确认上次执行结果？", isPresented: $confirmingRecovery, titleVisibility: .visible) {
            Button("已核对，确认结果") {
                perform {
                    try await boundClient().post("/threads/\(instance.id)/recover")
                    try await readState()
                }
            }
        } message: {
            Text("请先核对文件改动，并确认残留命令已停止。确认后可修改授权；会话等待你显式继续。")
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
        if state.recovery != nil { return "执行结果待确认" }
        switch state.phase {
        case "stopping": return "正在停止"
        case "finishing": return "正在收尾"
        default:
            if state.busy { return "运行中" }
            return state.waitingForResume ? "等待继续" : "空闲"
        }
    }

    private func field<Value>(_ keyPath: WritableKeyPath<ExecutionGrantDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: keyPath] ?? fallback }, set: { draft?[keyPath: keyPath] = $0 })
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient(in: area)
        guard available, current.machineID == area.remote?.machine.id, client == nil || client == current else {
            throw KitedError(message: "工作机或实例已变化，请重新打开实例设置")
        }
        return current
    }

    private func load() async throws {
        let client = try boundClient()
        self.client = client
        async let snapshot = client.request("/instances/\(instance.id)/execution-grants", as: InstanceExecutionGrants.self)
        async let execution = client.request("/threads/\(instance.id)/state", as: RemoteState.self)
        let (value, state) = try await (snapshot, execution)
        _ = try boundClient()
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

    private func perform(succeeds: Bool = false, _ action: @escaping () async throws -> Void) {
        $phase.run(succeeds: succeeds, action)
    }
}
