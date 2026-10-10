import SwiftUI

extension ModelAccount.Quota {
    /// 距重置还有多久，各周期一律倒计时：一天以上写天和小时，一小时以上写小时和分钟，再短只写分钟。
    func resetCountdown(now: Double) -> String? {
        guard let resetsAt else { return nil }
        let minutes = max(1, Int(((resetsAt - now) / 60).rounded(.up)))
        let days = minutes / (24 * 60), hours = minutes % (24 * 60) / 60, rest = minutes % 60
        if days > 0 { return hours == 0 ? "\(days) 天" : "\(days) 天 \(hours) 小时" }
        if hours > 0 { return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分" }
        return "\(rest) 分钟"
    }

    func resetText(now: Double) -> String? {
        resetCountdown(now: now).map { "\($0)后重置" }
    }

    /// 重置时刻已过，等着下一次刷新。
    func isExpired(now: Double) -> Bool { resetsAt.map { $0 <= now } ?? false }

    /// 圆弧与百分比的颜色：旧数据或重置时刻已过为灰，剩余不到两成为警示色。
    func tint(stale: Bool, now: Double) -> Color {
        stale || isExpired(now: now) ? .secondary : remaining < 0.2 ? Theme.warning : .accentColor
    }
}

/// 标题前的额度圆环，和会话窗口的状态圆环同一位置、同样大小。每个整个账号共用的周期一圈，窗口长的在外圈：
/// 只有每周额度时是单环，另有 5 小时额度时内圈是 5 小时。圆弧是剩余的比例。
/// 悬停时圆环虚化，外圈的剩余百分比渐显在原处；内圈的数字只在提示里，重置时间写在正文。
/// 信息区有提示时由提示占住这个位置，悬停不再显示百分比。
struct AccountQuotaRing: View {
    let quotas: [ModelAccount.Quota]
    let stale: Bool
    @State private var hovering = false
    @Environment(\.paneNotice) private var notice
    private var lineWidth: CGFloat { quotas.count > 1 ? 2.5 : 3 }

    var body: some View {
        let rings = Array(quotas.prefix(2))
        let revealed = hovering && notice == nil
        TimelineView(.everyMinute) { context in
            let now = context.date.timeIntervalSince1970
            ZStack {
                ForEach(Array(rings.enumerated()), id: \.element.id) { index, quota in
                    let color = quota.tint(stale: stale, now: now)
                    ZStack {
                        Circle().stroke(color, lineWidth: lineWidth).opacity(0.25)
                        if !quota.isExpired(now: now) {
                            Circle()
                                .trim(from: 0, to: quota.remaining)
                                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                    }
                    .padding(CGFloat(index) * (lineWidth + 1.5))
                }
            }
            .blur(radius: revealed ? 2.5 : 0)
            .opacity(revealed ? 0.3 : 1)
            .overlay {
                if let quota = rings.first {
                    Text(quota.isExpired(now: now) ? "–" : String(Int((quota.remaining * 100).rounded())))
                        .font(Theme.ringValue)
                        .foregroundStyle(quota.tint(stale: stale, now: now))
                        .fixedSize()
                        .opacity(revealed ? 1 : 0)
                }
            }
        }
        .paneHeaderRing(lineWidth: lineWidth, status: description)
        .onHover { inside in withAnimation(.easeInOut(duration: 0.2)) { hovering = inside } }
    }

    private var description: String {
        let now = Date.now.timeIntervalSince1970
        return quotas.prefix(2).map { quota in
            ["\(quota.title)剩余 \(quota.remaining.formatted(.percent.precision(.fractionLength(0))))", quota.resetText(now: now)]
                .compactMap(\.self).joined(separator: "，")
        }
        .joined(separator: "\n")
    }
}

/// 用量的计量单位：token 数，或按工作机价格表折算的美元。保存在本机，Kite 账号页切换，各账号窗口跟着用。
enum UsageUnit: String, CaseIterable, Identifiable {
    case tokens, cost

    static let storageKey = "KiteUsageUnit"

    var id: Self { self }
    var title: String { self == .tokens ? "Token" : "金额" }

    /// token 数按本地习惯缩写，例如 4358万、261亿；金额百元以下留两位小数，上万再缩写。
    func format(_ value: Double) -> String {
        switch self {
        case .tokens:
            return Int(value.rounded()).formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
        case .cost:
            let style = FloatingPointFormatStyle<Double>.Currency(code: "USD")
            if value >= 10_000 { return value.formatted(style.notation(.compactName).precision(.significantDigits(1...3))) }
            return value.formatted(style.precision(.fractionLength(value >= 100 ? 0 : 2)))
        }
    }
}

extension ModelAccount.Usage.Day {
    func total(_ unit: UsageUnit) -> Double { unit == .tokens ? tokens : cost }
    func hours(_ unit: UsageUnit) -> [Double] { unit == .tokens ? hours : costHours }
}

/// 一项数字：上面一行小字写它是什么，note 跟在标题后面，不另起一行，免得整行被撑高；下面是大号的值。
struct UsageFigure: View {
    let title: String
    let value: String
    var note: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                if let note { Text(note).foregroundStyle(.tertiary) }
            }
            .font(Theme.caption)
            Text(value).font(Theme.heading2).monospacedDigit().foregroundStyle(tint)
        }
        .lineLimit(1)
    }
}

/// 用量统计：某一天的 24 小时柱状图与近一年的热力图，都画在窗口的点阵上：
/// 柱状图一小时一根，宽处每小时占几列；热力图一列一周，宽度放得下几列就画最近几周。
struct AccountUsageSection: View {
    let stale: Bool
    /// 日期与当天用量的对照；没有用量的日子不在其中。
    private let days: [String: ModelAccount.Usage.Day]
    @AppStorage(UsageUnit.storageKey) private var unit = UsageUnit.tokens
    /// 柱状图画的那天：热力图上点按选定的，没有时是今天。
    @State private var pinnedDay: String?
    /// 柱状图上悬停的小时优先，其次是点按选定的；选定的只属于当时那一天。
    @State private var hoveredHour: Int?
    @State private var pinnedHour: PinnedHour?
    /// 一行摆得下几格点阵；量到宽度之前是 0，图先不画。
    @State private var columns = 0

    private struct PinnedHour { let day: String; let hour: Int }

    init(usage: ModelAccount.Usage, stale: Bool) {
        self.stale = stale
        days = Dictionary(usage.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var tint: Color { stale ? .secondary : .accentColor }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let today = Calendar.current.startOfDay(for: context.date)
            let day = pinnedDay ?? UsageCalendar.key(today)
            let pinned = pinnedHour.flatMap { $0.day == day ? $0.hour : nil }
            let hour = hoveredHour ?? pinned
            VStack(alignment: .leading, spacing: DotMetrics.module * 2) {
                VStack(alignment: .leading, spacing: DotMetrics.module) {
                    readout(day, hour: hour, today: today)
                    UsageHours(hours: days[day]?.hours(unit),
                               current: day == UsageCalendar.key(today) ? Calendar.current.component(.hour, from: context.date) : nil,
                               columns: columns, tint: tint, shown: hour, pinned: pinned, hovered: $hoveredHour) { hour in
                        pinnedHour = hour.map { PinnedHour(day: day, hour: $0) }
                    }
                }
                UsageHeatmap(values: days.mapValues { $0.total(unit) }, weeks: min(53, columns), today: today, tint: tint,
                             shown: day, pinned: $pinnedDay)
            }
            // 宽度只取外面给的，不被按旧格数画出的图撑开；否则窗口变窄时量到的仍是旧宽度，格数只增不减。
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: Int.self) { Int($0.size.width / DotMetrics.pitch) } action: { columns = $0 }
    }

    /// 柱状图的标题行：那天的日期和用量，选中某小时时是那一小时的；右边写柱子顶格代表多少。
    /// 按金额看时，价格表里没有的模型不计入金额，整天的读数后面注明有多少 token 没算进去。
    private func readout(_ key: String, hour: Int?, today: Date) -> some View {
        let name = UsageCalendar.date(key).map {
            Calendar.current.isDate($0, inSameDayAs: today) ? "今天" : $0.formatted(.dateTime.month().day().weekday(.abbreviated))
        } ?? key
        let suffix = unit == .tokens ? " token" : ""
        let unpriced = days[key]?.unpriced ?? 0
        let detail = hour.map { "\($0):00–\($0 + 1):00 · \(unit.format(days[key]?.hours(unit)[$0] ?? 0))\(suffix)" }
            ?? "\(unit.format(days[key]?.total(unit) ?? 0))\(suffix)"
            + (unit == .cost && unpriced > 0 ? " · \(UsageUnit.tokens.format(unpriced)) token 未计价" : "")
        let peak = days[key]?.hours(unit).max() ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(Theme.secondary.weight(.medium))
            Text(detail).font(Theme.caption).foregroundStyle(.secondary)
            Spacer(minLength: DotMetrics.module)
            if peak > 0 {
                Text("最高 \(unit.format(peak))/时").font(Theme.status).foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

extension ModelAccount.Usage {
    func lifetime(_ unit: UsageUnit) -> Double { unit == .tokens ? lifetimeTokens : lifetimeCost }

    /// 截至 today 的最近几天合计。
    func total(days count: Int, through today: Date, unit: UsageUnit) -> Double {
        let since = UsageCalendar.key(UsageCalendar.add(-count, to: today)), until = UsageCalendar.key(today)
        return days.filter { $0.date > since && $0.date <= until }.reduce(0) { $0 + $1.total(unit) }
    }

    /// 几项统计：累计、近 7 天、单日峰值与连续使用天数。
    @ViewBuilder func figures(unit: UsageUnit, today: Date) -> some View {
        let peak = days.max { $0.total(unit) < $1.total(unit) }
        UsageFigure(title: "累计", value: unit.format(lifetime(unit)))
        UsageFigure(title: "近 7 天", value: unit.format(total(days: 7, through: today, unit: unit)))
        UsageFigure(title: "单日峰值", value: peak.map { unit.format($0.total(unit)) } ?? "—",
                    note: peak.flatMap { UsageCalendar.date($0.date)?.formatted(.dateTime.month().day()) })
        UsageFigure(title: "连续使用", value: "\(streak(through: today)) 天")
    }

    /// 从今天往前数连续有用量的天数；今天还没用时从昨天数起。
    func streak(through today: Date) -> Int {
        let used = Set(days.filter { $0.tokens > 0 }.map(\.date))
        var streak = 0
        var cursor = used.contains(UsageCalendar.key(today)) ? today : UsageCalendar.add(-1, to: today)
        while used.contains(UsageCalendar.key(cursor)) {
            streak += 1
            cursor = UsageCalendar.add(-1, to: cursor)
        }
        return streak
    }
}

/// 用量的日期键与服务端一致，是 YYYY-MM-DD；按本地日历取今天。
enum UsageCalendar {
    static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func add(_ days: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }
}

/// 坐标文字的行高。
nonisolated private let labelHeight = DotMetrics.pitch * 1.5

private func axisLabel(_ text: String) -> some View {
    Text(text).font(Theme.status).foregroundStyle(.secondary).lineLimit(1).fixedSize()
}

/// 指针位置换成图案里的格子；落在图案外为 nil。
private func cell(at point: CGPoint, columns: Int, rows: Int) -> (column: Int, row: Int)? {
    let column = Int(point.x / DotMetrics.pitch), row = Int(point.y / DotMetrics.pitch)
    guard point.x >= 0, point.y >= 0, column < columns, row < rows else { return nil }
    return (column, row)
}

/// 一天 24 小时铺满整行：每一列按它在一天里的位置归到某一小时，相邻小时连成阶梯，各小时宽度至多差一列。
/// 图的高度占满外面剩下的空间，能放几行点就画几行，至少五行，图贴着下面的时刻画，不足一行的零头留在上面；柱高按当天最多的那一小时折算成满格，
/// 顶格按零头长一部分，最底一行是轴；今天还没到的小时不画轴。
/// 下方每 6 小时标一次时刻；悬停或点按某一段看那一小时。
private struct UsageHours: View {
    let hours: [Double]?
    /// 今天正在走的小时；不是今天时为 nil。
    let current: Int?
    let columns: Int
    let tint: Color
    /// 标出的小时：悬停的，或点按选定的。
    let shown: Int?
    let pinned: Int?
    @Binding var hovered: Int?
    let pin: (Int?) -> Void
    @Environment(\.self) private var environment
    @State private var height: CGFloat = 0

    nonisolated private static let minRows = 5
    nonisolated private static let minHeight = DotMetrics.pitch * CGFloat(minRows) + 4 + labelHeight

    private var rows: Int { max(Self.minRows, Int((height - 4 - labelHeight) / DotMetrics.pitch)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if columns > 0 {
                DotMask(figure: figure(), alignment: .bottomLeading)
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let point) = phase { hovered = hour(at: point) } else { hovered = nil }
                            }
                            .onTapGesture { point in
                                let hour = hour(at: point)
                                pin(hour == pinned ? nil : hour)
                            }
                    }
                ZStack(alignment: .topLeading) {
                    axisLabel("0:00")
                    ForEach([6, 12, 18], id: \.self) { hour in
                        axisLabel("\(hour):00")
                            .position(x: CGFloat(columns * hour) / 24 * DotMetrics.pitch, y: labelHeight / 2)
                    }
                    axisLabel("24:00").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: CGFloat(columns) * DotMetrics.pitch, height: labelHeight, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当天每小时用量")
    }

    /// 这一列的中点落在哪一小时。
    private func hour(of column: Int) -> Int {
        min(23, Int((Double(column) + 0.5) * 24 / Double(columns)))
    }

    /// 指针下的那一小时，只按列算，占位上面的零头也算；还没到的小时为 nil。
    private func hour(at point: CGPoint) -> Int? {
        let column = Int(point.x / DotMetrics.pitch)
        guard point.x >= 0, column < columns else { return nil }
        let hour = hour(of: column)
        return current.map { hour <= $0 } ?? true ? hour : nil
    }

    private func figure() -> DotFigure {
        let values = hours ?? Array(repeating: 0, count: 24)
        let peak = values.max() ?? 0
        let heights = values.map { value in peak > 0 && value > 0 ? max(0.35, value / peak * Double(rows)) : 0 }
        let tint = DotColor(tint.resolve(in: environment))
        let rule = DotColor(Theme.rule.resolve(in: environment))
        // 最底一行是轴：没用的小时也稍带一点主题色，和热力图里的零用量一致。
        var colors: [Character: DotColor] = ["F": tint, "S": tint.mixed(with: rule, by: 0.5), "0": rule.mixed(with: tint, by: 0.2)]
        var shapes: [Character: Double] = ["F": 0.75, "S": 0.75, "0": 0.2]
        // 顶格按零头分四档大小。
        let parts: [Character] = ["a", "b", "c", "d"]
        for (index, part) in parts.enumerated() {
            colors[part] = tint
            shapes[part] = 0.3 + 0.45 * Double(index + 1) / Double(parts.count + 1)
        }
        let lines = (0..<rows).map { row in
            String((0..<columns).map { column -> Character in
                let hour = hour(of: column)
                let axis: Character = row == rows - 1 && current.map({ hour <= $0 }) ?? true ? "0" : "."
                let height = heights[hour]
                let level = Double(rows - row)
                if height >= level { return shown == hour ? "S" : "F" }
                if height > level - 1 { return parts[min(parts.count - 1, Int((height - (level - 1)) * Double(parts.count)))] }
                return axis
            })
        }
        return DotFigure(lines, colors: colors, shapes: shapes)
    }
}

/// 每一列是一周，自上而下按日历的一周排列，最右一列是本周；格子大小和颜色按当天用量在有用量日子里的四分位分四档。
/// 下方在每月第一周标出月份；柱状图正在画的那天满格标出，点按某一天选定，再点一次回到今天；悬停的那天换个颜色。
private struct UsageHeatmap: View {
    /// 日期与当天用量的对照，按当前的计量单位；没有用量的日子不在其中。
    let values: [String: Double]
    let weeks: Int
    let today: Date
    let tint: Color
    let shown: String
    @Binding var pinned: String?
    @State private var hovered: String?
    @Environment(\.self) private var environment

    var body: some View {
        let start = start()
        VStack(alignment: .leading, spacing: 4) {
            if weeks > 0 {
                DotMask(figure: figure(start: start))
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let point) = phase { hovered = key(at: point, start: start) } else { hovered = nil }
                            }
                            .onTapGesture { point in
                                let key = key(at: point, start: start)
                                pinned = pinned == key ? nil : key
                            }
                    }
                ZStack(alignment: .topLeading) {
                    ForEach(monthTicks(start: start), id: \.column) { tick in
                        axisLabel(tick.label).offset(x: CGFloat(tick.column) * DotMetrics.pitch)
                    }
                }
                .frame(width: CGFloat(weeks) * DotMetrics.pitch, height: labelHeight, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: labelHeight + 4 + DotMetrics.pitch * 7, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近一年每日用量热力图")
    }

    /// 指针下的那一天；落在图外或还没到的日子为 nil。
    private func key(at point: CGPoint, start: Date) -> String? {
        guard let hit = cell(at: point, columns: weeks, rows: 7) else { return nil }
        let date = UsageCalendar.add(hit.column * 7 + hit.row, to: start)
        return date <= today ? UsageCalendar.key(date) : nil
    }

    /// 最左一列那一周的第一天。
    private func start() -> Date {
        let calendar = Calendar.current
        let weekday = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        return UsageCalendar.add(-(weeks - 1) * 7 - weekday, to: today)
    }

    /// 含有某月 1 日的那一列标出月份；最左一列也标，挨得太近的跳过。
    private func monthTicks(start: Date) -> [(column: Int, label: String)] {
        var ticks: [(column: Int, label: String)] = []
        for column in 0..<weeks {
            let days = (0..<7).map { UsageCalendar.add(column * 7 + $0, to: start) }
            guard let first = column == 0 ? days[0] : days.first(where: { Calendar.current.component(.day, from: $0) == 1 }) else { continue }
            if let last = ticks.last, column - last.column < 3 {
                // 最左一列只是半个月，让给紧跟着的整月。
                if last.column == 0 { ticks.removeLast() } else { continue }
            }
            ticks.append((column, first.formatted(.dateTime.month(.abbreviated))))
        }
        return ticks
    }

    private func figure(start: Date) -> DotFigure {
        let used = values.values.filter { $0 > 0 }.sorted()
        func quantile(_ q: Double) -> Double { used.isEmpty ? 0 : used[min(used.count - 1, Int(Double(used.count) * q))] }
        let thresholds = [quantile(0.25), quantile(0.5), quantile(0.75)]
        let levels: [Character] = ["1", "2", "3", "4"]
        let tint = DotColor(tint.resolve(in: environment)), rule = DotColor(Theme.rule.resolve(in: environment))
        // 没用的日子也稍带一点主题色，和还没到的日子、热力图外的点阵分开；柱状图画的那天满格。
        var colors: [Character: DotColor] = ["0": rule.mixed(with: tint, by: 0.2), "S": tint]
        var shapes: [Character: Double] = ["0": 0.2, "S": 0.85]
        for (index, level) in levels.enumerated() {
            let t = Double(index + 1) / Double(levels.count)
            colors[level] = rule.mixed(with: tint, by: 0.35 + 0.65 * t)
            shapes[level] = 0.3 + 0.45 * t
        }
        // 悬停的那天大小不变，只换成文字色。
        let hover = DotColor(Color.primary.resolve(in: environment))
        let hoverMarks: [Character: Character] = ["0": "z", "1": "a", "2": "b", "3": "c", "4": "d"]
        for (base, mark) in hoverMarks {
            colors[mark] = hover
            shapes[mark] = shapes[base]
        }
        let lines = (0..<7).map { row in
            String((0..<weeks).map { column -> Character in
                let date = UsageCalendar.add(column * 7 + row, to: start)
                guard date <= today else { return "." }
                let key = UsageCalendar.key(date)
                if key == shown { return "S" }
                let value = values[key] ?? 0
                let base = value > 0 ? levels[thresholds.filter { value >= $0 }.count] : "0"
                return key == hovered ? hoverMarks[base]! : base
            })
        }
        return DotFigure(lines, colors: colors, shapes: shapes)
    }
}
