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
    /// 该账号在这台工作机上按天的 token 用量。
    struct Usage: Decodable {
        struct Day: Decodable {
            let date: String
            let tokens: Double
            /// 本地时间 0–23 时每小时的 token。
            let hours: [Double]
            /// 按工作机的价格表折算的美元，不含未计价的 token。
            let cost: Double
            let costHours: [Double]
            /// 价格表里没有对应模型的 token，已计入 tokens。
            let unpriced: Double
        }
        let days: [Day]
        let lifetimeTokens: Double
        let lifetimeCost: Double
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

/// 工作机折算用量金额用的价格表，单价是每百万 token 的美元。
nonisolated struct TokenPriceTable: Decodable {
    struct Rates: Decodable {
        let input: Double
        let cacheRead: Double
        /// 价格页没有列出时为 nil。
        let cacheWrite: Double?
        /// Claude 的 1 小时缓存写入。
        let cacheWrite1h: Double?
        let output: Double
    }
    struct Model: Decodable, Identifiable {
        /// 提示超过 above 个 token 的请求整次按 rates 计价。
        struct Long: Decodable { let above: Double; let rates: Rates }
        let model: String
        let provider: String
        let rates: Rates
        let long: Long?
        var id: String { model }

        private enum CodingKeys: String, CodingKey { case model, provider, long }

        /// 单价和型号写在同一层。
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            provider = try container.decode(String.self, forKey: .provider)
            long = try container.decodeIfPresent(Long.self, forKey: .long)
            rates = try Rates(from: decoder)
        }
    }
    /// 核对价格的日期。
    let checked: String
    let models: [Model]
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

    /// 所有工作机上各账号的用量按天相加。每台工作机只统计自己的会话记录，同一账号登录在几台机器上也不会重复；
    /// 只含已收到账号数据的工作机。
    var totalUsage: ModelAccount.Usage? {
        let usages = connections.values.compactMap(\.modelAccounts).flatMap(\.accounts).compactMap(\.usage)
        guard !usages.isEmpty else { return nil }
        let days = Dictionary(grouping: usages.flatMap(\.days), by: \.date).map { date, days in
            let sum = { (value: (ModelAccount.Usage.Day) -> Double) in days.reduce(0) { $0 + value($1) } }
            let hours = { (value: (ModelAccount.Usage.Day) -> [Double]) in
                (0..<24).map { hour in days.reduce(0) { $0 + (value($1).indices.contains(hour) ? value($1)[hour] : 0) } }
            }
            return ModelAccount.Usage.Day(date: date, tokens: sum(\.tokens), hours: hours(\.hours), cost: sum(\.cost),
                                          costHours: hours(\.costHours), unpriced: sum(\.unpriced))
        }
        return ModelAccount.Usage(days: days.sorted { $0.date < $1.date },
                                  lifetimeTokens: usages.reduce(0) { $0 + $1.lifetimeTokens },
                                  lifetimeCost: usages.reduce(0) { $0 + $1.lifetimeCost })
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
