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

/// 添加项目分两步：先选来源（远程地址或工作机上的文件夹）和要带上的环境变量文件，再定集成方式。
/// 没有远程的文件夹只能直接合入，跳过第二步。文件夹里的和在工作机上选的环境变量文件由那台工作机读，内容不经过 App；
/// 所以工作机上选的文件只能来自添加项目的那台：文件夹所在的，远程项目则是第一次选文件的那台。
/// 添加完成后打开项目页，工作区从项目上直接建，见 AppModel.createWorkspace。
private struct AddProject: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.remote
    @State private var machineID: String
    @State private var path = ""
    @State private var remote = ""
    @State private var repositories: [GitHubRepository]?
    /// 最近一次检查：对着哪个来源和工作机做的，结果是什么。
    @State private var checked: (source: ProjectSource, machine: String, result: ProjectCheck)?
    /// 文件夹里找到的环境变量文件中选上的。
    @State private var found: Set<String> = []
    /// 从这台设备或工作机上选的文件，路径可以改。
    @State private var picked: [PickedFile] = []
    @State private var importing = false
    @State private var browsing: HostFilePicker.Request?
    /// 远程要求登录：底部按钮换成登录这个平台，绑好令牌后重试被挡住的那一步。
    @State private var gitLogin: GitLogin?
    @State private var loggingIn = false
    @State private var integration = "merge"
    @State private var step = 1
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?

    /// 默认的工作机在建视图时就定好，见 CardSheet 按内容定高的说明。
    init(model: AppModel) {
        _machineID = State(initialValue: model.preferredWorker()?.id ?? "")
    }

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
            + picked.map { ProjectEnvFile(path: $0.path.trimmingCharacters(in: .whitespaces), value: $0.value, from: $0.from) }
    }
    private var filesValid: Bool {
        let paths = envFiles.map(\.path)
        return paths.allSatisfy { !$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") } && Set(paths).count == paths.count
    }

    /// 填好的文件夹路径，没填时为空。
    private var folderPath: String? { current.path.flatMap { $0.isEmpty ? nil : $0 } }

    /// 在工作机上选的文件来自哪台；没选过时为空。
    private var fileWorker: String? { picked.lazy.compactMap(\.machine).first }
    /// 能从哪几台工作机选文件：文件夹只能是它所在的那台，远程项目选过一台后只能是那台。
    private var fileWorkers: [WorkerConnection] {
        let only = source == .folder ? machineID : fileWorker
        return model.availableWorkers.filter { only == nil || $0.id == only }
    }

    var body: some View {
        Group {
            if step == 1 { sourceStep } else { integrationStep }
        }
        .endsTyping(focus != nil) { focus = nil }
        .sheet(item: $browsing) { request in
            HostFilePicker(request: request) { paths in
                if request.folders { path = paths.first ?? path; inspect() } else { addWorkerFiles(paths, from: request.machineID) }
            }
        }
        // 文件夹换了工作机：在别的工作机上选的文件这次带不上
        .onChange(of: machineID) { dropForeignFiles() }
        .onChange(of: source) { dropForeignFiles() }
        // 失败原因显示在底部按钮里，改了来源就收起
        .onChange(of: current) {
            if phase.error != nil { phase = .idle }
            gitLogin = nil
        }
        .sheet(isPresented: $loggingIn) {
            if let gitLogin {
                // 存到马上要重试的那台：文件夹所在的工作机；远程项目的检查任一台都行
                GitLoginSheet(host: gitLogin.host, machineID: source == .folder ? machineID : nil) {
                    self.gitLogin = nil
                    attempt(gitLogin.retry)
                }
            }
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
                    picked.append(PickedFile(path: freePath(name), value: text))
                }
                if phase.error != nil { phase = .idle }
            } catch { phase = .failed(error.localizedDescription) { importing = true } }
        }
    }

    // MARK: 第一步：来源与环境变量文件

    private var sourceStep: some View {
        CardSheet(title: "添加项目", subtitle: "从远程或任一工作机添加项目及所需环境变量",
                  typing: focus != nil, close: { dismiss() }) {
            HStack(spacing: 12) {
                CardChoice(title: "远程仓库", detail: "GitHub、GitLab 等平台上的仓库", symbol: .world, selected: source == .remote) { source = .remote }
                CardChoice(title: "工作机文件夹", detail: "任一工作机上的本地仓库或文件夹", symbol: .folder, selected: source == .folder) { source = .folder }
            }
            if source == .folder {
                CardField(label: "工作机") { WorkerMenu(machineID: $machineID, placeholder: "选择文件夹所在的工作机") }
            }
            CardField(label: "仓库位置", focused: focus == .path || focus == .remote, note: locationNote) {
                HStack(spacing: 0) {
                    if source == .folder {
                        TextField("工作机上的绝对路径，如 /Users/me/code/app", text: $path)
                            .literal().focused($focus, equals: .path).onSubmit(inspect)
                            .cardInput { focus = .path }
                        Button {
                            browsing = HostFilePicker.Request(machineID: machineID, folders: true, start: folderPath)
                        } label: {
                            PaneButtonLabel("浏览", systemImage: "folder")
                        }
                        .buttonStyle(PaneButtonStyle()).fixedSize()
                        .disabled(model.connections[machineID]?.connected != true)
                        .help("在工作机上浏览")
                        .padding(.trailing, 4)
                    } else {
                        TextField("github.com/me/repo", text: $remote)
                            .literal().focused($focus, equals: .remote).onSubmit(next)
                            .cardInput { focus = .remote }
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
                Menu("选文件…") {
                    Button("这台设备") { importing = true }
                    Section("工作机") {
                        ForEach(fileWorkers) { connection in
                            Button(connection.machine.name) {
                                let start = source == .folder && connection.id == machineID ? folderPath : nil
                                browsing = HostFilePicker.Request(machineID: connection.id, folders: false, start: start)
                            }
                        }
                    }
                }
                .menuStyle(.button).menuIndicator(.hidden)
            }
        } footer: {
            footer("下一步", enabled: sourceReady && filesValid, action: next)
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
        attempt { _ = try await runCheck() }
    }

    /// 跑一次请求；远程要求登录时不算失败，记下来让底部按钮换成登录，绑好令牌后重跑。
    private func attempt(_ action: @escaping () async throws -> Void) {
        $phase.run {
            do { try await action() }
            catch let error as KitedError where error.gitLogin != nil { gitLogin = GitLogin(host: error.gitLogin!, retry: action) }
        }
    }

    /// 下一步：先检查（远程要确认能访问），已登记的直接收下；没有远程的跳过第二步直接添加。
    private func next() {
        guard sourceReady, filesValid, !phase.working else { return }
        attempt {
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
        CardSheet(title: "集成方式", subtitle: "工作区的改动怎样进入主线，之后可以在项目配置里改", back: true,
                  close: { phase = .idle; gitLogin = nil; step = 1 }) {
            VStack(spacing: 8) {
                CardChoice(title: "直接合入", detail: "把工作区的改动合进主线，再推送到远程。适合只有自己用的仓库。",
                           symbol: .gitMerge, selected: integration == "merge") { integration = "merge" }
                CardChoice(title: "提交 PR", detail: "把工作区分支推到远程并开一个 PR，在网页上审查后合并。适合多人共用或主线受保护的仓库。",
                           symbol: .gitPullRequest, selected: integration == "pullRequest") { integration = "pullRequest" }
            }
            if let reason = check?.integrationReason { CardNote("已按仓库情况预选：\(reason)。") }
        } footer: {
            footer("添加") { attempt { try await add() } }
        }
    }

    /// 两步共用的底部按钮：远程要求登录时换成登录这个平台。
    private func footer(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        CardActions(primary: gitLogin.map { "登录 \($0.host)" } ?? title, enabled: gitLogin != nil || enabled, phase: $phase) {
            if gitLogin != nil { loggingIn = true } else { action() }
        }
    }

    /// 环境变量文件在工作区里的路径还没被占用就用它，否则留空让用户填。
    private func freePath(_ path: String) -> String {
        picked.contains { $0.path == path } || found.contains(path) ? "" : path
    }

    /// 在工作机上选的文件：在要添加的文件夹里的照原来的相对路径放（检查时已找到的直接勾上），别处的按文件名，不是 .env 开头的放到 .env。
    private func addWorkerFiles(_ paths: [String], from machine: String) {
        let folder = source == .folder && machine == machineID ? current.path.map { $0.hasSuffix("/") ? $0 : $0 + "/" } : nil
        for file in paths where !picked.contains(where: { $0.from == file }) {
            let inside = folder.flatMap { file.hasPrefix($0) ? String(file.dropFirst($0.count)) : nil }
            if let inside, check?.envFiles.contains(inside) == true { found.insert(inside); continue }
            let name = (file as NSString).lastPathComponent
            picked.append(PickedFile(path: freePath(inside ?? (name.hasPrefix(".env") ? name : ".env")), from: file, machine: machine))
        }
        if phase.error != nil { phase = .idle }
    }

    private func dropForeignFiles() {
        guard source == .folder else { return }
        picked.removeAll { $0.machine != nil && $0.machine != machineID }
    }

    private func add() async throws {
        let project = try await model.addProject(current, machineID: current.path == nil ? fileWorker : machineID,
                                                 integration: check?.remote == nil ? nil : integration, envFiles: envFiles)
        model.selectProject(project.id)
        dismiss()
    }

    /// 选的文件：从这台设备选的带着内容，从工作机上选的记着那台和绝对路径。
    private struct PickedFile: Identifiable {
        let id = UUID()
        var path: String
        var value: String?
        var from: String?
        var machine: String?
    }

    private enum Field { case path, remote }

    private enum Source { case folder, remote }

    private struct GitLogin {
        let host: String
        let retry: () async throws -> Void
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

extension View {
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
            .sheet(isPresented: $model.addingProject) { AddProject(model: model).environment(model).toastHost().appAppearance() }
            .sheet(item: $model.contextVariable) { ContextVariableSheet(variable: $0).environment(model).toastHost().appAppearance() }
            .modifier(WorkspaceGitPresentation())
    }
}
