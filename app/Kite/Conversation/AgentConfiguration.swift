import Foundation

nonisolated struct AgentModelConfiguration: Codable, Equatable, Sendable {
    var model: String
    var reasoning: String

    mutating func selectModel(_ id: String, supportedReasoning levels: [String]) {
        model = id
        if !levels.contains(reasoning) {
            reasoning = levels.contains("medium") ? "medium" : levels.first ?? "default"
        }
    }
}

/// 编辑模型时保留其余配置；上下文继续按原有结构往返，不转成纯文本。
nonisolated struct AgentConfiguration: Codable, Equatable, Sendable {
    var runtime: String
    var model: AgentModelConfiguration
    var tools: [String]
    var context: JSON
    var maxRequestsPerTurn: Int
}

/// 新会话草稿里选好的定义、后端与模型；还没有实例，发出第一条消息时随创建请求一起提交。
struct DraftAgentChoice: Equatable {
    var definitionId: String
    var runtime: String
    var model: AgentModelConfiguration?
    private let defaultRuntime: String
    private let defaultModel: AgentModelConfiguration?

    init?(_ definition: RemotePluginDefinition) {
        guard let agent = definition.agent else { return nil }
        definitionId = definition.id
        runtime = agent.runtime.rawValue
        model = agent.model
        defaultRuntime = runtime
        defaultModel = model
    }

    /// 没改过就不提交模型，由工作机按定义与环境变量覆盖决定。
    var changedModel: AgentModelConfiguration? { runtime != defaultRuntime || model != defaultModel ? model : nil }
}

nonisolated struct InstanceAgentConfig: Decodable, Sendable {
    var agent: AgentConfiguration?
}

nonisolated struct AgentConfigurationSnapshot: Decodable, Sendable {
    nonisolated struct Instance: Decodable, Sendable { let config: InstanceAgentConfig }
    let instance: Instance
    let revision: String
    let configurationBoundary: String
}

nonisolated struct AgentCapabilities: Decodable, Sendable {
    struct Model: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let name: String
        let reasoning: [String]
    }
    let models: [Model]
    let tools: [String]
    let configurationBoundary: String
    let toolCatalogBoundary: String

    func model(_ id: String) -> Model? { models.first { $0.id == id } }
    func canEdit(_ state: RemoteState?) -> Bool {
        guard let state, state.status == "open", state.recovery == nil, state.phase != "stopping" else { return false }
        return configurationBoundary == "request" || !state.busy
    }
    var explanation: String { configurationBoundary == "request" ? "保存后在下一次模型请求时生效。" : "请在会话空闲时保存，下次执行生效。" }
}

struct AgentConfigurationUpdate: Encodable {
    let expectedRevision: String
    let agent: AgentConfiguration
}
