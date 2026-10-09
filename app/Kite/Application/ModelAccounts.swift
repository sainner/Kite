import Foundation

nonisolated struct ModelAccountsSnapshot: Decodable {
    let checkedAt: Double
    let accounts: [ModelAccount]
}

nonisolated struct ModelAccount: Decodable, Identifiable {
    struct Quota: Decodable, Identifiable {
        let id: String
        let label: String
        /// 只限某个模型或功能的额度；缺省是整个账号共用。
        let model: String?
        let remainingPercent: Double
        let windowMinutes: Double?
        let resetsAt: Double?
        var remaining: Double { min(1, max(0, remainingPercent / 100)) }
        var title: String { [model, label].compactMap(\.self).joined(separator: " · ") }
    }
    struct Credits: Decodable { let value: Double?; let unlimited: Bool }
    /// Claude 的额外用量，超出套餐额度后按金额计费。
    struct ExtraUsage: Decodable { let enabled: Bool; let currency: String?; let used: Double?; let limit: Double?; let balance: Double? }
    struct Cost: Decodable { let value: Double; let currency: String; let from: Double; let to: Double }
    /// 按天的 token 用量；scope 为 account 时是整个账号在所有设备上的用量，machine 只含这台工作机的记录。
    struct Usage: Decodable {
        struct Day: Decodable {
            let date: String
            let tokens: Double
            /// 本地时间 0–23 时每小时的 token，只来自工作机本机的记录；没有时为 nil。
            let hours: [Double]?
        }
        let scope: String
        let days: [Day]
        let lifetimeTokens: Double
    }
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
    let extraUsage: ExtraUsage?
    let cost: Cost?
    let balances: [Balance]?
    let usage: Usage?

    /// 整个账号共用的周期，窗口长的在前；标题前的圆环外圈是第一个。
    var sharedQuotas: [Quota] {
        quotas.filter { $0.model == nil }.sorted { ($0.windowMinutes ?? 0) > ($1.windowMinutes ?? 0) }
    }

    var statusTitle: String {
        switch status {
        case "ready": kind == "api" && cost == nil && balances == nil ? "已配置" : "已读取"
        case "unconfigured": kind == "api" ? "未配置" : "未登录"
        case "reauthentication": "需重新授权"
        default: "暂不可查询"
        }
    }

    /// 档位首字母大写，例如 max 20x 显示为 Max 20x。
    var planTitle: String? { plan.map { $0.prefix(1).uppercased() + $0.dropFirst() } }

    /// 暂时查询失败时工作机沿用上次的数据，界面按旧数据显示。
    var showsPreviousData: Bool {
        status == "unavailable" && (!quotas.isEmpty || credits != nil || cost != nil || balances != nil)
    }
}

extension WorkerConnection {
    /// 账号按旧数据显示：工作机离线、这次更新失败，或工作机沿用了上次的数据。
    func showsStaleData(_ account: ModelAccount) -> Bool {
        !connected || modelAccountsError != nil || account.showsPreviousData
    }
}

/// 侧栏按厂商汇总在线工作机的订阅额度，每个账号按限制最紧的周期计。
struct SubscriptionQuota: Identifiable {
    struct Account {
        let name: String
        let quota: String
        let remaining: Double
    }
    let provider: String
    let accounts: [Account]
    var id: String { provider }
    /// 上游不给各账号额度的绝对大小，按等额合计。
    var remaining: Double { accounts.map(\.remaining).reduce(0, +) / Double(accounts.count) }
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
        let now = Date.now.timeIntervalSince1970
        // 同一账号登录在几台工作机上只算一次，取最近一次查询的结果；身份未知的无法判断，各算一个。
        var accounts: [String: (checkedAt: Double, provider: String, account: SubscriptionQuota.Account)] = [:]
        for connection in availableWorkers where connection.modelAccountsError == nil {
            guard let snapshot = connection.modelAccounts else { continue }
            for account in snapshot.accounts where account.kind == "subscription" && account.status == "ready" {
                // 已过重置时间的周期已恢复整额
                let quotas = account.quotas.map { ($0, $0.isExpired(now: now) ? 1 : $0.remaining) }
                guard let tightest = quotas.min(by: { $0.1 < $1.1 }) else { continue }
                let key = account.identity.map { [account.provider, $0, account.plan ?? ""] }
                    ?? [connection.id, account.id]
                let id = key.joined(separator: "\n")
                guard accounts[id].map({ $0.checkedAt < snapshot.checkedAt }) ?? true else { continue }
                let name = [account.identity ?? connection.machine.name, account.planTitle].compactMap(\.self).joined(separator: " · ")
                accounts[id] = (snapshot.checkedAt, account.provider,
                                .init(name: name, quota: tightest.0.title, remaining: tightest.1))
            }
        }
        return Dictionary(grouping: accounts.values, by: \.provider)
            .map { SubscriptionQuota(provider: $0.key, accounts: $0.value.map(\.account).sorted { $0.name < $1.name }) }
            .sorted { $0.provider < $1.provider }
    }

    /// 账号里的 API Key 变了，各台在线工作机都要重新领取。
    func refreshAllModelAccounts() {
        for connection in availableWorkers { Task { await refreshModelAccounts(connection) } }
    }

    /// 让工作机重新查询上游。结果和会话带回的额度一样经目录事件流到达，避免较早的响应覆盖较新的推送。
    func refreshModelAccounts(_ connection: WorkerConnection) async {
        guard !connection.readingModelAccounts else { return }
        let client = connection.client
        connection.readingModelAccounts = true
        defer { connection.readingModelAccounts = false }
        do {
            try await client.post("/model-accounts/refresh")
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, accepts(client) else { return }
            connection.modelAccountsError = error.localizedDescription
        }
    }
}
