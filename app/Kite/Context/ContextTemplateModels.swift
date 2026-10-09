import Foundation

/// 与组装契约同形，编辑过程中保留变量和未选中的分支。
nonisolated struct ContextDefinition: Codable, Equatable, Identifiable, Sendable {
    var version = 2
    var id: String
    var title: String
    var scene = "thread.create"
    var blocks: [ContextBlock]
    var input: [ContextBlock]? = nil
}

nonisolated struct ContextBlock: Codable, Equatable, Identifiable, Sendable {
    var type: String
    var id = UUID().uuidString.lowercased()
    var title: String
    var parts: [ContextPart]?
    var variable: String?
    var cases: [ContextBranch]?
    var otherwise: ContextBranch?

    static func paragraph() -> Self { .init(type: "paragraph", title: "新段落", parts: [.text("")]) }
    static func condition(variable: String) -> Self {
        .init(type: "condition", title: "新条件", variable: variable,
              cases: [.init(title: "为空时", equals: "", blocks: [])],
              otherwise: .init(title: "其他情况", blocks: []))
    }
}

nonisolated struct ContextPart: Codable, Equatable, Identifiable, Sendable {
    // 编辑时保持文字和变量的身份，避免增删、重排让输入框绑定到相邻片段；不写入模板契约。
    var id = UUID()
    var type: String
    var text: String?
    var name: String?
    private enum CodingKeys: String, CodingKey { case type, text, name }
    static func text(_ value: String) -> Self { .init(type: "text", text: value) }
    static func variable(_ name: String) -> Self { .init(type: "variable", name: name) }
}

nonisolated struct ContextBranch: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var title: String
    var equals: String?
    var blocks: [ContextBlock]
}

nonisolated struct ContextScene: Decodable, Identifiable, Sendable {
    struct Variable: Decodable, Identifiable, Sendable {
        let name: String
        let title: String
        var id: String { name }
    }
    let id: String
    let title: String
    let variables: [Variable]
}

nonisolated struct ContextTemplate: Decodable, Identifiable, Sendable {
    var definition: ContextDefinition
    var revision: String
    var id: String { definition.id }
}

/// 角色点阵签名的设计：一行表达式、正负两种颜色（字母见 DotFigure.letters）和点的形状。
nonisolated struct EmblemDesign: Codable, Equatable, Sendable {
    var expression: String
    var positive: String
    var negative: String
    var form: String

    static let letters = ["B", "M", "L", "Y", "D"]
    static let letterTitles = ["B": "主题色", "M": "晨风蓝", "L": "露水蓝", "Y": "阳光黄", "D": "深阳光黄"]
    /// 没有签名或签名还在生成时用的图案。
    static let fallback = EmblemDesign(expression: "sin(x/5 + t*0.6) * cos(y/4 - t*0.4) * 0.55 + 0.4*max(0, 1 - d/6)*sin(d - t*3)",
                                       positive: "B", negative: "L", form: "circle")

    /// 主题色按所在环境解析；表达式无效时为 nil。
    func pattern(accent: DotColor) -> DotPattern? {
        guard let expression = try? DotExpression(expression) else { return nil }
        let letters = DotFigure.letters(accent: accent)
        return DotPattern(expression: expression, positive: positive.first.flatMap { letters[$0] } ?? accent,
                          negative: negative.first.flatMap { letters[$0] } ?? accent, form: DotForm(rawValue: form) ?? .circle)
    }
}

nonisolated struct TemplateEmblem: Decodable, Equatable, Sendable {
    var design: EmblemDesign
    /// generated 或 manual。
    var source: String

    private enum CodingKeys: String, CodingKey { case source }
    init(from decoder: Decoder) throws {
        design = try EmblemDesign(from: decoder)
        source = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .source)
    }
}

nonisolated struct EmblemStatus: Decodable, Sendable {
    var emblem: TemplateEmblem?
    var emblemState: String
    var emblemError: String?
}

struct EmblemSave: Encodable { let emblem: EmblemDesign }
struct EmblemGenerate: Encodable { let force: Bool }

nonisolated struct ContextTemplateCatalog: Decodable, Sendable {
    var templates: [ContextTemplate]
    let scenes: [ContextScene]
}

struct ContextTemplateSave: Encodable {
    let definition: ContextDefinition
    let expectedRevision: String
}

/// 新代理连同草稿里的角色与改过的参数一次创建；新工作区带首条消息时只带角色。
struct CreateThreadRequest: Encodable {
    let prompt: String
    var checkout: String? = nil
    var role: RoleSelection? = nil
    var model: AgentModelConfiguration? = nil
    var tools: [String]? = nil
    var maxRequestsPerTurn: Int? = nil
}

extension AppModel {
    func templates(in area: WorkArea) -> ContextTemplateCatalog? {
        connection(for: area)?.templates
    }

    func templateConnection(_ revision: UUID) -> WorkerConnection? {
        connections.values.first { $0.catalog.generation == revision }
    }

    func refreshContextTemplates(in area: WorkArea? = nil) async throws {
        guard let connection = connection(for: area), connection.connected else { throw KitedError(message: "所属工作机未连接") }
        try await refreshTemplates(of: connection)
    }

    /// fresh 时不复用进行中的请求：它可能早于这次变化发出，等它完成后再读一次。
    func refreshTemplates(of connection: WorkerConnection, fresh: Bool = false) async throws {
        let revision = connection.catalog.generation
        if let request = connection.templatesRequest, request.connection == revision {
            if fresh { try? await request.task.value } else { try await request.task.value; return }
            if let request = connection.templatesRequest, request.connection == revision { try await request.task.value; return }
        }
        let client = connection.client
        let task = Task {
            defer { if connection.templatesRequest?.connection == revision { connection.templatesRequest = nil } }
            let result = try await client.request("/context-templates", as: ContextTemplateCatalog.self)
            try Task.checkCancellation()
            guard revision == connection.catalog.generation, accepts(client) else { throw KitedError(message: "工作机连接已变化") }
            connection.templates = result
        }
        connection.templatesRequest = (revision, task)
        try await task.value
    }

    /// 模板只能修改，各场景的模板由工作机提供。
    func saveContextTemplate(_ definition: ContextDefinition, expectedRevision: String, connection: UUID) async throws -> ContextTemplate {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        let client = target.client
        let component = definition.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        let result = try await client.request("/context-templates/\(component)", method: "PUT",
            body: ContextTemplateSave(definition: definition, expectedRevision: expectedRevision), as: ContextTemplate.self)
        guard target.catalog.generation == connection, accepts(client) else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        target.templates?.templates.removeAll { $0.id == result.id }
        target.templates?.templates.append(result)
        return result
    }
}
