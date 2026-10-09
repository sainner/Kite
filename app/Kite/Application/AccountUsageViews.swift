import SwiftUI

extension ModelAccount.Quota {
    /// 重置的时刻：一天内按剩余时长说，一周内说星期几，再远写日期。
    func resetMoment(now: Double) -> String? {
        guard let resetsAt else { return nil }
        let minutes = max(1, Int(((resetsAt - now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) 分钟后" }
        if minutes < 24 * 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60) 小时后" : "\(minutes / 60) 小时 \(rest) 分后"
        }
        let date = Date(timeIntervalSince1970: resetsAt)
        let style: Date.FormatStyle = minutes < 6 * 24 * 60 ? .dateTime.weekday(.abbreviated).hour().minute()
            : .dateTime.month().day().hour().minute()
        return date.formatted(style)
    }

    func resetText(now: Double) -> String? {
        resetMoment(now: now).map { $0.hasSuffix("后") ? "\($0)重置" : "\($0) 重置" }
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
struct AccountQuotaRing: View {
    let quotas: [ModelAccount.Quota]
    let stale: Bool
    @State private var hovering = false
    private var lineWidth: CGFloat { quotas.count > 1 ? 2.5 : 3 }

    var body: some View {
        let rings = Array(quotas.prefix(2))
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
            .blur(radius: hovering ? 2.5 : 0)
            .opacity(hovering ? 0.3 : 1)
            .overlay {
                if let quota = rings.first {
                    Text(quota.isExpired(now: now) ? "–" : String(Int((quota.remaining * 100).rounded())))
                        .font(Theme.ringValue)
                        .foregroundStyle(quota.tint(stale: stale, now: now))
                        .fixedSize()
                        .opacity(hovering ? 1 : 0)
                }
            }
        }
        .paneHeaderRing(lineWidth: lineWidth)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeInOut(duration: 0.2)) { hovering = inside } }
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
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

/// 用量统计：近一年的热力图、某一天的 24 小时柱状图与几项汇总。两张图画在窗口的点阵上：
/// 热力图一列一周，宽度放得下几列就画最近几周；柱状图一小时一根，宽处每小时占几列。
struct AccountUsageSection: View {
    let usage: ModelAccount.Usage
    let stale: Bool
    /// 日期与 token 数的对照；没有记录的日子是零。
    private let tokens: [String: Double]
    /// 日期与按小时分布的对照，只有本机有记录的日子。
    private let hours: [String: [Double]]
    /// 柱状图画的那天：热力图上悬停的优先，其次是点按选定的，都没有时是今天。
    @State private var hoveredDay: String?
    @State private var pinnedDay: String?
    /// 柱状图上悬停的小时优先，其次是点按选定的；选定的只属于当时那一天。
    @State private var hoveredHour: Int?
    @State private var pinnedHour: PinnedHour?
    /// 一行摆得下几格点阵；量到宽度之前是 0，图先不画。
    @State private var columns = 0

    private struct PinnedHour { let day: String; let hour: Int }

    init(usage: ModelAccount.Usage, stale: Bool) {
        self.usage = usage
        self.stale = stale
        tokens = Dictionary(usage.days.map { ($0.date, $0.tokens) }, uniquingKeysWith: +)
        hours = Dictionary(usage.days.compactMap { day in day.hours.flatMap { $0.count == 24 ? (day.date, $0) : nil } },
                           uniquingKeysWith: { first, _ in first })
    }

    private var tint: Color { stale ? .secondary : .accentColor }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let today = Calendar.current.startOfDay(for: context.date)
            let day = hoveredDay ?? pinnedDay ?? UsageCalendar.key(today)
            let pinned = pinnedHour.flatMap { $0.day == day ? $0.hour : nil }
            let hour = hoveredHour ?? pinned
            VStack(alignment: .leading, spacing: DotMetrics.module * 2) {
                UsageHeatmap(tokens: tokens, weeks: min(53, columns), today: today, tint: tint, shown: day,
                             hovered: $hoveredDay, pinned: $pinnedDay)
                VStack(alignment: .leading, spacing: DotMetrics.module) {
                    readout(day, hour: hour, today: today)
                    UsageHours(hours: hours[day], total: tokens[day] ?? 0,
                               current: day == UsageCalendar.key(today) ? Calendar.current.component(.hour, from: context.date) : nil,
                               columns: columns, tint: tint, shown: hour, pinned: pinned, hovered: $hoveredHour) { hour in
                        pinnedHour = hour.map { PinnedHour(day: day, hour: $0) }
                    }
                    // 上游只给整个账号按天的合计，按小时的分布只有本机记录，两者可能对不上。
                    if usage.scope == "account", hours[day] != nil {
                        Text("按小时只含这台工作机的记录").font(Theme.status).foregroundStyle(.tertiary)
                    }
                }
                summary(today: today)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: Int.self) { Int($0.size.width / DotMetrics.pitch) } action: { columns = $0 }
    }

    /// 柱状图的标题行：那天的日期和用量，选中某小时时是那一小时的；右边写柱子顶格代表多少。
    private func readout(_ key: String, hour: Int?, today: Date) -> some View {
        let name = UsageCalendar.date(key).map {
            Calendar.current.isDate($0, inSameDayAs: today) ? "今天" : $0.formatted(.dateTime.month().day().weekday(.abbreviated))
        } ?? key
        let detail = hour.map { "\($0):00–\($0 + 1):00 · \(Self.format(hours[key]?[$0] ?? 0)) token" }
            ?? "\(Self.format(tokens[key] ?? 0)) token"
        let peak = hours[key]?.max() ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(Theme.secondary.weight(.medium))
            Text(detail).font(Theme.caption).foregroundStyle(.secondary)
            Spacer(minLength: DotMetrics.module)
            if peak > 0 {
                Text("最高 \(Self.format(peak))/时").font(Theme.status).foregroundStyle(.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    private func summary(today: Date) -> some View {
        let week = (0..<7).reduce(0.0) { sum, offset in
            sum + (tokens[UsageCalendar.key(UsageCalendar.add(-offset, to: today))] ?? 0)
        }
        let peak = usage.days.max { $0.tokens < $1.tokens }
        // 连续天数从今天往前数；今天还没用时从昨天数起。
        var streak = 0
        var cursor = (tokens[UsageCalendar.key(today)] ?? 0) > 0 ? today : UsageCalendar.add(-1, to: today)
        while (tokens[UsageCalendar.key(cursor)] ?? 0) > 0 {
            streak += 1
            cursor = UsageCalendar.add(-1, to: cursor)
        }
        let items: [(String, String, String?)] = [
            ("近 7 天", Self.format(week), nil),
            ("累计", Self.format(usage.lifetimeTokens), usage.scope == "account" ? "整个账号，含其他设备" : "这台工作机的记录"),
            ("单日峰值", peak.map { Self.format($0.tokens) } ?? "—",
             peak.flatMap { UsageCalendar.date($0.date)?.formatted(.dateTime.month().day()) }),
            ("连续使用", "\(streak) 天", nil),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: DotMetrics.module * 8), spacing: DotMetrics.module * 2, alignment: .topLeading)],
                         alignment: .leading, spacing: DotMetrics.module * 2) {
            ForEach(items, id: \.0) { title, value, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.caption).foregroundStyle(.secondary)
                    Text(value).font(Theme.heading2).monospacedDigit()
                    if let note { Text(note).font(Theme.status).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    /// token 数按本地习惯缩写，例如 4358万、261亿。
    static func format(_ tokens: Double) -> String {
        Int(tokens.rounded()).formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
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
private let labelHeight = DotMetrics.pitch * 1.5

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
/// 柱高按当天最多的那一小时折算成六格，顶格按零头长一部分，最底一行是轴；今天还没到的小时不画轴。
/// 下方每 6 小时标一次时刻；悬停或点按某一段看那一小时。
private struct UsageHours: View {
    let hours: [Double]?
    /// 当天合计；有用量却没有按小时的记录时在图里说明。
    let total: Double
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

    private static let rows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if columns > 0 {
                DotMask(figure: figure())
                    .overlay {
                        if hours == nil, total > 0 {
                            Text("这一天没有本机的按小时记录").font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
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
        .frame(maxWidth: .infinity, minHeight: DotMetrics.pitch * CGFloat(Self.rows) + 4 + labelHeight, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当天每小时用量")
    }

    /// 这一列的中点落在哪一小时。
    private func hour(of column: Int) -> Int {
        min(23, Int((Double(column) + 0.5) * 24 / Double(columns)))
    }

    /// 指针下的那一小时；还没到的小时为 nil。
    private func hour(at point: CGPoint) -> Int? {
        guard let hit = cell(at: point, columns: columns, rows: Self.rows) else { return nil }
        let hour = hour(of: hit.column)
        return current.map { hour <= $0 } ?? true ? hour : nil
    }

    private func figure() -> DotFigure {
        let rows = Self.rows
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
/// 上方在每月第一周标出月份；柱状图正在画的那天满格标出，悬停看某一天，点按选定。
private struct UsageHeatmap: View {
    let tokens: [String: Double]
    let weeks: Int
    let today: Date
    let tint: Color
    let shown: String
    @Binding var hovered: String?
    @Binding var pinned: String?
    @Environment(\.self) private var environment

    var body: some View {
        let start = start()
        let date = { (column: Int, row: Int) in UsageCalendar.add(column * 7 + row, to: start) }
        VStack(alignment: .leading, spacing: 4) {
            if weeks > 0 {
                ZStack(alignment: .topLeading) {
                    ForEach(monthTicks(start: start), id: \.column) { tick in
                        axisLabel(tick.label).offset(x: CGFloat(tick.column) * DotMetrics.pitch)
                    }
                }
                .frame(width: CGFloat(weeks) * DotMetrics.pitch, height: labelHeight, alignment: .topLeading)
                DotMask(figure: figure(start: start))
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let point) = phase, let hit = cell(at: point, columns: weeks, rows: 7),
                                   date(hit.column, hit.row) <= today {
                                    hovered = UsageCalendar.key(date(hit.column, hit.row))
                                } else {
                                    hovered = nil
                                }
                            }
                            .onTapGesture { point in
                                let key = cell(at: point, columns: weeks, rows: 7)
                                    .map { date($0.column, $0.row) }.flatMap { $0 <= today ? UsageCalendar.key($0) : nil }
                                pinned = pinned == key ? nil : key
                            }
                    }
            }
        }
        .frame(maxWidth: .infinity, minHeight: labelHeight + 4 + DotMetrics.pitch * 7, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近一年每日用量热力图")
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
        let values = tokens.values.filter { $0 > 0 }.sorted()
        func quantile(_ q: Double) -> Double { values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * q))] }
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
        let lines = (0..<7).map { row in
            String((0..<weeks).map { column -> Character in
                let date = UsageCalendar.add(column * 7 + row, to: start)
                guard date <= today else { return "." }
                let key = UsageCalendar.key(date)
                if key == shown { return "S" }
                guard let value = tokens[key], value > 0 else { return "0" }
                return levels[thresholds.filter { value >= $0 }.count]
            })
        }
        return DotFigure(lines, colors: colors, shapes: shapes)
    }
}
