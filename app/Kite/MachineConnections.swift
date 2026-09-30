import Foundation

/// 连接属于客户端；同一工作机改变地址时仍使用同一个身份。
struct MachineConnection: Codable, Identifiable, Equatable {
    let machine: RemoteMachine
    let address: String
    /// 该机最近返回的项目身份，供切换工作机后显式关联；目录和执行状态仍从服务读取。
    var projects: [RemoteProject] = []
    var id: String { machine.id }
}

struct MachineConnections: Codable {
    private(set) var entries: [MachineConnection] = []
    private(set) var selectedID: String?
    var selected: MachineConnection? { entries.first { $0.id == selectedID } }
    var knownProjects: [RemoteProject] {
        var seen = Set<String>()
        return entries.flatMap(\.projects).filter { seen.insert($0.id).inserted }
    }

    mutating func remember(_ machine: RemoteMachine, address: String) {
        if let index = entries.firstIndex(where: { $0.id == machine.id }) {
            entries[index] = MachineConnection(machine: machine, address: address, projects: entries[index].projects)
        } else { entries.append(MachineConnection(machine: machine, address: address)) }
        selectedID = machine.id
    }

    mutating func updateProjects(_ projects: [RemoteProject], on machineID: String) {
        guard let index = entries.firstIndex(where: { $0.id == machineID }) else { return }
        entries[index].projects = projects
    }

    mutating func select(_ id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    static func load(from defaults: UserDefaults = .standard) -> MachineConnections {
        guard let data = defaults.data(forKey: "KiteMachineConnections"),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "KiteMachineConnections")
    }
}
