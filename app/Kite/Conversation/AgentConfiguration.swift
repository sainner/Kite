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

    mutating func selectModel(_ id: String, in models: [AgentCapabilities.Model]) {
        selectModel(id, supportedReasoning: models.first { $0.id == id }?.reasoning ?? [])
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
    /// 草稿里改过的审批模式；没改时用角色的默认。
    var approval: ApprovalMode?
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
    /// monitor 实例的配置：唤醒的对象代理；Line 的收件箱带 system。
    struct Monitor: Decodable, Sendable {
        let target: String
        var system: String?
    }
    var agent: AgentConfiguration?
    var role: Role?
    var monitor: Monitor?
    /// 审批模式；没设过时是仅白名单。
    var approval: ApprovalMode?
}

nonisolated struct AgentConfigurationSnapshot: Decodable, Sendable {
    nonisolated struct Instance: Decodable, Sendable { let config: InstanceAgentConfig }
    let instance: Instance
    let revision: String
    let configurationBoundary: String
}

/// 工具在界面上的名称与分组，工作机给出；目录顺序即界面顺序。
nonisolated struct AgentToolInfo: Decodable, Identifiable, Sendable {
    let name: String
    let title: String
    let group: String
    var id: String { name }
}

/// 一组工具，界面上折叠成一行。
nonisolated struct AgentToolGroup: Identifiable, Sendable {
    let title: String
    let tools: [AgentToolInfo]
    var id: String { title }
}

nonisolated extension [AgentToolInfo] {
    /// 按目录的分组和顺序排出 names。工作机给出的工具都在目录里。
    func groups(of names: [String]) -> [AgentToolGroup] {
        let catalog = filter { names.contains($0.name) }
        var titles: [String] = []
        for info in catalog where !titles.contains(info.group) { titles.append(info.group) }
        return titles.map { title in AgentToolGroup(title: title, tools: catalog.filter { $0.group == title }) }
    }
}

/// 模型按厂商分组，后端由所选模型推出；tools 是这个代理可开的工具（代理插件的全部工具），defaults 是角色给的默认，
/// required 是角色必需、不能关闭的，blocked 是正被项目约束禁用的。
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
    var defaults: [String]? = nil
    let required: [String]
    let blocked: [String]
    let toolCatalog: [AgentToolInfo]
    let configurationBoundary: String
    let toolCatalogBoundary: String

    func model(_ id: String) -> Model? { models.first { $0.id == id } }
    /// 角色给的默认工具；旧工作机没有 defaults 时可开的就是默认。
    var defaultTools: [String] { defaults ?? tools }
    /// 配置页里工具名旁的注明：项目禁用、角色必需，或角色没给、由这个代理自己开的。
    func toolNote(_ name: String) -> String? {
        blocked.contains(name) ? "项目禁用" : required.contains(name) ? "角色必需" : defaultTools.contains(name) ? nil : "角色未给"
    }
    var toolGroups: [AgentToolGroup] { toolCatalog.groups(of: tools) }
    func canEdit(_ state: RemoteState?) -> Bool {
        guard let state, state.status == "open", state.phase != "stopping" else { return false }
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
        var defaults: [String]? = nil
        let required: [String]
        let blocked: [String]
        let unavailable: String?
    }
    let vendors: [AgentCapabilities.Vendor]
    let models: [AgentCapabilities.Model]
    let toolCatalog: [AgentToolInfo]
    let roles: [Role]

    /// 草稿还没有实例，按所选角色给出与已有代理同形的能力，模型菜单与配置页共用。
    func capabilities(for role: String) -> AgentCapabilities? {
        guard let option = roles.first(where: { $0.id == role }) else { return nil }
        return AgentCapabilities(vendors: vendors, models: models, tools: option.tools, defaults: option.defaults, required: option.required, blocked: option.blocked, toolCatalog: toolCatalog,
                                 configurationBoundary: "request", toolCatalogBoundary: "session")
    }
}

struct AgentConfigurationUpdate: Encodable {
    let expectedRevision: String
    let agent: AgentConfiguration
}
