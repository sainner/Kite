import Foundation
import Security

/// 连接属于客户端；同一工作机改变地址时仍使用同一个身份。
struct MachineConnection: Codable, Identifiable, Equatable {
    let machine: RemoteMachine
    let address: String
    /// 该机最近返回的项目身份，供切换工作机后显式关联；目录和执行状态仍从服务读取。
    var projects: [RemoteProject] = []
    /// 远程配对令牌只放钥匙串，不写进偏好设置；本机连接没有令牌。
    var token: String?
    var id: String { machine.id }

    private enum CodingKeys: String, CodingKey { case machine, address, projects }
}

/// 每台工作机一条钥匙串记录，以机器身份为账户名。
enum DeviceTokens {
    private static let service = "Kite 工作机配对"

    private static func query(_ machineID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: machineID]
    }

    static func read(_ machineID: String) -> String? {
        var query = query(machineID)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for machineID: String) throws {
        SecItemDelete(query(machineID) as CFDictionary)
        var item = query(machineID)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法把配对令牌存入钥匙串（\(status)）"])
        }
    }
}

struct MachineConnections: Codable {
    private(set) var entries: [MachineConnection] = []
    private(set) var selectedID: String?
    var selected: MachineConnection? { entries.first { $0.id == selectedID } }
    var knownProjects: [RemoteProject] {
        var seen = Set<String>()
        return entries.flatMap(\.projects).filter { seen.insert($0.id).inserted }
    }

    /// 未给出新令牌时沿用已有令牌：同一工作机换地址仍是同一台设备。
    mutating func remember(_ machine: RemoteMachine, address: String, token: String? = nil) {
        if let index = entries.firstIndex(where: { $0.id == machine.id }) {
            entries[index] = MachineConnection(machine: machine, address: address, projects: entries[index].projects,
                                               token: token ?? entries[index].token)
        } else { entries.append(MachineConnection(machine: machine, address: address, token: token)) }
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
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        for index in saved.entries.indices { saved.entries[index].token = DeviceTokens.read(saved.entries[index].id) }
        return saved
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "KiteMachineConnections")
    }
}
