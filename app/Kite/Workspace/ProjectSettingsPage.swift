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
    @State private var accountProject: AccountProject?
    @State private var target = ""
    @State private var migrating = false
    @State private var savingHandover = false
    @State private var error: String?

    private var checkouts: [RemoteCheckout] { model.checkouts.filter { $0.projectId == project.id } }

    var body: some View {
        SectionPage(header: PaneHeader(title: model.projectLabel(project), subtitle: "项目配置")) {
            Form {
                Section("外观") {
                    ProjectAppearanceOptions(projectID: project.id)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                Section("远程仓库") {
                    LabeledContent("名称", value: project.name)
                    if let remote = accountProject?.remote ?? project.remote {
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
                Section("检出") {
                    ForEach(checkouts) { checkout in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(machineName(checkout)).font(Theme.body)
                            Text(checkout.path).font(Theme.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                if let root = model.workspaces.first(where: {
                                    $0.remote?.checkout.id == checkout.id && $0.remote?.workspace.kind == .root
                                }) {
                                    Button("打开现场") { model.selectWorkspace(root.id) }
                                }
                                Button("创建工作区") { model.newWorkspace = .checkout(checkout.id) }
                            }
                        }
                    }
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

    private func machineName(_ checkout: RemoteCheckout) -> String {
        model.workspaces.first { $0.remote?.checkout.id == checkout.id }?.remote?.machine.name ?? "工作机"
    }

    private func setNeed(_ need: HandoverNeed, _ on: Bool) {
        let current = accountProject?.handoverNeeds ?? []
        setHandover(needs: on ? current + [need.rawValue] : current.filter { $0 != need.rawValue })
    }

    private func setHandover(enabled: Bool? = nil, needs: [String]? = nil) {
        savingHandover = true
        error = nil
        Task {
            defer { savingHandover = false }
            do { accountProject = try await model.setProjectHandover(project.id, enabled: enabled, needs: needs) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func migrate() {
        migrating = true
        error = nil
        Task {
            defer { migrating = false }
            do {
                accountProject = try await model.setProjectRemote(project.id, remote: target.trimmingCharacters(in: .whitespacesAndNewlines))
                target = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}
