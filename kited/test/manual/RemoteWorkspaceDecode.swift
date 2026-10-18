import Foundation

@main
struct RemoteWorkspaceDecode {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 12 else {
            throw DecodeError.usage
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let machineURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let localProjectsURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let remoteProjectsURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let machine = try JSONDecoder().decode(RemoteMachine.self, from: Data(contentsOf: machineURL))
        // 协议号 App 与 kited 各记一份，这里核对两边一致（AGENTS.md「项目阶段」）。
        guard machine.version?.protocol == KiteProtocol.version else { throw DecodeError.protocolMismatch }
        print("App 与工作机的协议号一致")
        let localProjects = try JSONDecoder().decode([RemoteProject].self, from: Data(contentsOf: localProjectsURL))
        let remoteProjects = try JSONDecoder().decode([RemoteProject].self, from: Data(contentsOf: remoteProjectsURL))
        let workspaces = try JSONDecoder().decode([RemoteWorkspace].self, from: Data(contentsOf: url))
        let cursorFixture = try JSONDecoder().decode(CatalogCursorFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5])))
        let archivedWorkspaces = try JSONDecoder().decode([RemoteWorkspace].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[6])))
        let definitions = try JSONDecoder().decode([RemotePluginDefinition].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[7])))
        let files = try JSONDecoder().decode(FileFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[8])))
        let registry = try JSONDecoder().decode(RegistryFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[9])))
        let secretState = try JSONDecoder().decode(SecretStateFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[10])))
        let directory = try JSONDecoder().decode(MachinesFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[11])))
        guard localProjects.count == 1,
              remoteProjects.count == 2,
              remoteProjects.contains(where: { $0.id == localProjects[0].id }),
              remoteProjects.contains(where: { $0.id != localProjects[0].id && $0.name == localProjects[0].name }) else {
            throw DecodeError.invalidProjects
        }
        print("已解码跨工作机共享项目身份及同名独立项目")
        try verifyRegistry(registry, local: localProjects[0], remote: remoteProjects)
        try verifyDirectory(directory, machine: machine)
        // 两个工作区按身份认：停在密钥请求上的线程所在的是密钥工作区，另一个是两线程的工作区。
        guard let secret = workspaces.first(where: { $0.threads.contains(where: { $0.instanceId == secretState.threadId }) }),
              let worktree = workspaces.first(where: { $0.id != secret.id }) else {
            throw DecodeError.missingWorkspace
        }
        // 没有根工作区：同一项目、同一检出上的几个工作区各有自己的分支和工作树。
        // behind 断言具体值：新建时先拉取主线，主线之后没有新提交，为 0；键名对不上时 Swift 只会静默得到 nil。
        guard workspaces.count == 2,
              worktree.machine.id == machine.id,
              secret.machine.id == machine.id,
              worktree.checkout.machineId == machine.id,
              secret.checkout.machineId == machine.id,
              secret.project.id == worktree.project.id,
              secret.checkout.id == worktree.checkout.id,
              worktree.workspace.checkoutId == worktree.checkout.id,
              secret.workspace.checkoutId == secret.checkout.id,
              secret.id != worktree.id,
              secret.workspace.cwd != worktree.workspace.cwd,
              let worktreeBranch = worktree.workspace.branch, let secretBranch = secret.workspace.branch,
              !worktreeBranch.isEmpty, worktreeBranch != secretBranch,
              worktree.workspace.base?.isEmpty == false,
              secret.workspace.base?.isEmpty == false,
              worktree.workspace.status == .open,
              secret.workspace.status == .open,
              worktree.workspace.behind == 0,
              secret.workspace.behind == 0,
              worktree.workspace.pullRequest == nil,
              secret.workspace.pullRequest == nil,
              worktree.threads.count >= 2,
              Set(worktree.threads.map(\.instanceId)).count == worktree.threads.count,
              worktree.threads.allSatisfy({ $0.runtime == .harness && !$0.nativeId.isEmpty }) else {
            throw DecodeError.invalidRelationships
        }
        print("已解码同一项目的两个工作区：各自的分支、开出时的主线提交、behind 与 pullRequest")
        try verifySecret(secretState, workspace: secret)
        let threadInstanceIDs = Set(worktree.threads.map(\.instanceId))
        let agentInstances = worktree.instances.filter { $0.definitionId == "kite.agent" }
        guard Set(agentInstances.map(\.id)) == threadInstanceIDs,
              agentInstances.allSatisfy({ $0.workspaceId == worktree.workspace.id && $0.status == .open && $0.presentation == .window }),
              agentInstances.allSatisfy({ $0.state?.path == nil && $0.state?.revision == nil }),
              let filesInstance = worktree.instances.first(where: { $0.definitionId == "kite.files" }),
              filesInstance.workspaceId == worktree.workspace.id,
              filesInstance.status == .open,
              filesInstance.presentation == .window,
              let customInstance = worktree.instances.first(where: { $0.definitionId == "custom.decode-state" }),
              customInstance.state?.plugin == .object(["count": .number(1)]) else {
            throw DecodeError.invalidRelationships
        }
        print("已解码真实自定义插件业务状态，保留 JSON 比较输入")
        try verifyFiles(files, instance: filesInstance)
        let fileViews = worktree.windows.filter { $0.target.instanceId == filesInstance.id }
        let agentViews = worktree.windows.filter { threadInstanceIDs.contains($0.target.instanceId) }
        guard fileViews.count == 1,
              fileViews[0].target.viewId == "files",
              fileViews.allSatisfy({ $0.workspaceId == worktree.workspace.id && $0.state == .open }),
              Set(agentViews.map { $0.target.instanceId }) == threadInstanceIDs,
              Set(agentViews.map { $0.target.viewId }) == ["conversation"],
              agentViews.allSatisfy({ $0.workspaceId == worktree.workspace.id && $0.state == .open }) else {
            throw DecodeError.invalidRelationships
        }
        guard let agentDefinition = definitions.first(where: { $0.id == "kite.agent" }),
              agentDefinition.lifetime == .persistent,
              agentDefinition.defaultView == "conversation",
              agentDefinition.agent?.runtime == .harness,
              agentDefinition.agent?.model != nil,
              agentInstances.allSatisfy({ $0.config?.agent?.model == agentDefinition.agent?.model }),
              agentDefinition.views.map(\.id) == ["conversation"],
              let filesDefinition = definitions.first(where: { $0.id == "kite.files" }),
              filesDefinition.lifetime == .window,
              filesDefinition.defaultView == "files",
              filesDefinition.views.map(\.id) == ["files"] else {
            throw DecodeError.invalidRelationships
        }
        try verifyCatalog(initial: workspaces, archived: archivedWorkspaces, cursors: cursorFixture)
        print("已解码 \(workspaces.count) 个工作区聚合")
    }

    /// 添加项目前的检查、添加的结果与登记表：没有远程的文件夹只能直接合入，外观为默认值，登记表与项目身份是同一组项目。
    private static func verifyRegistry(_ fixture: RegistryFixture, local: RemoteProject, remote: [RemoteProject]) throws {
        let check = fixture.check
        guard check.remote == nil,
              check.integration == "merge",
              check.envFiles == [".env"],
              check.existing == nil,
              fixture.added.id == local.id,
              fixture.added.name == local.name,
              fixture.added.remote == nil,
              fixture.added.integration == "merge",
              !fixture.added.proposes,
              fixture.added.appearance == ProjectAppearance(),
              fixture.separate.id != fixture.added.id,
              fixture.separate.name == fixture.added.name,
              Set(fixture.registry.map(\.id)) == Set(remote.map(\.id)),
              Set(fixture.registry.map(\.id)) == [fixture.added.id, fixture.separate.id],
              fixture.registry.allSatisfy({ $0.remote == nil && $0.integration == "merge" && $0.appearance == ProjectAppearance() }) else {
            throw DecodeError.invalidRegistry
        }
        print("已解码添加项目前的检查、登记表里的项目与集成方式")
    }

    /// 工作机目录：本机在前，第二台最近一次的目录摘要能还原出它为同一项目建的工作区（离线目录没有窗口与会话内容）。
    private static func verifyDirectory(_ fixture: MachinesFixture, machine: RemoteMachine) throws {
        guard fixture.machines.first?.id == machine.id,
              let other = fixture.machines.first(where: { $0.id == fixture.otherMachine }),
              let snapshot = other.snapshot,
              snapshot.machine.id == fixture.otherMachine,
              let summary = snapshot.summaries.first(where: { $0.id == fixture.sharedWorkspace }),
              summary.project.id == fixture.project,
              summary.checkout.machineId == fixture.otherMachine,
              summary.workspace.status == .open,
              summary.workspace.branch?.isEmpty == false,
              summary.workspace.base?.isEmpty == false,
              summary.threads.isEmpty, summary.windows.isEmpty else {
            throw DecodeError.invalidDirectory
        }
        print("已解码工作机目录里另一台工作机的目录摘要")
    }

    /// 密钥请求：线程流首帧的状态带 kind 为 secret 的等待，工作区聚合里线程的活动摘要也停在 secret。
    private static func verifySecret(_ fixture: SecretStateFixture, workspace: RemoteWorkspace) throws {
        guard workspace.threads.count == 1,
              let thread = workspace.threads.first,
              thread.instanceId == fixture.threadId,
              thread.runtime == .harness,
              thread.activity?.waiting == "secret",
              workspace.instances.contains(where: { $0.id == thread.instanceId && $0.definitionId == "kite.agent" && $0.status == .open }),
              fixture.state.phase == "running",
              let waiting = fixture.state.waiting,
              waiting.isSecret,
              !waiting.isQuestion,
              !waiting.id.isEmpty,
              waiting.since > 0,
              waiting.name == "STRIPE_KEY",
              waiting.secretKind == "file",
              waiting.reason == "调支付接口",
              waiting.value == "sk_test_prefilled",
              waiting.exists == false,
              waiting.file == nil,
              waiting.key == nil,
              waiting.questions == nil,
              waiting.tool == nil else {
            throw DecodeError.invalidSecret
        }
        print("已解码密钥请求的等待与线程活动摘要")
    }

    private static func verifyFiles(_ files: FileFixture, instance: RemotePluginInstance) throws {
        guard files.directory.entries.contains(where: {
                  $0.name == "base.txt" && $0.path == "base.txt" && $0.kind == "file"
              }),
              files.directory.total >= files.directory.entries.count,
              files.page.path == "base.txt",
              files.page.text.contains("原始"),
              files.page.offset == 1,
              files.page.totalLines >= 1,
              !files.page.version.isEmpty,
              files.before.path == nil,
              files.selected.path == "base.txt",
              files.selected.revision != files.before.revision,
              files.after == files.selected,
              instance.state?.path == files.selected.path,
              instance.state?.revision == files.selected.revision else {
            throw DecodeError.invalidFiles
        }
        print("已解码文件目录、文本页、选择状态及插件实例状态")
    }

    @MainActor private static func verifyCatalog(
        initial: [RemoteWorkspace], archived: [RemoteWorkspace], cursors: CatalogCursorFixture
    ) throws {
        guard let before = EventCursor(cursors.before),
              let after = EventCursor(cursors.after),
              let other = EventCursor(cursors.other),
              cursors.archived.count == 3,
              after.covers(before), !before.covers(after), !after.covers(other),
              archived.contains(where: { workspace in
                  guard workspace.workspace.status == .archived, workspace.threads.count == 2 else { return false }
                  let ids = Set(workspace.threads.map(\.instanceId))
                  let agents = workspace.instances.filter { $0.definitionId == "kite.agent" }
                  return Set(agents.map(\.id)) == ids && workspace.instances.allSatisfy({ $0.status == .archived })
              }) else {
            throw DecodeError.invalidCatalog
        }
        let notifications = try cursors.archived.map { raw -> EventCursor in
            guard let value = EventCursor(raw) else { throw DecodeError.invalidCatalog }
            return value
        }
        let refresh = CatalogRefresh()
        let firstGeneration = refresh.generation
        var displayed = ""
        var reads = 0
        guard refresh.apply(before, generation: firstGeneration, update: { displayed = "before" }),
              notifications.allSatisfy({ refresh.needsRefresh($0) }) else {
            throw DecodeError.invalidCatalog
        }
        guard refresh.apply(after, generation: firstGeneration, update: { displayed = "after"; reads += 1 }),
              reads == 1,
              notifications.allSatisfy({ !refresh.needsRefresh($0) }),
              !refresh.apply(before, generation: firstGeneration, update: { displayed = "stale" }),
              !refresh.apply(other, generation: firstGeneration, update: { displayed = "wrong-machine" }),
              displayed == "after" else {
            throw DecodeError.invalidCatalog
        }

        let reconnected = refresh.reset()
        guard refresh.needsRefresh(before),
              refresh.apply(before, generation: reconnected, update: { displayed = "reconnected" }),
              !refresh.apply(after, generation: firstGeneration, update: { displayed = "old-connection" }),
              displayed == "reconnected" else {
            throw DecodeError.invalidCatalog
        }
        let switched = refresh.reset()
        guard refresh.apply(other, generation: switched, update: { displayed = "other-machine" }),
              !refresh.apply(after, generation: switched, update: { displayed = "old-machine" }),
              displayed == "other-machine" else {
            throw DecodeError.invalidCatalog
        }
        print("已核对目录游标、合并刷新、乱序响应与连接切换")
    }

}

private struct CatalogCursorFixture: Decodable {
    let before: String
    let after: String
    let other: String
    let archived: [String]
}

private struct RegistryFixture: Decodable {
    let check: ProjectCheck
    let added: AccountProject
    let separate: AccountProject
    let registry: [AccountProject]
}

private struct MachinesFixture: Decodable {
    let machines: [DirectoryMachine]
    let otherMachine: String
    let sharedWorkspace: String
    let project: String
}

private struct SecretStateFixture: Decodable {
    let threadId: String
    let state: RemoteState
}

private struct FileFixture: Decodable {
    let directory: FileDirectory
    let page: FilePage
    let before: FileSelection
    let selected: FileSelection
    let after: FileSelection
}

private enum DecodeError: Error {
    case usage
    case missingWorkspace
    case invalidRelationships
    case invalidProjects
    case invalidCatalog
    case invalidFiles
    case invalidRegistry
    case invalidSecret
    case invalidDirectory
    case protocolMismatch
}
