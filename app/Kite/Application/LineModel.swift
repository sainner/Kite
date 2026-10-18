import Foundation

/// 个人 agent Line 在 App 里的位置：Line 所在的工作区（侧栏顶部的标志进入）与它的收件箱（Line 那个 monitor 实例）。
/// 账号下只有一个 Line，从各工作机的目录里按角色找；收件箱的操作都发到 Line 所在的工作机（docs/Line与工作区流转.md）。
extension AppModel {
    static let lineRole = "kite.line"
    static let monitorDefinition = "kite.monitor"

    /// Line 所在的工作区。
    /// 侧栏、输入区在观察里读它：上次找到的还是 Line 时只看那一个工作区，观察范围不铺到所有工作区的实例。
    var lineArea: WorkArea? {
        if let hint = lineAreaHint, let area = workspaces.first(where: { $0.id == hint }), hostsLine(area) { return area }
        let found = workspaces.first(where: hostsLine)
        lineAreaHint = found?.id
        return found
    }

    private func hostsLine(_ area: WorkArea) -> Bool {
        area.remote.workspace.status == .open && lineThread(in: area) != nil
    }

    /// Line 的线程（实例 ID）。
    var lineThreadID: String? { lineArea.flatMap(lineThread(in:)) }

    /// Line 的收件箱实例。
    var lineInbox: RemotePluginInstance? { lineArea.flatMap(inboxInstance(in:)) }

    private func lineThread(in area: WorkArea) -> String? {
        area.instances.first { $0.status == .open && $0.config?.role?.id == Self.lineRole }?.id
    }

    private func inboxInstance(in area: WorkArea) -> RemotePluginInstance? {
        area.instances.first { $0.status == .open && $0.definitionId == Self.monitorDefinition && $0.config?.monitor?.system == "line" }
    }

    /// 回应卡片上的「交给 Line」：把这一项交给 Line 代处理；没有 Line，或这是 Line 自己线程上的请求时为空。
    /// 远程工作机上的等待要等 Line 那边读到汇总（最多一分钟）才在收件箱里，那之前交不出去，工作机会返回 404。
    func lineDelegate(_ thread: WorkThread) -> (() async throws -> Void)? {
        guard let area = lineArea, area.pluginClient != nil, inboxInstance(in: area) != nil, thread.id != lineThread(in: area) else { return nil }
        return { [weak self, weak thread] in
            guard let self, let waiting = thread?.waiting else { return }
            do {
                // 卡片上合成的几项请求逐项交出，见 WorkThread.waiting
                for id in waiting.id.components(separatedBy: "|") {
                    try await lineInboxOperation("monitor.delegate", ["item": .string("waiting:\(id)")])
                }
            } catch let error as KitedError where error.status == 404 {
                throw KitedError(message: "Line 还没看到这一项，稍后再试", status: 404)
            }
        }
    }
}

/// Line 的收件箱（monitor.read）：等你的事项，以及当前或上一次离开那一段里了结的记录。
nonisolated struct LineInbox: Decodable, Equatable, Sendable {
    nonisolated struct Named: Decodable, Equatable, Sendable { let id: String; let name: String }
    nonisolated struct Workspace: Decodable, Equatable, Sendable { let id: String; let name: String; let project: Named }
    nonisolated struct ThreadRef: Decodable, Equatable, Sendable { let id: String; let title: String }
    nonisolated struct Delegated: Decodable, Equatable, Sendable { let by: String; let at: Double; var sent: Double? }
    nonisolated struct Item: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        /// approval、question、turn、failed、recovery、preparation、unreachable。
        let kind: String
        let machine: Named
        var workspace: Workspace?
        var thread: ThreadRef?
        var waiting: RemoteWaiting?
        let text: String
        let at: Double
        let addedAt: Double
        var own: Bool?
        var delegated: Delegated?
        var left: Bool?
        var note: String?

        /// Line 能代处理的：别人线程上的审批、提问、回合结束与失败。
        var delegable: Bool { own != true && ["approval", "question", "turn", "failed"].contains(kind) }
    }
    nonisolated struct Record: Decodable, Equatable, Sendable {
        let at: Double
        let item: Item
        /// handled：Line 代处理了；left：Line 留给你；resolved：在别处回应或自己解除。
        let outcome: String
        var decision: String?
        var reason: String?
    }
    nonisolated struct Period: Decodable, Equatable, Sendable { let since: Double; var until: Double? }
    nonisolated struct Delegation: Decodable, Equatable, Sendable { var until: Double?; var timeoutMinutes: Int? }

    let items: [Item]
    var period: Period?
    let records: [Record]
    let delegation: Delegation

    /// 等你的事项：回合结束以外的，加上离开那一段之前留下、还没点「知道了」的回合结束。
    var waiting: [Item] {
        items.filter { item in item.kind != "turn" || period.map { item.addedAt < $0.since } ?? true }
    }
    /// 离开期间结束的回合。
    var awayTurns: [Item] {
        guard let period else { return [] }
        return items.filter { $0.kind == "turn" && $0.addedAt >= period.since }
    }
}

extension AppModel {
    /// 读一遍 Line 的收件箱；没有 Line 时清掉。
    func refreshLineInbox() async {
        guard let area = lineArea, let inbox = lineInbox, let client = area.pluginClient else {
            if lineInboxSnapshot != nil { lineInboxSnapshot = nil }
            return
        }
        do {
            let snapshot = try await client.request("/workspaces/\(area.id.pathComponent)/operations/monitor.read", method: "POST",
                                                    body: ["instanceId": inbox.id], as: LineInbox.self)
            if lineInboxSnapshot != snapshot { lineInboxSnapshot = snapshot }
        } catch {
            TimingTrace.mark("读取收件箱失败：\(error.localizedDescription)")
        }
    }

    /// 收件箱上的操作：交给 Line、知道了、托管，都发到 Line 所在的工作机，完成后重读。
    func lineInboxOperation(_ operation: String, _ body: [String: JSON]) async throws {
        guard let area = lineArea, let inbox = lineInbox, let client = area.pluginClient else { throw KitedError(message: "还没有启用 Line") }
        var payload = body
        payload["operationId"] = .string(UUID().uuidString.lowercased())
        payload["instanceId"] = .string(inbox.id)
        let _: JSON = try await client.request("/workspaces/\(area.id.pathComponent)/operations/\(operation)", method: "POST",
                                               body: JSON.object(payload), as: JSON.self)
        await refreshLineInbox()
    }

    /// 点标志：进 Line 的工作区。
    func openLine() {
        guard let area = lineArea else { return }
        selectWorkspace(area.id)
    }

    /// 在一台工作机上启用 Line，建好后进它的工作区。
    func enableLine(on connection: WorkerConnection) async throws {
        let _: JSON = try await connection.client.request("/line", method: "POST", timeout: 300, as: JSON.self)
        try await refresh(connection.client)
        openLine()
    }

    /// 收件箱里一项所在工作机的连接，回应等待、继续线程用它。
    func client(forMachine id: String) -> KitedClient? { connections[id]?.client }
}
