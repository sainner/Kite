import SwiftUI

/// 账号身份、订阅周期与 API 费用各自保留原有单位；不从用量推算余额。
struct ModelAccountPane: View {
    let pane: Pane
    @Environment(AppModel.self) private var model
    @State private var login: SubscriptionLoginRequest?

    var body: some View {
        accountWindow(title: PaneGroup.accounts(model.accountWindows).appearance(of: pane).name,
                      subscriptionID: pane.id == "api" ? nil : pane.id)
            .sheet(item: $login) { request in
                SubscriptionLoginSheet(request: request).environment(model).appAppearance()
            }
    }

    private func accountWindow(title: String, subscriptionID: String?) -> some View {
        let connection = model.accountWorker
        let account = connection?.modelAccounts?.accounts.first { $0.id == subscriptionID }
        let status = account.map {
            connection?.connected != true || connection?.modelAccountsError != nil ? "上次数据" : $0.statusTitle
        }
        return PaneWindow(header: PaneHeader(title: title, subtitle: status), usesDots: true) {
            ScrollView {
                VStack(alignment: .leading, spacing: DotMetrics.module * 2) {
                    if let connection {
                        accountContent(connection, subscriptionID: subscriptionID)
                    } else {
                        Label("暂无已连接的工作机", systemImage: "desktopcomputer")
                            .font(Theme.secondary).foregroundStyle(.secondary)
                    }
                    if let error = model.account.error {
                        Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CardMetrics.inset)
                .separateScrollPocket()
            }
        } controls: { _ in
            EmptyView()
        } headerActions: {
            if let connection {
                PaneHeaderButtonGroup {
                    if let subscriptionID,
                       let account = connection.modelAccounts?.accounts.first(where: { $0.id == subscriptionID }) {
                        let title = account.status == "ready" ? "重新登录" : "登录"
                        Button {
                            login = SubscriptionLoginRequest(account: account, connection: connection)
                        } label: {
                            PaneHeaderButtonLabel(title, systemImage: "person.crop.circle")
                        }
                        .disabled(!connection.connected)
                        .help(title)
                    }
                    Button {
                        Task { await model.refreshModelAccounts(connection) }
                    } label: {
                        PaneHeaderButtonLabel("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(!connection.connected || connection.readingModelAccounts)
                    .help("刷新这台工作机的账号与额度")
                }
            }
        }
    }

    @ViewBuilder
    private func accountContent(_ connection: WorkerConnection, subscriptionID: String?) -> some View {
        if let snapshot = connection.modelAccounts {
            let accounts = snapshot.accounts.filter {
                if let subscriptionID { $0.id == subscriptionID }
                else { $0.kind == "api" }
            }
            ForEach(accounts) { account in
                if account.id != accounts.first?.id { Divider() }
                ModelAccountRow(account: account, showsProvider: subscriptionID == nil,
                                stale: !connection.connected || connection.modelAccountsError != nil)
            }
            Text("更新于 \(Date(timeIntervalSince1970: snapshot.checkedAt).formatted(date: .abbreviated, time: .shortened))")
                .font(Theme.caption).foregroundStyle(.secondary)
        } else if connection.readingModelAccounts {
            HStack(spacing: DotMetrics.module) {
                ProgressView().controlSize(.small)
                Text("正在读取账号与额度…").font(Theme.secondary).foregroundStyle(.secondary)
            }
        } else {
            Text(connection.connected ? "尚未取得账号数据" : "工作机离线，连接后可查看账号与额度")
                .font(Theme.secondary).foregroundStyle(.secondary)
        }
        if let error = connection.modelAccountsError {
            Text("本次更新失败：\(error)").font(Theme.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ModelAccountRow: View {
    let account: ModelAccount
    let showsProvider: Bool
    let stale: Bool

    private var isSubscription: Bool { account.kind == "subscription" }

    var body: some View {
        VStack(alignment: .leading, spacing: isSubscription ? DotMetrics.module * 2 : DotMetrics.module) {
            if showsProvider {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DotMetrics.module * 2) {
                        identity
                        Spacer(minLength: 0)
                        status
                    }
                    VStack(alignment: .leading, spacing: DotMetrics.module) {
                        identity
                        status
                    }
                }
            } else if account.plan != nil || account.identity != nil {
                identity
            }
            if !account.quotas.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DotMetrics.module * 20), spacing: DotMetrics.module * 3, alignment: .top)],
                          alignment: .leading, spacing: DotMetrics.module * 2) {
                    ForEach(account.quotas) { quota in
                        quotaRow(quota)
                    }
                }
            }
            if let credits = account.credits {
                LabeledContent("额外额度") {
                    if credits.unlimited { Text("不限额") }
                    else if let value = credits.value { Text(value, format: .number).monospacedDigit() }
                    else { Text("余额未返回").foregroundStyle(.secondary) }
                }
                .font(Theme.secondary)
            }
            if let cost = account.cost {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本月组织费用").font(Theme.secondary)
                        Text("\(Date(timeIntervalSince1970: cost.from).formatted(date: .abbreviated, time: .omitted)) 起 · UTC")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(cost.value, format: .currency(code: cost.currency))
                        .font(Theme.heading2).monospacedDigit()
                }
            }
            ForEach(account.balances ?? []) { balance in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("可用余额").font(Theme.secondary).foregroundStyle(.secondary)
                        Spacer()
                        Text(balance.total, format: .currency(code: balance.currency))
                            .font(Theme.heading2).monospacedDigit()
                    }
                    Text("充值 \(balance.toppedUp.formatted(.currency(code: balance.currency))) · 赠金 \(balance.granted.formatted(.currency(code: balance.currency)))")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            if let message = account.message {
                Text(message).font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if account.status == "unconfigured" {
                Text(account.kind == "api" ? "这台工作机尚未配置此 API 账号。" : "这台工作机尚未登录此订阅账号。")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: DotMetrics.module) {
                if showsProvider {
                    Text(account.provider).font(Theme.title)
                }
                if let plan = account.plan {
                    Text(plan)
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.dewy.opacity(0.18), in: Capsule())
                }
            }
            if let identity = account.identity {
                Text(identity).font(Theme.secondary).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
            }
        }
    }

    private var status: some View {
        Text(stale ? "上次数据" : account.statusTitle)
            .font(Theme.caption)
            .foregroundStyle(stale || account.status == "reauthentication" || account.status == "unavailable" ? Theme.warning : .secondary)
            .fixedSize()
    }

    private func quotaRow(_ quota: ModelAccount.Quota) -> some View {
        let expired = quota.resetsAt.map { $0 <= Date.now.timeIntervalSince1970 } ?? false
        let tint = quota.remaining < 0.2 ? Theme.warning : Color.accentColor
        return VStack(alignment: .leading, spacing: DotMetrics.module) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.label).foregroundStyle(.secondary)
                Spacer()
                if expired { Text("等待刷新").foregroundStyle(.secondary) }
                else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("剩余").font(Theme.caption).foregroundStyle(.secondary)
                        Text(quota.remaining.formatted(.percent.precision(.fractionLength(0))))
                            .font(Theme.heading1).monospacedDigit()
                            .foregroundStyle(stale ? .secondary : tint)
                    }
                }
            }
            .font(Theme.secondary)
            if !expired {
                AccountQuotaDots(remaining: quota.remaining, tint: stale ? .secondary : tint)
                    .accessibilityLabel("\(quota.label)剩余额度")
                    .accessibilityValue(quota.remaining.formatted(.percent.precision(.fractionLength(0))))
            }
            if let reset = quota.resetsAt {
                Text("重置时间 \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 五行点阵按列填满，最多一百格；窄处减少列数，百分比仍由旁边的文字准确表达。
private struct AccountQuotaDots: View {
    let remaining: Double
    let tint: Color
    @Environment(\.self) private var environment

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, min(20, DotMatrix.columns(fitting: geometry.size.width)))
            let rows = 5
            DotMatrix(columns: columns, rows: rows) { column, row in
                let index = column * rows + (rows - row - 1)
                let fraction = min(1, max(0, remaining * Double(columns * rows) - Double(index)))
                return Dot(.circle, shape: 0.12 + 0.63 * fraction,
                           color: DotColor(Theme.rule.mix(with: tint, by: fraction).resolve(in: environment)))
            }
        }
        .frame(height: DotMetrics.pitch * 5 - DotMetrics.gap)
        .accessibilityElement(children: .ignore)
    }
}
