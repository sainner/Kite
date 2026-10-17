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
                KeySheet<ApiProvider>().environment(model).appAppearance()
            }
    }

    private func accountWindow(title: String, subscriptionID: String?) -> some View {
        let connection = model.accountWorker
        let account = connection?.modelAccounts?.accounts.first { $0.id == subscriptionID }
        let stale = account.map { connection?.showsStaleData($0) ?? true } ?? false
        // 副行写这个窗口是什么：API 窗口说 Key 存在哪，订阅窗口是账号邮箱，没登录或还没有身份时说窗口里是什么；
        // 订阅窗口的档位是标题右边的标签。状态不进正文也不进副行，都在信息区（notice）。
        let subtitle = subscriptionID == nil ? "API Key 保存在资源库的凭据中"
            : account.flatMap { $0.status == "unconfigured" ? nil : $0.identity } ?? "订阅的额度与用量"
        // 订阅窗口：登录、重新登录；API 窗口：添加。
        var actions: [[PaneHeaderAction]] = []
        if let connection, let account {
            let title = account.status == "ready" ? "重新登录" : "登录"
            actions = [[PaneHeaderAction(title: title, systemImage: "person.crop.circle", disabled: !connection.connected) {
                login = SubscriptionLoginRequest(account: account, connection: connection)
            }]]
        } else if subscriptionID == nil {
            actions = [[PaneHeaderAction(title: "添加", systemImage: "plus",
                                         help: model.account.signedIn ? "添加 API Key" : "登录后添加 API Key",
                                         disabled: !model.account.signedIn) { addingApiKey = true }]]
        }
        return PaneWindow(header: PaneHeader(title: title, subtitle: subtitle, badge: account?.planTitle), usesDots: subscriptionID != nil,
                          notice: notice(connection, account: account, subscriptionID: subscriptionID),
                          status: account.flatMap { $0.sharedQuotas.isEmpty ? nil : AnyView(AccountQuotaRing(quotas: $0.sharedQuotas, stale: stale)) },
                          actions: PaneHeaderActions(groups: actions)) {
            let content = VStack(alignment: .leading, spacing: DotMetrics.module * 2) {
                if let accounts = connection?.modelAccounts?.accounts {
                    accountContent(accounts, connection: connection, subscriptionID: subscriptionID)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CardMetrics.inset)
            // 订阅窗口只有一个账号，正文占满窗口、不滚动；API 窗口的 Key 可以有很多个，仍放在滚动区里。
            if subscriptionID == nil {
                ScrollView { content.separateScrollPocket() }.dotClip()
            } else {
                // 高度只取窗口给的：内容比窗口高时从顶部往下截掉，不把标题栏顶出窗口。
                // 控制区浮在内容上面，不滚动的正文也铺到它后面，不让它占掉高度。
                content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped().dotClip()
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        } controls: { _ in
            EmptyView()
        }
    }

    @ViewBuilder
    private func accountContent(_ accounts: [ModelAccount], connection: WorkerConnection?, subscriptionID: String?) -> some View {
        let accounts = accounts.filter {
            if let subscriptionID { $0.id == subscriptionID }
            else { $0.kind == "api" }
        }
        ForEach(accounts) { account in
            let stale = connection?.showsStaleData(account) ?? true
            if subscriptionID == nil {
                if account.id != accounts.first?.id { Divider() }
                ApiAccountRow(account: account, stale: stale)
            } else {
                ModelAccountRow(account: account, stale: stale)
            }
        }
    }

    /// 还没有可显示的账号数据时的情况；有数据时是 nil。额度只在点刷新或会话带回时更新，打开页面不查询。
    private func pending(_ connection: WorkerConnection?, subscriptionID: String?) -> String? {
        guard let connection else { return "暂无已连接的工作机" }
        guard let snapshot = connection.modelAccounts else {
            if connection.readingModelAccounts { return "正在读取账号与额度…" }
            return connection.connected ? "以该账号运行 agent 以更新数据" : "连接工作机后可查看账号与额度"
        }
        if let subscriptionID {
            return snapshot.accounts.contains { $0.id == subscriptionID } ? nil : "以该账号运行 agent 以更新数据"
        }
        return snapshot.accounts.contains { $0.kind == "api" } ? nil : "还没有 API 账号，添加 API Key 后可查询额度与余额"
    }

    /// 窗口自己的提示，同时只有一项：先是要处理的（见 problem），再是还没有数据的情况（见 pending），最后是订阅没登录。
    /// 工作机离线由窗口外层的连接提示表达。
    private func notice(_ connection: WorkerConnection?, account: ModelAccount?, subscriptionID: String?) -> PaneNotice? {
        if let problem = problem(connection, account: account) { return problem }
        if let pending = pending(connection, subscriptionID: subscriptionID) {
            return PaneNotice(text: pending, symbol: connection?.readingModelAccounts == true ? "hourglass" : "info.circle", tint: .secondary)
        }
        if let account, account.status == "unconfigured" {
            return PaneNotice(text: account.statusTitle, symbol: "person.crop.circle", tint: .secondary)
        }
        return nil
    }

    /// 要处理的提示：账号要重新授权，这次更新失败，工作机沿用了上次的数据，账号暂不可查询，服务对额度的说明。
    private func problem(_ connection: WorkerConnection?, account: ModelAccount?) -> PaneNotice? {
        guard let connection else { return nil }
        let detail = account?.message.map { "：\($0)" } ?? ""
        if let account, account.status == "reauthentication" { return .failure(account.statusTitle + detail) }
        if let error = connection.modelAccountsError {
            return .failure(connection.modelAccounts == nil ? "本次更新失败：\(error)" : "本次更新失败，显示的是上次数据：\(error)")
        }
        guard let account else { return nil }
        if account.showsPreviousData {
            return PaneNotice(text: "暂时查询不到，显示的是上次数据" + detail, symbol: "clock.arrow.circlepath", tint: .secondary)
        }
        if account.status == "unavailable" { return .failure(account.statusTitle + detail) }
        if account.status == "ready", let message = account.message {
            return PaneNotice(text: message, symbol: "info.circle", tint: .secondary)
        }
        return nil
    }
}

/// 订阅账号：额度在标题前的圆环里，正文是一组数字、用量统计图与按模型的周期；账号状态在标题栏，见 ModelAccountPane。
private struct ModelAccountRow: View {
    let account: ModelAccount
    let stale: Bool
    @AppStorage(UsageUnit.storageKey) private var unit = UsageUnit.tokens

    private static let figureSpacing = DotMetrics.module * 2
    /// 每列至少放得下「6 天 20 小时」这样的倒计时，宽度按窗口放几列。
    private static let figureMinWidth = DotMetrics.module * 11
    private static let figureColumns = [GridItem(.adaptive(minimum: figureMinWidth), spacing: figureSpacing, alignment: .topLeading)]

    var body: some View {
        // 整个账号共用的周期在标题前的圆环里，悬停看外圈的数字；正文里的重置倒计时每分钟跟着走一次。
        // 柱状图占满剩下的高度，正文比窗口高时由窗口从底部截掉。
        TimelineView(.everyMinute) { context in
            let now = context.date.timeIntervalSince1970
            VStack(alignment: .leading, spacing: DotMetrics.module * 2) {
                if account.usage != nil || !account.sharedQuotas.isEmpty || account.credits != nil || account.extraUsage != nil {
                    // 栈先给其他部分留够最小高度，剩下的交给数字挑排法。
                    figureBlock(now: now).layoutPriority(1)
                }
                if let usage = account.usage {
                    AccountUsageSection(usage: usage, stale: stale)
                }
                if account.quotas.contains(where: { $0.model != nil }) {
                    scopedQuotas(now: now)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 高度够时数字换行排开，先拿够自己的高度，柱状图分剩下的；换行后柱状图保不住最小高度时排成一行横向滚动，
    /// 一页放的项数和换行时一行一样，按项对齐翻页。
    private func figureBlock(now: Double) -> some View {
        let spacing = Self.figureSpacing, minWidth = Self.figureMinWidth
        return ViewThatFits(in: .vertical) {
            LazyVGrid(columns: Self.figureColumns, alignment: .leading, spacing: spacing) { figures(now: now) }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(subviews: figures(now: now)) { item in
                        item.containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            let perRow = max(1, ((length + spacing) / (minWidth + spacing)).rounded(.down))
                            return (length - spacing * (perRow - 1)) / perRow
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            // 各项靠左与上下的内容对齐，左边保持硬边，前后还有没有由右边的一对箭头提醒。
            .hintsScrollOverflow(.horizontal, carets: .atEnd)
            // 横向滚动区在竖直方向也会占满给它的高度，限定为内容高度，剩下的空间留给柱状图。
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: DotMetrics.module * 20), spacing: DotMetrics.module * 3, alignment: .top)]

    /// 一组数字，依次是额外用量、圆环里整个账号共用的周期各自还有多久重置、累计用量与几项零碎统计。
    /// 额外额度和额外用量与套餐额度分开计，换用主题色。
    @ViewBuilder
    private func figures(now: Double) -> some View {
        if let credits = account.credits {
            figure("额外额度", credits.unlimited ? "不限额" : credits.value?.formatted(.number.precision(.fractionLength(0...2))) ?? "—",
                   tint: .accentColor)
        }
        if let extra = account.extraUsage {
            if extra.enabled {
                let money = { (value: Double) in extra.currency.map { value.formatted(.currency(code: $0)) } ?? value.formatted() }
                // 已用 / 上限。
                let amounts = [extra.used, extra.limit].compactMap { $0.map(money) }
                figure("额外用量", amounts.isEmpty ? "—" : amounts.joined(separator: " / "), tint: .accentColor)
                if let balance = extra.balance { figure("额外余额", money(balance), tint: .accentColor) }
            } else {
                figure("额外用量", "未开启", tint: .secondary)
            }
        }
        ForEach(account.sharedQuotas) { quota in
            let expired = quota.isExpired(now: now)
            figure("\(quota.label)重置", expired ? "等待刷新" : quota.resetCountdown(now: now) ?? "—", tint: expired ? .secondary : .primary)
        }
        if let usage = account.usage {
            usage.figures(unit: unit, today: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)))
        }
    }

    /// 额度这几项与用量统计用同一种数字样式。
    private func figure(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        UsageFigure(title: title, value: value, tint: tint)
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

/// API 账号：供应商与 Key 名称、状态，主数字是余额或本月组织费用，下面是明细和提示。
private struct ApiAccountRow: View {
    let account: ModelAccount
    let stale: Bool

    private var warns: Bool { account.status == "reauthentication" || account.status == "unavailable" }

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
        let color: Color = warns ? Theme.warning : !stale && account.status == "ready" && hasData ? .accentColor : .secondary
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(account.statusTitle)
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
