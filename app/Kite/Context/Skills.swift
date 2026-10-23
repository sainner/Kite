import SwiftUI
import UniformTypeIdentifiers

/// 资源库里的一个 skill：SKILL.md 和附属文件，与工作机上的 SkillPackage 同形（docs/kited.md「账号级数据」）。
nonisolated struct SkillPackage: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable, Identifiable {
        enum Encoding: String, Codable, Sendable { case base64 }
        var path: String
        var content: String
        var encoding: Encoding? = nil
        var id: String { path }
        var isBinary: Bool { encoding == .base64 }
        var data: Data? { isBinary ? Data(base64Encoded: content) : Data(content.utf8) }
        var byteCount: Int { data?.count ?? 0 }

        init(path: String, content: String) {
            self.path = path
            self.content = content
        }

        init(path: String, data: Data) throws {
            self.path = path
            if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
                content = text
            } else {
                guard path != SkillPackage.mainFile else { throw KitedError(message: "SKILL.md 必须是 UTF-8 文本") }
                content = data.base64EncodedString()
                encoding = .base64
            }
        }

        static func importing(_ url: URL, path: String? = nil) throws -> File {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= SkillPackage.maximumBytes else { throw KitedError(message: "skill 整包不能超过 4 MiB") }
            return try File(path: path ?? url.lastPathComponent, data: Data(contentsOf: url))
        }
    }

    var version = 1
    var name: String
    var files: [File]

    static let mainFile = "SKILL.md"
    static let maximumBytes = 4 * 1024 * 1024

    /// Agent Skills 标准的名字：小写字母、数字和连字符，最长 64。
    static func validName(_ name: String) -> Bool {
        name.count <= 64 && name.wholeMatch(of: #/[a-z0-9]+(-[a-z0-9]+)*/#) != nil
    }

    /// 新建时的内容：头里写上名字，说明留给用户填。
    static func blank(name: String) -> SkillPackage {
        SkillPackage(name: name, files: [File(path: mainFile, content: "---\nname: \(name)\ndescription: \n---\n\n")])
    }
}

/// 导出选中的文件时保留原始字节，不经过文本编辑器。
struct SkillFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

nonisolated struct LibrarySkill: Decodable, Identifiable, Sendable {
    var skill: SkillPackage
    var revision: String
    /// 随 kited 带的 skill 默认内容的版本，自建的没有。
    var defaultRevision: String?
    var id: String { skill.name }
    var isBuiltin: Bool { defaultRevision != nil }
    /// 随 kited 带的改过才能恢复默认。
    var canReset: Bool { defaultRevision.map { $0 != revision } ?? false }
}

nonisolated struct SkillCatalog: Decodable, Sendable {
    var skills: [LibrarySkill]
}

/// 这个工作区的代理能加载的 skill，输入框点选用（GET /workspaces/:id/skills）。
nonisolated struct AvailableSkill: Decodable, Hashable, Identifiable, Sendable {
    let name: String
    let description: String
    let layer: String
    var id: String { name }
}

nonisolated struct AvailableSkills: Decodable, Sendable {
    let skills: [AvailableSkill]
}

private struct SkillSave: Encodable {
    let skill: SkillPackage
    let expectedRevision: String?
}

/// 资源库里改过还没保存的 skill；新建的还没存过，revision 为 nil。切到别的页再回来还在，保存或放弃后清掉。
struct SkillDraft: Identifiable {
    var skill: SkillPackage
    var revision: String?
    var id: String { skill.name }
    var isNew: Bool { revision == nil }
}

extension AppModel {
    var skillCatalog: SkillCatalog? { activeConnection?.skills }

    /// 工作机上已有的名字加本机新建的草稿，供选中项和新建查重使用；已保存的 skill 不能改名。
    var librarySkillNames: [String] {
        (skillCatalog?.skills ?? []).map(\.id) + skillDrafts.filter(\.isNew).map(\.id)
    }

    func skillDraft(_ name: String) -> SkillDraft? { skillDrafts.first { $0.id == name } }

    func librarySkill(_ name: String) -> SkillPackage? { skillDraft(name)?.skill ?? savedSkill(name)?.skill }

    func savedSkill(_ name: String) -> LibrarySkill? { skillCatalog?.skills.first { $0.id == name } }

    /// Skill 页显示的那个：侧栏选中的，没选过或已不在时是第一个。
    var skillItem: String? {
        let names = librarySkillNames
        if let selectedSkill, names.contains(selectedSkill) { return selectedSkill }
        return names.first
    }

    var skillGroup: PaneGroup? { skillItem.map { .skill($0, skillWindows) } }

    /// 改动资源库里的 skill；改回与工作机上一致时不再算草稿，新建的一直是草稿。
    func editSkill(_ name: String, _ change: (inout SkillDraft) -> Void) {
        let saved = savedSkill(name)
        let index = skillDrafts.firstIndex { $0.id == name }
        guard var draft = index.map({ skillDrafts[$0] }) ?? saved.map({ SkillDraft(skill: $0.skill, revision: $0.revision) }) else { return }
        change(&draft)
        let unchanged = !draft.isNew && (saved.map { draft.skill == $0.skill && draft.revision == $0.revision } ?? false)
        if let index {
            if unchanged { skillDrafts.remove(at: index) } else { skillDrafts[index] = draft }
        } else if !unchanged {
            skillDrafts.append(draft)
        }
    }

    /// 新建一个 skill 的草稿：名字先占一个没用过的，在标题栏里改。
    func newLibrarySkill() {
        let taken = Set(librarySkillNames)
        var name = "new-skill"
        var number = 2
        while taken.contains(name) { name = "new-skill-\(number)"; number += 1 }
        skillDrafts.append(SkillDraft(skill: .blank(name: name), revision: nil))
        extensionPage = .skills
        selectedSkill = name
    }

    /// 新建的 skill 改名：名字要合规、不与已有的重复；SKILL.md 头里的 name 跟着改。
    func renameNewSkill(_ name: String, to newName: String) throws {
        guard let index = skillDrafts.firstIndex(where: { $0.id == name && $0.isNew }), newName != name else { return }
        guard SkillPackage.validName(newName) else { throw KitedError(message: "名字只能用小写字母、数字和连字符") }
        guard !librarySkillNames.contains(newName) else { throw KitedError(message: "已有同名的 skill") }
        var draft = skillDrafts[index]
        draft.skill.name = newName
        if let file = draft.skill.files.firstIndex(where: { $0.path == SkillPackage.mainFile }) {
            draft.skill.files[file].content = draft.skill.files[file].content
                .replacing(#/^name:[^\n]*$/#.anchorsMatchLineEndings(), with: "name: \(newName)", maxReplacements: 1)
        }
        skillDrafts[index] = draft
        if selectedSkill == name { selectedSkill = newName }
    }

    /// 列表没读过才读；读过的由 skills.changed 事件和重连后的重读保持最新。
    func ensureSkills() async throws {
        guard let connection = activeConnection, connection.connected else { throw KitedError(message: "所属工作机未连接") }
        if connection.skills == nil { try await refreshSkills(of: connection) }
    }

    func refreshSkills(of connection: WorkerConnection, fresh: Bool = false) async throws {
        try await refreshCatalog("/skills", of: connection, fresh: fresh, request: \.skillsRequest, into: \.skills)
    }

    /// 保存：新建的 POST，已有的带着看到的版本 PUT；随 kited 带的改回默认时工作机删掉账号里那份。
    func saveSkill(_ draft: SkillDraft, connection: UUID) async throws {
        let path = draft.isNew ? "/skills" : "/skills/\(draft.skill.name.pathComponent)"
        let (target, result) = try await libraryRequest(path, method: draft.isNew ? "POST" : "PUT",
            body: SkillSave(skill: draft.skill, expectedRevision: draft.revision), connection: connection, changed: Self.skillConnectionChanged, as: LibrarySkill.self)
        target.replaceSkill(result)
    }

    /// 随 kited 带的 skill 恢复默认：整个文件夹换回默认内容。
    func resetSkill(_ skill: LibrarySkill, connection: UUID) async throws {
        let (target, result) = try await libraryRequest("/skills/\(skill.id.pathComponent)/reset", method: "POST",
            body: LibraryReset(expectedRevision: skill.revision), connection: connection, changed: Self.skillConnectionChanged, as: LibrarySkill.self)
        target.replaceSkill(result)
    }

    /// 删掉自建的 skill；随 kited 带的只能恢复默认。
    func deleteSkill(_ skill: LibrarySkill, connection: UUID) async throws {
        let (target, _) = try await libraryRequest("/skills/\(skill.id.pathComponent)?expectedRevision=\(skill.revision.pathComponent)", method: "DELETE",
            connection: connection, changed: Self.skillConnectionChanged, as: JSON.self)
        target.removeSkill(skill.id)
    }

    private static let skillConnectionChanged = "工作机连接已变化，请返回 Skill 列表"
}

extension WorkerConnection {
    /// 工作机存好的 skill 换进列表。
    func replaceSkill(_ skill: LibrarySkill) {
        if let index = skills?.skills.firstIndex(where: { $0.id == skill.id }) { skills?.skills[index] = skill } else { skills?.skills.append(skill) }
        skills?.skills.sort { $0.id < $1.id }
    }

    func removeSkill(_ name: String) {
        skills?.skills.removeAll { $0.id == name }
    }
}
