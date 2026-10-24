import SwiftUI

/// monitor 的窗口（docs/Monitor.md）：所有 monitor 共用这一种。Line 的就是收件箱，见 InboxPane；代理开的上面是来源、下面是事件时间线。
struct MonitorPane: View {
    let instance: RemotePluginInstance
    @Environment(AppModel.self) private var model

    var body: some View {
        if instance.config?.monitor?.system == "line" { InboxPane() } else { MonitorTimelinePane(instance: instance) }
    }
}

// MARK: - 代理开的 monitor

/// monitor.read 读到的代理开的 monitor。
private struct MonitorSnapshot: Decodable, Equatable {
    struct Source: Decodable, Equatable {
        let id: String
        let kind: String
        var command: String?
        var at: Double?
        var repeatEvery: String?
        var next: Double?
        var ended: Ended?
        enum CodingKeys: String, CodingKey { case id, kind, command, at, next, ended, repeatEvery = "repeat" }
    }
    struct Ended: Decodable, Equatable { let at: Double; let reason: String }
    struct Event: Decodable, Equatable, Identifiable {
        let seq: Int
        let at: Double
        let source: String
        let kind: String
        let text: String
        var id: Int { seq }
    }
    let title: String
    let target: String
    let sources: [Source]
    let status: String
    let wakesToday: Int
    let dailyWakes: Int
    let events: [Event]
}

private struct MonitorTimelinePane: View {
    let instance: RemotePluginInstance
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model
    @State private var snapshot: MonitorSnapshot?
    @State private var failure: String?

    private var targetTitle: String {
        guard let snapshot else { return "" }
        return area.instances.first { $0.id == snapshot.target }?.title ?? "代理"
    }

    private var header: PaneHeader {
        guard let snapshot else { return PaneHeader(title: instance.title, subtitle: "监视") }
        let status = snapshot.status == "ended" ? "已结束" : "运行中"
        return PaneHeader(title: instance.title, subtitle: "\(status) · 交给「\(targetTitle)」 · 今天唤醒 \(snapshot.wakesToday) 次")
    }

    var body: some View {
        PaneWindow(header: header, notice: failure.map(PaneNotice.failure), actions: PaneHeaderActions(groups: [[
            PaneHeaderAction(title: "停止监视", systemImage: "stop.circle", help: "停掉这个 monitor，时间线保留", tint: Theme.danger) { stop() },
        ]])) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let snapshot {
                        ForEach(snapshot.sources, id: \.id) { source in sourceBlock(source) }
                        // 事件最多几百条、每条可以很长，只建看得到的那些
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshot.events.reversed()) { event in eventRow(event) }
                        }
                    }
                }
                .padding(.horizontal, Metrics.padding)
                .padding(.bottom, Metrics.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } controls: { _ in
            EmptyView()
        }
        .task(id: model.monitorRevisions[instance.id, default: 0]) { await load() }
    }

    private func sourceBlock(_ source: MonitorSnapshot.Source) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.kind == "command" ? "命令" : "定时").font(Theme.status).foregroundStyle(.secondary)
            if let command = source.command {
                Text(command).font(Theme.code).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
            } else if let next = source.next ?? source.at {
                Text("\(InboxText.time(next))\(source.repeatEvery == "daily" ? "，每天" : source.repeatEvery == "weekly" ? "，每周" : "")")
                    .font(Theme.secondary)
            }
            if let ended = source.ended {
                Text("已结束：\(ended.reason)").font(Theme.status).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func eventRow(_ event: MonitorSnapshot.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(InboxText.clock(event.at)).font(Theme.status.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 40, alignment: .leading)
            Text(event.text)
                .font(event.kind == "event" ? Theme.code : Theme.secondary)
                .foregroundStyle(event.kind == "event" ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// 每次变化都整份重读：一阵连着来的变化稍等合成一次（新的一次会取消等着的这次），读回来没变就不换。
    private func load() async {
        guard let client = area.pluginClient else { return }
        if snapshot != nil {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        do {
            let read = try await client.request("/workspaces/\(area.id.pathComponent)/operations/monitor.read", method: "POST",
                                                body: ["instanceId": instance.id], as: MonitorSnapshot.self)
            guard !Task.isCancelled else { return }
            if read != snapshot { snapshot = read }
            failure = nil
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    private func stop() {
        guard let client = area.pluginClient else { return }
        Task {
            do { let _: JSON = try await client.request("/instances/\(instance.id.pathComponent)/archive", method: "POST", as: JSON.self) }
            catch { failure = error.localizedDescription }
        }
    }
}

// MARK: - Line 的收件箱

/// Line 的收件箱：上面是此刻等你的事项，下面是你离开那一段的时间线，回来后当简报看。审批与提问在这里直接回应，写回原线程所在的工作机。
private struct InboxPane: View {
    @Environment(AppModel.self) private var model
    @State private var failure: String?

    private var inbox: LineInbox? { model.lineInboxSnapshot }

    private var header: PaneHeader {
        let count = inbox?.waiting.count ?? 0
        var parts = [count == 0 ? "没有等你的事" : "\(count) 项等你"]
        if let until = inbox?.delegation.until, until > Date().timeIntervalSince1970 * 1000 { parts.append("托管到 \(InboxText.clock(until))") }
        if let minutes = inbox?.delegation.timeoutMinutes { parts.append("超时 \(minutes) 分钟交给 Line") }
        return PaneHeader(title: "收件箱", subtitle: parts.joined(separator: " · "))
    }

    var body: some View {
        PaneWindow(header: header, notice: failure.map(PaneNotice.failure),
                   actions: PaneHeaderActions(menus: AnyView(HostingMenu(delegation: inbox?.delegation, failure: $failure)))) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let inbox {
                            if !inbox.waiting.isEmpty { groupTitle("等你") }
                            ForEach(inbox.waiting) { item in InboxItemView(item: item, failure: $failure).id(item.id) }
                            if let period = inbox.period, !(inbox.awayTurns.isEmpty && inbox.records.isEmpty) {
                                awayTitle(period)
                                ForEach(awayEntries(inbox), id: \.id) { entry in
                                    switch entry.content {
                                    case .turn(let item): InboxItemView(item: item, failure: $failure).id(item.id)
                                    case .record(let record): RecordRow(record: record)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.padding)
                    .padding(.bottom, Metrics.padding)
                }
                .onChange(of: model.lineFocusItem) { _, item in
                    guard let item else { return }
                    withAnimation { proxy.scrollTo(item, anchor: .top) }
                    model.lineFocusItem = nil
                }
            }
        } controls: { _ in
            EmptyView()
        }
        .task { await model.refreshLineInbox() }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text).font(Theme.status.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }

    private func awayTitle(_ period: LineInbox.Period) -> some View {
        let minutes = Int(((period.until ?? Date().timeIntervalSince1970 * 1000) - period.since) / 60_000)
        let range = "\(InboxText.clock(period.since)) – \(period.until.map(InboxText.clock) ?? "现在")"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("离开期间").font(Theme.secondary.weight(.semibold))
            Text("\(range) · \(InboxText.duration(minutes))").font(Theme.status).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if period.until != nil { Text("简报在 Line 的对话里").font(Theme.status).foregroundStyle(.tertiary) }
        }
        .padding(.top, 14)
    }

    private struct AwayEntry {
        enum Content { case turn(LineInbox.Item), record(LineInbox.Record) }
        let id: String
        let at: Double
        let content: Content
    }

    private func awayEntries(_ inbox: LineInbox) -> [AwayEntry] {
        let turns = inbox.awayTurns.map { AwayEntry(id: $0.id, at: $0.at, content: .turn($0)) }
        let records = inbox.records.enumerated().map { AwayEntry(id: "record:\($0.offset)", at: $0.element.at, content: .record($0.element)) }
        return (turns + records).sorted { $0.at < $1.at }
    }
}

/// 收件箱里一项：类型图标、项目与线程、正文和按钮；审批与提问直接带回应卡片。
private struct InboxItemView: View {
    let item: LineInbox.Item
    @Binding var failure: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            kindIcon
            VStack(alignment: .leading, spacing: 3) {
                meta
                if let waiting = item.waiting, item.delegated == nil {
                    WaitingResponseCard(waiting: waiting, respond: { try await respond(waiting, $0) }, delegate: delegateAction, inset: false)
                } else {
                    Text(title).font(Theme.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty {
                        Text(detail).font(Theme.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = item.note {
                        Label { Text(note) } icon: { Image(systemName: "sparkles") }
                            .font(Theme.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    buttons
                }
            }
        }
        .padding(10)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var kindIcon: some View {
        let (symbol, tint): (String, Color) = switch item.kind {
        case "approval": ("checkmark.shield", Theme.warning)
        case "question": ("questionmark.bubble", Theme.warning)
        case "secret": ("key", Theme.warning)
        case "turn": ("checkmark.circle", Theme.unseen)
        case "failed", "preparation": ("exclamationmark.triangle", Theme.danger)
        default: ("bolt.horizontal", .secondary)
        }
        return Image(systemName: symbol)
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if item.own == true { chip("Line 发起") }
            if let project = item.workspace?.project.name { Text(project).fontWeight(.semibold) }
            if let thread = item.thread?.title { Text("·"); Text(thread).lineLimit(1) }
            Text("·"); Text(item.machine.name).lineLimit(1)
            if item.delegated != nil { chip("Line 处理中") }
            Spacer(minLength: 0)
            Text(InboxText.ago(item.at)).foregroundStyle(.tertiary)
        }
        .font(Theme.status)
        .foregroundStyle(.secondary)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(Theme.status.weight(.semibold)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var title: String {
        switch item.kind {
        case "turn": "回合结束"
        case "failed": "上一回合失败"
        case "preparation": "工作区准备失败"
        case "unreachable": "工作机「\(item.machine.name)」连不上"
        default: item.waiting.map { waiting in
            if waiting.isQuestion { return waiting.questions?.first?.question ?? "" }
            if waiting.isSecret { return (waiting.secrets ?? []).map(\.title).joined(separator: "、") }
            return waiting.target ?? ""
        } ?? item.text
        }
    }

    private var detail: String {
        switch item.kind {
        case "turn", "unreachable": ""
        case "approval", "question": item.delegated?.by == "timeout" ? "等了一阵没处理，按超时托管交给了 Line；你仍可以直接回应" : ""
        // 要几项时用途各写在卡片里
        case "secret": item.waiting?.secrets.flatMap { $0.count == 1 ? $0.first?.reason : nil } ?? ""
        default: item.text
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: Metrics.paneButtonGap / 2) {
            if item.kind == "turn" {
                Button("知道了") { run { try await model.lineInboxOperation("monitor.dismiss", ["item": .string(item.id)]) } }
                    .buttonStyle(PaneButtonStyle(text: true, foreground: .primary))
            }
            if item.kind == "failed", let thread = item.thread {
                Button("继续") { run { try await resume(thread.id) } }.buttonStyle(PaneButtonStyle(text: true, foreground: .primary))
            }
            Spacer(minLength: 0)
            if let delegateAction, item.waiting == nil {
                Button("交给 Line") { run(delegateAction) }.buttonStyle(PaneButtonStyle(text: true, foreground: .accentColor))
            }
        }
    }

    /// 能交给 Line、还没交出去的才有。
    private var delegateAction: (() async throws -> Void)? {
        guard item.delegable, item.delegated == nil else { return nil }
        let id = item.id
        return { try await model.lineInboxOperation("monitor.delegate", ["item": .string(id)]) }
    }

    private func respond(_ waiting: RemoteWaiting, _ reply: WaitingReply) async throws {
        guard let thread = item.thread, let client = model.client(forMachine: item.machine.id) else {
            throw KitedError(message: "连不上「\(item.machine.name)」，到原线程窗口里回应")
        }
        let _: JSON = try await client.request("/threads/\(thread.id.pathComponent)/waiting/\(waiting.id.pathComponent)", method: "POST",
                                               body: reply, as: JSON.self)
        await model.refreshLineInbox()
    }

    private func resume(_ thread: String) async throws {
        guard let client = model.client(forMachine: item.machine.id) else { throw KitedError(message: "连不上「\(item.machine.name)」") }
        try await client.post("/threads/\(thread.pathComponent)/resume")
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); failure = nil }
            catch { failure = error.localizedDescription }
        }
    }
}

/// 离开那一段里了结的一项：时刻、谁了结的和理由。
private struct RecordRow: View {
    let record: LineInbox.Record

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(InboxText.clock(record.at)).font(Theme.status.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                (Text(headline).fontWeight(.semibold).foregroundStyle(.primary) + Text(" · \(subject)"))
                    .font(Theme.secondary).foregroundStyle(.secondary)
                if let reason = record.reason { Text(reason).font(Theme.secondary).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
    }

    private var headline: String {
        switch record.outcome {
        case "handled":
            switch record.decision {
            case "once": "Line 批准了这一次"
            case "deny": "Line 拒绝了"
            case "answered": "Line 回答了"
            default: "Line 处理了"
            }
        case "left": "Line 留给你"
        default:
            switch record.item.kind {
            case "approval", "question", "secret": "已回应"
            case "unreachable": "恢复连接"
            case "turn": "线程开始了新一轮"
            default: "已解除"
            }
        }
    }

    private var subject: String {
        let item = record.item
        let place = [item.workspace?.project.name, item.thread.map { "「\($0.title)」" }].compactMap { $0 }.joined()
        return place.isEmpty ? item.machine.name : place
    }
}

/// 收件箱标题栏的托管菜单：按时段托管与超时托管可以同时开。
private struct HostingMenu: View {
    let delegation: LineInbox.Delegation?
    @Binding var failure: String?
    @Environment(AppModel.self) private var model

    private var now: Double { Date().timeIntervalSince1970 * 1000 }
    private var periodOn: Bool { (delegation?.until ?? 0) > now }
    private var timeoutOn: Bool { delegation?.timeoutMinutes != nil }

    var body: some View {
        PaneHeaderButtonGroup(selected: periodOn || timeoutOn) {
            Menu {
                Section("按时段托管：这段时间新进的事项交给 Line") {
                    ForEach([30, 60, 120], id: \.self) { minutes in
                        Button(minutes < 60 ? "接下来 \(minutes) 分钟" : "接下来 \(minutes / 60) 小时") {
                            set(["until": .number(now + Double(minutes) * 60_000)])
                        }
                    }
                    Button("到今天结束") {
                        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400).timeIntervalSince1970 * 1000
                        set(["until": .number(end)])
                    }
                    if periodOn { Button("结束按时段托管") { set(["until": .null]) } }
                }
                Section("超时托管：审批和提问等你多久没处理就交给 Line") {
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button {
                            set(["timeoutMinutes": .number(Double(minutes))])
                        } label: {
                            if delegation?.timeoutMinutes == minutes { Label("\(minutes) 分钟", systemImage: "checkmark") } else { Text("\(minutes) 分钟") }
                        }
                    }
                    if timeoutOn { Button("关闭超时托管") { set(["timeoutMinutes": .null]) } }
                }
            } label: {
                PaneButtonLabel("托管", systemImage: "hand.raised")
            }
            .help("托管：Line 替你处理收件箱里它能处理的事；不会替你「允许并记住」，拿不准的留给你")
        }
    }

    private func set(_ body: [String: JSON]) {
        Task {
            do { try await model.lineInboxOperation("monitor.hosting", body); failure = nil }
            catch { failure = error.localizedDescription }
        }
    }
}

/// 收件箱里的时间写法：工作机给的是毫秒。
enum InboxText {
    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
    static func clock(_ ms: Double) -> String { date(ms).formatted(date: .omitted, time: .shortened) }
    static func time(_ ms: Double) -> String { date(ms).formatted(date: .abbreviated, time: .shortened) }
    static func ago(_ ms: Double) -> String { date(ms).formatted(.relative(presentation: .named)) }
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(max(minutes, 1)) 分钟" : minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
