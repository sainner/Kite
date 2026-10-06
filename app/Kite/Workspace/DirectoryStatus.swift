import SwiftUI

/// 目录尚未载入内容时保留原有窗口和侧栏入口。
struct DirectoryStatus: View {
    var workspace: WorkArea? = nil
    @Environment(AppModel.self) private var model

    private var connection: WorkerConnection? { workspace.flatMap { model.connection(for: $0) } }
    private var title: String {
        if workspace != nil { return connection?.error == nil ? "正在连接工作机" : "工作机暂不可达" }
        if model.account.workers.isEmpty { return "还没有工作机" }
        if !model.availableWorkers.isEmpty { return "添加第一个项目" }
        return "正在连接工作机"
    }

    var body: some View {
        PaneWindow(header: workspace?.header ?? PaneHeader(title: "Kite")) {
            VStack(spacing: 12) {
                Text(title).font(Theme.title)
                if let remote = workspace?.remote {
                    Text("\(remote.machine.name) · \(remote.workspace.cwd)")
                        .textSelection(.enabled)
                    Text("目录已保留，连接后自动载入工作区内容。")
                    if let updatedAt = connection?.updatedAt {
                        Text("目录更新于 \(Date(timeIntervalSince1970: Double(updatedAt) / 1000).formatted())")
                    }
                } else {
                    Text(model.account.workers.isEmpty
                         ? "在一台 Mac 上登录此账号，并选择“在这台 Mac 上运行任务”。"
                         : "把工作机上的文件夹登记为项目，即可开始工作。")
                }
                if let error = workspace == nil ? model.account.error : connection?.error {
                    Text(error).foregroundStyle(Theme.danger)
                }
            }
            .font(Theme.secondary).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).padding(24)
        } controls: { _ in
            HStack(spacing: 12) {
                Button("设置") { model.showConnection = true }
                if workspace == nil {
                    Button("添加项目") { model.showNewWorkspace = true }
                        .disabled(model.availableWorkers.isEmpty)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}
