import SwiftUI

/// 窗口内容的来源与窗口容器分开；工作区、设备账号与资源库的代理上下文、凭据共用排布、底栏与切换手势。
enum PaneGroup: Identifiable {
    case workspace(WorkArea)
    case accounts(WindowLayout)
    /// 资源库代理上下文里选中的一项；角色与模板各用一套固定窗口。
    case agentContext(AgentContextItem, WindowLayout)
    /// 资源库 Skill 页里选中的一个 skill（名字），一套固定窗口。
    case skill(String, WindowLayout)
    case credentials(WindowLayout)

    var id: String {
        switch self {
        case .workspace(let area): "workspace:\(area.id)"
        case .accounts: "machine-accounts"
        // 同一套窗口里换一项只换窗口内容，窗口不重建。
        case .agentContext(let item, _): "agent-context:\(item.category == .role ? "role" : "template")"
        case .skill: "skill"
        case .credentials: "credentials"
        }
    }

    var layout: WindowLayout {
        switch self {
        case .workspace(let area): area.layout
        case .accounts(let layout): layout
        case .agentContext(_, let layout): layout
        case .skill(_, let layout): layout
        case .credentials(let layout): layout
        }
    }

    var workspace: WorkArea? {
        if case .workspace(let area) = self { area } else { nil }
    }

    var canShowWindows: Bool {
        guard let workspace else { return true }
        return workspace.pluginClient != nil
    }

    func appearance(of pane: Pane) -> WindowAppearance {
        switch self {
        case .workspace(let area): return area.appearance(of: pane)
        case .accounts:
            switch pane.id {
            case "chatgpt": return .init(name: "ChatGPT", icon: "person.crop.circle")
            case "claude": return .init(name: "Claude", icon: "person.crop.circle")
            default: return .init(name: "API 账号", icon: "key")
            }
        case .agentContext:
            switch pane.id {
            case "emblem": return .init(name: "签名", icon: "circle.grid.3x3")
            case "settings": return .init(name: "初始配置", icon: "slider.horizontal.3")
            default: return .init(name: "上下文", icon: "text.alignleft")
            }
        case .skill:
            return .init(name: "Skill", icon: "sparkles")
        case .credentials:
            switch pane.id {
            case "git": return .init(name: "Git 账号", icon: "arrow.triangle.branch")
            case "api": return .init(name: ApiProvider.category, icon: "key")
            case "speech": return .init(name: SpeechProvider.category, icon: "waveform")
            default: return .init(name: "密钥", icon: "key")
            }
        }
    }
}

extension AppModel {
    var paneGroup: PaneGroup? {
        if sidebarSection == .drive, drivePage == .accounts { return .accounts(accountWindows) }
        if sidebarSection == .extensions, extensionPage == .contexts { return agentContextGroup }
        if sidebarSection == .extensions, extensionPage == .skills { return skillGroup }
        if sidebarSection == .extensions, extensionPage == .credentials { return .credentials(credentialWindows) }
        guard sidebarSection == .workspaces, selectedProject == nil, let current else { return nil }
        return .workspace(current)
    }
}
