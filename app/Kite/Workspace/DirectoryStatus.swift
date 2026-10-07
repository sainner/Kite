import SwiftUI

/// 目录尚未载入内容时内容区的画板，宽屏和 iPhone 相同。
struct DirectoryStatus: View {
    var workspace: WorkArea? = nil
    @Environment(AppModel.self) private var model

    private var connection: WorkerConnection? { workspace.flatMap { model.connection(for: $0) } }

    private var scene: StageScene {
        if workspace != nil { return connection?.error == nil ? .connecting : .unreachable }
        if model.account.workers.isEmpty { return .grounded }
        if !model.availableWorkers.isEmpty { return .addProject }
        return .connecting
    }

    private var title: String {
        switch scene {
        case .connecting: "正在连接工作机"
        case .unreachable: "工作机暂不可达"
        case .grounded: "还没有工作机"
        case .addProject, .idle: "添加第一个项目"
        }
    }

    private var details: [String] {
        switch scene {
        case .grounded:
            return ["在一台 Mac 上登录此账号，并选择“在这台 Mac 上运行任务”。"]
        case .addProject, .idle:
            return ["把工作机上的文件夹或远程仓库登记为项目，即可开始工作。"]
        case .connecting, .unreachable:
            guard let remote = workspace?.remote else { return ["正在连接账号下的工作机。"] }
            var lines = ["\(remote.machine.name) · \(remote.workspace.cwd)", "目录已保留，连接后自动载入工作区内容。"]
            if let updatedAt = connection?.updatedAt {
                lines.append("目录更新于 \(Date(timeIntervalSince1970: Double(updatedAt) / 1000).formatted())")
            }
            return lines
        }
    }

    private var error: String? { workspace == nil ? model.account.error : connection?.error }

    var body: some View {
        EmptyStage(scene: scene, title: title, details: details, error: error, actions: actions)
    }

    private var actions: [StageAction] {
        var actions: [StageAction] = []
        if scene == .addProject {
            actions.append(StageAction(title: "添加项目", prominent: true) { model.newWorkspace = .project })
        }
        if scene != .connecting {
            actions.append(StageAction(title: "设置") { model.openSettings() })
        }
        return actions
    }
}
