import SwiftUI

/// 账号身份、订阅周期与 API 费用各自保留原有单位；不从用量推算余额。
struct ModelAccountPane: View {
    let pane: Pane
    @Environment(AppModel.self) private var model
    @State private var login: SubscriptionLoginRequest?
    @State private var addingApiKey = false

    var body: some View {
        accountWindow(title: PaneGroup.accounts(model.accountWindows).appearance(of: pane).name,
                      subscriptionID: pane.id == "api" ? nil : pane.id)
            .sheet(item: $login) { request in
                SubscriptionLoginSheet(request: request).environment(model).appAppearance()
            }
            .sheet(isPresented: $addingApiKey) {
                ApiKeySheet().environment(model).appAppearance()
            }
    }

    private func accountWindow(title: String, subscriptionID: String?) -> some View {
        let connection = model.accountWorker
        let account = connection?.modelAccounts?.accounts.first { $0.id == subscriptionID }
        let stale = account.map { connection?.showsStaleData($0) ?? true } ?? false
        // 订阅窗口的档位是标题右边的标签，副行是账号邮箱，状态异常写在正文顶部；还没有身份时副行退回状态。
        let subtitle = account.map { $0.identity ?? (stale ? "上次数据" : $0.statusTitle) }
        // API 窗口的副行说明密钥存放位置。
        return PaneWindow(header: PaneHeader(title: title, subtitle: subscriptionID == nil ? "API Key 保存在资源库的凭据中" : subtitle,
                                             badge: account?.planTitle), usesDots: subscriptionID != nil) {
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
            .dotClip()
        } controls: { _ in
            EmptyView()
        } headerStatus: {
            if let account, !account.sharedQuotas.isEmpty {
                AccountQuotaRing(quotas: account.sharedQuotas, stale: stale)
            }
        } headerActions: {
            if let connection, let account {
                let title = account.status == "ready" ? "重新登录" : "登录"
                PaneHeaderButtonGroup {
                    Button {
                        login = SubscriptionLoginRequest(account: account, connection: connection)
                    } label: {
                        PaneHeaderButtonLabel(title, systemImage: "person.crop.circle")
                    }
                    .disabled(!connection.connected)
                    .help(title)
                }
            } else if subscriptionID == nil {
                PaneHeaderButtonGroup {
                    Button { addingApiKey = true } label: {
                        PaneHeaderButtonLabel("添加", systemImage: "plus")
                    }
                    .disabled(!model.account.signedIn)
                    .help(model.account.signedIn ? "添加 API Key" : "登录 Kite 账号后添加 API Key")
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
            if accounts.isEmpty {
                if subscriptionID == nil {
                    Text("还没有 API 账号，点「添加」保存 API Key 后即可查询额度与余额")
                        .font(Theme.secondary).foregroundStyle(.secondary)
                } else {
                    pendingNotice(connection)
                }
            }
            ForEach(accounts) { account in
                let stale = connection.showsStaleData(account)
                if subscriptionID == nil {
                    if account.id != accounts.first?.id { Divider() }
                    ApiAccountRow(account: account, stale: stale)
                } else {
                    ModelAccountRow(account: account, stale: stale)
                }
            }
            Text("更新于 \(Date(timeIntervalSince1970: snapshot.checkedAt).formatted(date: .abbreviated, time: .shortened))")
                .font(Theme.caption).foregroundStyle(.tertiary)
        } else if connection.readingModelAccounts {
            HStack(spacing: DotMetrics.module) {
                ProgressView().controlSize(.small)
                Text("正在读取账号与额度…").font(Theme.secondary).foregroundStyle(.secondary)
            }
        } else {
            pendingNotice(connection)
        }
        if let error = connection.modelAccountsError {
            Text("本次更新失败：\(error)").font(Theme.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 额度只在点刷新或会话带回时更新，打开页面不查询。
    private func pendingNotice(_ connection: WorkerConnection) -> some View {
        Text(connection.connected ? "尚未取得账号数据，会话运行后自动更新，也可在侧栏的账号行刷新" : "工作机离线，连接后可查看账号与额度")
            .font(Theme.secondary).foregroundStyle(.secondary)
    }
}

/// 订阅账号：额度在标题前的圆环里，正文是状态提示、用量统计、额度重置时间、按模型的周期与额外额度。
private struct ModelAccountRow: View {
    let account: ModelAccount
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DotMetrics.module * 2) {
            notice
            // 整个账号共用的周期在标题前的圆环里，悬停看外圈的数字；正文先是用量统计。
            if let usage = account.usage {
                AccountUsageSection(usage: usage, stale: stale)
            }
            if !account.quotas.isEmpty {
                // 重置时间按剩余时长显示，每分钟跟着走一次。
                TimelineView(.everyMinute) { context in
                    let now = context.date.timeIntervalSince1970
                    VStack(alignment: .leading, spacing: DotMetrics.module * 2) {
                        if !account.sharedQuotas.isEmpty { resets(now: now) }
                        if account.quotas.contains(where: { $0.model != nil }) { scopedQuotas(now: now) }
                    }
                }
            }
            if let credits = account.credits {
                LabeledContent("额外额度") {
                    if credits.unlimited { Text("不限额") }
                    else if let value = credits.value { Text(value, format: .number.precision(.fractionLength(0...2))).monospacedDigit() }
                    else { Text("余额未返回").foregroundStyle(.secondary) }
                }
                .font(Theme.secondary)
            }
            if let extra = account.extraUsage {
                if extra.enabled {
                    let money = { (value: Double) in extra.currency.map { value.formatted(.currency(code: $0)) } ?? value.formatted() }
                    LabeledContent("额外用量") {
                        Text([extra.used.map { "已用 \(money($0))" }, extra.limit.map { "上限 \(money($0))" }, extra.balance.map { "余额 \(money($0))" }]
                            .compactMap(\.self).joined(separator: " · ")).monospacedDigit()
                    }
                    .font(Theme.secondary)
                } else {
                    Text("额外用量未开启").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 订阅窗口的标题副行只放身份和档位；未登录、需要重新授权、沿用旧数据这些状态写在额度上方。
    @ViewBuilder
    private var notice: some View {
        let unconfigured = account.status == "unconfigured"
        let warns = stale || account.status == "reauthentication" || account.status == "unavailable"
        let detail = unconfigured ? "这台工作机尚未登录此订阅账号。" : account.message
        if unconfigured || warns {
            HStack(alignment: .firstTextBaseline, spacing: DotMetrics.module / 2) {
                Image(systemName: unconfigured ? "person.crop.circle.badge.questionmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(warns ? Theme.warning : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stale ? "显示的是上次数据" : account.statusTitle).font(Theme.secondary.weight(.medium))
                    if let detail {
                        Text(detail).font(Theme.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if let message = account.message {
            Text(message).font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: DotMetrics.module * 20), spacing: DotMetrics.module * 3, alignment: .top)]

    /// 圆环里整个账号共用的周期各自何时重置，排法和用量汇总一样。
    private func resets(now: Double) -> some View {
        HStack(alignment: .top, spacing: DotMetrics.module * 3) {
            ForEach(account.sharedQuotas) { quota in
                let expired = quota.isExpired(now: now)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(quota.label)额度重置").font(Theme.caption).foregroundStyle(.secondary)
                    Text(expired ? "等待刷新" : quota.resetMoment(now: now) ?? "—")
                        .font(Theme.heading2).monospacedDigit()
                        .foregroundStyle(expired ? .secondary : .primary)
                }
                .lineLimit(1)
            }
        }
    }

    /// 只限某个模型的周期归到一组，每个一行。
    private func scopedQuotas(now: Double) -> some View {
        VStack(alignment: .leading, spacing: DotMetrics.module) {
            Text("按模型").font(Theme.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: DotMetrics.module) {
                ForEach(account.quotas.filter { $0.model != nil }) { quotaLine($0, now: now) }
            }
        }
    }

    private func percent(_ quota: ModelAccount.Quota) -> String {
        quota.remaining.formatted(.percent.precision(.fractionLength(0)))
    }

    private func quotaLine(_ quota: ModelAccount.Quota, now: Double) -> some View {
        let expired = quota.isExpired(now: now), tint = quota.tint(stale: stale, now: now)
        let name = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(quota.model ?? "").font(Theme.secondary)
            Text(quota.label).font(Theme.caption).foregroundStyle(.secondary)
        }
        let value = Text(expired ? "等待刷新" : percent(quota))
            .font(expired ? Theme.caption : Theme.secondary.weight(.semibold)).monospacedDigit()
            .foregroundStyle(tint)
        return VStack(alignment: .leading, spacing: DotMetrics.module / 2) {
            // 放不下时先省掉重置时间，名称和百分比总在。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: DotMetrics.module) {
                    name
                    Spacer(minLength: 0)
                    if !expired, let reset = quota.resetText(now: now) {
                        Text(reset).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    value
                }
                .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: DotMetrics.module) {
                    name
                    Spacer(minLength: 0)
                    value
                }
                .lineLimit(1)
            }
            if !expired {
                AccountQuotaDots(remaining: quota.remaining, tint: tint)
                    .accessibilityLabel("\(quota.title)剩余额度")
                    .accessibilityValue(percent(quota))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// API 账号：供应商与 Key 名称、状态，主数字是余额或本月组织费用，下面是明细、用量统计和提示。
private struct ApiAccountRow: View {
    let account: ModelAccount
    let stale: Bool

    private var warns: Bool { stale || account.status == "reauthentication" || account.status == "unavailable" }

    var body: some View {
        VStack(alignment: .leading, spacing: DotMetrics.module) {
            HStack(alignment: .firstTextBaseline, spacing: DotMetrics.module) {
                Text(account.provider).font(Theme.title)
                if let identity = account.identity {
                    Text(identity).font(Theme.secondary).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                status
            }
            ForEach(account.balances ?? []) { balance in
                figure(balance.total.formatted(.currency(code: balance.currency)), title: "可用余额",
                       detail: "充值 \(balance.toppedUp.formatted(.currency(code: balance.currency))) · 赠金 \(balance.granted.formatted(.currency(code: balance.currency)))")
            }
            if let cost = account.cost {
                figure(cost.value.formatted(.currency(code: cost.currency)), title: "本月组织费用",
                       detail: "\(Date(timeIntervalSince1970: cost.from).formatted(.dateTime.month().day())) 起，按 UTC 计 · 组织合计，不是余额")
            }
            if let usage = account.usage {
                AccountUsageSection(usage: usage, stale: stale)
                    .padding(.top, DotMetrics.module)
            }
            if let message = account.message {
                Label(message, systemImage: warns ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.monochrome)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DotMetrics.module / 2)
    }

    /// 大号金额，旁边一行小字写它是什么，下面一行写明细。
    private func figure(_ value: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: DotMetrics.module) {
                Text(value).font(Theme.display).monospacedDigit()
                    .foregroundStyle(stale ? .secondary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(title).font(Theme.secondary).foregroundStyle(.secondary)
            }
            Text(detail).font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    /// 状态用一个小圆点加文字：可用为主题色，需要处理为警示色，只确认了配置为灰色。
    private var status: some View {
        let hasData = account.cost != nil || account.balances != nil
        let color: Color = warns ? Theme.warning : account.status == "ready" && hasData ? .accentColor : .secondary
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(stale ? "上次数据" : account.statusTitle)
        }
        .font(Theme.caption)
        .foregroundStyle(warns ? Theme.warning : .secondary)
        .fixedSize()
    }
}

/// 一行从左往右填满，最多一百格；窄处减少格数，百分比仍由旁边的文字准确表达。
/// 只占位，额度画在窗口那一套点阵上：剩余的格子长成 tint 色的方块，最后一格按零头长一部分，其余是轨道色的点。
private struct AccountQuotaDots: View {
    let remaining: Double
    let tint: Color
    @Environment(\.self) private var environment

    var body: some View {
        GeometryReader { geometry in
            DotMask(figure: figure(columns: max(1, min(100, Int(geometry.size.width / DotMetrics.pitch)))))
        }
        .frame(height: DotMetrics.pitch)
        .accessibilityElement(children: .ignore)
    }

    private func figure(columns: Int) -> DotFigure {
        let filled = remaining * Double(columns)
        let part = filled - filled.rounded(.down)
        let line = String((0..<columns).map { column -> Character in
            Double(column) + 1 <= filled ? "F" : Double(column) < filled ? "P" : "T"
        })
        let full = 0.75, track = 0.12
        let tint = DotColor(tint.resolve(in: environment)), rule = DotColor(Theme.rule.resolve(in: environment))
        return DotFigure([line], colors: ["F": tint, "P": rule.mixed(with: tint, by: part), "T": rule],
                         shapes: ["F": full, "P": track + (full - track) * part, "T": track])
    }
}
