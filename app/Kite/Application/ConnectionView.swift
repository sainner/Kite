import SwiftUI
import UniformTypeIdentifiers

/// 设置一栏里的各页。
nonisolated enum SettingsPage: String, SidebarPage {
    case account, appearance

    var id: Self { self }

    var title: String {
        switch self {
        case .account: "Kite 账号"
        case .appearance: "外观"
        }
    }

    var icon: TablerSymbol {
        switch self {
        case .account: .user
        case .appearance: .palette
        }
    }

    var available: Bool { true }
}

/// 设置一栏的单页：侧栏选中的那一页。Kite 账号页开点阵，用量合计画在上面。
struct SettingsContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let page = model.settingsPage
        SectionPage(header: PaneHeader(title: page.title, subtitle: "设置"), usesDots: page == .account) {
            switch page {
            case .account: AccountSettingsPage()
            case .appearance:
                Form {
                    Section { AppearancePicker() }
                    #if os(iOS)
                    Section { KeepAwakeToggle() }
                    #endif
                    if let error = model.error { Text(error).foregroundStyle(Theme.danger) }
                }
                .pageForm()
            }
        }
        .id(page)
    }
}

/// 每台工作机的子页。文件尚未接通。
nonisolated enum DrivePage: String, SidebarPage {
    case accounts, network, version, files

    var id: Self { self }

    var title: String {
        switch self {
        case .accounts: "账号"
        case .network: "网络"
        case .version: "版本"
        case .files: "文件"
        }
    }

    var icon: TablerSymbol {
        switch self {
        case .accounts: .user
        case .network: .world
        case .version: .refresh
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
            case .network:
                SectionPage(header: PaneHeader(title: model.accountWorker?.machine.name ?? "设备", subtitle: model.drivePage.title)) {
                    if let worker = model.accountWorker { NetworkSettingsPage(connection: worker) }
                }
            case .version:
                SectionPage(header: PaneHeader(title: model.accountWorker?.machine.name ?? "设备", subtitle: model.drivePage.title)) {
                    if let worker = model.accountWorker { UpdateSettingsPage(connection: worker) }
                }
            case .files:
                SectionPage(header: PaneHeader(title: model.accountWorker?.machine.name ?? "设备", subtitle: model.drivePage.title)) {
                    EmptyView()
                }
            }
        }
        .id(model.drivePage)
    }
}

/// 新建分成两个入口：添加项目只登记（远程不 clone，没有远程的文件夹由所在工作机导入），见 AddProject；
/// 新建工作区选项目和工作机，工作机上还没有检出时由它先 clone。
struct NewWorkspace: View {
    enum Mode: Equatable, Identifiable {
        case project, session, inProject(String)
        var id: String {
            switch self {
            case .project: "project"
            case .session: "session"
            case .inProject(let id): "project:\(id)"
            }
        }
    }

    let mode: Mode

    var body: some View {
        if mode == .project { AddProject() } else { NewSession(mode: mode) }
    }
}

/// 在选定的工作机上为项目建工作区，开场的话作为第一条消息。
private struct NewSession: View {
    let mode: NewWorkspace.Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var machineID = ""
    @State private var prompt = ""
    @State private var phase = CardPhase.idle
    @FocusState private var typing: Bool

    /// Line 的项目从侧栏顶部的标志进，不在这里建工作区。
    private var projects: [RemoteProject] {
        let line = model.lineArea?.remote?.project.id
        return model.knownProjects.filter { $0.id != line }
    }
    private var project: RemoteProject? { projects.first { $0.id == projectID } }
    private var enabled: Bool {
        !phase.working && project != nil && model.connections[machineID]?.connected == true
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let label = model.projectLabels()
        CardSheet(title: "新建工作区", subtitle: "在一台工作机上为项目开一个工作区", error: phase.error, typing: typing, close: { dismiss() }) {
            CardField(label: "项目") {
                Menu {
                    ForEach(projects) { project in
                        Button(label(project)) { select(project.id) }
                    }
                } label: {
                    CardSelection(title: project.map(label), placeholder: "选择项目")
                }
                .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden)
            }
            CardField(label: "工作机", note: note) {
                WorkerMenu(machineID: $machineID, placeholder: "选择工作机")
            }
            CardField(label: "要做什么", focused: typing) {
                TextField("说说要做什么", text: $prompt, axis: .vertical).lineLimit(3...8)
                    .focused($typing)
                    .scrollsOnlyWhileTyping(typing)
                    .cardInput { typing = true }
            }
        } actions: {
            CardSheetAction(title: "创建工作区", systemImage: "checkmark", busy: phase.working, action: create)
                .disabled(!enabled)
        }
        .endsTyping(typing) { typing = false }
        .onAppear {
            if case .inProject(let id) = mode { select(id) }
            else { select(model.current?.remote?.project.id ?? projects.first?.id ?? "") }
            prompt = model.draftWorkspace.draftThread.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 选中项目时工作机默认取已有它检出、连着的那台，其次是当前连着的工作机。
    private func select(_ id: String) {
        projectID = id
        let holders = Set(model.checkouts.filter { $0.projectId == id }.map(\.machineId))
        machineID = model.availableWorkers.first { holders.contains($0.id) }?.id
            ?? (model.activeConnection?.connected == true ? model.machine?.id : nil) ?? model.availableWorkers.first?.id ?? ""
    }

    private var note: String? {
        guard project != nil, !machineID.isEmpty else { return nil }
        return model.checkouts.contains { $0.projectId == projectID && $0.machineId == machineID } ? nil : "这台工作机上还没有这个项目，建工作区前先 clone。"
    }

    private func create() {
        guard enabled, let project else { return }
        $phase.run { try model.create(project: project, machineID: machineID, prompt: prompt); dismiss() }
    }
}

/// 添加项目分两步：先选来源（远程地址或工作机上的文件夹）和要带上的环境变量文件，再定集成方式。
/// 没有远程的文件夹只能直接合入，跳过第二步。文件夹里的环境变量文件由所在工作机读，内容不经过 App。
private struct AddProject: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.remote
    @State private var machineID = ""
    @State private var path = ""
    @State private var remote = ""
    @State private var repositories: [GitHubRepository]?
    /// 最近一次检查：对着哪个来源和工作机做的，结果是什么。
    @State private var checked: (source: ProjectSource, machine: String, result: ProjectCheck)?
    /// 文件夹里找到的环境变量文件中选上的。
    @State private var found: Set<String> = []
    /// 从这台设备选的文件，路径可以改。
    @State private var picked: [PickedFile] = []
    @State private var importing = false
    @State private var integration = "merge"
    @State private var step = 1
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?

    private var current: ProjectSource {
        source == .folder ? ProjectSource(path: path.trimmingCharacters(in: .whitespaces))
            : ProjectSource(remote: remote.trimmingCharacters(in: .whitespaces))
    }
    private var sourceReady: Bool {
        source == .folder ? !machineID.isEmpty && current.path?.hasPrefix("/") == true : !(current.remote ?? "").isEmpty
    }
    /// 对当前来源与工作机的检查；来源或工作机改了就不算。
    private var check: ProjectCheck? {
        guard let checked, checked.source == current, checked.machine == machineID else { return nil }
        return checked.result
    }
    private var envFiles: [ProjectEnvFile] {
        found.intersection(check?.envFiles ?? []).sorted().map { ProjectEnvFile(path: $0) }
            + picked.map { ProjectEnvFile(path: $0.path.trimmingCharacters(in: .whitespaces), value: $0.value) }
    }
    private var filesValid: Bool {
        let paths = envFiles.map(\.path)
        return paths.allSatisfy { !$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") } && Set(paths).count == paths.count
    }

    var body: some View {
        Group {
            if step == 1 { sourceStep } else { integrationStep }
        }
        .endsTyping(focus != nil) { focus = nil }
        .onAppear {
            machineID = (model.activeConnection?.connected == true ? model.machine?.id : nil) ?? model.availableWorkers.first?.id ?? ""
        }
        .task(id: source) {
            guard source == .remote, repositories == nil else { return }
            repositories = try? await model.gitHubRepositories()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() {
                    let text = try readSecretText(url)
                    let name = url.lastPathComponent.hasPrefix(".env") ? url.lastPathComponent : ".env"
                    picked.append(PickedFile(path: picked.contains { $0.path == name } || found.contains(name) ? "" : name, value: text))
                }
                if phase.error != nil { phase = .idle }
            } catch { phase = .failed(error.localizedDescription) { importing = true } }
        }
    }

    // MARK: 第一步：来源与环境变量文件

    private var sourceStep: some View {
        CardSheet(title: "添加项目", subtitle: "选远程仓库或工作机上的文件夹，可以一起带上环境变量文件", error: phase.error,
                  typing: focus != nil, close: { dismiss() }) {
            if source == .folder {
                CardField(label: "工作机") { WorkerMenu(machineID: $machineID, placeholder: "选择文件夹所在的工作机") }
            }
            CardField(label: "仓库位置", focused: focus == .path || focus == .remote, note: locationNote) {
                HStack(spacing: 0) {
                    sourceMenu
                    if source == .folder {
                        TextField("工作机上的绝对路径，如 /Users/me/code/app", text: $path)
                            .literal().focused($focus, equals: .path).onSubmit(inspect)
                            .cardInput(leading: 2) { focus = .path }
                    } else {
                        TextField("github.com/me/repo", text: $remote)
                            .literal().focused($focus, equals: .remote).onSubmit(next)
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
            CardSection("环境变量文件（可选）", note: "存成项目专用的密钥，每次建工作区时写到它在工作区里的路径。") {
                ForEach((check?.envFiles ?? []), id: \.self) { file in
                    Toggle(file, isOn: Binding(get: { found.contains(file) }, set: { on in
                        if on { found.insert(file) } else { found.remove(file) }
                    }))
                }
                ForEach($picked) { $file in
                    HStack {
                        TextField("在工作区里的路径，如 .env", text: $file.path).literal()
                        Button("移除") { picked.removeAll { $0.id == file.id } }
                    }
                }
                Button("从这台设备选文件…") { importing = true }
            }
        } actions: {
            CardSheetAction(title: "下一步", systemImage: "arrow.right", busy: phase.working, action: next)
                .disabled(phase.working || !sourceReady || !filesValid)
        }
        // 路径填完（回车或离开输入框）就去看一眼，找到的环境变量文件默认选上；打字途中不看，免得把上级目录整个扫一遍
        .onChange(of: focus) { old, new in
            if old == .path, new != .path { inspect() }
        }
    }

    private var locationNote: String? {
        guard let check else { return nil }
        if let existing = check.existing {
            return "这个仓库已经登记为项目「\(existing.name)」，添加时直接用它" + (envFiles.isEmpty ? "。" : "，选中的环境变量文件存进它的项目密钥。")
        }
        if source == .folder { return check.remote.map { "按它的远程 \($0) 登记，不动这个文件夹。" } ?? "没有远程：导入到 Kite 自己的仓库，不动这个文件夹。" }
        return nil
    }

    private var sourceMenu: some View {
        Menu {
            Picker("来源", selection: $source) {
                Label("工作机上的文件夹", systemImage: Source.folder.symbol).tag(Source.folder)
                Label("远程仓库", systemImage: Source.remote.symbol).tag(Source.remote)
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            PaneButtonLabel(source == .folder ? "文件夹" : "远程仓库", systemImage: source.symbol)
        }
        .menuStyle(.button).buttonStyle(PaneButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("来源：\(source == .folder ? "工作机上的文件夹" : "远程仓库")")
        .padding(.leading, 4)
    }

    /// 检查当前来源：文件夹找到的环境变量文件默认选上，集成方式换成建议的。检查期间来源或工作机改了就作废，返回 nil。
    private func runCheck() async throws -> ProjectCheck? {
        let source = current, machine = machineID
        let result = try await model.checkProject(source, machineID: source.path == nil ? nil : machine)
        guard source == current, machine == machineID else { return nil }
        checked = (source, machine, result)
        found = Set(result.envFiles)
        integration = result.integration
        return result
    }

    private func inspect() {
        guard sourceReady, check == nil else { return }
        $phase.run { _ = try await runCheck() }
    }

    /// 下一步：先检查（远程要确认能访问），已登记的直接收下；没有远程的跳过第二步直接添加。
    private func next() {
        guard sourceReady, filesValid, !phase.working else { return }
        $phase.run {
            if check == nil {
                guard let result = try await runCheck() else { return }
                // 文件夹里找到了环境变量文件：先停在这一步，让用户看一眼默认选上的
                if !result.envFiles.isEmpty { return }
            }
            if let existing = check?.existing {
                if envFiles.isEmpty {
                    model.selectProject(existing.id)
                    dismiss()
                } else {
                    try await add()
                }
            } else if check?.remote == nil {
                try await add()
            } else {
                step = 2
            }
        }
    }

    // MARK: 第二步：集成方式

    private var integrationStep: some View {
        CardSheet(title: "集成方式", subtitle: "工作区的改动怎样进入主线，之后可以在项目配置里改", error: phase.error, back: true,
                  close: { step = 1 }) {
            VStack(spacing: 8) {
                CardChoice(title: "直接合入", detail: "把工作区的改动合进主线，再推送到远程。适合只有自己用的仓库。",
                           symbol: .gitMerge, selected: integration == "merge") { integration = "merge" }
                CardChoice(title: "提交 PR", detail: "把工作区分支推到远程并开一个 PR，在网页上审查后合并。适合多人共用或主线受保护的仓库。",
                           symbol: .gitPullRequest, selected: integration == "pullRequest") { integration = "pullRequest" }
            }
            if let reason = check?.integrationReason { CardNote("已按仓库情况预选：\(reason)。") }
        } actions: {
            CardSheetAction(title: "添加", systemImage: "checkmark", busy: phase.working) {
                $phase.run { try await add() }
            }
            .disabled(phase.working)
        }
    }

    private func add() async throws {
        let project = try await model.addProject(current, machineID: current.path == nil ? nil : machineID,
                                                 integration: check?.remote == nil ? nil : integration, envFiles: envFiles)
        model.selectProject(project.id)
        dismiss()
    }

    private struct PickedFile: Identifiable {
        let id = UUID()
        var path: String
        let value: String
    }

    private enum Field { case path, remote }

    private enum Source {
        case folder, remote
        var symbol: String { self == .folder ? "folder" : "globe" }
    }
}

/// 卡片里下拉选择的当前值，没选时显示灰色的提示。
private struct CardSelection: View {
    let title: String?
    let placeholder: String

    var body: some View {
        Text(title ?? placeholder).foregroundStyle(title == nil ? .secondary : .primary)
    }
}

/// 选一台连着的工作机。
private struct WorkerMenu: View {
    @Binding var machineID: String
    let placeholder: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.availableWorkers) { connection in
                Button(connection.machine.name) { machineID = connection.id }
            }
        } label: {
            CardSelection(title: model.availableWorkers.first { $0.id == machineID }?.machine.name, placeholder: placeholder)
        }
        .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden)
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
            .onChange(of: phase) { _, phase in
                guard phase == .background else { return }
                TimingTrace.mark("进入后台")
                NodeGrace.shared.background()
            }
            #endif
            .sheet(item: $model.newWorkspace) { NewWorkspace(mode: $0).environment(model).toastHost().appAppearance() }
            .sheet(item: $model.contextVariable) { ContextVariableSheet(variable: $0).environment(model).toastHost().appAppearance() }
            .modifier(WorkspaceGitPresentation())
    }
}
