import SwiftUI

struct AppSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") { AppearancePicker() }
                Section("插件") {
                    NavigationLink("管理插件定义") { PluginLibrary().id(model.connectionRevision) }
                        .disabled(SampleWorkspace.enabled || !model.connected)
                }
                Section("上下文") {
                    NavigationLink("管理上下文模板") { ContextTemplateLibrary().id(model.connectionRevision) }
                        .disabled(!SampleWorkspace.enabled && !model.connected)
                }
                if !SampleWorkspace.enabled { AccountDevices() }
                if SampleWorkspace.enabled || model.account.signedIn {
                    GitAccountsSection()
                    AccountProjectsSection()
                }
                if let error = model.account.error { Text(error).foregroundStyle(Theme.danger) }
                if let error = model.error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 480, height: 500)
        #endif
    }
}

struct NewWorkspace: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var checkoutID = ""
    @State private var machineID = ""
    @State private var prompt = ""
    @State private var source = Source.folder
    @State private var path = ""
    @State private var remote = ""
    @State private var repositories: [GitHubRepository] = []
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("项目") {
                    Picker("在工作机上登记目录", selection: $machineID) {
                        Text("选择工作机").tag("")
                        ForEach(model.availableWorkers) { connection in Text(connection.machine.name).tag(connection.id) }
                    }
                    Picker("工作目录", selection: $checkoutID) {
                        Text("选择工作目录").tag("")
                        ForEach(model.checkouts) { checkout in
                            Text("\(model.connections[checkout.machineId]?.machine.name ?? "工作机") · \(checkout.path)").tag(checkout.id)
                        }
                    }
                    .clickPointer()
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
                                checkoutID = try await model.registerCheckout(path: path, machineID: machineID)
                                path = ""
                            }
                        }.disabled(working || machineID.isEmpty || !path.hasPrefix("/"))
                    case .remote:
                        HStack {
                            TextField("远程地址，如 github.com/me/repo", text: $remote).autocorrectionDisabled()
                            if !repositories.isEmpty {
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
                                checkoutID = try await model.cloneCheckout(remote: remote, path: path.isEmpty ? nil : path, machineID: machineID)
                                remote = ""; path = ""
                            }
                        }.disabled(working || machineID.isEmpty || remote.trimmingCharacters(in: .whitespaces).isEmpty
                                   || !(path.isEmpty || path.hasPrefix("/")))
                    }
                }
                Section("开始会话") {
                    TextField("说说要做什么", text: $prompt, axis: .vertical).lineLimit(3...8)
                    Button(working ? "正在创建…" : "创建工作区") {
                        perform { try await model.create(checkout: checkoutID, prompt: prompt); dismiss() }
                    }.disabled(working || checkoutID.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle("新工作区")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onAppear {
            checkoutID = model.checkouts.first(where: { model.connections[$0.machineId]?.connected == true })?.id ?? ""
            machineID = (model.activeConnection?.connected == true ? model.machine?.id : nil) ?? model.availableWorkers.first?.id ?? ""
            prompt = model.draftWorkspace.draftThread.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .task(id: source) {
            guard source == .remote, repositories.isEmpty else { return }
            repositories = (try? await model.account.gitHubRepositories()) ?? []
        }
        #if os(macOS)
        .frame(width: 520, height: 480)
        #endif
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
                guard !SampleWorkspace.enabled, !OnboardingPreview.enabled, shouldConnect else { return }
                await model.connect()
            }
            .onChange(of: model.account.signedIn) { _, signedIn in
                if !signedIn { model.clearAccountConnections(); Task { await Tailnet.shared.stop() } }
            }
            #if os(iOS)
            .onOpenURL { url in Task { await model.acceptInvite(url) } }
            .onChange(of: phase) { _, phase in if phase == .background { Task { await Tailnet.shared.stop() } } }
            #endif
            .sheet(isPresented: $model.showConnection) { AppSettings().environment(model).toastHost().appAppearance() }
            .sheet(isPresented: $model.showNewWorkspace) { NewWorkspace().environment(model).toastHost().appAppearance() }
            .modifier(WorkspaceGitPresentation())
    }
}
