import SwiftUI

/// 集成结果：直接合入时合进主线后推送，推送失败不撤销本地主线，下次集成时一并推上去；提交 PR 时推到 PR 分支。
struct RemoteAdoptResult: Decodable {
    struct Push: Decodable { let status: String; let message: String? }
    let status: String
    let files: [String]?
    let push: Push?
    let branch: String?
    let url: String?
    let number: Int?

    var summary: String {
        if status == "conflict" { return "合并有冲突，已交给工作区里的 agent 处理：\((files ?? []).joined(separator: "、"))" }
        if status == "proposed" {
            return number.map { "已推到分支 \(branch ?? "")，PR #\($0) 已更新" } ?? "已推到分支 \(branch ?? "")，去网页上开 PR"
        }
        if push?.status == "pushed" { return "已合进主线并推送到远程" }
        if push?.status == "local" { return "已合进主线；项目没有远程，其他工作机同步时会快进过来" }
        return "已合进主线，推送失败：\(push?.message ?? "未知原因")"
    }
}

/// 同步结果：把主线的新改动合进工作区分支，不推送。
struct RemoteSyncResult: Decodable {
    let status: String
    let files: [String]?

    var summary: String {
        switch status {
        case "conflict": "合并有冲突，已交给工作区里的 agent 处理：\((files ?? []).joined(separator: "、"))"
        case "current": "已是最新"
        default: "已把主线的新改动合进工作区"
        }
    }
}

extension AppModel {
    /// 项目登记表里的集成方式：提交 PR 为 true，直接合入为 false；登记表还没读到时为 nil。
    func proposes(_ area: WorkArea) -> Bool? {
        guard let project = area.remote?.project else { return nil }
        if project.remote == nil { return false }
        return account.registeredProjects.first { $0.id == project.id }?.proposes
    }

    /// 用户手动集成、同步、流转，连带确认工作区里待恢复的线程，见 kited 的 confirmWorkspaceRecovery。
    func adopt(_ area: WorkArea) async throws -> RemoteAdoptResult {
        guard let remote = area.remote else { throw KitedError(message: "工作区尚未创建") }
        struct Adopt: Encodable { let confirmRecovery = true }
        let client = try activeClient(in: area)
        let result = try await client.request("/workspaces/\(remote.workspace.id)/adopt", method: "POST", body: Adopt(), timeout: 600, as: RemoteAdoptResult.self)
        try await refresh(client)
        return result
    }

    func syncMainline(_ area: WorkArea) async throws -> RemoteSyncResult {
        guard let remote = area.remote else { throw KitedError(message: "工作区尚未创建") }
        struct Sync: Encodable { let confirmRecovery = true }
        let client = try activeClient(in: area)
        let result = try await client.request("/workspaces/\(remote.workspace.id)/sync", method: "POST", body: Sync(), timeout: 600, as: RemoteSyncResult.self)
        try await refresh(client)
        return result
    }

    func archive(_ area: WorkArea, force: Bool) async throws {
        guard let remote = area.remote else { return }
        struct Archive: Encodable { let force: Bool }
        let client = try activeClient(in: area)
        let _: JSON = try await client.request("/workspaces/\(remote.workspace.id)/archive", method: "POST", body: Archive(force: force), timeout: 120, as: JSON.self)
        try await refresh(client)
    }

    /// 交给工作区所在的工作机办：它交出工作区、让目标还原，没成就撤回，见 kited 的 /workspaces/:id/transfer。
    func transfer(_ area: WorkArea, to target: WorkerConnection) async throws {
        guard let remote = area.remote else { throw KitedError(message: "工作区尚未创建") }
        struct Transfer: Encodable { let to: String; let operationId: String; let confirmRecovery = true }
        let client = try activeClient(in: area)
        let _: JSON = try await client.request("/workspaces/\(remote.workspace.id)/transfer", method: "POST",
                                               body: Transfer(to: target.machine.id, operationId: UUID().uuidString.lowercased()),
                                               timeout: 1800, as: JSON.self)
        try? await refresh(target.client)
        try? await refresh(client)
    }

    /// 所在工作机已丢失：用 target 手上的副本强制接管，副本没跟上的部分会丢。
    func takeOver(_ area: WorkArea, on target: WorkerConnection) async throws {
        guard let remote = area.remote else { throw KitedError(message: "工作区尚未创建") }
        guard target.connected else { throw KitedError(message: "\(target.machine.name) 未连接") }
        struct Restore: Encodable { let workspaceId: String; let operationId: String; let force: Bool }
        let _: JSON = try await target.client.request("/workspaces/restore", method: "POST",
                                                      body: Restore(workspaceId: remote.workspace.id, operationId: UUID().uuidString.lowercased(), force: true),
                                                      timeout: 1800, as: JSON.self)
        try? await refresh(target.client)
    }
}

/// 侧栏工作区行的右键菜单：同步主线、按项目的集成方式集成、打开 PR、归档。
struct WorkspaceGitActions: View {
    let workspace: WorkArea
    var showsWorkspaceMenu = false
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast
    @Environment(\.openURL) private var openURL

    var body: some View {
        if showsWorkspaceMenu {
            Button(integrateTitle) { integrate() }
                .disabled(workspace.remote == nil || !model.isConnected(workspace))
            Button(syncTitle) { sync() }
                .disabled(workspace.remote == nil || !model.isConnected(workspace))
            MenuButton("丢弃改动", role: .destructive) { }
                .disabled(true)
                .help("尚未接通")
            Divider()
            MenuButton("删除工作区", role: .destructive) { }
                .disabled(true)
                .help("尚未接通")
        } else if let remote = workspace.remote {
            Button(syncTitle) { sync() }
            Button(integrateTitle) { integrate() }
            if let pull = remote.workspace.pullRequest, let url = URL(string: pull.url) {
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
        guard let behind = workspace.remote?.workspace.behind, behind > 0 else { return "同步主线" }
        return "同步主线（落后 \(behind) 个提交）"
    }

    private func integrate() {
        let toast = toast
        Task {
            do { toast?.show(try await model.adopt(workspace).summary) }
            catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
        }
    }

    private func sync() {
        let toast = toast
        Task {
            do { toast?.show(try await model.syncMainline(workspace).summary) }
            catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
        }
    }
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
        if let remote = workspace.remote {
            let targets = model.availableWorkers.filter { $0.machine.id != remote.machine.id }
            let status = model.deviceStatus(model.connection(for: workspace))
            if status.ready || status.waiting {
                Menu("流转到") {
                    ForEach(targets) { target in
                        Button(target.machine.name) { transfer(to: target) }
                    }
                }
                .disabled(!status.ready || targets.isEmpty || remote.workspace.status != .open)
            } else {
                Menu("强制接管到") {
                    ForEach(targets) { target in
                        Button(target.machine.name) { model.takeoverRequest = TakeoverRequest(area: workspace, target: target) }
                    }
                }
                .disabled(targets.isEmpty)
            }
        }
    }

    private func transfer(to target: WorkerConnection) {
        let toast = toast
        let title = workspace.title
        toast?.show("正在把「\(title)」流转到 \(target.machine.name)…")
        Task {
            do { try await model.transfer(workspace, to: target); toast?.show("「\(title)」已流转到 \(target.machine.name)") }
            catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
        }
    }
}

/// 挂在主窗口与 iPhone 根部，承接侧栏菜单发起的归档与强制接管确认。
struct WorkspaceGitPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert("归档工作区", isPresented: Binding { model.archiveRequest != nil } set: { if !$0 { model.archiveRequest = nil } },
                   presenting: model.archiveRequest) { area in
                Button("归档", role: .destructive) { archive(area, force: false) }
                Button("丢弃未集成的改动并归档", role: .destructive) { archive(area, force: true) }
                Button("取消", role: .cancel) {}
            } message: { area in
                Text(area.remote?.workspace.pullRequest?.state == "merged"
                     ? "「\(area.title)」的 PR 已经合并。归档会停止其中的线程并回收工作树。"
                     : "归档「\(area.title)」会停止其中的线程并回收工作树。还没集成的改动只有选择丢弃时才会删除。")
            }
            .alert("强制接管工作区", isPresented: Binding { model.takeoverRequest != nil } set: { if !$0 { model.takeoverRequest = nil } },
                   presenting: model.takeoverRequest) { request in
                Button("强制接管", role: .destructive) { takeOver(request) }
                Button("取消", role: .cancel) {}
            } message: { request in
                Text("确认「\(request.area.remote?.machine.name ?? "原来的工作机")」已经丢失，用「\(request.target.machine.name)」手上的副本接管「\(request.area.title)」。副本没跟上的部分会丢失；原来的工作机回来后，它那份记录会冻结，多出的改动存成快照留给你合并。")
            }
    }

    private func takeOver(_ request: TakeoverRequest) {
        let toast = toast
        Task {
            do { try await model.takeOver(request.area, on: request.target); toast?.show("已在 \(request.target.machine.name) 上接管「\(request.area.title)」") }
            catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
        }
    }

    private func archive(_ area: WorkArea, force: Bool) {
        let toast = toast
        Task {
            do { try await model.archive(area, force: force); toast?.show("已归档") }
            catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
        }
    }
}
