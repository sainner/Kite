import SwiftUI

/// `/instances/:id/mcp`：代理打开的服务（可以有本机没装的）、项目禁用的，以及这台工作机装的。
nonisolated struct InstanceMcp: Decodable, Sendable {
    let servers: [String]
    let denied: [String]
    let available: [McpServerSummary]
}

/// 代理能用的外部 MCP 服务：在这台工作机装的服务里开关，开关即保存，下一次请求生效。
struct InstanceMcpSettings: View {
    let instance: RemotePluginInstance
    /// 回到实例设置。
    let back: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var client: KitedClient?
    @State private var value: InstanceMcp?
    @State private var phase = CardPhase.idle

    private var available: Bool {
        model.isConnected(area) && area.remote.workspace.status == .open
            && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }

    var body: some View {
        Group {
            if let value {
                CardSection("服务", note: "开关后下一次请求生效，运行中也能改。服务在工作机上运行，不在沙箱里，授权一个服务等于把它能做的事交给代理；执行授权管不到它。在「设备」里给这台工作机添加服务。") {
                    if value.available.isEmpty && value.servers.isEmpty {
                        Text("这台工作机还没有 MCP 服务。").foregroundStyle(.secondary)
                    }
                    McpServerToggles(available: value.available, denied: value.denied,
                                     selected: Binding(get: { value.servers }, set: { servers in $phase.run { try await save(servers) } }),
                                     showsStatus: true)
                }
            }
        }
        .disabled(phase.working || !available)
        .cardSheetPage("MCP 服务", subtitle: "选择代理能用的外部 MCP 服务", error: phase.error,
                       actions: [[.sheet("重新读取", systemImage: "arrow.clockwise", disabled: phase.working || !available) {
                           $phase.run { try await load() }
                       }]],
                       back: back)
        // 工作机推 mcp.changed（装卸服务、连接状态变化）时重新读。
        .task(id: model.connections[area.remote.machine.id]?.mcpRevision) { $phase.run { try await load() } }
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient(in: area)
        guard available, current.machineID == area.remote.machine.id, client == nil || client == current else {
            throw KitedError(message: "工作机或实例已变化，请重新打开实例设置")
        }
        return current
    }

    private func load() async throws {
        let client = try boundClient()
        self.client = client
        let value = try await client.request("/instances/\(instance.id)/mcp", as: InstanceMcp.self)
        _ = try boundClient()
        self.value = value
    }

    private func save(_ servers: [String]) async throws {
        struct Update: Encodable { let servers: [String] }
        let value = try await boundClient().request("/instances/\(instance.id)/mcp", method: "PUT", body: Update(servers: servers), as: InstanceMcp.self)
        _ = try boundClient()
        self.value = value
    }
}
