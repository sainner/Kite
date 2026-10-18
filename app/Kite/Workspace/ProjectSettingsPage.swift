import SwiftUI

/// 项目可以为自动换机声明的环境需求，与 kited 的 HANDOVER_NEEDS 对应。
enum HandoverNeed: String, CaseIterable, Identifiable {
    case xcode, iosDevice

    var id: String { rawValue }
    var title: String {
        switch self {
        case .xcode: "需要 Xcode"
        case .iosDevice: "需要连着的 iPhone 或 iPad"
        }
    }
}

/// 项目级配置作为内容区单页显示，复用账号的远程配置。
struct ProjectSettingsPage: View {
    let project: RemoteProject
    @Environment(AppModel.self) private var model
    @Environment(\.toast) private var toast
    @State private var accountProject: AccountProject?
    @State private var target = ""
    @State private var migrating = false
    @State private var savingHandover = false
    @State private var savingIntegration = false
    @State private var error: String?

    private var checkouts: [RemoteCheckout] { model.checkouts.filter { $0.projectId == project.id } }
    private var remote: String? { accountProject?.remote ?? project.remote }

    var body: some View {
        SectionPage(header: PaneHeader(title: model.projectLabel(project), subtitle: "项目配置")) {
            Form {
                Section("外观") {
                    ProjectAppearanceOptions(projectID: project.id)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                Section("远程仓库") {
                    LabeledContent("名称", value: project.name)
                    if let remote {
                        LabeledContent("地址") { Text(remote).textSelection(.enabled) }
                    } else {
                        LabeledContent("地址", value: "没有远程，各工作机上的检出互相同步")
                        TextField("远程地址，如 github.com/me/repo", text: $target)
                            .autocorrectionDisabled()
                        Button(migrating ? "正在推送…" : "设为远程") { migrate() }
                            .disabled(migrating || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    Picker("集成方式", selection: Binding(get: { accountProject?.integration ?? "merge" }, set: { setIntegration($0) })) {
                        Text("直接合入").tag("merge")
                        if remote != nil { Text("提交 PR").tag("pullRequest") }
                    }
                    .disabled(accountProject == nil || savingIntegration || remote == nil)
                } header: {
                    Text("集成")
                } footer: {
                    Text(integrationNote)
                }
                Section {
                    Toggle("工作机睡眠或关机前自动换机", isOn: Binding(get: { accountProject?.autoHandover == true }, set: { setHandover(enabled: $0) }))
                        .disabled(accountProject == nil || savingHandover)
                    if accountProject?.autoHandover == true {
                        ForEach(HandoverNeed.allCases) { need in
                            Toggle(need.title, isOn: Binding(get: { accountProject?.handoverNeeds?.contains(need.rawValue) == true },
                                                             set: { setNeed(need, $0) }))
                                .disabled(savingHandover)
                        }
                    }
                } header: {
                    Text("换机")
                } footer: {
                    Text("打开后，工作机将要睡眠、登出、重启或关机时，把这个项目里正在工作的工作区换到另一台在线、已登录模型、满足所需环境的工作机，被打断的回合在那边接着做；有几台时优先不带电池的。空闲的工作区不动。")
                }
                ProjectConstraintsSection(projectID: project.id)
                Section {
                    ForEach(checkouts) { checkout in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(machineName(checkout)).font(Theme.body)
                            Text(checkout.path).font(Theme.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Button("创建工作区") { model.createWorkspace(in: project.id, toast: toast) }
                } header: {
                    Text("检出")
                } footer: {
                    Text("检出是 Kite 在各台工作机数据目录里的仓库，工作区都从它开出；在一台还没有检出的工作机上建工作区时自动 clone。你自己的文件夹 Kite 不碰。")
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .pageForm()
            .task(id: project.id) {
                do { accountProject = try await model.registeredProjects().first { $0.id == project.id } }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private var integrationNote: String {
        guard remote != nil else { return "没有远程的项目只能直接合入：合进本机的主线，其他工作机同步时快进过来。" }
        let base = accountProject?.proposes == true
            ? "集成时把工作区分支推到远程并开 PR（自动开 PR 只支持 GitHub，其他平台给出去网页上开 PR 的链接）。"
            : "集成时把工作区的改动合进主线，再推送到远程。"
        return accountProject?.integrationReason.map { "\(base)按仓库情况自动选择：\($0)。" } ?? base
    }

    private func setIntegration(_ value: String) {
        guard value != (accountProject?.integration ?? "merge") else { return }
        save($savingIntegration) { try await model.setProjectSettings(project.id, integration: value) }
    }

    private func machineName(_ checkout: RemoteCheckout) -> String {
        model.workspaces.first { $0.remote.checkout.id == checkout.id }?.remote.machine.name ?? "工作机"
    }

    private func setNeed(_ need: HandoverNeed, _ on: Bool) {
        let current = accountProject?.handoverNeeds ?? []
        setHandover(needs: on ? current + [need.rawValue] : current.filter { $0 != need.rawValue })
    }

    private func setHandover(enabled: Bool? = nil, needs: [String]? = nil) {
        save($savingHandover) { try await model.setProjectSettings(project.id, autoHandover: enabled, handoverNeeds: needs) }
    }

    private func migrate() {
        save($migrating) {
            let updated = try await model.setProjectRemote(project.id, remote: target.trimmingCharacters(in: .whitespacesAndNewlines))
            target = ""
            return updated
        }
    }

    /// 改一项设置：进行中 saving 为 true，改好的登记换掉 accountProject，出错写在页底。
    private func save(_ saving: Binding<Bool>, _ change: @escaping @MainActor () async throws -> AccountProject) {
        saving.wrappedValue = true
        error = nil
        Task {
            defer { saving.wrappedValue = false }
            do { accountProject = try await change() }
            catch { self.error = error.localizedDescription }
        }
    }
}
