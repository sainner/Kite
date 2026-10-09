import Foundation

@main
struct RemoteWorkspaceDecode {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 9 else {
            throw DecodeError.usage
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let machineURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let localProjectsURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let remoteProjectsURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let machine = try JSONDecoder().decode(RemoteMachine.self, from: Data(contentsOf: machineURL))
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
        guard localProjects.count == 1,
              remoteProjects.count == 2,
              remoteProjects.contains(where: { $0.id == localProjects[0].id }),
              remoteProjects.contains(where: { $0.id != localProjects[0].id && $0.name == localProjects[0].name }) else {
            throw DecodeError.invalidProjects
        }
        print("已解码跨工作机共享项目身份及同名独立项目")
        guard let root = workspaces.first(where: { $0.workspace.kind == .root }),
              let worktree = workspaces.first(where: { $0.workspace.kind == .worktree }) else {
            throw DecodeError.missingWorkspaceKind
        }
        guard root.threads.isEmpty,
              root.instances.isEmpty,
              root.machine.id == machine.id,
              worktree.machine.id == machine.id,
              root.checkout.machineId == machine.id,
              worktree.checkout.machineId == machine.id,
              worktree.project.id == root.project.id,
              worktree.checkout.id == root.checkout.id,
              worktree.threads.count >= 2,
              Set(worktree.threads.map(\.instanceId)).count == worktree.threads.count,
              worktree.threads.allSatisfy({ $0.runtime == .harness && !$0.nativeId.isEmpty }) else {
            throw DecodeError.invalidRelationships
        }
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
                  guard workspace.workspace.kind == .worktree, workspace.threads.count == 2 else { return false }
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

private struct FileFixture: Decodable {
    let directory: FileDirectory
    let page: FilePage
    let before: FileSelection
    let selected: FileSelection
    let after: FileSelection
}

private enum DecodeError: Error {
    case usage
    case missingWorkspaceKind
    case invalidRelationships
    case invalidProjects
    case invalidCatalog
    case invalidFiles
}
