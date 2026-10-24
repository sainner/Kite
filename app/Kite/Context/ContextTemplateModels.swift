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

    static func paragraph() -> Self { .init(type: "paragraph", title: "新段落", parts: []) }
    static func condition(variable: String) -> Self {
        .init(type: "condition", title: "新条件", variable: variable,
              cases: [.init(title: "为空时", equals: "", blocks: [])],
              otherwise: .init(title: "其他情况", blocks: []))
    }

    /// 条件的全部分支，其他情况排在最后。
    var branches: [ContextBranch] { (cases ?? []) + [otherwise].compactMap { $0 } }

    /// 按 id 换掉条件里的一个分支。
    mutating func replaceBranch(_ branch: ContextBranch) {
        if let index = cases?.firstIndex(where: { $0.id == branch.id }) { cases?[index] = branch }
        else if otherwise?.id == branch.id { otherwise = branch }
    }
}

nonisolated struct ContextPart: Codable, Equatable, Sendable {
    var type: String
    var text: String?
    var name: String?
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
        /// 变量里是什么、什么时候为空、什么时候变化。
        let description: String
        /// 分组显示的名称：场景自己的材料，或公共变量的层（环境、项目、工作区、代理）。
        let group: String
        /// 公共变量所在的层；场景材料没有，只在生成时才有，不能按代理取值。
        let layer: String?
        var id: String { name }

        /// 表示变量的图标：工具栏的插入变量和正文开头的可用变量用同一个，用户才认得出。
        static let icon = "curlybraces"
    }
    /// 辅助生成可选的模型，连同模板窗口副行里用什么凭据调用的说明；counts 是能不能按这些模型计数，不能时按工作机的默认模型估。
    struct Models: Decodable, Sendable {
        let note: String
        let vendors: [AgentCapabilities.Vendor]
        let models: [AgentCapabilities.Model]
        let counts: Bool
    }
    /// 在资源库代理上下文里的分类，见 AgentContextCategory。
    enum Kind: String, Decodable, Sendable { case notification, compaction, generation }
    let id: String
    let kind: Kind
    let title: String
    let variables: [Variable]
    /// 只有辅助生成的场景有。
    let models: Models?
}

/// 变量按 group 分组，组和组内的顺序照工作机给出的。
nonisolated struct ContextVariableGroup: Identifiable, Sendable {
    let title: String
    let variables: [ContextScene.Variable]
    var id: String { title }
}

extension Array where Element == ContextScene.Variable {
    var grouped: [ContextVariableGroup] {
        reduce(into: []) { groups, variable in
            if groups.last?.title == variable.group {
                groups[groups.count - 1] = ContextVariableGroup(title: variable.group, variables: groups[groups.count - 1].variables + [variable])
            } else {
                groups.append(ContextVariableGroup(title: variable.group, variables: [variable]))
            }
        }
    }
}

nonisolated struct ContextTemplate: Decodable, Identifiable, Sendable {
    var definition: ContextDefinition
    /// 辅助生成的模型与思考强度，其他模板没有。
    var model: AgentModelConfiguration?
    var revision: String
    /// 默认内容的版本，模板都是内置的。
    var defaultRevision: String
    var id: String { definition.id }
    /// 改过才能恢复默认。
    var canReset: Bool { defaultRevision != revision }
}

/// 角色点阵签名的设计：一行表达式、正负两种颜色（字母见 DotFigure.letters）和点的形状。
nonisolated struct EmblemDesign: Codable, Hashable, Sendable {
    var expression: String
    /// 停靠栏头像的算式：同一意象画在 9×9 格的圆形小画布上，见 AgentAvatar。
    var avatar: String
    var positive: String
    var negative: String
    var form: String

    static let letters = ["B", "M", "L", "Y", "D"]
    static let letterTitles = ["B": "主题色", "M": "晨风蓝", "L": "露水蓝", "Y": "阳光黄", "D": "深阳光黄"]
    /// 没有签名或签名还在生成时用的图案。
    static let fallback = EmblemDesign(expression: "sin(x/5 + t*0.6) * cos(y/4 - t*0.4) * (0.55 + 0.45*v) + 0.4*max(0, 1 - d/6)*sin(d - t*3)",
                                       avatar: "sin(x*0.9+t*0.6)*cos(y*0.8-t*0.4)*0.75+0.35*(r<1.5)*sin(t*2)",
                                       positive: "B", negative: "L", form: "circle")

    /// 主题色按所在环境解析；表达式无效时为 nil。
    func pattern(accent: DotColor) -> DotPattern? { pattern(expression, accent: accent) }

    /// 头像的图案，颜色与点的形状同签名；头像算式无效时为 nil。
    func avatarPattern(accent: DotColor) -> DotPattern? { pattern(avatar, accent: accent) }

    /// 两条算式都能解析。
    var isValid: Bool { DotExpression.cached(expression) != nil && DotExpression.cached(avatar) != nil }

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
    let model: AgentModelConfiguration?
    let expectedRevision: String
}

/// 内置角色或模板恢复默认，带上看到的版本。
struct LibraryReset: Encodable {
    let expectedRevision: String
}

/// 客户端按类读取的资源库目录，与工作机 library.changed 事件的 kind 一一对应：角色列表带着点阵签名，签名变了也是 role；
/// plugin 是插件定义，连同 Bun 插件的定义级授权：定义列表重读，打开着的插件窗口重读授权。
enum LibraryList: String, CaseIterable {
    case role, template, skill, plugin
}

/// 新代理连同草稿里的角色与改过的参数一次创建。
struct CreateThreadRequest: Encodable {
    let prompt: String
    var role: RoleSelection? = nil
    var model: AgentModelConfiguration? = nil
    var tools: [String]? = nil
    /// 草稿里选的审批模式；没选时用角色的默认。
    var approval: ApprovalMode? = nil
    /// 草稿里选的 MCP 服务；没选时用角色的默认。
    var mcp: [String]? = nil
    var windowId: String? = nil
    var messageId: String? = nil
    /// 第一条消息带的附件（已传到这个工作区）。
    var attachments: [String]? = nil
}

/// 新建空工作区：工作机没有项目的检出时先 clone；id 由本机定，见 AppModel.createWorkspace。
struct CreateWorkspaceRequest: Encodable {
    let project: String
    let id: String
}

extension AppModel {
    func templates(in area: WorkArea) -> ContextTemplateCatalog? {
        connection(for: area)?.templates
    }

    func templateConnection(_ revision: UUID) -> WorkerConnection? {
        connections.values.first { $0.catalog.generation == revision }
    }

    /// 资源库的写请求：发出前、回来后都核对还是打开时那一次连接，变了就报 changed。
    func libraryRequest<T: Decodable>(_ path: String, method: String, body: (any Encodable)? = nil, connection: UUID,
                                      changed: String, as type: T.Type) async throws -> (WorkerConnection, T) {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: changed) }
        let client = target.client
        let result = try await client.request(path, method: method, body: body, as: type)
        guard target.catalog.generation == connection, accepts(client) else { throw KitedError(message: changed) }
        return (target, result)
    }

    func refreshContextTemplates(in area: WorkArea? = nil) async throws {
        guard let connection = connection(for: area), connection.connected else { throw KitedError(message: "所属工作机未连接") }
        try await refreshTemplates(of: connection)
    }

    /// 目录没读过才读；读过的由 library.changed 事件和重连后的重读保持最新（见 libraryChanged）。
    func ensureContextTemplates(in area: WorkArea? = nil) async throws {
        if connection(for: area)?.templates == nil { try await refreshContextTemplates(in: area) }
    }

    func refreshTemplates(of connection: WorkerConnection, fresh: Bool = false) async throws {
        try await refreshCatalog("/context-templates", of: connection, fresh: fresh, into: \.templates)
    }

    /// 读取工作机上的目录，同一连接上同一路径进行中的请求复用。fresh 时不复用：进行中的请求可能早于这次变化发出，等它完成后再读一次。
    func refreshCatalog<Value: Decodable & Sendable>(
        _ path: String, of connection: WorkerConnection, fresh: Bool, into value: ReferenceWritableKeyPath<WorkerConnection, Value?>
    ) async throws {
        let revision = connection.catalog.generation
        if let pending = connection.catalogRequests[path], pending.connection == revision {
            if fresh { try? await pending.task.value } else { try await pending.task.value; return }
            if let pending = connection.catalogRequests[path], pending.connection == revision { try await pending.task.value; return }
        }
        let client = connection.client
        let task = Task {
            defer { if connection.catalogRequests[path]?.connection == revision { connection.catalogRequests[path] = nil } }
            let result = try await client.request(path, as: Value.self)
            try Task.checkCancellation()
            guard revision == connection.catalog.generation, accepts(client) else { throw KitedError(message: "工作机连接已变化") }
            connection[keyPath: value] = result
        }
        connection.catalogRequests[path] = (revision, task)
        try await task.value
    }

    /// 资源库编辑器的草稿对账：先取已有的草稿，没有就从已保存的 saved 建；改完与已保存的一致（unchanged）就删掉草稿，否则写回。
    /// 草稿和已保存的都没有时不改。change 改的是一份拷贝，不在改数组的途中调用。
    func editDraft<Draft: Identifiable>(_ drafts: ReferenceWritableKeyPath<AppModel, [Draft]>, _ id: Draft.ID, from saved: Draft?,
                                        _ change: (inout Draft) -> Void, unchanged: (Draft) -> Bool) {
        let index = self[keyPath: drafts].firstIndex { $0.id == id }
        guard var draft = index.map({ self[keyPath: drafts][$0] }) ?? saved else { return }
        change(&draft)
        if let index {
            if unchanged(draft) { self[keyPath: drafts].remove(at: index) } else { self[keyPath: drafts][index] = draft }
        } else if !unchanged(draft) {
            self[keyPath: drafts].append(draft)
        }
    }

    /// 工作机上这一类目录变了：读过的重新读；skill 变了，各工作区能加载的 skill 也作废，下次列候选时重读。
    /// 收到 library.changed 时按它的 kind，目录流重连后每一类都走一遍。
    func libraryChanged(_ kind: LibraryList, on connection: WorkerConnection) {
        switch kind {
        case .role: if connection.roles != nil { Task { try? await refreshRoles(of: connection, fresh: true) } }
        case .template: if connection.templates != nil { Task { try? await refreshTemplates(of: connection, fresh: true) } }
        case .skill:
            if connection.skills != nil { Task { try? await refreshSkills(of: connection, fresh: true) } }
            for area in workspaces where area.remote.machine.id == connection.id { area.invalidateAvailableSkills() }
        case .plugin:
            // 定义列表连上工作机就读，不用看读没读过
            Task { try? await refreshDefinitions(connection.client) }
            connection.pluginGrantsRevision += 1
        }
    }

    /// 模板只能修改，各场景的模板由工作机提供。
    func saveContextTemplate(_ draft: TemplateDraft, connection: UUID) async throws {
        let (target, result) = try await libraryRequest("/context-templates/\(draft.id.pathComponent)", method: "PUT",
            body: ContextTemplateSave(definition: draft.definition, model: draft.model, expectedRevision: draft.revision),
            connection: connection, changed: "工作机连接已变化，请重试", as: ContextTemplate.self)
        target.replaceTemplate(result)
    }

    /// 模板恢复默认：内容连同辅助生成的模型一起换回默认。
    func resetContextTemplate(_ template: ContextTemplate, connection: UUID) async throws {
        let (target, result) = try await libraryRequest("/context-templates/\(template.id.pathComponent)/reset", method: "POST",
            body: LibraryReset(expectedRevision: template.revision), connection: connection, changed: "工作机连接已变化，请重试", as: ContextTemplate.self)
        target.replaceTemplate(result)
    }
}

extension WorkerConnection {
    /// 工作机存好的模板换进目录。
    func replaceTemplate(_ template: ContextTemplate) {
        templates?.templates.removeAll { $0.id == template.id }
        templates?.templates.append(template)
    }
}
