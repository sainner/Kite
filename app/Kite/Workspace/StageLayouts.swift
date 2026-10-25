import SwiftUI

/// 布局：项目的一张配方，不是具体实例的清单（docs/台面与停靠栏.md「布局」；接口见 docs/kited.md 的 /project-registry/:id/layouts）。
/// 账号级数据，随项目登记同步到各工作机，任一台都能改。
struct ProjectLayout: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let members: [LayoutMember]
    let arrangement: LayoutArrangement
    let revision: String

    /// 保存时发出去的部分（PUT 的 layout）。
    struct Recipe: Encodable {
        let name: String
        let members: [LayoutMember]
        let arrangement: LayoutArrangement
    }

    var recipe: Recipe { Recipe(name: name, members: members, arrangement: arrangement) }
}

/// 布局的一个成员：代理记角色，浏览记当前网页（看文件的不记），预览记目标与设备，其余记类型或定义。
enum LayoutMember: Codable, Equatable {
    case agent(role: String)
    case files(page: BrowsePage?)
    case terminal
    case preview(target: String, device: PreviewDevice?)
    case plugin(definition: String)

    private enum Keys: String, CodingKey { case kind, role, page, target, device, definition }
    private struct Page: Codable {
        var port: Int?
        var url: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "agent": self = .agent(role: try c.decode(String.self, forKey: .role))
        case "files":
            let page = try c.decodeIfPresent(Page.self, forKey: .page)
            if let port = page?.port { self = .files(page: .port(port)) }
            else if let url = page?.url.flatMap(URL.init(string:)) { self = .files(page: .url(url)) }
            else { self = .files(page: nil) }
        case "terminal": self = .terminal
        case "preview": self = .preview(target: try c.decode(String.self, forKey: .target), device: try c.decodeIfPresent(PreviewDevice.self, forKey: .device))
        case "plugin": self = .plugin(definition: try c.decode(String.self, forKey: .definition))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知的布局成员 \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .agent(let role):
            try c.encode("agent", forKey: .kind)
            try c.encode(role, forKey: .role)
        case .files(let page):
            try c.encode("files", forKey: .kind)
            try c.encodeIfPresent(page, forKey: .page)
        case .terminal:
            try c.encode("terminal", forKey: .kind)
        case .preview(let target, let device):
            try c.encode("preview", forKey: .kind)
            try c.encode(target, forKey: .target)
            try c.encodeIfPresent(device, forKey: .device)
        case .plugin(let definition):
            try c.encode("plugin", forKey: .kind)
            try c.encode(definition, forKey: .definition)
        }
    }
}

/// 成员的摆法：分栏树（方向、比例）与成员顺序，叶子是成员在 members 里的序号；iPhone 只用顺序。
indirect enum LayoutArrangement: Codable, Equatable {
    case member(Int)
    case split(axis: Axis, ratio: Double, first: LayoutArrangement, second: LayoutArrangement)

    private enum Keys: String, CodingKey { case kind, index, axis, ratio, first, second }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "member": self = .member(try c.decode(Int.self, forKey: .index))
        case "split":
            self = .split(axis: try c.decode(String.self, forKey: .axis) == "vertical" ? .vertical : .horizontal,
                          ratio: try c.decode(Double.self, forKey: .ratio),
                          first: try c.decode(LayoutArrangement.self, forKey: .first), second: try c.decode(LayoutArrangement.self, forKey: .second))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知的排布 \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .member(let index):
            try c.encode("member", forKey: .kind)
            try c.encode(index, forKey: .index)
        case .split(let axis, let ratio, let first, let second):
            try c.encode("split", forKey: .kind)
            try c.encode(axis == .vertical ? "vertical" : "horizontal", forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }

    /// 成员序号按出现的先后，iPhone 按它排。
    var order: [Int] {
        switch self {
        case .member(let index): [index]
        case .split(_, _, let first, let second): first.order + second.order
        }
    }

    /// 把排布里的 pane 换成成员序号；没有成员的 pane 拿掉，它所在的那一刀由另一半补上。
    init?(tile: Tile, index: (Pane) -> Int?) {
        switch tile {
        case .pane(let pane):
            guard let member = index(pane) else { return nil }
            self = .member(member)
        case .placeholder:
            return nil
        case .split(let split):
            let first = LayoutArrangement(tile: split.first, index: index), second = LayoutArrangement(tile: split.second, index: index)
            switch (first, second) {
            case (let first?, let second?): self = .split(axis: split.axis, ratio: Double(split.ratio), first: first, second: second)
            case (let only?, nil), (nil, let only?): self = only
            case (nil, nil): return nil
            }
        }
    }

    /// 按成员序号找到的 pane 摆成排布；没找到的成员拿掉。
    func tile(panes: [Int: Pane]) -> Tile? {
        switch self {
        case .member(let index): return panes[index].map(Tile.pane)
        case .split(let axis, let ratio, let first, let second):
            switch (first.tile(panes: panes), second.tile(panes: panes)) {
            case (let first?, let second?): return .split(Split(axis, CGFloat(min(max(ratio, 0), 1)), first, second))
            case (let only?, nil), (nil, let only?): return only
            case (nil, nil): return nil
            }
        }
    }
}

extension WorkArea {
    /// 布局成员最多这么多（工作机的限制）。
    static let layoutMemberLimit = 32

    /// 把本机台面上现有的卡片翻成配方保存：代理记角色，浏览记当前网页（看文件的不记），预览记目标与设备，其余记类型；
    /// 草稿按选的角色记，新建页不记。保存成一个新布局；给了 replacing 就用当前台面覆盖它（带着它的版本，别处刚改过时工作机拒绝）。
    func saveLayout(name: String, replacing: ProjectLayout? = nil, model: AppModel) async throws {
        var members: [LayoutMember] = []
        var indices: [Pane: Int] = [:]
        for pane in layout.shown?.panes ?? [] {
            guard members.count < Self.layoutMemberLimit, let member = layoutMember(of: pane, model: model) else { continue }
            indices[pane] = members.count
            members.append(member)
        }
        guard let shown = layout.shown, let arrangement = LayoutArrangement(tile: shown, index: { indices[$0] }) else {
            throw KitedError(message: "台面上没有能记进布局的实例")
        }
        let client = try model.activeClient(in: self)
        _ = try await client.putLayout(project: remote.project.id, id: replacing?.id ?? Self.newPaneID(), expectedRevision: replacing?.revision,
                                       layout: ProjectLayout.Recipe(name: name, members: members, arrangement: arrangement))
        await model.refreshLayouts(project: remote.project.id, client: client)
    }

    private func layoutMember(of pane: Pane, model: AppModel) -> LayoutMember? {
        if pane.id == draftPane {
            guard let role = model.newThreadRole(for: draftThread, in: self) else { return nil }
            return .agent(role: role.id)
        }
        guard let instance = instance(of: pane) else { return nil }
        if isAgent(instance) {
            guard let role = instance.config?.role else { return nil }
            return .agent(role: role.id)
        }
        switch instance.definitionId {
        case AppModel.filesDefinition: return .files(page: instance.state?.selection.page)
        case "kite.terminal": return .terminal
        case AppModel.previewDefinition:
            guard let preview = instance.config?.preview else { return nil }
            return .preview(target: preview.target, device: preview.device)
        default: return .plugin(definition: instance.definitionId)
        }
    }

    /// 整个台面换成这组：每个成员在当前工作区找现成的（代理按角色，先取已在台面上的，再取最近活动过的；浏览、终端、插件按类型，
    /// 预览还按目标与设备），找不到的新建（代理新建为这个角色的草稿；草稿只有一份，第二个找不到的代理不建），再按配方摆。
    func openLayout(_ layout: ProjectLayout, model: AppModel) {
        var used: Set<String> = []
        var panes: [Int: Pane] = [:]
        var draftRole: AgentRole?
        let onStage = Set((self.layout.shown?.panes ?? []).map(\.id))
        func pick(_ matches: (RemotePluginInstance) -> Bool) -> RemotePluginInstance? {
            let candidates = instances.filter { $0.status == .open && !used.contains($0.id) && !isOpening(instance: $0.id) && matches($0) }
            return candidates.first { onStage.contains($0.id) }
                ?? candidates.max { recentActivity($0) < recentActivity($1) }
        }
        for (index, member) in layout.members.enumerated() {
            switch member {
            case .agent(let role):
                if let found = pick({ isAgent($0) && !isSubagent($0.id) && $0.config?.role?.id == role }) {
                    used.insert(found.id)
                    panes[index] = Pane(found.id)
                } else if draftRole == nil, let role = model.roles(in: self)?.roles.first(where: { $0.id == role }) {
                    draftRole = role
                    panes[index] = Pane(prepareDraft(role: role))
                }
            case .files(let page):
                if let found = pick({ $0.definitionId == AppModel.filesDefinition }) {
                    used.insert(found.id)
                    panes[index] = Pane(found.id)
                    if let page, let browser = files[found.id] { Task { try? await browser.openPage(page) } }
                } else {
                    panes[index] = created(CreateInstanceRequest(id: Self.newPaneID(), definitionId: AppModel.filesDefinition, page: page), model: model)
                }
            case .terminal:
                if let found = pick({ $0.definitionId == "kite.terminal" }) {
                    used.insert(found.id)
                    panes[index] = Pane(found.id)
                } else {
                    panes[index] = created(CreateInstanceRequest(id: Self.newPaneID(), definitionId: "kite.terminal"), model: model)
                }
            case .preview(let target, let device):
                let spec = PreviewSpec(target: target, device: device)
                if let found = pick({ $0.definitionId == AppModel.previewDefinition && $0.config?.preview == spec }) {
                    used.insert(found.id)
                    panes[index] = Pane(found.id)
                } else {
                    panes[index] = created(CreateInstanceRequest(id: Self.newPaneID(), definitionId: AppModel.previewDefinition, title: target, preview: spec), model: model)
                }
            case .plugin(let definition):
                if let found = pick({ $0.definitionId == definition }) {
                    used.insert(found.id)
                    panes[index] = Pane(found.id)
                } else if definitions.contains(where: { $0.id == definition && !$0.views.isEmpty }) {
                    panes[index] = created(CreateInstanceRequest(id: Self.newPaneID(), definitionId: definition), model: model)
                }
            }
        }
        rebuildForLayout()
        guard let tile = layout.arrangement.tile(panes: panes) else { return }
        self.layout.present(tile)
    }

    /// 新建一个成员的实例：本机先建、不放上台面（整组最后一起摆），工作机建好接上。
    private func created(_ request: CreateInstanceRequest, model: AppModel) -> Pane? {
        guard definitions.contains(where: { $0.id == request.definitionId }) else { return nil }
        model.createInstance(request, in: self, show: false)
        return Pane(request.id)
    }

    /// 代理最近活动的时间，没有摘要时按创建时间。
    private func recentActivity(_ instance: RemotePluginInstance) -> Double {
        activities[instance.id]?.changedAt ?? Double(instance.createdAt)
    }
}

extension AppModel {
    /// 读这个项目的布局，交给它的各个工作区；library.changed 的 layout 也从这里重读。
    func refreshLayouts(project: String, client: KitedClient) async {
        guard accepts(client) else { return }
        guard let layouts = try? await client.layouts(project: project), accepts(client) else { return }
        projectLayouts[project] = layouts
        for area in workspaces where area.remote.project.id == project && area.layouts != layouts { area.layouts = layouts }
    }

    /// 目录接上后：各工作区拿已读到的布局，没读过的项目去读一次。
    func distributeLayouts(on client: KitedClient) {
        for area in workspaces where area.remote.machine.id == client.machineID {
            let project = area.remote.project.id
            if let layouts = projectLayouts[project] {
                if area.layouts != layouts { area.layouts = layouts }
            } else if !loadingLayouts.contains(project) {
                loadingLayouts.insert(project)
                Task {
                    await refreshLayouts(project: project, client: client)
                    loadingLayouts.remove(project)
                }
            }
        }
    }
}
