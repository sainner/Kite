import Foundation

/// 与组装契约同形，编辑过程中保留变量和未选中的分支。
nonisolated struct ContextDefinition: Codable, Equatable, Identifiable, Sendable {
    var version = 2
    var id: String
    var title: String
    var scene = "thread.create"
    var blocks: [ContextBlock]
    var input: [ContextBlock]? = nil

    static func empty() -> Self { .init(id: UUID().uuidString.lowercased(), title: "新模板", blocks: []) }
    func copy() -> Self {
        var result = self
        result.id = UUID().uuidString.lowercased()
        result.title += " 副本"
        return result
    }
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
    /// 创建会话模板的点阵签名，其他场景没有。
    var emblem: TemplateEmblem?
    /// ready、stale、missing、generating 或 failed。
    var emblemState: String?
    var emblemError: String?
    var id: String { definition.id }
    var selection: ContextTemplateSelection { .init(id: id, revision: revision) }
}

/// 点阵签名的设计：一行表达式、正负两种颜色（字母见 DotFigure.letters）和点的形状。
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

nonisolated struct ContextTemplateSelection: Encodable, Sendable {
    let id: String
    let revision: String
}

nonisolated struct ContextTemplateCatalog: Decodable, Sendable {
    var templates: [ContextTemplate]
    let scenes: [ContextScene]
}

struct ContextTemplateSave: Encodable {
    let definition: ContextDefinition
    let expectedRevision: String?
}

struct ApplyContextTemplate: Encodable {
    let expectedRevision: String
    let templateId: String
    let templateRevision: String
}

struct CreateThreadRequest: Encodable {
    let prompt: String
    var checkout: String? = nil
    var contextTemplate: ContextTemplateSelection? = nil
    var definitionId: String? = nil
    var runtime: String? = nil
    var model: AgentModelConfiguration? = nil
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

    func saveContextTemplate(_ definition: ContextDefinition, expectedRevision: String?, connection: UUID) async throws -> ContextTemplate {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        let client = target.client
        let component = definition.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        let path = expectedRevision == nil ? "/context-templates" : "/context-templates/\(component)"
        let result = try await client.request(path, method: expectedRevision == nil ? "POST" : "PUT",
            body: ContextTemplateSave(definition: definition, expectedRevision: expectedRevision), as: ContextTemplate.self)
        guard target.catalog.generation == connection, accepts(client) else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        target.templates?.templates.removeAll { $0.id == result.id }
        target.templates?.templates.append(result)
        return result
    }

    func saveTemplateEmblem(_ design: EmblemDesign, for template: ContextTemplate, connection: UUID) async throws {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        let client = target.client
        let result = try await client.request("/context-templates/\(Self.pathComponent(template.id))/emblem", method: "PUT",
            body: EmblemSave(emblem: design), as: ContextTemplate.self)
        guard target.catalog.generation == connection, accepts(client) else { throw KitedError(message: "工作机连接已变化，请返回模板列表") }
        if let index = target.templates?.templates.firstIndex(where: { $0.id == result.id }) { target.templates?.templates[index] = result }
    }

    /// 请工作机生成签名；force 时连手改的一起重新生成。结果随模板变化事件送达。
    func generateTemplateEmblem(_ template: ContextTemplate, force: Bool, connection: UUID) async throws {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化") }
        let client = target.client
        let status = try await client.request("/context-templates/\(Self.pathComponent(template.id))/emblem/generate", method: "POST",
            body: EmblemGenerate(force: force), as: EmblemStatus.self)
        guard target.catalog.generation == connection, accepts(client) else { return }
        if let index = target.templates?.templates.firstIndex(where: { $0.id == template.id }) {
            target.templates?.templates[index].emblem = status.emblem
            target.templates?.templates[index].emblemState = status.emblemState
            target.templates?.templates[index].emblemError = status.emblemError
        }
    }

    private static func pathComponent(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }

    func applyContextTemplate(_ template: ContextTemplate, to thread: WorkThread, in area: WorkArea, connection: UUID) async throws {
        guard revision(for: area) == connection else { throw KitedError(message: "工作机已切换") }
        if let instance = area.instances.first(where: { $0.id == thread.id }) {
            let client = try activeClient(in: area)
            @MainActor func requireCurrent() throws {
                guard revision(for: area) == connection, client == (try activeClient(in: area)),
                      area.remote?.machine.id == client.machineID,
                      area.instances.contains(where: { $0.id == instance.id && $0.status == .open }) else {
                    throw KitedError(message: "工作机或会话已变化，请重新选择模板")
                }
            }
            try requireCurrent()
            let config = try await client.request("/instances/\(instance.id)/agent-config", as: AgentConfigurationSnapshot.self)
            try requireCurrent()
            let updated = try await client.request("/instances/\(instance.id)/context-template", method: "PUT",
                body: ApplyContextTemplate(expectedRevision: config.revision, templateId: template.id, templateRevision: template.revision),
                as: AgentConfigurationSnapshot.self)
            try requireCurrent()
            if let index = area.instances.firstIndex(where: { $0.id == instance.id }) {
                area.instances[index].config = updated.instance.config
            }
        }
        thread.contextTemplate = template
    }
}
