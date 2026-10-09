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
    /// 停靠栏头像的算式：同一意象画在 9×9 格的圆形小画布上，见 AgentAvatar。
    var avatar: String
    var positive: String
    var negative: String
    var form: String

    static let letters = ["B", "M", "L", "Y", "D"]
    static let letterTitles = ["B": "主题色", "M": "晨风蓝", "L": "露水蓝", "Y": "阳光黄", "D": "深阳光黄"]
    /// 没有签名或签名还在生成时用的图案。
    static let fallback = EmblemDesign(expression: "sin(x/5 + t*0.6) * cos(y/4 - t*0.4) * 0.55 + 0.4*max(0, 1 - d/6)*sin(d - t*3)",
                                       avatar: "sin(x*0.9+t*0.6)*cos(y*0.8-t*0.4)*0.75+0.35*(r<1.5)*sin(t*2)",
                                       positive: "B", negative: "L", form: "circle")

    /// 主题色按所在环境解析；表达式无效时为 nil。
    func pattern(accent: DotColor) -> DotPattern? { pattern(expression, accent: accent) }

    /// 头像的图案，颜色与点的形状同签名；头像算式无效时为 nil。
    func avatarPattern(accent: DotColor) -> DotPattern? { pattern(avatar, accent: accent) }

    /// 正值的颜色，不用解析算式。
    func positiveColor(accent: DotColor) -> DotColor { color(positive, accent: accent) }

    private func pattern(_ source: String, accent: DotColor) -> DotPattern? {
        guard let expression = DotExpression.cached(source) else { return nil }
        return DotPattern(expression: expression, positive: color(positive, accent: accent),
                          negative: color(negative, accent: accent), form: DotForm(rawValue: form) ?? .circle)
    }

    private func color(_ letter: String, accent: DotColor) -> DotColor {
        letter.first.flatMap { DotFigure.letters(accent: accent)[$0] } ?? accent
    }
}

nonisolated extension EmblemDesign {
    /// 加头像之前手改的签名没有头像算式，用默认头像；生成的会由 kited 判为过期后重新生成。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expression = try container.decode(String.self, forKey: .expression)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar) ?? Self.fallback.avatar
        positive = try container.decode(String.self, forKey: .positive)
        negative = try container.decode(String.self, forKey: .negative)
        form = try container.decode(String.self, forKey: .form)
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
    var windowId: String? = nil
    var messageId: String? = nil
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

    func refreshTemplates(of connection: WorkerConnection, fresh: Bool = false) async throws {
        try await refreshCatalog("/context-templates", of: connection, fresh: fresh, request: \.templatesRequest, into: \.templates)
    }

    /// 读取工作机上的目录，同一连接上进行中的请求复用。fresh 时不复用：进行中的请求可能早于这次变化发出，等它完成后再读一次。
    func refreshCatalog<Value: Decodable & Sendable>(
        _ path: String, of connection: WorkerConnection, fresh: Bool,
        request: ReferenceWritableKeyPath<WorkerConnection, (connection: UUID, task: Task<Void, Error>)?>,
        into value: ReferenceWritableKeyPath<WorkerConnection, Value?>
    ) async throws {
        let revision = connection.catalog.generation
        if let pending = connection[keyPath: request], pending.connection == revision {
            if fresh { try? await pending.task.value } else { try await pending.task.value; return }
            if let pending = connection[keyPath: request], pending.connection == revision { try await pending.task.value; return }
        }
        let client = connection.client
        let task = Task {
            defer { if connection[keyPath: request]?.connection == revision { connection[keyPath: request] = nil } }
            let result = try await client.request(path, as: Value.self)
            try Task.checkCancellation()
            guard revision == connection.catalog.generation, accepts(client) else { throw KitedError(message: "工作机连接已变化") }
            connection[keyPath: value] = result
        }
        connection[keyPath: request] = (revision, task)
        try await task.value
    }

    /// 模板只能修改，各场景的模板由工作机提供。
    func saveContextTemplate(_ definition: ContextDefinition, expectedRevision: String, connection: UUID) async throws {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        let client = target.client
        let result = try await client.request("/context-templates/\(definition.id.pathComponent)", method: "PUT",
            body: ContextTemplateSave(definition: definition, expectedRevision: expectedRevision), as: ContextTemplate.self)
        guard target.catalog.generation == connection, accepts(client) else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        target.templates?.templates.removeAll { $0.id == result.id }
        target.templates?.templates.append(result)
    }
}
