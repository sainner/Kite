import SwiftUI

/// 资源库「代理上下文」的三类，按进入代理上下文的方式分：角色是新建代理时的初始上下文与配置，
/// 旁路任务另外调用模型生成内容，事件通知是插进会话的正文。三类内容同一种组装契约。
nonisolated enum AgentContextCategory: String, CaseIterable, Identifiable {
    case role, task, notification

    var id: Self { self }

    var title: String {
        switch self {
        case .role: "角色"
        case .task: "旁路任务"
        case .notification: "事件通知"
        }
    }

    /// 这一类模板在场景目录里的分类；角色不是模板。
    var templateKind: ContextScene.Kind? {
        switch self {
        case .role: nil
        case .task: .task
        case .notification: .notification
        }
    }
}

/// 代理上下文页里的一项：一个角色或一个模板。
nonisolated struct AgentContextItem: Hashable {
    let category: AgentContextCategory
    let id: String
}

extension AppModel {
    /// 一类里各项的 ID，按侧栏里的先后排。
    func agentContextIDs(_ category: AgentContextCategory) -> [String] {
        if let kind = category.templateKind { return libraryTemplates(kind).map(\.id) }
        return libraryRoles.map(\.id)
    }

    /// 代理上下文页显示的那项：侧栏选中的，没选过或已不在时是默认角色，角色还没读到时是第一个模板。
    var agentContextItem: AgentContextItem? {
        if let item = selectedAgentContext, agentContextIDs(item.category).contains(item.id) { return item }
        if let role = roleCatalog?.defaultRole { return AgentContextItem(category: .role, id: role.id) }
        return AgentContextCategory.allCases.lazy
            .compactMap { category in self.agentContextIDs(category).first.map { AgentContextItem(category: category, id: $0) } }
            .first
    }

    /// 代理上下文页的窗口：角色有上下文、签名与初始配置三个，模板只有上下文。
    var agentContextGroup: PaneGroup? {
        agentContextItem.map { .agentContext($0, $0.category == .role ? roleWindows : templateWindows) }
    }
}

/// 资源库的代理上下文页：侧栏里选中的角色或模板在固定排布的窗口里编辑，同设备账号页。
struct AgentContextLibrary: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        Group {
            if let group = model.agentContextGroup {
                // 角色与模板的窗口套数不同，换套时重新量一次内容区。
                TilesLayer(group: group).id(group.id)
            } else {
                SectionPage(header: PaneHeader(title: ExtensionLibrary.contexts.title, subtitle: SidebarSection.extensions.title)) {
                    Group {
                        if let error { Text(error).foregroundStyle(Theme.danger) } else { ProgressView() }
                    }
                    .font(Theme.body)
                    .padding(Metrics.padding)
                }
            }
        }
        .task(id: model.connectionRevision) {
            error = nil
            do {
                try await model.ensureRoles()
                try await model.ensureContextTemplates()
            }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 代理上下文的一个窗口；换一项时窗口留着，里面的内容换成新的一项。
struct AgentContextPane: View {
    let item: AgentContextItem
    let pane: Pane

    var body: some View {
        Group {
            switch (item.category, pane.id) {
            case (.role, "emblem"): RoleEmblemPane(id: item.id)
            case (.role, "settings"): RoleSettingsPane(id: item.id)
            case (.role, _): RoleContextPane(id: item.id)
            default: TemplatePane(id: item.id, category: item.category)
            }
        }
        .id(item)
    }
}
