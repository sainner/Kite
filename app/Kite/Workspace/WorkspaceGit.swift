import SwiftUI

/// 集成结果：合回主线后推送；推送失败不撤销本地主线，下次集成或现场推送时一并推上去。
struct RemoteAdoptResult: Decodable {
    struct Push: Decodable { let status: String; let message: String? }
    let status: String
    let commit: String?
    let files: [String]?
    let push: Push?

    var summary: String {
        if status == "conflict" { return "合并有冲突，已交给工作区里的 agent 处理：\((files ?? []).joined(separator: "、"))" }
        if push?.status == "pushed" { return "已合回主线并推送到远程" }
        return "已合回主线，推送失败：\(push?.message ?? "未知原因")"
    }
}

/// 检出现场与远程的关系，按工作机最近一次拉取计算。
struct CheckoutSync: Decodable, Equatable {
    let branch: String?
    let dirty: Bool
    let ahead: Int?
    let behind: Int?

    var summary: String {
        guard let branch else { return "现场不在任何分支上" }
        var parts = [branch]
        if let ahead, let behind {
            if ahead == 0 && behind == 0 { parts.append("与远程一致") }
            if ahead > 0 { parts.append("领先远程 \(ahead) 个提交") }
            if behind > 0 { parts.append("落后远程 \(behind) 个提交") }
        } else { parts.append("尚未与远程同步") }
        if dirty { parts.append("有未提交的改动") }
        return parts.joined(separator: " · ")
    }
}

/// 预览依次给出各种结果，覆盖推送成功、推送失败、冲突与现场的几种状态。
enum WorkspaceGitSamples {
    nonisolated(unsafe) static var turn = 0
    static let adoptions: [RemoteAdoptResult] = [
        .init(status: "adopted", commit: "8dc7ad4", files: nil, push: .init(status: "pushed", message: nil)),
        .init(status: "adopted", commit: "8dc7ad4", files: nil, push: .init(status: "failed", message: "推送失败：连不上 github.com")),
        .init(status: "conflict", commit: nil, files: ["src/main.ts", "README.md"], push: nil),
    ]
    static let syncs: [CheckoutSync] = [
        .init(branch: "main", dirty: true, ahead: 0, behind: 0),
        .init(branch: "main", dirty: false, ahead: 2, behind: 0),
        .init(branch: "main", dirty: true, ahead: 1, behind: 3),
        .init(branch: "main", dirty: false, ahead: nil, behind: nil),
    ]
    static func next<T>(_ values: [T]) -> T {
        defer { turn += 1 }
        return values[turn % values.count]
    }
}

extension AppModel {
    func adopt(_ area: WorkArea) async throws -> RemoteAdoptResult {
        if area.isSample { return WorkspaceGitSamples.next(WorkspaceGitSamples.adoptions) }
        guard let remote = area.remote else { throw KitedError(message: "工作区尚未创建") }
        let client = try activeClient(in: area)
        let result = try await client.request("/workspaces/\(remote.workspace.id)/adopt", method: "POST", timeout: 600, as: RemoteAdoptResult.self)
        try await refresh(client)
        return result
    }

    func archive(_ area: WorkArea, force: Bool) async throws {
        if area.isSample { throw KitedError(message: "预览数据不能归档") }
        guard let remote = area.remote else { return }
        struct Archive: Encodable { let force: Bool }
        let client = try activeClient(in: area)
        let _: JSON = try await client.request("/workspaces/\(remote.workspace.id)/archive", method: "POST", body: Archive(force: force), timeout: 120, as: JSON.self)
        try await refresh(client)
    }

    func checkoutSync(_ area: WorkArea) async throws -> CheckoutSync {
        if area.isSample { return WorkspaceGitSamples.next(WorkspaceGitSamples.syncs) }
        guard let remote = area.remote else { throw KitedError(message: "工作区尚未创建") }
        return try await activeClient(in: area).request("/checkouts/\(remote.checkout.id)/sync", as: CheckoutSync.self)
    }

    func pushCheckout(_ area: WorkArea, message: String) async throws -> CheckoutSync {
        if area.isSample {
            throw KitedError(message: "远程有新的提交，和现场的改动分叉了。请新建工作区，在工作区里集成", status: 409)
        }
        guard let remote = area.remote else { throw KitedError(message: "工作区尚未创建") }
        struct Push: Encodable { let message: String? }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await activeClient(in: area).request("/checkouts/\(remote.checkout.id)/push", method: "POST",
                                                         body: Push(message: text.isEmpty ? nil : text), timeout: 600, as: CheckoutSync.self)
    }
}

/// 侧栏工作区行的右键菜单：独立工作区集成与归档，检出现场提交并推送。
struct WorkspaceGitActions: View {
    let workspace: WorkArea
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast

    var body: some View {
        if workspace.remote?.workspace.kind == .root {
            Button("提交并推送…") { model.scenePush = workspace }
        } else if workspace.remote != nil {
            Button("集成到主线并推送") {
                let toast = toast
                Task {
                    do { toast?.show(try await model.adopt(workspace).summary) }
                    catch { toast?.show(error.localizedDescription, systemImage: "exclamationmark.triangle") }
                }
            }
            Button("归档工作区…", role: .destructive) { model.archiveRequest = workspace }
        }
    }
}

/// 检出现场的「提交并推送」：先看现场与远程的关系，再由用户填写说明提交。
struct ScenePushSheet: View {
    let workspace: WorkArea
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sync: CheckoutSync?
    @State private var message = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("现场") {
                    Text(workspace.remote.map { "\($0.machine.name) · \($0.checkout.path)" } ?? workspace.title)
                        .lineLimit(1).truncationMode(.middle)
                    if let sync { Text(sync.summary).foregroundStyle(.secondary) } else { ProgressView() }
                }
                Section {
                    TextField("提交说明", text: $message, axis: .vertical).lineLimit(2...6)
                } footer: {
                    Text("现场的改动由你自己决定何时提交。远程有新提交而现场没有新内容时直接更新；两边都有新内容时不在现场合并，请新建工作区处理。")
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle("提交并推送")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "正在推送…" : "推送") { push() }
                        .disabled(working || sync == nil || (sync?.dirty == true && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .task {
            do { sync = try await model.checkoutSync(workspace) } catch { self.error = error.localizedDescription }
        }
        #if os(macOS)
        .frame(width: 460, height: 360)
        #endif
    }

    private func push() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                sync = try await model.pushCheckout(workspace, message: message)
                message = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// 挂在主窗口与 iPhone 根部，承接侧栏菜单发起的现场推送与归档确认。
struct WorkspaceGitPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: $model.scenePush) { area in
                ScenePushSheet(workspace: area).environment(model).appAppearance()
            }
            .confirmationDialog("归档工作区", isPresented: Binding { model.archiveRequest != nil } set: { if !$0 { model.archiveRequest = nil } },
                                presenting: model.archiveRequest) { area in
                Button("归档", role: .destructive) { archive(area, force: false) }
                Button("丢弃未集成的改动并归档", role: .destructive) { archive(area, force: true) }
            } message: { area in
                Text("归档「\(area.title)」会停止其中的线程并回收工作树。还没集成到主线的改动只有选择丢弃时才会删除。")
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
