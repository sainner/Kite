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
    let runtime: String
    var model: AgentModelConfiguration
    var tools: [String]
    var context: JSON
    var maxRequestsPerTurn: Int
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
        var resolvedModel: String?
        let reasoning: [String]
    }
    let models: [Model]
    let tools: [String]
    let configurationBoundary: String
    let toolCatalogBoundary: String

    func model(_ id: String) -> Model? { models.first { $0.id == id || $0.resolvedModel == id } }
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
