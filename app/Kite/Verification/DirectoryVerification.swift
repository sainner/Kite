#if DEBUG
import Darwin
import Foundation
import Observation

/// 手动验收运行真实 AppModel；本入口不模拟连接、聚合、操作或 SSE。
@MainActor
enum DirectoryVerification {
    private struct Fixture: Decodable {
        let login: Data
        let directory: AccountDirectory
        let controlURL: URL
        let userID: String
        let projectID: String
        let workspaceA: String
        let workspaceB: String
        let liveWorkspaceA: RemoteWorkspace
    }

    private struct Failure: Error { let message: String }

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["KITE_VERIFY_DIRECTORY"] != nil
    }

    static func account() throws -> KiteAccount {
        let fixture = try load()
        return try KiteAccount(verificationLogin: fixture.login, directory: fixture.directory)
    }

    static func run(model: AppModel) async {
        var code: Int32 = 0
        do {
            let fixture = try load()
            defer {
                model.clearAccountConnections()
                AccountDirectory.clear(fixture.userID)
                for key in UserDefaults.standard.dictionaryRepresentation().keys
                where key.contains(fixture.workspaceA) || key.contains(fixture.workspaceB) {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            try await verify(model, fixture: fixture)
            output("目录 App 验收通过：两机汇总、摘要保留布局、按工作区操作、离线隔离及旧响应丢弃")
        } catch {
            model.clearAccountConnections()
            output("目录 App 验收失败：\((error as? Failure)?.message ?? error.localizedDescription)", error: true)
            code = 1
        }
        Darwin.exit(code)
    }

    private static func load() throws -> Fixture {
        guard let fixture = ProcessInfo.processInfo.environment["KITE_VERIFY_DIRECTORY"] else {
            throw Failure(message: "缺少 KITE_VERIFY_DIRECTORY fixture")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(fixture.utf8))
    }

    private static func verify(_ model: AppModel, fixture: Fixture) async throws {
        // 用真实完整快照保存布局，再用目录摘要创建同一个工作区；摘要不能抹掉已有布局。
        let seeded = WorkArea(remote: fixture.liveWorkspaceA)
        guard let pane = seeded.layout.panes.first else { throw Failure(message: "布局夹具缺少真实窗口") }
        seeded.layout.minimize(pane)
        let layout = layoutRecords(fixture.workspaceA)
        try require(!layout.isEmpty, "布局夹具未写入可恢复记录")

        model.mergeDirectory()
        try require(layoutRecords(fixture.workspaceA) == layout, "仅目录摘要的工作区清除了旧布局")
        try require(model.knownProjects.filter { $0.id == fixture.projectID }.count == 1, "同项目身份没有合并为一个项目")
        try require(model.workspace(fixture.workspaceA) != nil && model.workspace(fixture.workspaceB) != nil,
                    "托管目录未同时呈现两台工作机的工作区")
        model.startConnections()
        try await wait("两台工作机的实时目录") {
            guard let a = model.workspace(fixture.workspaceA), let b = model.workspace(fixture.workspaceB) else { return false }
            return model.isConnected(a) && model.isConnected(b)
                && model.connection(for: a)?.hasLiveCatalog == true && model.connection(for: b)?.hasLiveCatalog == true
        }
        guard let areaA = model.workspace(fixture.workspaceA), let areaB = model.workspace(fixture.workspaceB) else {
            throw Failure(message: "实时目录丢失了工作区")
        }
        try require(areaA.remote?.project.id == fixture.projectID && areaB.remote?.project.id == fixture.projectID,
                    "两台真实工作机返回的共享项目身份不同")

        model.selected = areaB.id
        let count = areaA.windows.count
        model.openWindow(.create("kite.agent"), in: areaA)
        try await wait("选中 B 时在 A 新建窗口") {
            guard let area = model.workspace(fixture.workspaceA) else { return false }
            return !area.changingWindows && area.windows.count > count
        }
        try await control(fixture, "/assert-operation-a")
        try require(model.workspace(fixture.workspaceB) != nil, "A 的实时快照清除了 B")

        try await control(fixture, "/disconnect-a")
        try await wait("A 离线且 B 仍在线") {
            guard let a = model.workspace(fixture.workspaceA), let b = model.workspace(fixture.workspaceB) else { return false }
            return !model.isConnected(a) && model.isConnected(b)
        }
        try require(model.knownProjects.contains { $0.id == fixture.projectID }, "A 离线后共享项目丢失")

        // B 仍有真实连接；挂起其真实 HTTP 响应，在连接字典清空后才交回旧响应。
        let oldClient = try model.activeClient(in: areaB)
        try await control(fixture, "/hold-b")
        let pending = Task { try await model.refresh(oldClient) }
        try await control(fixture, "/held-b", method: "GET")
        model.clearAccountConnections()
        try require(!model.accepts(oldClient), "清空连接后旧客户端仍被接受")
        try require(model.workspaces.isEmpty, "清空账号连接未清空工作区")
        try await control(fixture, "/release-b")
        try await pending.value
        try require(model.workspaces.isEmpty && !model.accepts(oldClient), "已清空的账号被旧响应重新填入目录")
        try await control(fixture, "/finished")
    }

    private static func layoutRecords(_ workspaceID: String) -> [String: Data] {
        UserDefaults.standard.dictionaryRepresentation().keys.reduce(into: [:]) { records, key in
            if key.contains(workspaceID), let data = UserDefaults.standard.data(forKey: key) { records[key] = data }
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    /// 等实际 Observation 变更；计时器只用于失败期限，不用轮询或 sleep 推动状态。
    private static func wait(_ description: String, until predicate: @escaping @MainActor () -> Bool) async throws {
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let deadline = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            continuation.finish(throwing: Failure(message: "等待\(description)超时"))
        }
        defer { deadline.invalidate(); continuation.finish() }
        func observe() {
            let ready = withObservationTracking { predicate() } onChange: { continuation.yield(()) }
            if ready { continuation.finish() }
        }
        observe()
        for try await _ in stream { observe() }
    }

    private static func control(_ fixture: Fixture, _ path: String, method: String = "POST") async throws {
        var request = URLRequest(url: fixture.controlURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "编排门闩失败：\(String(data: data, encoding: .utf8) ?? path)")
        }
    }

    private static func output(_ text: String, error: Bool = false) {
        (error ? FileHandle.standardError : FileHandle.standardOutput).write(Data((text + "\n").utf8))
    }
}
#endif
