import Foundation

/// 账号级数据——项目登记与外观、项目约束、凭据、GitHub 绑定、各工作机的目录摘要——存在工作机上，工作机之间互相同步；
/// App 找一台连着的工作机读写，见 docs/分布式架构.md。
extension AppModel {
    /// 读写账号级数据用的工作机：作为工作机的这台 Mac 优先，其次是任一台连着的工作机。
    func dataWorker() throws -> KitedClient { try dataConnection().client }

    private func dataConnection() throws -> WorkerConnection {
        guard let connection = availableWorkers.first(where: { $0.client.isLocal }) ?? availableWorkers.first else {
            throw KitedError(message: "没有连上的工作机。凭据、项目外观与约束存在工作机上，连上一台再试")
        }
        return connection
    }

    /// 连着的、有这个项目检出的工作机，作为工作机的这台 Mac 优先：设远程要用那台本机的检出推送。
    private func checkoutWorker(_ projectID: String) throws -> KitedClient {
        let holders = Set(checkouts.filter { $0.projectId == projectID }.map(\.machineId))
        let candidates = availableWorkers.filter { holders.contains($0.machine.id) }
        guard let connection = candidates.first(where: { $0.client.isLocal }) ?? candidates.first else {
            throw KitedError(message: "连着的工作机上都没有这个项目的检出，连上有检出的那台再设远程")
        }
        return connection.client
    }

    /// 从一台连着的工作机读目录摘要与项目外观；都没连上时沿用缓存，返回是否读到了。
    func refreshDirectory() async -> Bool {
        guard let client = try? dataWorker() else { return false }
        let revision = account.appearanceRevision
        do {
            async let machines = client.request("/machines", as: [DirectoryMachine].self)
            async let projects = client.request("/project-registry", as: [AccountProject].self)
            try account.updateDirectory(machines: await machines, projects: await projects, revision: revision)
            return true
        } catch { return false }
    }

    func registeredProjects() async throws -> [AccountProject] {
        try await dataWorker().request("/project-registry", as: [AccountProject].self)
    }

    /// 添加项目前的检查：远程能不能访问、集成方式的默认值，文件夹另列出被忽略的环境变量文件。
    /// 文件夹问它所在的工作机，远程问哪台都行。
    func checkProject(_ source: ProjectSource, machineID: String?) async throws -> ProjectCheck {
        try await projectWorker(source, machineID: machineID).request("/project-registry/check", method: "POST", body: source, timeout: 120, as: ProjectCheck.self)
    }

    /// 添加项目：远程只登记不 clone，没有远程的文件夹由它所在的工作机导入；环境变量文件一起存成项目密钥。
    func addProject(_ source: ProjectSource, machineID: String?, integration: String?, envFiles: [ProjectEnvFile]) async throws -> AccountProject {
        struct Addition: Encodable {
            let remote: String?; let path: String?; let integration: String?; let envFiles: [ProjectEnvFile]?
        }
        let body = Addition(remote: source.remote, path: source.path, integration: integration, envFiles: envFiles.isEmpty ? nil : envFiles)
        let project = try await updateProject(projectWorker(source, machineID: machineID), "/project-registry", method: "POST", body: body, timeout: 1800)
        _ = await refreshDirectory()
        return project
    }

    /// 改了登记表里的一个项目（添加、设置、远程）：本机立即换上工作机返回的这一项。
    private func updateProject(_ client: KitedClient, _ path: String, method: String, body: some Encodable, timeout: TimeInterval = 30) async throws -> AccountProject {
        let project = try await client.request(path, method: method, body: body, timeout: timeout, as: AccountProject.self)
        account.applyProject(project)
        return project
    }

    private func projectWorker(_ source: ProjectSource, machineID: String?) throws -> KitedClient {
        guard source.path != nil else { return try dataWorker() }
        guard let machineID, let connection = connections[machineID], connection.connected else { throw KitedError(message: "文件夹所在的工作机未连接") }
        return connection.client
    }

    /// 改项目设置，只改给了的那几项：集成方式是直接合入（merge）或提交 PR（pullRequest），另有自动换机与换机的环境需求。
    func setProjectSettings(_ projectID: String, integration: String? = nil, autoHandover: Bool? = nil,
                            handoverNeeds: [String]? = nil) async throws -> AccountProject {
        struct Settings: Encodable { let integration: String?; let autoHandover: Bool?; let handoverNeeds: [String]? }
        return try await updateProject(dataWorker(), "/project-registry/\(projectID)/settings", method: "PUT",
                                       body: Settings(integration: integration, autoHandover: autoHandover, handoverNeeds: handoverNeeds))
    }

    /// 给没有远程的项目设远程：一台有检出的工作机把全部分支和标签推上去，再写进登记表，各检出随后改用它。大仓库要推很久。
    func setProjectRemote(_ projectID: String, remote: String) async throws -> AccountProject {
        try await updateProject(checkoutWorker(projectID), "/project-registry/\(projectID)/remote", method: "PUT", body: ["remote": remote], timeout: 600)
    }

    /// 删除项目：登记、约束与项目专用的密钥一起删，各工作机随后移除本机的工作区和 Kite 的检出；用户自己的文件夹不动。
    /// 接请求的工作机先停下本机这个项目的线程，可能要一会儿。
    func deleteProject(_ projectID: String) async throws {
        let client = try dataWorker()
        let _: JSON = try await client.request("/project-registry/\(projectID)", method: "DELETE", timeout: 120, as: JSON.self)
        if selectedProjectID == projectID { selectedProjectID = nil }
        try await refresh(client)
        _ = await refreshDirectory()
    }

    func setProjectAppearance(_ values: [String: String], projectID: String) async throws {
        try account.applyAppearance(try await dataWorker().request("/project-registry/\(projectID)/appearance", method: "PUT", body: values, as: AccountProject.self))
    }

    func projectConstraints(_ projectID: String) async throws -> ProjectConstraints {
        try await dataWorker().request("/project-registry/\(projectID)/constraints", as: ProjectConstraints.self)
    }

    func saveProjectConstraints(_ projectID: String, tools: ProjectConstraints.Tools, execution: ProjectExecution,
                                expectedRevision: String) async throws -> ProjectConstraints {
        struct Save: Encodable { let tools: ProjectConstraints.Tools; let execution: ProjectExecution; let expectedRevision: String }
        return try await dataWorker().request("/project-registry/\(projectID)/constraints", method: "PUT",
                                                 body: Save(tools: tools, execution: execution, expectedRevision: expectedRevision), as: ProjectConstraints.self)
    }

    func credentials(type: String, projectID: String = "") async throws -> [AccountCredential] {
        try await dataWorker().request("/credentials?type=\(type)" + (projectID.isEmpty ? "" : "&projectId=\(projectID)"), as: [AccountCredential].self)
    }

    func createCredential(type: String, name: String, projectID: String = "", meta: [String: String] = [:], secret: [String: String]) async throws {
        struct Body: Encodable { let type: String; let name: String; let projectId: String?; let meta: [String: String]; let secret: [String: String] }
        let _: AccountCredential = try await dataWorker().request("/credentials", method: "POST",
            body: Body(type: type, name: name, projectId: projectID.isEmpty ? nil : projectID, meta: meta, secret: secret), as: AccountCredential.self)
    }

    /// 类型与范围不变；不提供的项保留原样。
    func updateCredential(_ id: String, name: String? = nil, meta: [String: String]? = nil, secret: [String: String]? = nil) async throws {
        struct Body: Encodable { let name: String?; let meta: [String: String]?; let secret: [String: String]? }
        let _: AccountCredential = try await dataWorker().request("/credentials/\(id)", method: "PUT",
            body: Body(name: name, meta: meta, secret: secret), as: AccountCredential.self)
    }

    func deleteCredential(_ id: String) async throws {
        let _: JSON = try await dataWorker().request("/credentials/\(id)", method: "DELETE", as: JSON.self)
    }

    func startGitHub() async throws -> GitHubDevice {
        let connection = try dataConnection()
        var device = try await connection.client.request("/git/github/device", method: "POST", as: GitHubDevice.self)
        device.machineID = connection.machine.id
        return device
    }

    /// 问发起授权的那台工作机；返回 pending、slow_down、expired、denied 或 authorized。
    func pollGitHub(_ device: GitHubDevice) async throws -> String {
        struct Poll: Decodable { let status: String }
        guard let connection = connections[device.machineID], connection.connected else {
            throw KitedError(message: "发起授权的工作机断开了，请重新绑定")
        }
        return try await connection.client.request("/git/github/device/\(device.flow)", method: "POST", as: Poll.self).status
    }

    /// 没有绑定 GitHub 时为空。
    func gitHubRepositories() async throws -> [GitHubRepository] {
        try await dataWorker().request("/git/github/repos", as: [GitHubRepository].self)
    }
}
