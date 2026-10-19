import SwiftUI

/// 集成结果：直接合入时合进主线后推送，推送失败不撤销本地主线，下次集成时一并推上去；提交 PR 时推到 PR 分支。
struct RemoteAdoptResult: Decodable {
    /// 推送失败时 gitLogin 是要求登录的远程主机。
    struct Push: Decodable { let status: String; let message: String?; let gitLogin: String? }
    let status: String
    let files: [String]?
    let push: Push?
    let branch: String?
    let url: String?
    let number: Int?

    var summary: String {
        if status == "conflict" { return conflictSummary(files) }
        if status == "proposed" {
            return number.map { "已推到分支 \(branch ?? "")，PR #\($0) 已更新" } ?? "已推到分支 \(branch ?? "")，去网页上开 PR"
        }
        if push?.status == "pushed" { return "已合进主线并推送到远程" }
        if push?.status == "local" { return "已合进主线；项目没有远程，其他工作机同步时会快进过来" }
        return "已合进主线，推送失败：\(push?.message ?? "未知原因")"
    }
}

/// 集成或同步把主线合进工作区分支时冲突了。
private func conflictSummary(_ files: [String]?) -> String {
    "合并有冲突，已交给工作区里的 agent 处理：\((files ?? []).joined(separator: "、"))"
}

/// 同步结果：把主线的新改动合进工作区分支，不推送。
struct RemoteSyncResult: Decodable {
    let status: String
    let files: [String]?

    var summary: String {
        switch status {
        case "conflict": conflictSummary(files)
        case "current": "已是最新"
        default: "已把主线的新改动合进工作区"
        }
    }
}

/// 子工作区合回父工作区的结果：合进去或没有改动时子工作区已归档，冲突交给了子工作区里的 agent，处理完由工作机接着合。
struct RemoteMergeResult: Decodable {
    let status: String
    let files: [String]?

    var summary: String {
        switch status {
        case "conflict": conflictSummary(files)
        case "unchanged": "子工作区没有改动，已归档"
        default: "已合回父工作区并归档"
        }
    }
}

private struct ConfirmRecovery: Encodable { let confirmRecovery = true }

extension AppModel {
    /// 项目登记表里的集成方式：提交 PR 为 true，直接合入为 false；登记表还没读到时为 nil。
    func proposes(_ area: WorkArea) -> Bool? {
        let project = area.remote.project
        if project.remote == nil { return false }
        return account.registeredProjects.first { $0.id == project.id }?.proposes
    }

    /// 合进了主线、推送时远程要求登录：当成要登录的失败报出（见 GitLogin），绑好令牌后再集成一次就推上去。
    func adopt(_ area: WorkArea) async throws -> RemoteAdoptResult {
        let client = try activeClient(in: area)
        let result: RemoteAdoptResult = try await mergeMainline(area, "adopt", via: client)
        if let host = result.push?.gitLogin { throw KitedError(message: result.summary, gitLogin: host, machineID: client.machineID) }
        return result
    }

    func syncMainline(_ area: WorkArea) async throws -> RemoteSyncResult { try await mergeMainline(area, "sync", via: activeClient(in: area)) }

    /// 子工作区合回父工作区，见 kited 的 /workspaces/:id/merge。
    func merge(_ area: WorkArea) async throws -> RemoteMergeResult { try await mergeMainline(area, "merge", via: activeClient(in: area)) }

    /// 按项目的集成方式集成；还有子工作区没合回或放弃时不报错，交给用户逐个处理（pendingChildren）。
    func integrate(_ area: WorkArea, toast: ToastCenter?) {
        perform(toast: toast) { [self] in
            do { return try await adopt(area).summary }
            catch let error as KitedError where !(error.children ?? []).isEmpty {
                pendingChildren = PendingChildren(area: area, children: error.children ?? [])
                return nil
            }
        }
    }

    /// 用户手动集成（adopt）、同步（sync）、合回（merge）、流转，连带确认工作区里待恢复的线程，见 kited 的 confirmWorkspaceRecovery。
    private func mergeMainline<Result: Decodable>(_ area: WorkArea, _ action: String, via client: KitedClient) async throws -> Result {
        let result = try await client.request("/workspaces/\(area.remote.workspace.id)/\(action)", method: "POST", body: ConfirmRecovery(),
                                              timeout: 600, as: Result.self)
        try await refresh(client)
        return result
    }

    func archive(_ area: WorkArea, force: Bool) async throws {
        struct Archive: Encodable { let force: Bool }
        let client = try activeClient(in: area)
        let _: JSON = try await client.request("/workspaces/\(area.remote.workspace.id)/archive", method: "POST", body: Archive(force: force), timeout: 120, as: JSON.self)
        try await refresh(client)
    }

    /// 交给工作区所在的工作机办：它交出工作区、让目标还原，没成就撤回，见 kited 的 /workspaces/:id/transfer。
    func transfer(_ area: WorkArea, to target: WorkerConnection) async throws {
        struct Transfer: Encodable { let to: String; let operationId: String; let confirmRecovery = true }
        let client = try activeClient(in: area)
        let _: JSON = try await client.request("/workspaces/\(area.remote.workspace.id)/transfer", method: "POST",
                                               body: Transfer(to: target.machine.id, operationId: UUID().uuidString.lowercased()),
                                               timeout: 1800, as: JSON.self)
        try? await refresh(target.client)
        try? await refresh(client)
    }

    /// 所在工作机已丢失：用 target 手上的副本强制接管，副本没跟上的部分会丢。子工作区由 target 跟着一起接管。
    func takeOver(_ area: WorkArea, on target: WorkerConnection) async throws {
        guard target.connected else { throw KitedError(message: "\(target.machine.name) 未连接") }
        struct Restore: Encodable { let workspaceId: String; let operationId: String; let force: Bool }
        let _: JSON = try await target.client.request("/workspaces/restore", method: "POST",
                                                      body: Restore(workspaceId: area.remote.workspace.id, operationId: UUID().uuidString.lowercased(), force: true),
                                                      timeout: 1800, as: JSON.self)
        try? await refresh(target.client)
    }
}

/// 侧栏工作区行的右键菜单：同步主线、按项目的集成方式集成、打开 PR、归档；子工作区只有合回父工作区与放弃。
struct WorkspaceGitActions: View {
    let workspace: WorkArea
    var showsWorkspaceMenu = false
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast
    @Environment(\.openURL) private var openURL

    var body: some View {
        if workspace.remote.workspace.parentId != nil {
            Button("合回父工作区") { merge() }
                .disabled(!model.isConnected(workspace) || workspace.remote.workspace.status != .open)
            MenuButton("放弃子工作区…", role: .destructive) { model.archiveRequest = workspace }
                .disabled(!model.isConnected(workspace))
        } else if showsWorkspaceMenu {
            Button(integrateTitle) { integrate() }
                .disabled(!model.isConnected(workspace))
            Button(syncTitle) { sync() }
                .disabled(!model.isConnected(workspace))
            MenuButton("丢弃改动", role: .destructive) { }
                .disabled(true)
                .help("尚未接通")
            Divider()
            MenuButton("删除工作区", role: .destructive) { }
                .disabled(true)
                .help("尚未接通")
        } else {
            Button(syncTitle) { sync() }
            Button(integrateTitle) { integrate() }
            if let pull = workspace.remote.workspace.pullRequest, let url = URL(string: pull.url) {
                Button(pull.number.map { "打开 PR #\($0)" } ?? "去网页上开 PR") { openURL(url) }
            }
            // Line 的工作区随 Line 存在，不能归档
            if model.lineArea?.id != workspace.id {
                MenuButton("归档工作区…", role: .destructive) { model.archiveRequest = workspace }
            }
        }
    }

    private var integrateTitle: String {
        switch model.proposes(workspace) {
        case true?: "提交 PR"
        case false?: "集成到主线并推送"
        case nil: "集成改动"
        }
    }

    private var syncTitle: String {
        guard let behind = workspace.remote.workspace.behind, behind > 0 else { return "同步主线" }
        return "同步主线（落后 \(behind) 个提交）"
    }

    private func integrate() { model.integrate(workspace, toast: toast) }

    private func merge() { model.perform(toast: toast) { [model, workspace] in try await model.merge(workspace).summary } }

    private func sync() { model.perform(toast: toast) { [model, workspace] in try await model.syncMainline(workspace).summary } }
}

/// 强制接管：所在工作机连不上时，由用户确认它已丢失，用 target 手上的副本接管。
struct TakeoverRequest: Identifiable {
    let area: WorkArea
    let target: WorkerConnection
    var id: String { "\(area.id)/\(target.id)" }
}

/// 工作区的流转入口（docs/Line与工作区流转.md「工作区流转」）：所在工作机连着时流转到另一台连着的工作机；
/// 所在工作机离线时换成强制接管，确认后才执行；所在工作机在线但这台设备连不上时两样都不给。
struct WorkspaceTransferMenu: View {
    let workspace: WorkArea
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast

    var body: some View {
        let remote = workspace.remote
        let targets = model.availableWorkers.filter { $0.machine.id != remote.machine.id }
        let status = model.deviceStatus(model.connection(for: workspace))
        // 父工作区也在这台工作机上的子工作区随父工作区流转与接管
        let follows = model.parent(of: workspace) != nil
        if status.ready || status.waiting {
            Menu("流转到") {
                ForEach(targets) { target in
                    Button(target.machine.name) { transfer(to: target) }
                }
            }
            .disabled(!status.ready || targets.isEmpty || remote.workspace.status != .open || follows)
            .help(follows ? "子工作区随父工作区一起流转" : "")
        } else {
            Menu("强制接管到") {
                ForEach(targets) { target in
                    Button(target.machine.name) { model.takeoverRequest = TakeoverRequest(area: workspace, target: target) }
                }
            }
            .disabled(targets.isEmpty || follows)
            .help(follows ? "子工作区随父工作区一起接管" : "")
        }
    }

    private func transfer(to target: WorkerConnection) {
        let toast = toast
        let title = workspace.title
        model.perform(toast: toast) { [model, workspace] in
            toast?.show("正在把「\(title)」流转到 \(target.machine.name)…")
            try await model.transfer(workspace, to: target)
            return "「\(title)」已流转到 \(target.machine.name)"
        }
    }
}

/// 挂在主窗口与 iPhone 根部，承接侧栏菜单发起的归档与强制接管确认，以及菜单和页面发起的操作遇到远程要求登录时的就地登录
/// （AppModel.gitLogin）：先说明原因、问要不要「登录 host」，绑好令牌后重跑那次操作。
struct WorkspaceGitPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast
    @State private var loggingIn: GitLogin?

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(model.archiveRequest?.remote.workspace.parentId == nil ? "归档工作区" : "放弃子工作区",
                   isPresented: Binding { model.archiveRequest != nil } set: { if !$0 { model.archiveRequest = nil } },
                   presenting: model.archiveRequest) { area in
                if area.remote.workspace.parentId == nil {
                    Button("归档", role: .destructive) { archive(area, force: false) }
                    Button("丢弃未集成的改动并归档", role: .destructive) { archive(area, force: true) }
                } else {
                    Button("放弃", role: .destructive) { archive(area, force: true) }
                }
                Button("取消", role: .cancel) {}
            } message: { area in
                Text(archiveMessage(area))
            }
            .sheet(item: $model.pendingChildren) { PendingChildrenSheet(request: $0).environment(model).toastHost().appAppearance() }
            .alert("强制接管工作区", isPresented: Binding { model.takeoverRequest != nil } set: { if !$0 { model.takeoverRequest = nil } },
                   presenting: model.takeoverRequest) { request in
                Button("强制接管", role: .destructive) { takeOver(request) }
                Button("取消", role: .cancel) {}
            } message: { request in
                Text("确认「\(request.area.remote.machine.name)」已经丢失，用「\(request.target.machine.name)」手上的副本接管「\(request.area.title)」。副本没跟上的部分会丢失；原来的工作机回来后，它那份记录会冻结，多出的改动存成快照留给你合并。")
            }
            .alert("远程要求登录", isPresented: Binding { model.gitLogin != nil } set: { if !$0 { model.gitLogin = nil } },
                   presenting: model.gitLogin) { login in
                Button("登录 \(login.host)") { loggingIn = login }
                Button("取消", role: .cancel) {}
            } message: { login in
                Text(login.message)
            }
            .sheet(item: $loggingIn) { GitLoginSheet($0).environment(model).toastHost().appAppearance() }
    }

    private func takeOver(_ request: TakeoverRequest) {
        model.perform(toast: toast) { [model] in
            try await model.takeOver(request.area, on: request.target)
            return "已在 \(request.target.machine.name) 上接管「\(request.area.title)」"
        }
    }

    /// 归档或放弃会停下什么、丢掉什么；下面还挂着子工作区时说明它们一并归档。
    private func archiveMessage(_ area: WorkArea) -> String {
        let count = model.descendants(of: area).count
        let children = count == 0 ? "" : "它下面的 \(count) 个子工作区一并归档。"
        if area.remote.workspace.parentId != nil { return discardChildMessage(area.title) + children }
        return (area.remote.workspace.pullRequest?.state == "merged"
                ? "「\(area.title)」的 PR 已经合并。归档会停止其中的线程并回收工作树。"
                : "归档「\(area.title)」会停止其中的线程并回收工作树。还没集成的改动只有选择丢弃时才会删除。") + children
    }

    private func archive(_ area: WorkArea, force: Bool) {
        let toast = toast
        Task {
            do { try await model.archive(area, force: force); toast?.show("已归档") }
            catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
        }
    }
}

/// 放弃子工作区的说明，侧栏菜单与集成前的处理表共用。
private func discardChildMessage(_ title: String) -> String {
    "放弃「\(title)」会停止其中的线程、回收工作树，改动不合回父工作区；快照留着。"
}

/// 集成被还没合回的子工作区挡住：用户逐个合回或放弃，处理完再接着集成，或暂不集成，见 docs/项目与远程仓库.md「子工作区」。
struct PendingChildren: Identifiable {
    let area: WorkArea
    let children: [KitedError.Child]
    var id: String { area.id }
}

struct PendingChildrenSheet: View {
    let request: PendingChildren
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.toast) private var toast
    /// 处理过的子工作区与结果的说明。
    @State private var handled: [String: String] = [:]
    @State private var working: String?
    @State private var discarding: KitedError.Child?
    @State private var error: String?

    var body: some View {
        CardSheet(title: "还有子工作区没合回", subtitle: "逐个合回或放弃，处理完再集成", error: error, close: { dismiss() }) {
            CardSection(note: "「\(request.area.title)」下面这些子工作区的改动还没合回，下层的排在前面，先合回它们。") {
                ForEach(request.children) { child in
                    LabeledContent {
                        if let note = handled[child.id] {
                            Text(note).foregroundStyle(.secondary)
                        } else if working == child.id {
                            ProgressView().controlSize(.small)
                        } else {
                            HStack(spacing: 16) {
                                Button("合回") { merge(child) }
                                    .foregroundStyle(Color.accentColor)
                                Button("放弃") { discarding = child }
                                    .foregroundStyle(Theme.danger)
                            }
                            .buttonStyle(.pointingPlain)
                            .disabled(working != nil || model.workspace(child.id) == nil)
                        }
                    } label: {
                        Text(child.name).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        } actions: {
            CardSheetAction(title: "集成", action: integrate)
                .disabled(working != nil || handled.count < request.children.count)
        }
        .alert("放弃子工作区", isPresented: Binding { discarding != nil } set: { if !$0 { discarding = nil } }, presenting: discarding) { child in
            Button("放弃", role: .destructive) { discard(child) }
            Button("取消", role: .cancel) {}
        } message: { child in
            Text(discardChildMessage(child.name))
        }
    }

    private func merge(_ child: KitedError.Child) {
        guard let area = model.workspace(child.id) else { return }
        run(child) {
            let result = try await model.merge(area)
            // 有冲突时这一项留着，等子工作区里的 agent 处理完由工作机接着合回
            if result.status == "conflict" { toast?.show(result.summary); return nil }
            return result.summary
        }
    }

    private func discard(_ child: KitedError.Child) {
        guard let area = model.workspace(child.id) else { return }
        run(child) {
            try await model.archive(area, force: true)
            return "已放弃"
        }
    }

    /// action 返回这一项处理后的说明；返回 nil 时没处理完（合回有冲突），这一项留着。
    private func run(_ child: KitedError.Child, _ action: @escaping @MainActor () async throws -> String?) {
        working = child.id
        error = nil
        Task {
            do { if let note = try await action() { handled[child.id] = note } }
            catch { self.error = error.localizedDescription }
            // 上层合回或放弃后，它下面的随之归档
            for other in request.children where handled[other.id] == nil && model.workspace(other.id) == nil { handled[other.id] = "已随上层归档" }
            working = nil
        }
    }

    /// 关掉这一页再集成：集成仍被挡住时会重新列出剩下的。
    private func integrate() {
        dismiss()
        model.integrate(request.area, toast: toast)
    }
}
