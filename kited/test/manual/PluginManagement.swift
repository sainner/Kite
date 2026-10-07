import Foundation

private enum PluginManagementFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        if case .failed(let message) = self { return message }
        return "插件授权合同失败"
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw PluginManagementFailure.failed(message) }
}

private struct ExecutionFixture: Decodable {
    let url: String
    let machineID: String
    let instanceID: String
    let readPath: String
    let writePath: String
}

/// 共享模型清单的 Swift 解码形状，用来与真实后端默认配置交叉校验。
private struct AgentModelCatalog: Decodable {
    struct Entry: Decodable {
        let id: String
        let tier: String
    }
    let defaultTier: String
    let models: [Entry]
    var defaultModel: Entry { models.first { $0.tier == defaultTier }! }
}

// 手动跨层合同：真实后端 JSON 经 Swift Codable 修改后，再由脚本交回严格的 HTTP PUT。
@main
private struct PluginManagementContract {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 else {
            throw PluginManagementFailure.failed("用法：PluginManagement <add|remove|execution|model> <快照路径> <目标实例、执行夹具或共享模型清单路径> <PUT路径>")
        }
        if arguments[1] == "execution" {
            try await verifyExecution(arguments)
            return
        }
        if arguments[1] == "model" {
            // 共享 JSON 在 Swift Decodable 与 Bun 导入之间往返，并与真实后端默认配置交叉校验。
            let catalog = try JSONDecoder().decode(AgentModelCatalog.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
            let snapshot = try JSONDecoder().decode(AgentConfigurationSnapshot.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            guard var agent = snapshot.instance.config.agent else {
                throw PluginManagementFailure.failed("真实配置快照没有 agent")
            }
            try require(agent.model.model == catalog.defaultModel.id,
                        "Swift 共享清单默认模型与真实后端初始配置不一致")
            guard let selectedModel = catalog.models.first(where: { $0.tier == "astra" }) else {
                throw PluginManagementFailure.failed("Swift 共享清单没有 astra 模型")
            }
            agent.model.model = selectedModel.id
            let update = AgentConfigurationUpdate(expectedRevision: snapshot.revision, agent: agent)
            try JSONEncoder().encode(update).write(to: URL(fileURLWithPath: arguments[4]))
            print("Swift 共享模型清单与后端默认配置一致，选择模型保留完整 agent 与原始 revision")
            return
        }
        let snapshot = try JSONDecoder().decode(InstanceGrants.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let target = arguments[3]
        var draft = PluginGrantDraft(snapshot: snapshot)
        let preserved = snapshot.grants.filter { !($0.operation == "plugin.call" && $0.instanceId == target) }
        try require(preserved.contains { $0.operation.hasPrefix("agent.") }
                    && preserved.contains { $0.operation.hasPrefix("files.") }
                    && preserved.contains { $0.operation == "plugin.call" },
                    "真实后端快照缺少 agent、files 或另一目标的授权")
        try require(draft.includesTool(instanceID: target, name: "state"), "Swift 没有读到目标的原有工具授权")

        switch arguments[1] {
        case "add":
            try require(!draft.includesTool(instanceID: target, name: "read-file"), "新增前已有 read-file 授权")
            draft.setTool(instanceID: target, name: "read-file", enabled: true)
            try require(draft.includesTool(instanceID: target, name: "state")
                        && draft.includesTool(instanceID: target, name: "read-file"),
                        "新增工具丢掉原有工具或未加入新工具")
        case "remove":
            try require(draft.includesTool(instanceID: target, name: "read-file"), "撤权前没有新增工具")
            draft.setTool(instanceID: target, name: "read-file", enabled: false)
            try require(draft.includesTool(instanceID: target, name: "state"), "撤去一个工具连带撤去了其余工具")
            draft.setTool(instanceID: target, name: "state", enabled: false)
            try require(!draft.grants.contains { $0.operation == "plugin.call" && $0.instanceId == target },
                        "撤去最后工具留下了空目标授权")
        default:
            throw PluginManagementFailure.failed("未知编辑动作：\(arguments[1])")
        }

        try require(draft.revision == snapshot.revision && draft.request.expectedRevision == snapshot.revision,
                    "编辑草稿改变了用于冲突校验的原始 revision")
        try require(draft.grants.filter { !($0.operation == "plugin.call" && $0.instanceId == target) } == preserved,
                    "编辑工具授权丢掉或改写了 agent、files 或另一目标的授权")
        try require(draft.request.grants == draft.grants, "PUT 请求没有包含当前草稿的全部授权")
        try JSONEncoder().encode(draft.request).write(to: URL(fileURLWithPath: arguments[4]))
        print("Swift 插件授权 \(arguments[1]) 保留其它授权及原始 revision")
    }

    // Codable、真实 HTTP 规范化和 revision 冲突一起运行；同一份 Swift 草稿保留到失败响应之后。
    private static func verifyExecution(_ arguments: [String]) async throws {
        let decoder = JSONDecoder()
        let fixture = try decoder.decode(ExecutionFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let snapshot = try decoder.decode(InstanceExecutionGrants.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let endpoint = URL(string: fixture.url + "/instances/" + fixture.instanceID + "/execution-grants")!
        func exchange(_ method: String, body: ExecutionGrantUpdate? = nil, status: Int = 200) async throws -> Data {
            var request = URLRequest(url: endpoint)
            request.httpMethod = method
            request.setValue(fixture.machineID, forHTTPHeaderField: "X-Kite-Machine")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            try require((response as? HTTPURLResponse)?.statusCode == status,
                        "Swift 执行授权 \(method) 状态与预期 \(status) 不符：\(String(decoding: data, as: UTF8.self))")
            return data
        }

        var draft = ExecutionGrantDraft(snapshot: snapshot)
        draft.workspace = .read
        draft.readPaths = "\n  \(fixture.readPath)/ \n\n\(fixture.readPath)\n"
        draft.writePaths = "  \(fixture.writePath)\n\n\(fixture.writePath)/  \n"
        draft.networkDomains = "\n API.Example.COM \n\nexample.org:443\napi.example.com\n"
        let original = draft.request
        let accepted = try decoder.decode(InstanceExecutionGrants.self,
            from: await exchange("PUT", body: original))
        try require(accepted.grants.workspace == .read
                    && accepted.grants.read == [fixture.readPath]
                    && accepted.grants.write == [fixture.writePath]
                    && accepted.grants.network == ["api.example.com", "example.org:443"],
                    "Swift 草稿经严格 PUT 后没有保存规范化目录和域名")

        var concurrent = ExecutionGrantDraft(snapshot: accepted)
        concurrent.networkDomains = "new.example.net"
        let changed = try decoder.decode(InstanceExecutionGrants.self,
            from: await exchange("PUT", body: concurrent.request))
        try require(changed.revision != accepted.revision && changed.grants.network == ["new.example.net"],
                    "并发保存没有产生新 revision 和域名")
        _ = try await exchange("PUT", body: draft.request, status: 409)
        try require(draft.request.expectedRevision == original.expectedRevision
                    && draft.request.grants == original.grants
                    && draft.readPaths == "\n  \(fixture.readPath)/ \n\n\(fixture.readPath)\n"
                    && draft.writePaths == "  \(fixture.writePath)\n\n\(fixture.writePath)/  \n"
                    && draft.networkDomains == "\n API.Example.COM \n\nexample.org:443\napi.example.com\n",
                    "冲突后 Swift 草稿内容或原始 revision 被覆盖")
        let afterConflict = try decoder.decode(InstanceExecutionGrants.self, from: await exchange("GET"))
        try require(afterConflict.revision == changed.revision && afterConflict.grants == changed.grants,
                    "旧草稿冲突覆盖了已保存执行授权")
        try JSONEncoder().encode(draft.request).write(to: URL(fileURLWithPath: arguments[4]))
        print("Swift 执行授权保存规范化目录与域名，冲突保留草稿和服务端新版本")
    }
}
