import SwiftUI

/// 设置一栏里的各页。
nonisolated enum SettingsPage: String, SidebarPage {
    case appearance, account, projects

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "外观"
        case .account: "Kite 账号"
        case .projects: "项目"
        }
    }

    var icon: TablerSymbol {
        switch self {
        case .appearance: .palette
        case .account: .user
        case .projects: .folder
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
            if page == .account {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        KiteAccountSection()
                        AccountDeviceInvitation()
                    }
                        .frame(maxWidth: DotMetrics.module * 84, alignment: .leading)
                        .padding(CardMetrics.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Form {
                    switch page {
                    case .appearance:
                        Section { AppearancePicker() }
                        #if os(iOS)
                        Section { KeepAwakeToggle() }
                        #endif
                    case .account: EmptyView()
                    case .projects:
                        if model.account.signedIn { AccountProjectsSection() }
                    }
                    if let error = model.account.error { Text(error).foregroundStyle(Theme.danger) }
                    if let error = model.error { Text(error).foregroundStyle(Theme.danger) }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .id(page)
    }
}

/// 每台工作机的子页。文件尚未接通。
nonisolated enum DrivePage: String, SidebarPage {
    case accounts, files

    var id: Self { self }

    var title: String {
        switch self {
        case .accounts: "账号"
        case .files: "文件"
        }
    }

    var icon: TablerSymbol {
        switch self {
        case .accounts: .user
        case .files: .folder
        }
    }

    var available: Bool { self != .files }
}

/// 模型账号按工作机隔离，账号页使用固定分区。
struct DriveContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.drivePage {
            case .accounts: TilesLayer(group: .accounts(model.accountWindows))
            case .files:
                SectionPage(header: PaneHeader(title: model.accountWorker?.machine.name ?? "设备", subtitle: model.drivePage.title)) {
                    EmptyView()
                }
            }
        }
        .id(model.drivePage)
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
    @State private var source = Source.remote
    @State private var path = ""
    @State private var remote = ""
    @State private var repositories: [GitHubRepository]?
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?
    private var working: Bool { phase.working }

    private var title: String { mode == .project ? "添加项目" : "开始会话" }
    private var subtitle: String { mode == .project ? "克隆远程仓库，或登记工作机上已有的目录" : "在已登记的工作目录上新建工作区" }

    var body: some View {
        CardSheet(title: title, subtitle: subtitle, typing: focus != nil, close: { dismiss() }) {
            switch mode {
            case .project: projectFields
            case .session, .checkout: sessionFields
            }
        } footer: {
            CardActions(primary: primary.title, enabled: primary.enabled, phase: $phase, action: primary.run)
        }
        .endsTyping(focus != nil) { focus = nil }
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
    }

    /// 登记完成后项目出现在侧栏，弹窗随之关闭。
    @ViewBuilder private var projectFields: some View {
        CardField(label: "工作机") {
            Menu {
                ForEach(model.availableWorkers) { connection in
                    Button(connection.machine.name) { machineID = connection.id }
                }
            } label: {
                selection(model.availableWorkers.first { $0.id == machineID }?.machine.name, placeholder: "选择工作机")
            }
            .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden).clickPointer()
        }
        // 来源切换做成地址框左侧的图标，和地址同一行
        switch source {
        case .folder:
            CardField(label: "仓库位置", focused: focus == .path) {
                HStack(spacing: 0) {
                    sourceMenu
                    TextField("工作机上的绝对路径，如 /Users/me/code/app", text: $path)
                        .literal().focused($focus, equals: .path).onSubmit(submit)
                        .cardInput(leading: 2) { focus = .path }
                }
            }
        case .remote:
            CardField(label: "仓库位置", focused: focus == .remote) {
                HStack(spacing: 0) {
                    sourceMenu
                    TextField("github.com/me/repo", text: $remote)
                        .literal().focused($focus, equals: .remote).onSubmit(submit)
                        .cardInput(leading: 2) { focus = .remote }
                    if let repositories, !repositories.isEmpty {
                        Menu {
                            ForEach(repositories) { repository in
                                Button(repository.fullName + (repository.private ? "（私有）" : "")) { remote = repository.url }
                            }
                        } label: {
                            PaneButtonLabel("从 GitHub 选择", systemImage: "list.bullet")
                        }
                        .menuStyle(.button).buttonStyle(PaneButtonStyle()).menuIndicator(.hidden).fixedSize()
                        .help("从 GitHub 选择")
                        .padding(.trailing, 4)
                    }
                }
            }
        }
    }

    /// 在已登记的检出上建工作区，开场的话作为第一条消息。
    @ViewBuilder private var sessionFields: some View {
        CardField(label: "工作目录") {
            Menu {
                ForEach(model.checkouts) { checkout in
                    Button(checkoutTitle(checkout)) { checkoutID = checkout.id }
                }
            } label: {
                selection(model.checkouts.first { $0.id == checkoutID }.map(checkoutTitle), placeholder: "选择工作目录")
            }
            .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden).clickPointer()
        }
        CardField(label: "要做什么", focused: focus == .prompt) {
            TextField("说说要做什么", text: $prompt, axis: .vertical).lineLimit(3...8)
                .focused($focus, equals: .prompt)
                .cardInput { focus = .prompt }
        }
    }

    /// 地址框左侧的来源图标：点开选本机文件夹或远程仓库。
    private var sourceMenu: some View {
        Menu {
            Picker("来源", selection: $source) {
                Label("本机文件夹", systemImage: Source.folder.symbol).tag(Source.folder)
                Label("远程仓库", systemImage: Source.remote.symbol).tag(Source.remote)
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            PaneButtonLabel(source == .folder ? "本机文件夹" : "远程仓库", systemImage: source.symbol)
        }
        .menuStyle(.button).buttonStyle(PaneButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("来源：\(source == .folder ? "本机文件夹" : "远程仓库")")
        .padding(.leading, 4)
    }

    private func selection(_ title: String?, placeholder: String) -> some View {
        Text(title ?? placeholder).foregroundStyle(title == nil ? .secondary : .primary)
    }

    private func checkoutTitle(_ checkout: RemoteCheckout) -> String {
        "\(model.connections[checkout.machineId]?.machine.name ?? "工作机") · \(checkout.path)"
    }

    /// 底部主按钮：随模式和来源变。
    private var primary: (title: String, enabled: Bool, run: () -> Void) {
        switch mode {
        case .project where source == .folder:
            return ("登记目录", !working && !machineID.isEmpty && path.hasPrefix("/"), {
                perform {
                    _ = try await model.registerCheckout(path: path, machineID: machineID)
                    dismiss()
                }
            })
        case .project:
            return ("克隆并登记",
                    !working && !machineID.isEmpty && !remote.trimmingCharacters(in: .whitespaces).isEmpty, {
                perform {
                    _ = try await model.cloneCheckout(remote: remote, machineID: machineID)
                    dismiss()
                }
            })
        case .session, .checkout:
            return ("创建工作区",
                    !working && !checkoutID.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, {
                perform { try await model.create(checkout: checkoutID, prompt: prompt); dismiss() }
            })
        }
    }

    private func submit() {
        if primary.enabled { primary.run() }
    }

    private enum Field { case path, remote, prompt }

    private enum Source {
        case folder, remote
        var symbol: String { self == .folder ? "folder" : "globe" }
    }

    /// 成功后弹窗直接关掉。
    private func perform(_ action: @escaping () async throws -> Void) {
        $phase.run(action)
    }
}

private extension View {
    /// 路径、地址这类照原样输入的文字：不纠正拼写，iPhone 上不自动大写。
    func literal() -> some View {
        #if os(iOS)
        autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        autocorrectionDisabled()
        #endif
    }
}

#if os(iOS)
/// 进入后台后先保留组网节点：申请到的后台时间内进程不会挂起，代理仍然有效，期间回到前台无需重建节点。
/// 宽限期满或系统收回后台时间时关闭节点并禁止再启动，挂起后代理会失效。
@MainActor final class NodeGrace {
    static let shared = NodeGrace()
    /// 系统给的后台时间约 30 秒，留出关闭节点的余量。
    private static let grace: Duration = .seconds(25)
    private var phase = 0
    private var task = UIBackgroundTaskIdentifier.invalid

    func background() {
        phase += 1
        let phase = phase
        end()
        task = UIApplication.shared.beginBackgroundTask(withName: "保留组网节点") { self.expire(phase) }
        Task {
            try? await Task.sleep(for: Self.grace)
            expire(phase)
        }
    }

    func foreground() async {
        phase += 1
        end()
        await Tailnet.shared.setActive(true, phase: phase)
    }

    private func expire(_ phase: Int) {
        guard phase == self.phase else { return }
        self.phase += 1
        let next = self.phase
        TimingTrace.mark("后台宽限结束，关闭节点")
        Task {
            await Tailnet.shared.setActive(false, phase: next)
            if next == self.phase { end() }
        }
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
#endif

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
                #if os(iOS)
                TimingTrace.begin("回到前台")
                await NodeGrace.shared.foreground()
                #endif
                await model.connect()
            }
            .onChange(of: model.account.signedIn) { _, signedIn in
                if !signedIn { model.clearAccountConnections(); Task { await Tailnet.shared.stop() } }
            }
            #if os(iOS)
            .onOpenURL { url in Task { await model.acceptInvite(url) } }
            .onChange(of: phase) { _, phase in
                guard phase == .background else { return }
                TimingTrace.mark("进入后台")
                NodeGrace.shared.background()
            }
            #endif
            .sheet(item: $model.newWorkspace) { NewWorkspace(mode: $0).environment(model).toastHost().appAppearance() }
            .modifier(WorkspaceGitPresentation())
    }
}
