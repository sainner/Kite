import SwiftUI

/// 窗口内容的来源与窗口容器分开；工作区和设备账号共用排布、底栏与切换手势。
enum PaneGroup: Identifiable {
    case workspace(WorkArea)
    case accounts(WindowLayout)

    var id: String {
        switch self {
        case .workspace(let area): "workspace:\(area.id)"
        case .accounts: "machine-accounts"
        }
    }

    var layout: WindowLayout {
        switch self {
        case .workspace(let area): area.layout
        case .accounts(let layout): layout
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
        if let workspace { return workspace.appearance(of: pane) }
        switch pane.id {
        case "chatgpt": return .init(name: "ChatGPT", icon: "person.crop.circle")
        case "claude": return .init(name: "Claude", icon: "person.crop.circle")
        default: return .init(name: "API 账号", icon: "key")
        }
    }
}

extension AppModel {
    var paneGroup: PaneGroup? {
        if sidebarSection == .drive, drivePage == .accounts { return .accounts(accountWindows) }
        guard sidebarSection == .workspaces, selectedProject == nil, let current else { return nil }
        return .workspace(current)
    }
}
