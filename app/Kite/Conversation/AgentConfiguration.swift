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

/// 新代理草稿里在角色之上改过的参数；nil 表示沿用角色。还没有实例，发出第一条消息时随创建请求一起提交。
struct DraftAgentChoice: Equatable {
    var model: AgentModelConfiguration?
    var tools: [String]?
    var maxRequestsPerTurn: Int?
}

/// 工具的黑白名单：白名单只准列出的，黑名单排除列出的。角色规则与项目约束共用，开关的含义都是「能用这个工具」。
nonisolated protocol ToolFilter {
    var mode: String { get set }
    var tools: [String] { get set }
}

nonisolated extension ToolFilter {
    func allows(_ name: String) -> Bool { (mode == "allow") == tools.contains(name) }
    func permitted(in universe: [String]) -> [String] { universe.filter(allows) }

    /// 换规则方向时保持当前能用的工具不变；方向只决定以后新增的工具默认是否可用。
    mutating func setMode(_ mode: String, in universe: [String]) {
        let enabled = permitted(in: universe)
        self.mode = mode
        tools = mode == "allow" ? enabled : universe.filter { !enabled.contains($0) }
    }

    mutating func setEnabled(_ name: String, _ enabled: Bool) {
        tools.removeAll { $0 == name }
        if enabled == (mode == "allow") { tools.append(name) }
    }
}

/// 角色的工具规则；required 是角色离不开、不能关闭的工具。
nonisolated struct ToolRule: Codable, Equatable, Sendable, ToolFilter {
    var mode: String
    var tools: [String]
    var required: [String]
}

nonisolated struct InstanceAgentConfig: Decodable, Sendable {
    /// 创建时的角色与它的工具规则。
    struct Role: Decodable, Sendable { let id: String }
    var agent: AgentConfiguration?
    var role: Role?
}

nonisolated struct AgentConfigurationSnapshot: Decodable, Sendable {
    nonisolated struct Instance: Decodable, Sendable { let config: InstanceAgentConfig }
    let instance: Instance
    let revision: String
    let configurationBoundary: String
}

/// 模型按厂商分组，后端由所选模型推出；tools 是这个代理可开的工具，required 是角色必需、不能关闭的，blocked 是其中正被项目约束禁用的。
nonisolated struct AgentCapabilities: Decodable, Sendable {
    struct Vendor: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
    }
    struct Model: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let name: String
        let reasoning: [String]
        let vendor: String
    }
    let vendors: [Vendor]
    let models: [Model]
    let tools: [String]
    let required: [String]
    let blocked: [String]
    let configurationBoundary: String
    let toolCatalogBoundary: String

    func model(_ id: String) -> Model? { models.first { $0.id == id } }
    /// 配置页里工具开关的标签：注明角色必需或项目禁用。
    func toolLabel(_ name: String) -> String {
        blocked.contains(name) ? "\(name)（项目禁用）" : required.contains(name) ? "\(name)（角色必需）" : name
    }
    func canEdit(_ state: RemoteState?) -> Bool {
        guard let state, state.status == "open", state.recovery == nil, state.phase != "stopping" else { return false }
        return configurationBoundary == "request" || !state.busy
    }
    var explanation: String { configurationBoundary == "request" ? "保存后在下一次模型请求时生效。" : "请在代理空闲时保存，下次执行生效。" }
}

/// 新代理草稿的选项：模型目录与各角色在这个工作区可开的工具；必需工具不可用的角色带原因。
nonisolated struct AgentOptions: Decodable, Sendable {
    struct Role: Decodable, Identifiable, Sendable {
        let id: String
        let revision: String
        let tools: [String]
        let required: [String]
        let blocked: [String]
        let unavailable: String?
    }
    let vendors: [AgentCapabilities.Vendor]
    let models: [AgentCapabilities.Model]
    let roles: [Role]

    /// 草稿还没有实例，按所选角色给出与已有代理同形的能力，模型菜单与配置页共用。
    func capabilities(for role: String) -> AgentCapabilities? {
        guard let option = roles.first(where: { $0.id == role }) else { return nil }
        return AgentCapabilities(vendors: vendors, models: models, tools: option.tools, required: option.required, blocked: option.blocked,
                                 configurationBoundary: "request", toolCatalogBoundary: "session")
    }
}

struct AgentConfigurationUpdate: Encodable {
    let expectedRevision: String
    let agent: AgentConfiguration
}
