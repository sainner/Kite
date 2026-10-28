import SwiftUI

/// 一个真实线程；显示记录的事实来自 kited，本地只保留草稿与尚未确认的发送。
@Observable
final class WorkThread: Identifiable {
    /// 草稿的 id 是本地的，工作机建好实例后换成实例 ID，见 adopt。
    private(set) var id: String
    let tint: Color
    var title: String
    var project: String
    var transcript: Transcript {
        didSet { summarizeTranscript() }
    }
    /// 从 transcript 摘出的几项，只在变了时写：窗口、标题栏和控制区只读这些，不跟着收发消息和每一次流式刷新重算。
    private(set) var hasTranscript = false
    private(set) var transcriptRoot = ""
    var draft = "" {
        didSet { if draft != oldValue { usedAt = .now } }
    }
    /// 本机上人最近一次在这个会话里打字或发消息的时候，指认放进哪个对话按它挑（WorkArea.pointingThread）。
    @ObservationIgnored private(set) var usedAt: Date?
    /// 输入框里待发的附件，按选的先后；发送时连同草稿一起带走。
    private(set) var draftAttachments: [DraftAttachment] = []
    /// 所属工作区；附件按它上传、读取。
    let workspaceID: String
    /// 草稿里选好的角色；已有代理的角色记在实例配置里。
    var role: AgentRole?
    var draftChoice: DraftAgentChoice?
    /// 草稿的模型目录与各角色可开的工具，按工作区读取。
    var agentOptions: AgentOptions?
    var configuringTemplate = false
    var state: RemoteState? {
        didSet { if let waiting { answers.adopt(waiting) } }
    }
    /// 在等的那一项的作答，回应卡片和输入区共用，见 WaitingAnswers。
    let answers = WaitingAnswers()
    var agentCapabilities: AgentCapabilities?
    var connected = false
    /// 收到过工作机发来的完整历史。已有代理在这之前对话是空的，只是还没读出来。
    private(set) var historyLoaded = false
    var error: String?
    /// 还没有消息时读角色列表或套用角色失败的说明，见 AppModel.loadNewThreadRoles。
    var roleError: String?
    private(set) var regeneratingTitle = false
    /// 选好的压缩起点（一条人发消息的 id），等在这条或之后的消息上选终点。
    var compactionStart: String?
    /// 核对过、等确认的回退，见 RewindConfirmation。
    var rewindRequest: RewindRequest?
    /// 调试模式：不为空时窗口的对话区换成原始记录，见 RawTranscript。
    var raw: RawTranscript?
    private(set) var client: KitedClient?
    // 未识别的块保留位置，后续同 id 的记录替换仍沿用服务端顺序。
    private var remoteRecords: [RemoteRecord] = []
    private var visiblePositions: [Int: Int] = [:]
    private var streamingChanges: Set<Int> = []
    private var streamingRefresh: Task<Void, Never>?
    /// 主对话里 agent 的话收到的字不当场全给，按节奏放，见 StreamPacer；pacing 是放字的循环，放完就停。
    private var pacer = StreamPacer()
    private var pacing: Task<Void, Never>?
    private var positions: [String: Int] = [:]
    /// 线程流最近处理过的事件的 cursor：重连时带上，工作机只补之后变过的记录；副本可能不全时清掉，下次整份重读。
    private var cursor: String?
    private var received: Set<String> = []
    private var pending: [RemoteInput] = []
    private var outbox: [Message] = []
    private(set) var failed: Set<String> = []
    private var sending: Set<String> = []
    /// 撤回请求还在路上的消息：按住上键连发、连点撤回时不再撤一次。
    private var cancelling: Set<String> = []
    private var returned: Set<String> = []
    /// 收起回应卡片时发的消息跳过哪一项等待，按消息 ID 记，重试照样带上。
    private var skips: [String: String] = [:]
    private var stopRequest: StopRequest?
    private(set) var stopping = false

    var isDraft: Bool { client == nil }
    /// 还没有消息的代理，窗口铺满点阵签名（NewThreadStage）。已有代理的历史还没到时不算，免得签名长出来又马上收回。
    var isInitial: Bool { !hasTranscript && (isDraft || historyLoaded) }
    var canSend: Bool { stopRequest == nil && connected && (state?.capabilities.send ?? isDraft) }
    var canResume: Bool { stopRequest == nil && connected && state?.capabilities.resume == true }
    var canStop: Bool { connected && !stopping && showStop }
    var hasUnconfirmedStop: Bool { stopRequest != nil }
    var showStop: Bool { stopRequest != nil || !outbox.isEmpty || state?.capabilities.interrupt == true }
    var canCancel: Bool { stopRequest == nil && connected && state?.capabilities.cancel == true }
    var canCompact: Bool { !isDraft && connected && state?.capabilities.compact == true }
    /// 压缩全部要有内容、空闲着：工作机只在空闲时压缩。
    var canCompactAll: Bool { canCompact && hasTranscript && !showStop && state?.compacting != true }
    var canRewind: Bool { !isDraft && connected && state?.capabilities.rewind == true }
    var canRegenerateTitle: Bool { !isDraft && connected && state?.status == "open" && !regeneratingTitle }
    /// 圆环的阶段：在等人回应时是 waiting，圆环换警示黄、明暗起伏；正在压缩是 running 的子状态 compacting，弧画满再收掉。
    var statusPhase: String {
        if stopping { return "stopping" }
        if awaiting != nil { return "waiting" }
        if state?.phase == "running" && state?.compacting == true { return "compacting" }
        return state?.phase ?? "idle"
    }
    /// 在等人回应的是哪一类：卡着回合的审批；没回应的提问、密钥请求不阻塞，代理停下以后才算在等（同工作机的活动摘要）。
    var awaiting: String? { state?.waiting?.kind ?? (state?.phase == "idle" ? state?.asks?.first?.kind : nil) }
    /// 会话自身的错误：本地操作失败，或工作机报回的错误（含上一轮失败的说明）。
    /// 作为窗口信息区的提示盖住圆环，圆环的说明里不再重复。
    var problem: String? { error ?? state?.error ?? (state?.status == "failed" ? "工作区准备失败" : nil) }
    var statusLabel: String {
        if isDraft && state == nil { return "空闲" }
        guard connected else { return "正在连接" }
        if stopping { return "正在停止" }
        if state?.compacting == true { return "正在压缩上下文" }
        switch state?.status {
        case "preparing": return "正在准备工作区"
        case "archived": return "已归档"
        case "handing_off": return "正在交给另一台工作机"
        case "transferred": return "已流转到另一台工作机"
        default: break
        }
        return Self.turnStatus(phase: state?.phase, outcome: state?.lastOutcome?.kind, waitingForResume: state?.waitingForResume == true,
                               waiting: awaiting)
    }

    /// 回合的状态文字，标题栏圆环与停靠栏共用：先看是否在跑，再看上一轮结果，等待继续优先级最低。
    static func turnStatus(phase: String?, outcome: String?, waitingForResume: Bool, unseen: Bool = false, waiting: String? = nil) -> String {
        if let waiting { return RemoteWaiting.title(of: waiting) }
        return switch phase {
        case "running": "运行中"
        case "stopping": "正在停止"
        case "finishing": "正在收尾"
        default:
            switch outcome {
            case "failed": "本轮失败"
            case "interrupted": "已停止"
            case "completed": unseen ? "已完成，未查看" : "已完成"
            default: waitingForResume ? "等待继续" : "空闲"
            }
        }
    }

    init(remote: RemoteThread, instance: RemotePluginInstance, workspace: WorkspaceInfo, project: String, client: KitedClient) {
        id = remote.instanceId
        tint = Palette.breeze
        title = instance.title
        self.project = project
        self.client = client
        workspaceID = workspace.id
        transcript = Transcript(root: workspace.cwd)
        summarizeTranscript()
    }

    /// 尚未创建的会话沿用同一套工作区，只保存草稿，不制造后端记录。id 由本机定，就是将来代理实例的 ID（见 WorkArea.draftPane）。
    init(workspace: String, workspaceID: String, project: String, id: String) {
        self.id = id
        self.workspaceID = workspaceID
        tint = Palette.breeze
        title = "新代理"
        self.project = project
        client = nil
        transcript = Transcript(root: workspace)
        summarizeTranscript()
    }

    private func summarizeTranscript() {
        let has = !transcript.items.isEmpty || !transcript.pending.isEmpty
        if hasTranscript != has { hasTranscript = has }
        if transcriptRoot != transcript.root { transcriptRoot = transcript.root }
    }

    /// 对话里的附件到哪去取：连着工作机时是这个工作区。
    var attachmentSource: AttachmentSource? { client.map { AttachmentSource(client: $0, workspace: workspaceID) } }

    // MARK: - 待发的附件

    /// 选好的文件放进输入框，当场开始传到 source。
    func attach(_ items: [DraftAttachment], to source: AttachmentSource) {
        for item in items {
            draftAttachments.append(item)
            item.upload(to: source)
        }
    }

    /// 输入框里还没发的字和附件抄给另一个会话（清空上下文时的新代理草稿），附件接着传；对方输入框里已有字时接在后面。
    /// 自己的留着：清空时这个会话正原地淡出，输入框不先变空；归档不成放回来时也还在。
    func copyDraft(to other: WorkThread) {
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            other.draft = other.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draft : other.draft + "\n" + draft
        }
        other.draftAttachments += draftAttachments.filter { item in !other.draftAttachments.contains { $0 === item } }
    }

    /// 还能放几个：一条消息最多带 maxAttachments 个。
    var attachmentRoom: Int { max(Self.maxAttachments - draftAttachments.count, 0) }

    func removeAttachment(_ item: DraftAttachment) {
        draftAttachments.removeAll { $0 === item }
        item.discard()
    }

    /// 都传好了、没超过上限：可以发了。退回输入框的几条加起来可能超过上限，拿掉几个才能发。
    var attachmentsReady: Bool { draftAttachments.count <= Self.maxAttachments && draftAttachments.allSatisfy { $0.uploaded != nil } }

    /// 发送时带走输入框里的附件，连同它们要接在正文后面的说明。
    func takeAttachments() -> (attachments: [Attachment], notes: [String]) {
        let taken = (draftAttachments.compactMap(\.uploaded), draftAttachments.compactMap(\.note))
        for item in draftAttachments { item.sent() }
        draftAttachments = []
        return taken
    }

    /// 同 kited 的 MAX_MESSAGE_ATTACHMENTS。
    static let maxAttachments = 10

    func use(_ client: KitedClient) {
        guard self.client != client else { return }
        self.client = client
        connected = false
    }

    /// 草稿发出后工作机建好了实例：同一个对象接着当这个代理，窗口里的对话、排着的第一条消息和动画都不换。
    /// 角色与参数此后以实例配置为准；接着 use 工作机连接，就不再是草稿。root 是工作区目录，新建工作区时本机先建的草稿还不知道。
    func adopt(instance: String, root: String) {
        guard isDraft else { return }
        id = instance
        if transcript.root != root { transcript.root = root }
        role = nil
        draftChoice = nil
        agentOptions = nil
    }

    func observe() async {
        guard let client else { return }
        defer { if self.client == client { flushStreaming(); finishPacing(); connected = false } }
        while !Task.isCancelled && self.client == client {
            do {
                try await client.events(scope: .thread(id), after: cursor) { event in
                    try Task.checkCancellation()
                    guard self.client == client else { return }
                    do { try self.apply(event) } catch { self.cursor = nil; throw error }
                    if event.threadId == self.id, let cursor = event.cursor { self.cursor = cursor }
                }
            } catch {
                if Task.isCancelled || self.client != client { return }
                flushStreaming()
                finishPacing()
                connected = false
                self.error = "连接中断，正在重连：\(error.localizedDescription)"
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func apply(_ event: RemoteEvent) throws {
        guard event.threadId == id else { return }
        raw?.poke()
        if event.type != "thread.record.delta" { flushStreaming() }
        var recordsChanged = false
        switch event.type {
        case "thread.history":
            guard event.version == 1 else { throw KitedError(message: "会话协议版本不兼容") }
            // 换了快照（重连、回退）：正在放的话照收到的显示，下面整份重排
            stopPacing()
            let history = event.records ?? []
            if let since = event.since {
                // 只补了变化：按 id 换掉或追加在末尾，与整份快照一致（docs/会话显示协议.md 的 cursor）
                guard since == cursor else { throw KitedError(message: "历史与本地副本对不上，重新同步") }
                for record in history { upsert(record) }
                recordsChanged = !history.isEmpty
            } else {
                remoteRecords = []
                positions = [:]
                received = []
                for record in history { upsert(record) }
                recordsChanged = true
            }
            TimingTrace.mark("会话 \(title) 历史已解码：\(history.count) 条\(event.since == nil ? "" : "（只补变化）")")
            pending = event.pending ?? []
            state = event.state
            connected = true
            historyLoaded = true
            error = nil
        case "thread.record":
            guard let record = event.record else { return }
            if let index = upsert(record) {
                // 压缩记录的变化（撤销）牵动整段收起，重新派生。
                if record.block.type != "compacted", let visibleIndex = visiblePositions[index], let visible = record.record {
                    transcript.replaceRecord(at: visibleIndex, with: paced(index, visible))
                } else {
                    recordsChanged = true
                }
            } else {
                recordsChanged = true
            }
            if ["human", "agent"].contains(record.block.type), let id = record.block.id {
                pending.removeAll { $0.id == id }
            }
        case "thread.record.delta":
            guard let delta = event.delta, let index = positions[delta.id] else {
                throw KitedError(message: "流式记录缺失，重新同步")
            }
            let shown = remoteRecords[index].block.text?.utf16.count ?? 0
            try remoteRecords[index].apply(delta)
            if remoteRecords[index].block.type == "text", remoteRecords[index].parent == nil {
                pace(index, shown: shown)
                return
            }
            streamingChanges.insert(index)
            if streamingRefresh == nil {
                streamingRefresh = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                    self?.flushStreaming()
                }
            }
            return
        case "thread.pending": pending = event.pending ?? []
        case "thread.state": state = event.state
        case "thread.error": error = event.message
        default: return
        }
        pending.removeAll { returned.contains($0.id) }
        let pendingIDs = Set(pending.map(\.id))
        let confirmed = Set(outbox.map(\.id)).union(failed).filter { received.contains($0) || pendingIDs.contains($0) }
        outbox.removeAll { confirmed.contains($0.id) }
        if !failed.isDisjoint(with: confirmed) { error = nil }
        failed.subtract(confirmed)
        render(recordsChanged: recordsChanged)
    }

    /// 按 id 换掉已有的记录，没有的追加在末尾；返回换掉的那条的位置。
    @discardableResult private func upsert(_ record: RemoteRecord) -> Int? {
        if ["human", "agent"].contains(record.block.type), let id = record.block.id { received.insert(id) }
        if let index = positions[record.id] {
            remoteRecords[index] = record
            return index
        }
        positions[record.id] = remoteRecords.count
        remoteRecords.append(record)
        return nil
    }

    private func flushStreaming() {
        streamingRefresh?.cancel()
        streamingRefresh = nil
        for index in streamingChanges.sorted() {
            guard let visibleIndex = visiblePositions[index], let record = remoteRecords[index].record else { continue }
            transcript.replaceRecord(at: visibleIndex, with: record)
        }
        streamingChanges.removeAll(keepingCapacity: true)
    }

    /// 主对话里 agent 的话收到了字（之前显示到 shown）：交给放字的循环，没在跑就起一个。
    private func pace(_ index: Int, shown: Int) {
        pacer.received(index, shown: shown)
        guard pacing == nil else { return }
        pacing = Task { [weak self] in
            var last = ContinuousClock.now
            while true {
                do { try await Task.sleep(for: StreamPacer.tick) } catch { return }
                guard let self else { return }
                let now = ContinuousClock.now
                let more = stepPacing((now - last) / .seconds(1))
                last = now
                if !more {
                    pacing = nil
                    return
                }
            }
        }
    }

    /// 放一次字：放了字和放完了的话换成新的样子。都放完了返回 false。
    private func stepPacing(_ elapsed: Double) -> Bool {
        let moved = pacer.advance(elapsed) { index in
            guard remoteRecords.indices.contains(index), let text = remoteRecords[index].block.text else { return nil }
            return (text, remoteRecords[index].generation)
        }
        for index in moved {
            guard let visibleIndex = visiblePositions[index], let record = remoteRecords[index].record else { continue }
            transcript.replaceRecord(at: visibleIndex, with: paced(index, record))
        }
        return !pacer.isEmpty
    }

    /// 不再放慢：停掉循环。接着整份重排的（换了快照）用它，不用一条条换。
    private func stopPacing() {
        pacing?.cancel()
        pacing = nil
        pacer.reset()
    }

    /// 不再放慢，正在放的话剩下的字当场给出（断了连接，等重连的快照之前照收到的显示）。
    private func finishPacing() {
        let indices = pacer.indices
        stopPacing()
        for index in indices {
            guard remoteRecords.indices.contains(index), let visibleIndex = visiblePositions[index],
                  let record = remoteRecords[index].record else { continue }
            transcript.replaceRecord(at: visibleIndex, with: record)
        }
    }

    /// 正在放的话只给放出来的那截；放完之前一直算生成中，行照生成中的样子画（补齐半截的 Markdown、新字淡入）。
    private func paced(_ index: Int, _ record: Record) -> Record {
        guard let shown = pacer.shown(index), case .text(let text) = record.block else { return record }
        var record = record
        record.block = .text(StreamPacer.prefix(text, shown))
        record.generation = "streaming"
        return record
    }

    private func render(recordsChanged: Bool = false) {
        let running = state?.busy == true && ["running", "stopping", "finishing"].contains(state?.phase ?? "")
        let compacting = running && state?.compacting == true
        let messages = pending.compactMap(\.queued) + outbox.map { Queued(message: $0) }
        if recordsChanged {
            var records: [Record] = []
            visiblePositions.removeAll(keepingCapacity: true)
            // 每次压缩收起首尾记录之间的一段；后来的压缩包含先前的，覆盖它的收起。
            var folds: [Int: String] = [:]
            for remote in remoteRecords where remote.block.type == "compacted" && remote.block.reverted != true {
                guard let fold = remote.block.id, let from = remote.block.from, let through = remote.block.through,
                      let first = positions[from], let last = positions[through], first <= last else { continue }
                for index in first...last { folds[index] = fold }
            }
            for (index, remote) in remoteRecords.enumerated() {
                guard var record = remote.record else { continue }
                if record.parent == nil { record.folded = folds[index] }
                visiblePositions[index] = records.count
                records.append(paced(index, record))
            }
            transcript = Transcript(root: transcript.root, records: records, running: running, compacting: compacting, pending: messages)
        } else {
            if transcript.running != running { transcript.running = running }
            if transcript.compacting != compacting { transcript.compacting = compacting }
            transcript.pending = messages
        }
    }

    /// 草稿没有连接，排着的第一条消息由创建请求带上（见 ThreadPane.send），不在这里投递。
    func send(_ message: Message) -> Bool {
        #if DEBUG && KITE_LAYOUT_AUDIT
        if let startsTurn = PerfProbe.hold(message, in: self) { return startsTurn }
        #endif
        guard canSend else { return false }
        // 停下后留在队列里的不会自己开回合，同 kited 的投影
        let startsTurn = !transcript.running && (transcript.pending.isEmpty || state?.waitingForResume == true)
        var queued = message
        queued.midTurn = !startsTurn
        outbox.append(queued)
        render()
        deliver(message)
        return startsTurn
    }

    func retry(_ message: Message) { deliver(message) }

    /// 草稿的第一条消息随创建请求发出，请求失败时：还是草稿就撤回消息，字退回输入框，好改了角色或参数再发；
    /// 工作机已经建好代理的，照普通消息标成未确认，点消息重试。
    func firstMessageFailed(_ message: Message, error: String) {
        if isDraft {
            outbox.removeAll { $0.id == message.id }
            render()
            restoreDraft([message])
            self.error = error
        } else if outbox.contains(where: { $0.id == message.id }) {
            markUnconfirmed(message, error)
        }
    }

    /// 发送没得到确认、工作机也还没收到这条时，标成未确认，点消息重试。
    private func markUnconfirmed(_ message: Message, _ error: String) {
        guard !received.contains(message.id), !pending.contains(where: { $0.id == message.id }) else { return }
        failed.insert(message.id)
        self.error = "发送未确认，点消息重试：\(error)"
    }

    private func deliver(_ message: Message) {
        guard let client, stopRequest == nil, !returned.contains(message.id), !sending.contains(message.id) else { return }
        sending.insert(message.id)
        failed.remove(message.id)
        error = nil
        Task {
            defer { sending.remove(message.id) }
            do {
                try await client.post("/threads/\(id)/messages", body: SendBody(id: message.id, text: message.typed,
                                                                                 attachments: message.attachments.isEmpty ? nil : message.attachments.map(\.id),
                                                                                 skipWaiting: skips[message.id]))
                skips[message.id] = nil
            } catch {
                guard !returned.contains(message.id) else { return }
                markUnconfirmed(message, error.localizedDescription)
            }
        }
    }

    /// 排在最后、此刻能撤回的那条人发的消息（正在发出的等它有了结果）；输入框空着时按上键撤回它，见 ThreadControlsModel.keyAction。
    var lastWithdrawable: Message? {
        guard canCancel else { return nil }
        return transcript.pending.last { $0.sender == nil && !sending.contains($0.id) && !cancelling.contains($0.id) }?.message
    }

    func cancel(_ message: Message, editing: Bool = false) {
        guard let client, canCancel, !sending.contains(message.id), !cancelling.contains(message.id) else { return }
        cancelling.insert(message.id)
        Task {
            defer { cancelling.remove(message.id) }
            do {
                // HTTP 返回失败也可能已经落盘，先由服务核查是否仍能撤回。
                try await client.post("/threads/\(id)/messages/\(message.id)/cancel")
                outbox.removeAll { $0.id == message.id }
                pending.removeAll { $0.id == message.id }
                failed.remove(message.id)
                error = nil
                if editing { restoreDraft([message]) }
                render()
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 退回输入框：字接在草稿前面，附件排在已有的前面。
    private func restoreDraft(_ messages: [Message]) {
        let texts = messages.map(\.typed).filter { !$0.isEmpty }
        draft = (texts + (draft.isEmpty ? [] : [draft])).joined(separator: "\n\n")
        let restored = messages.flatMap(\.attachments).filter { attachment in !draftAttachments.contains { $0.id == attachment.id } }
        draftAttachments = restored.map { DraftAttachment(restoring: $0, source: attachmentSource) } + draftAttachments
        if draftAttachments.count > Self.maxAttachments { error = "一条消息最多带 \(Self.maxAttachments) 个附件，拿掉几个再发" }
    }

    func stop() {
        guard canStop else { return }
        _ = try? startStop()
    }

    /// 设置页也能停止没有展开窗口的会话，沿用同一收据与队列退回逻辑。
    func stopAndWait() async throws {
        try await startStop().value
    }

    private func startStop() throws -> Task<Void, Error> {
        guard let client, !stopping else { throw KitedError(message: "代理尚不可停止，请刷新状态后重试") }
        let request = stopRequest ?? StopRequest(id: UUID().uuidString, inputs: outbox.map {
            RemoteInput(id: $0.id, text: $0.typed, source: "human", attachments: $0.attachments.isEmpty ? nil : $0.attachments)
        })
        // 同步冻结收据，点击停止后立即阻止继续发送或重复停止。
        stopRequest = request
        stopping = true
        return Task {
            defer { stopping = false }
            do {
                let response = try await client.request("/threads/\(id)/interrupt", method: "POST", body: request, as: StopResponse.self)
                let fresh = response.returned.filter { !returned.contains($0.id) }
                returned.formUnion(fresh.map(\.id))
                outbox.removeAll { returned.contains($0.id) }
                pending.removeAll { returned.contains($0.id) }
                failed.subtract(returned)
                stopRequest = nil
                error = nil
                restoreDraft(fresh.map(\.message))
                render()
            } catch {
                self.error = "停止尚未确认，请再次点停止重试：\(error.localizedDescription)"
                throw error
            }
        }
    }

    func regenerateTitle() async throws {
        guard let client, canRegenerateTitle else { return }
        regeneratingTitle = true
        defer { regeneratingTitle = false }
        let path = "/threads/\(id)/title"
        let snapshot = try await client.request(path, as: ThreadTitleSnapshot.self)
        guard connected, state?.status == "open" else { throw KitedError(message: "代理连接或状态已变化，请重试") }
        // 标题正文沿目录事件同步，避免迟到的 HTTP 响应覆盖更新的远端标题。
        let _: ThreadTitleSnapshot = try await client.request(path + "/regenerate", method: "POST",
            body: ["expectedRevision": snapshot.revision], timeout: 120, as: ThreadTitleSnapshot.self)
    }

    /// 压缩从起点那条消息到终点那条消息所在的一轮；结果经会话事件送达，失败显示在状态里。
    func compact(through message: String) {
        guard let client, let start = compactionStart, canCompact else { return }
        compactionStart = nil
        Task {
            do {
                try await client.post("/threads/\(id)/compactions", body: ["id": UUID().uuidString, "from": start, "through": message])
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 压缩全部已有历史，同 compact(through:)。
    func compactAll() {
        guard let client, canCompactAll else { return }
        compactionStart = nil
        Task {
            do {
                try await client.post("/threads/\(id)/compactions", body: ["id": UUID().uuidString])
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    func revertCompaction(_ compaction: String) {
        guard let client, canCompact else { return }
        Task {
            do { let _: JSON = try await client.request("/threads/\(id)/compactions/\(compaction)", method: "DELETE", as: JSON.self); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    /// 回退前先请工作机核对：这条还在上下文里，文件回到哪一枚、会一起撤掉哪些代理的改动；核对完弹确认（RewindConfirmation）。
    func prepareRewind(_ message: Message) {
        guard let client, canRewind else { return }
        Task {
            do {
                let response = try await client.request("/threads/\(id)/rewind", method: "POST",
                    body: RewindBody(input: message.id, conversation: true, files: true, preview: true), as: RewindResponse.self)
                rewindRequest = RewindRequest(message: message, files: response.files)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 回退了对话的，这条的原文和附件放回输入框；对话的结果经工作机整份重发的历史送达，失败显示在状态里，同 compact。
    func rewind(_ request: RewindRequest, conversation: Bool, files: Bool) {
        guard let client else { return }
        Task {
            do {
                try await client.post("/threads/\(id)/rewind", body: RewindBody(input: request.message.id, conversation: conversation, files: files))
                if conversation { restoreDraft([request.message]) }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 不回应审批、直接发 message：工作机先把消息排进输入，再按拒绝交回这次审批。在 send 之前调。
    func skip(_ waiting: RemoteWaiting, sending message: Message) {
        skips[message.id] = waiting.id
    }

    /// 回应卡片上的那一项：卡着回合的审批优先，否则是最早几项连着的同类请求合成的一项（提问逐题排下去，密钥逐项排下去），
    /// id 是各项的 id 用 | 连起来，回应时按项拆开，见 respond。断线重连时照旧显示最后知道的，卡片和答了一半的都不丢，
    /// 重连后的历史再定它还在不在；连着工作机时才能回应。
    var waiting: RemoteWaiting? {
        if let approval = state?.waiting { return approval }
        guard let asks = state?.asks, let first = asks.first else { return nil }
        let run = asks.prefix { $0.kind == first.kind }
        guard run.count > 1 else { return first }
        var merged = first
        merged.id = run.map(\.id).joined(separator: Self.mergedSeparator)
        merged.questions = first.isQuestion ? run.flatMap { $0.questions ?? [] } : nil
        merged.secrets = first.isSecret ? run.flatMap { $0.secrets ?? [] } : nil
        return merged
    }

    private static let mergedSeparator = "|"

    /// 回应等你的那一项；回应后由会话事件撤下。合成的一项按各请求的题数、项数拆开逐个提交，已回应或已收回的那一项工作机返回 409，
    /// 请求同样随事件更新。
    func respond(_ waiting: RemoteWaiting, _ reply: WaitingReply) async throws {
        guard let client, connected else { throw KitedError(message: "工作机未连接，连上后再提交") }
        let ids = waiting.id.components(separatedBy: Self.mergedSeparator)
        guard ids.count > 1 else {
            let _: JSON = try await client.request("/threads/\(id)/waiting/\(waiting.id.pathComponent)", method: "POST", body: reply, as: JSON.self)
            return
        }
        // 合成以后有一项被收回或回应了，题数、项数对不上，等卡片按新的请求换过再提交
        let asks = ids.compactMap { id in state?.asks?.first { $0.id == id } }
        guard asks.count == ids.count else { throw KitedError(message: "请求有变化，确认卡片上的内容后再提交") }
        var offset = 0
        for ask in asks {
            let count = ask.questions?.count ?? ask.secrets?.count ?? 0
            let part: WaitingReply = switch reply {
            case .answers(let answers): .answers(Array(answers[offset..<min(offset + count, answers.count)]))
            // 账号共享只对独立的密钥；全是环境变量文件里的项的请求只能项目专用
            case .secret(let secret): .secret(.init(values: Array(secret.values[offset..<min(offset + count, secret.values.count)]),
                                                    scope: ask.hasStandaloneSecret ? secret.scope : "project"))
            case .decision: reply
            }
            offset += count
            let _: JSON = try await client.request("/threads/\(id)/waiting/\(ask.id.pathComponent)", method: "POST", body: part, as: JSON.self)
        }
    }

    func resume() {
        guard let client else { return }
        Task {
            do { try await client.post("/threads/\(id)/resume"); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    private struct SendBody: Encodable { let id: String; let text: String; let attachments: [String]?; let skipWaiting: String? }
}

/// 控件的刻度顺序；可选档位由服务端模型能力筛选。
enum Effort: Int, CaseIterable {
    case low, medium, high, extra, max
    var name: String { self == .extra ? "xhigh" : "\(self)" }
}
