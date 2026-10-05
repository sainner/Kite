import Foundation

/// 与工作机共用打包进 App 的清单，不在界面里重复维护型号。
nonisolated struct AgentModelCatalog: Decodable, Sendable {
    struct Entry: Decodable, Identifiable, Sendable {
        let id: String
        let tier: String
    }
    let defaultTier: String
    let models: [Entry]
    var defaultModel: Entry { models.first { $0.tier == defaultTier }! }

    static let bundled: AgentModelCatalog = {
        guard let url = Bundle.main.url(forResource: "agent-models", withExtension: "json") else {
            preconditionFailure("App 缺少内置模型清单")
        }
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { preconditionFailure("内置模型清单无效：\(error)") }
    }()
}

nonisolated struct AgentModelConfiguration: Codable, Equatable, Sendable {
    var model: String
    var reasoning: String
}

/// 编辑模型时保留其余配置；上下文继续按原有结构往返，不转成纯文本。
nonisolated struct AgentConfiguration: Codable, Equatable, Sendable {
    let runtime: String
    var model: AgentModelConfiguration
    let tools: [String]
    var context: JSON
    let maxRequestsPerTurn: Int
}

nonisolated struct InstanceAgentConfig: Decodable, Sendable {
    var agent: AgentConfiguration?
}

nonisolated struct AgentConfigurationSnapshot: Decodable, Sendable {
    nonisolated struct Instance: Decodable, Sendable { let config: InstanceAgentConfig }
    let instance: Instance
    let revision: String
}

struct AgentConfigurationUpdate: Encodable {
    let expectedRevision: String
    let agent: AgentConfiguration
}
