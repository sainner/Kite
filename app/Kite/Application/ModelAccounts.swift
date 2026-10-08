import Foundation

nonisolated struct ModelAccountsSnapshot: Decodable {
    let checkedAt: Double
    let accounts: [ModelAccount]
}

nonisolated struct ModelAccount: Decodable, Identifiable {
    struct Quota: Decodable, Identifiable {
        let id: String
        let label: String
        let remainingPercent: Double
        let windowMinutes: Double?
        let resetsAt: Double?
        var remaining: Double { min(1, max(0, remainingPercent / 100)) }
    }
    struct Credits: Decodable { let value: Double?; let unlimited: Bool }
    struct Cost: Decodable { let value: Double; let currency: String; let from: Double; let to: Double }
    struct Balance: Decodable, Identifiable {
        let currency: String
        let total: Double
        let granted: Double
        let toppedUp: Double
        var id: String { currency }
    }
    let id: String
    let provider: String
    let kind: String
    let status: String
    let identity: String?
    let plan: String?
    let message: String?
    let quotas: [Quota]
    let credits: Credits?
    let cost: Cost?
    let balances: [Balance]?

    var statusTitle: String {
        switch status {
        case "ready": kind == "api" && cost == nil && balances == nil ? "已配置" : "已读取"
        case "unconfigured": kind == "api" ? "未配置" : "未登录"
        case "reauthentication": "需重新授权"
        default: "暂不可查询"
        }
    }
}

/// 侧栏只展示在线工作机的有效额度，详情仍按机器保留，避免同名供应商覆盖不同账号。
struct SubscriptionQuota: Identifiable {
    let id: String
    let provider: String
    let remaining: Double
    let detail: String
}

extension AppModel {
    var accountWorkers: [WorkerConnection] {
        connections.values.sorted {
            $0.machine.name == $1.machine.name ? $0.id < $1.id : $0.machine.name < $1.machine.name
        }
    }

    var accountWorker: WorkerConnection? {
        accountMachineID.flatMap { connections[$0] } ?? accountWorkers.first
    }

    var subscriptionQuotas: [SubscriptionQuota] {
        availableWorkers.flatMap { connection in
            (connection.modelAccounts?.accounts ?? []).compactMap { account in
                guard account.kind == "subscription", account.status == "ready",
                      connection.modelAccountsError == nil,
                      let quota = account.quotas.filter({ $0.resetsAt.map { $0 > Date.now.timeIntervalSince1970 } ?? true })
                        .min(by: { $0.remaining < $1.remaining }) else { return nil }
                return SubscriptionQuota(id: "\(connection.id):\(account.id)", provider: account.provider,
                                         remaining: quota.remaining, detail: "\(connection.machine.name) · \(quota.label)")
            }
        }
    }

    func refreshModelAccounts(_ connection: WorkerConnection) async {
        guard !connection.readingModelAccounts else { return }
        let client = connection.client
        connection.readingModelAccounts = true
        defer { connection.readingModelAccounts = false }
        do {
            let value = try await client.request("/model-accounts", timeout: 25, as: ModelAccountsSnapshot.self)
            try Task.checkCancellation()
            guard accepts(client) else { return }
            connection.modelAccounts = value
            connection.modelAccountsError = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, accepts(client) else { return }
            connection.modelAccountsError = error.localizedDescription
        }
    }

    /// 额度查询不参与会话连接的成败，断线时跟随连接任务取消。
    func followModelAccounts(_ connection: WorkerConnection) async {
        while !Task.isCancelled {
            await refreshModelAccounts(connection)
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}
