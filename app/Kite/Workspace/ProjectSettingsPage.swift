import SwiftUI

/// 项目级配置作为内容区单页显示，复用账号的远程配置。
struct ProjectSettingsPage: View {
    let project: RemoteProject
    @Environment(AppModel.self) private var model
    @State private var accountProject: AccountProject?
    @State private var target = ""
    @State private var migrating = false
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
                    LabeledContent("地址") {
                        Text(accountProject?.remote ?? project.remote)
                            .textSelection(.enabled)
                    }
                    if accountProject?.hosted == true {
                        LabeledContent("托管方式", value: "Kite 托管")
                        TextField("正式远程，如 github.com/me/repo", text: $target)
                            .autocorrectionDisabled()
                        Button(migrating ? "正在迁移…" : "迁移到正式远程") { migrate() }
                            .disabled(migrating || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
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
                do { accountProject = try await model.account.projects().first { $0.id == project.id } }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func machineName(_ checkout: RemoteCheckout) -> String {
        model.workspaces.first { $0.remote?.checkout.id == checkout.id }?.remote?.machine.name ?? "工作机"
    }

    private func migrate() {
        migrating = true
        error = nil
        Task {
            defer { migrating = false }
            do {
                accountProject = try await model.account.migrate(project.id, to: target.trimmingCharacters(in: .whitespacesAndNewlines))
                target = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}
