import SwiftUI

/// 设置一栏里的各页。
nonisolated enum SettingsPage: String, SidebarPage {
    case appearance, account, linked, devices, projects

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "外观"
        case .account: "Kite 账号"
        case .linked: "关联账号"
        case .devices: "设备列表"
        case .projects: "项目"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .account: "person.crop.circle"
        case .linked: "link"
        case .devices: "laptopcomputer.and.iphone"
        case .projects: "folder"
        }
    }

    var available: Bool { true }
}

/// 设置一栏的单页：侧栏选中的那一页。
struct SettingsContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let page = model.settingsPage
        SectionPage(header: PaneHeader(title: page.title, subtitle: "设置")) {
            Form {
                switch page {
                case .appearance:
                    Section { AppearancePicker() }
                case .account:
                    KiteAccountSection()
                case .linked:
                    if !model.subscriptionQuotas.isEmpty { SubscriptionSection() }
                    if model.account.signedIn { GitAccountsSection() }
                case .devices:
                    AccountDevices()
                case .projects:
                    if model.account.signedIn { AccountProjectsSection() }
                }
                if let error = model.account.error { Text(error).foregroundStyle(Theme.danger) }
                if let error = model.error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .id(page)
    }
}

/// 模型订阅账号与本周剩余额度，与用户栏的 chip 同源。
private struct SubscriptionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("模型订阅") {
            ForEach(model.subscriptionQuotas) { quota in
                LabeledContent(quota.provider) {
                    Text("本周剩余 \(quota.remaining.formatted(.percent.precision(.fractionLength(0))))")
                        .foregroundStyle(quota.remaining < 0.2 ? Theme.warning : .secondary)
                }
            }
        }
    }
}

/// 新建分成两个入口：添加项目在工作机上登记目录或克隆远程仓库；开始会话在已登记的检出上建工作区。
struct NewWorkspace: View {
    enum Mode: Equatable, Identifiable {
        case project, session, checkout(String)
        var id: String {
            switch self {
            case .project: "project"
            case .session: "session"
            case .checkout(let id): "checkout:\(id)"
            }
        }
    }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var checkoutID = ""
    @State private var machineID = ""
    @State private var prompt = ""
    @State private var source = Source.folder
    @State private var path = ""
    @State private var remote = ""
    @State private var repositories: [GitHubRepository]?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .project: projectSection
                case .session, .checkout: sessionSection
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle(mode == .project ? "添加项目" : "开始会话")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onAppear {
            if case .checkout(let id) = mode { checkoutID = id }
            else { checkoutID = model.checkouts.first(where: { model.connections[$0.machineId]?.connected == true })?.id ?? "" }
            machineID = (model.activeConnection?.connected == true ? model.machine?.id : nil) ?? model.availableWorkers.first?.id ?? ""
            prompt = model.draftWorkspace.draftThread.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .task(id: source) {
            guard source == .remote, repositories == nil else { return }
            repositories = try? await model.account.gitHubRepositories()
        }
        #if os(macOS)
        .frame(width: 520, height: mode == .project ? 360 : 320)
        #endif
    }

    /// 登记完成后项目出现在侧栏，表单随之关闭。
    private var projectSection: some View {
        Section {
            Picker("工作机", selection: $machineID) {
                Text("选择工作机").tag("")
                ForEach(model.availableWorkers) { connection in Text(connection.machine.name).tag(connection.id) }
            }
            Picker("来源", selection: $source) {
                Text("本机文件夹").tag(Source.folder)
                Text("远程仓库").tag(Source.remote)
            }
            .pickerStyle(.segmented)
            switch source {
            case .folder:
                TextField("工作机上的文件夹绝对路径", text: $path).autocorrectionDisabled()
                Button("登记目录") {
                    perform {
                        _ = try await model.registerCheckout(path: path, machineID: machineID)
                        dismiss()
                    }
                }.disabled(working || machineID.isEmpty || !path.hasPrefix("/"))
            case .remote:
                HStack {
                    TextField("远程地址，如 github.com/me/repo", text: $remote).autocorrectionDisabled()
                    if let repositories, !repositories.isEmpty {
                        Menu("从 GitHub 选择") {
                            ForEach(repositories) { repository in
                                Button(repository.fullName + (repository.private ? "（私有）" : "")) { remote = repository.url }
                            }
                        }
                        .fixedSize()
                    }
                }
                TextField("存放位置（可选，默认 ~/code/域名/owner/repo）", text: $path).autocorrectionDisabled()
                Button(working ? "正在克隆…" : "克隆并登记") {
                    perform {
                        _ = try await model.cloneCheckout(remote: remote, path: path.isEmpty ? nil : path, machineID: machineID)
                        dismiss()
                    }
                }.disabled(working || machineID.isEmpty || remote.trimmingCharacters(in: .whitespaces).isEmpty
                           || !(path.isEmpty || path.hasPrefix("/")))
            }
        }
    }

    /// 在已登记的检出上建工作区，开场的话作为第一条消息。
    private var sessionSection: some View {
        Section {
            Picker("工作目录", selection: $checkoutID) {
                Text("选择工作目录").tag("")
                ForEach(model.checkouts) { checkout in
                    Text("\(model.connections[checkout.machineId]?.machine.name ?? "工作机") · \(checkout.path)").tag(checkout.id)
                }
            }
            .clickPointer()
            TextField("说说要做什么", text: $prompt, axis: .vertical).lineLimit(3...8)
            Button(working ? "正在创建…" : "创建工作区") {
                perform { try await model.create(checkout: checkoutID, prompt: prompt); dismiss() }
            }.disabled(working || checkoutID.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private enum Source { case folder, remote }

    private func perform(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

extension View {
    func connectsToService() -> some View {
        modifier(ServiceConnection())
    }
}

struct ServiceConnection: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase

    private var shouldConnect: Bool {
        #if os(macOS)
        // 分离工作区或设置取得焦点时，主窗口不能关闭所有工作机的连接。
        model.account.ready
        #else
        model.account.ready && phase == .active
        #endif
    }

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .task(id: shouldConnect) {
                #if DEBUG
                if DirectoryVerification.isRequested { return }
                #endif
                guard !OnboardingPreview.enabled, shouldConnect else { return }
                await model.connect()
            }
            .onChange(of: model.account.signedIn) { _, signedIn in
                if !signedIn { model.clearAccountConnections(); Task { await Tailnet.shared.stop() } }
            }
            #if os(iOS)
            .onOpenURL { url in Task { await model.acceptInvite(url) } }
            .onChange(of: phase) { _, phase in if phase == .background { Task { await Tailnet.shared.stop() } } }
            #endif
            .sheet(item: $model.newWorkspace) { NewWorkspace(mode: $0).environment(model).toastHost().appAppearance() }
            .modifier(WorkspaceGitPresentation())
    }
}
