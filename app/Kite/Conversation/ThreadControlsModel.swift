import QuartzCore
import SwiftUI

/// 会话输入区的状态，建好不换：每个输入区（原生的 MacControlsBar、ControlsBarView，Mac 窄窗口的 SwiftUI 版 ThreadControls）各持一份。
@Observable final class ThreadControlsState {
    /// 刚发出去、正在淡掉的字，见 ThreadControlsModel.submit。控制区里由 SwiftUI 逐帧驱动的动画会和对话滑动抢同一帧，
    /// 发送时掉帧（2026-10-11 Mac 实测，字的模糊淡出和发送键的淡出各自都会）：输入框先藏起来，字画成图盖在原处
    /// 交给 Core Animation 淡掉（见 FadingSnapshotView），主按钮按清空后的草稿与会话状态更新。
    fileprivate(set) var fading: FadingText?
    /// 正在选、还没存下的思考强度。
    var effortDraft: Effort?
    fileprivate(set) var savingEffort = false
    var effortError: String?
    var voiceError: String?
}

/// 会话输入区的逻辑：发送、停止、继续、语音、思考强度，占位文字和哪些按钮显示。各个输入区共用，每次更新按当时的环境现做一份；
/// 读的都是会话、App 模型和 state 里的可观察属性，SwiftUI 版在 body 里读、原生版在 withObservationTracking 里读，都跟着变。
struct ThreadControlsModel {
    let thread: WorkThread
    let model: AppModel
    let area: WorkArea
    /// 窗口对应的实例；草稿还没有。
    let instance: RemotePluginInstance?
    let stage: DotStage?
    let scope: DotScope?
    /// 这个窗口录语音时的标识，见 VoiceInput.owner。
    let voiceOwner: String
    let state: ThreadControlsState
    /// 发一条消息；第二个参数和对话往上滑在同一次更新里调。
    let send: (Message, _ alongside: @escaping () -> Void) -> Void

    /// 附件、语音与固定主按钮之间的间距。
    static let actionGap: CGFloat = 4

    /// 写明发出去会怎样：作答时写的是当前这题的「其他」；恢复阻塞时发送即确认已核查、接着做；审批时发出去就拒绝。
    var placeholder: String {
        if answering != nil { return "填写其他回答" }
        if thread.state?.recovery != nil { return "发送消息并继续" }
        if skipping != nil { return "发送消息并拒绝" }
        return "发送消息"
    }

    // MARK: - 回应卡片

    /// 提问的卡片展开着：输入框写当前这题的「其他」，左边是上一题、下一题，主按钮发送答案（没答齐时是停止）。
    var answering: WaitingAnswers? {
        let answers = thread.answers
        guard let waiting = thread.waiting, waiting.isQuestion, answers.waiting?.id == waiting.id, !answers.collapsed else { return nil }
        return answers
    }

    /// 审批或密钥请求的卡片展开着：按钮行左边是拒绝和次级的决定（WaitingDecision.others），主按钮在输入框空着时是主决定（见 primaryAction），
    /// 输入框照常发消息：审批时发出去就拒绝（见 skipping），密钥请求不阻塞，照常只发消息。密钥的值填在卡片里。
    var deciding: RemoteWaiting? {
        let answers = thread.answers
        guard let waiting = thread.waiting, !waiting.isQuestion, answers.waiting?.id == waiting.id, !answers.collapsed else { return nil }
        return waiting
    }

    /// 回应卡片展开着（作答、审批或密钥请求）：按钮行左边不放思考强度。
    var responding: Bool { answering != nil || deciding != nil }

    /// 这个决定现在能不能按：回应途中不能，密钥请求要存的还得先填好合规的值。
    func canDecide(_ decision: WaitingDecision) -> Bool {
        !thread.answers.busy && decision.response(thread.answers) != nil
    }

    /// 按了按钮行上的决定或主按钮；回应途中不再接，失败的说明写在卡片上。
    func decide(_ decision: WaitingDecision) {
        let answers = thread.answers
        guard let waiting = deciding, !answers.busy, let reply = decision.response(answers) else { return }
        let thread = thread
        answers.run { try await thread.respond(waiting, reply) }
    }

    /// 输入框发的消息会拒绝的审批（审批卡着回合，决定在按钮行和主按钮上，见 deciding）。提问与密钥请求不阻塞，发消息不动它们。
    /// 见 WorkThread.skip。
    var skipping: RemoteWaiting? {
        guard let waiting = thread.state?.waiting, waiting.kind == "approval" else { return nil }
        return waiting
    }

    /// 输入框里的字：作答时是当前这题的「其他」，否则是草稿。
    var fieldText: String { answering?.currentOther ?? thread.draft }

    func setFieldText(_ text: String) {
        if let answers = answering {
            if answers.currentOther != text { answers.currentOther = text }
        } else if thread.draft != text {
            thread.draft = text
        }
    }

    /// 多题作答：左边有上一题、下一题。
    var questionSteps: Bool { (answering?.questions.count ?? 0) > 1 }

    /// 作答时在输入框里回车：这题答了就去下一题，最后一题答齐了就发送。
    func advanceAnswer() { answering?.advance(submit: submitAnswers) }

    func submitAnswers() {
        guard let answers = answering, let waiting = thread.waiting, answers.complete, !answers.busy else { return }
        let thread = thread, replies = answers.replies
        answers.run { try await thread.respond(waiting, .answers(replies)) }
    }

    /// 回应卡片上的「交给 Line」：有 Line、这不是 Line 自己发起的请求时才有。
    var delegate: (() async throws -> Void)? { model.lineDelegate(thread) }
    var listening: Bool { model.voice.owner == voiceOwner }
    /// 没写字，也没放附件。
    var blank: Bool { thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thread.draftAttachments.isEmpty }

    // MARK: - 附件

    /// 附件传到哪：所属工作机连着时是这个工作区。作答时不收附件，回答只收文字。
    var attachmentSource: AttachmentSource? {
        guard answering == nil, let client = try? model.activeClient(in: area) else { return nil }
        return AttachmentSource(client: client, workspace: area.id)
    }

    var canAttach: Bool { attachmentSource != nil }

    /// 选好的文件放进输入框，当场开始传。
    func attach(files: [URL]) { add(files) { try DraftAttachment(staging: $0) } }

    /// 粘贴、拍下的图片这类只有数据的。
    func attach(data: Data, name: String) { add([data]) { try DraftAttachment(data: $0, name: name) } }

    /// 一条消息最多带 maxAttachments 个，放不下的不读；读不了的跳过，其余照常放进去。
    private func add<Item>(_ items: [Item], _ make: (Item) throws -> DraftAttachment) {
        guard let source = attachmentSource else { return }
        let room = thread.attachmentRoom
        var made: [DraftAttachment] = []
        var failure: (any Error)?
        for item in items.prefix(room) {
            do { made.append(try make(item)) } catch { failure = error }
        }
        thread.attach(made, to: source)
        if items.count > room { thread.error = "一条消息最多带 \(WorkThread.maxAttachments) 个附件" }
        if let failure { thread.error = "附件读取失败：\(failure.localizedDescription)" }
    }

    #if os(macOS)
    /// 回形针：选文件（可以多选），选好放进输入框。
    func chooseFiles(in window: NSWindow?) {
        guard canAttach else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "添加"
        let controls = self
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK { controls.attach(files: panel.urls) } }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// 粘贴板、拖进来的东西：有文件就当附件；只有图片数据（截图、网页上拷的图）时存成 PNG。只有字的返回假，照常交给输入框。
    func attach(from pasteboard: NSPasteboard) -> Bool {
        guard canAttach else { return false }
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            attach(files: files)
            return true
        }
        // 有现成的 PNG 就直接用，没有时才从图片转
        guard pasteboard.string(forType: .string) == nil,
              let png = pasteboard.data(forType: .png) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation
                .flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { return false }
        attach(data: png, name: "图片.png")
        return true
    }
    #endif
    /// decide 是审批或密钥请求展开、输入框空着时的主决定（允许一次、存为项目专用等，见 WaitingDecision.primary），主题色实心圆里一个对勾。
    enum PrimaryAction: Equatable {
        case send, stop, resume
        case decide(WaitingDecision)

        var symbol: String {
            switch self {
            case .send: "arrow.up"
            case .decide: "checkmark"
            case .stop: "stop.fill"
            case .resume: "play.fill"
            }
        }

        var title: String {
            switch self {
            case .send: "发送"
            case .stop: "停止"
            case .resume: "继续"
            case .decide(let decision): decision.title
            }
        }
    }

    /// 草稿优先；审批、密钥请求展开时没写字是主决定，写了字照常发送（发出去就拒绝，同提问的「其他」）；
    /// 暂停着能继续时继续优先于停止（排着的消息逐条可撤回），停止没确认时先重试停止；空闲时仍保留发送键，由可用状态把它置灰。
    var primaryAction: PrimaryAction {
        if let answers = answering { return answers.complete ? .send : .stop }
        if !blank { return .send }
        if let waiting = deciding { return .decide(.primary(for: waiting)) }
        if thread.hasUnconfirmedStop { return .stop }
        if thread.state?.capabilities.resume == true { return .resume }
        if thread.showStop { return .stop }
        return .send
    }

    var canPerformPrimaryAction: Bool {
        switch primaryAction {
        case .send: answering.map { $0.complete && !$0.busy } ?? canSubmit
        case .stop: thread.canStop
        case .resume: thread.canResume
        case .decide(let decision): canDecide(decision)
        }
    }

    var primaryActionFill: Color {
        primaryAction == .stop || !canPerformPrimaryAction ? Theme.strongPlaceholder : .accentColor
    }

    func performPrimaryAction(submit: () -> Void) {
        guard canPerformPrimaryAction else { return }
        switch primaryAction {
        case .send: if answering != nil { submitAnswers() } else { submit() }
        case .stop: stop()
        case .resume: resume()
        case .decide(let decision): decide(decision)
        }
    }

    func stop() { thread.stop() }
    func resume() { thread.resume() }

    /// 开始或结束录语音。识别出的字接在开录时输入框里的字后面（草稿，作答时是这题的「其他」），每次都是到目前为止的全文；
    /// started 在开录以后调。
    func toggleVoice(started: @escaping @MainActor () -> Void = {}) {
        if let answers = answering {
            let index = answers.step
            dictate(base: answers.currentOther, started: started) { answers.setOther($0, at: index) }
        } else {
            let thread = thread
            dictate(base: thread.draft, started: started) { thread.draft = $0 }
        }
    }

    /// 开始或停下语音输入：识别出的字接在 base 后面交给 write。
    private func dictate(base: String, started: @escaping @MainActor () -> Void = {}, write: @escaping @MainActor (String) -> Void) {
        let voice = model.voice
        if listening {
            voice.stop()
            return
        }
        let thread = thread, model = model, area = area, owner = voiceOwner, state = state
        Task {
            do {
                let client = try thread.client ?? model.activeClient(in: area)
                try await voice.start(owner: owner, target: VoiceTarget(client: client, thread: thread.isDraft ? nil : thread.id)) { text in
                    switch text {
                    case .partial(let value), .final(let value): write(base + value)
                    case .failed(let message):
                        voice.stop(owner: owner)
                        state.voiceError = message
                    }
                }
                started()
            } catch {
                state.voiceError = error.localizedDescription
            }
        }
    }

    // MARK: - 思考强度

    /// 草稿还没有实例，思考强度改的是本机选择，随第一条消息一起提交。
    private var choice: DraftAgentChoice? { instance == nil ? thread.draftChoice : nil }
    private var agentModel: AgentModelConfiguration? { model.agentModel(for: thread, instance: instance, in: area) }
    private var reasoning: String { agentModel?.reasoning ?? "medium" }

    /// 当前档位；档位名读不出来（如 default）时为 nil，退成文字菜单，标题见 effortTitle。
    var effort: Effort? { Effort.allCases.first { $0.name == reasoning } }
    var effortTitle: String { reasoning == "default" ? "自动" : reasoning }
    /// 悬停时说明模型能力。
    var effortHelp: String { thread.agentCapabilities?.explanation ?? "正在读取模型能力" }

    var availableEfforts: [Effort] {
        let levels = thread.agentCapabilities?.model(agentModel?.model ?? "")?.reasoning ?? []
        return Effort.allCases.filter { levels.contains($0.name) }
    }

    var canChangeEffort: Bool {
        if choice != nil { return agentModel != nil && !availableEfforts.isEmpty && model.isConnected(area) }
        return instance != nil && !state.savingEffort && !availableEfforts.isEmpty
            && model.isConnected(area) && thread.agentCapabilities?.canEdit(thread.state) == true
    }

    /// 文字菜单里选了一档。
    func chooseEffort(_ value: Effort) {
        state.effortDraft = value
        saveEffort()
    }

    func saveEffort() {
        let state = state
        if choice != nil {
            if canChangeEffort, let effortDraft = state.effortDraft, var selected = agentModel {
                selected.reasoning = effortDraft.name
                thread.draftChoice?.model = selected
            }
            state.effortDraft = nil
            return
        }
        guard canChangeEffort, let effortDraft = state.effortDraft, effortDraft.name != reasoning, let instance else {
            state.effortDraft = nil
            return
        }
        state.savingEffort = true
        let model = model, area = area
        Task {
            defer { state.savingEffort = false; state.effortDraft = nil }
            do {
                try await model.updateAgent(in: area, id: instance.id) { $0.model.reasoning = effortDraft.name }
            } catch { state.effortError = error.localizedDescription }
        }
    }

    // MARK: - 发送

    /// 回车、发送键能不能发：草稿或附件不空、附件都传好了、上一条的字淡完了、会话能收。
    var canSubmit: Bool { !blank && thread.attachmentsReady && state.fading == nil && thread.canSend }

    /// 发送。frame 是控制区（玻璃那一块）在窗口坐标中的位置，点阵的波从这里推开；fieldHeight 是输入框此刻的高，
    /// 输入框撑着它淡完再变矮。新工作区先选择项目，这时不清草稿、不淡出，关闭选择窗口时仍保留原输入。
    func submit(from frame: CGRect, fieldHeight: CGFloat) {
        guard canSubmit else { return }
        let sent = thread.draft
        // 波只画在窗口里，朝窗口顶边走，和对话往上滑同一次更新起步
        let stage = stage, scope = scope
        let reach = frame.minY - (scope?.frame.minY ?? frame.minY)
        var message = Message(typed: sent.trimmingCharacters(in: .whitespacesAndNewlines))
        message.attachments = thread.takeAttachments()
        if let waiting = skipping { thread.skip(waiting, sending: message) }
        send(message) {
            stage?.emitWave(from: frame, parameters: Self.sendWave(from: frame, reach: reach), in: scope)
        }
        // 发送时就清空，输入框撑着原来的高度淡完再变矮。清空时键盘处理、输入框重排要几十毫秒（2026-10-11 iPhone 实测），
        // 放在对话刚起步的时候，不落在滑得最快的时候
        let fading = FadingText(text: sent, height: fieldHeight)
        state.fading = fading
        thread.draft = ""
        let state = state
        DispatchQueue.main.asyncAfter(deadline: .now() + FadingText.duration) {
            if state.fading?.id == fading.id { state.fading = nil }
        }
    }

    /// 发送时从控制区推开的波：弓形，中间先走，和对话往上滑同一条弹簧朝窗口顶边走，像把对话推上去；
    /// 从窄到宽、越走越淡，到窗口上部已经很淡。
    private static func sendWave(from frame: CGRect, reach: CGFloat) -> DotWave.Parameters {
        DotWave.Parameters(spring: .glide, width: 24, widthEnd: 144, reach: reach, bow: frame.width * 0.75, fadeEnd: 0.85)
    }
}

/// 一段正在淡掉的发出去的字，和发送时输入框的高度。
struct FadingText {
    let id = UUID()
    let text: String
    let height: CGFloat

    /// 发出去的字 0.3 秒 easeOut 模糊到 6、透明度到 0。
    static let duration = 0.3
    static let blur: CGFloat = 6
    /// 字画成的图四周留出的边，容下模糊溢出的部分；盖回去时往左上让开同样的距离。
    static let bleed: CGFloat = 12
}

/// 思考强度：读得到档位时是 EffortPicker，读不到退成文字菜单。两版输入区共用；Mac 宽屏的原生输入区把它放进单独的托管视图，
/// 只在它自己改宽（刻度展开、收起）时重排。
struct ThreadEffortControl: View {
    let controls: ThreadControlsModel

    var body: some View {
        let state = controls.state
        if let effort = controls.effort {
            EffortPicker(effort: Binding(get: { state.effortDraft ?? effort }, set: { state.effortDraft = $0 }),
                         allowed: controls.availableEfforts, enabled: controls.canChangeEffort,
                         commit: controls.saveEffort, cancel: { state.effortDraft = nil })
                .help(controls.effortHelp)
        } else {
            Menu {
                ForEach(controls.availableEfforts, id: \.self) { value in
                    Button(value.name) { controls.chooseEffort(value) }
                }
            } label: {
                Text(controls.effortTitle).font(Theme.secondary).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
                .disabled(!controls.canChangeEffort)
        }
    }
}

/// 两端原生输入区（MacControlsBar、PhoneControlsBar）的版式，照 ThreadControls：输入框左右 controlInset + 8、上下 6；输入框和按钮行之间 2；
/// 按钮行左右、底 controlButtonInset；顶 controlInset。附件、语音一组间距 0，和后面的主按钮间距 actionGap；横排时思考强度和按钮组之间至少两个按钮间距。
/// 有待发的附件时，那一行（DraftAttachmentStrip）在最上面，左右、顶离玻璃 controlInset，下面隔 stripGap 才是输入框。
enum ComposerLayout {
    static let fieldInset = Metrics.controlInset + 8
    static let fieldPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 2
    /// 输入框的顶边。
    static let fieldTop = Metrics.controlInset + fieldPadding
    /// 回应卡片里选项和输入框的灰底：左右离玻璃边 controlInset，圆角和玻璃同心。下面输入区的输入框不带底。
    static let fieldFill = Color.gray.opacity(0.12)
    static var fieldFillRadius: CGFloat { Metrics.controlRadius - Metrics.controlInset }

    static let stripGap: CGFloat = 4

    struct Plan {
        var height: CGFloat
        var field: CGFloat
        var effort: CGSize
        var hidesActions: Bool
        /// 待发附件那一行的高，没有附件时 0。
        var strip: CGFloat = 0

        /// 输入框的顶边：有附件时往下让出那一行。
        var fieldTop: CGFloat { ComposerLayout.fieldTop + (strip > 0 ? strip + ComposerLayout.stripGap : 0) }
    }

    /// 待发附件那一行的宽：玻璃左右各让 controlInset。
    static func stripWidth(_ width: CGFloat) -> CGFloat { max(width - 2 * Metrics.controlInset, 0) }

    /// 输入框（连同淡出的字）排出 field 高、思考强度是 effort 大、待发附件那一行 strip 高时：玻璃多高，按钮行还放不放得下附件、语音和主按钮。
    static func plan(width: CGFloat, field: CGFloat, effort: CGSize, strip: CGFloat = 0) -> Plan {
        let buttons = 3 * Metrics.paneButton + ThreadControlsModel.actionGap
        let hidesActions = effort.width + 2 * Metrics.paneButtonGap + buttons > width - 2 * Metrics.controlButtonInset
        let row = max(effort.height, Metrics.paneButton)
        let attachments = strip > 0 ? strip + stripGap : 0
        let height = Metrics.controlInset + attachments + 2 * fieldPadding + field + rowSpacing + row + Metrics.controlButtonInset
        return Plan(height: height, field: field, effort: effort, hidesActions: hidesActions, strip: strip)
    }

    /// 审批的决定在按钮行左边一个挨一个，之间 actionGap（同收件箱卡片里的那一行）：各个按钮离这一组左边多远，和整组多大。
    static func decisionRow(_ widths: [CGFloat]) -> (offsets: [CGFloat], size: CGSize) {
        var x: CGFloat = 0
        var offsets: [CGFloat] = []
        for width in widths {
            offsets.append(x)
            x += width + ThreadControlsModel.actionGap
        }
        return (offsets, widths.isEmpty ? .zero : CGSize(width: x - ThreadControlsModel.actionGap, height: Metrics.paneButton))
    }

    /// 按钮行：思考强度靠左，附件、语音、主按钮靠右，都在这一行里竖直居中。
    static func row(width: CGFloat, plan: Plan) -> (effort: CGRect, attach: CGRect, voice: CGRect, primary: CGRect) {
        let top = plan.fieldTop + plan.field + fieldPadding + rowSpacing
        let inset = Metrics.controlButtonInset, size = Metrics.paneButton
        let row = max(plan.effort.height, size)
        let effort = CGRect(x: inset, y: top + (row - plan.effort.height) / 2, width: plan.effort.width, height: plan.effort.height)
        let primary = CGRect(x: width - inset - size, y: top + (row - size) / 2, width: size, height: size)
        let voice = primary.offsetBy(dx: -ThreadControlsModel.actionGap - size, dy: 0)
        return (effort, voice.offsetBy(dx: -size, dy: 0), voice, primary)
    }
}

/// 回应卡片在输入区上方长出来、收回去的过渡：输入区一直在、贴着底边，卡片摆在它上面。玻璃的高和卡片的不透明度从改变那一刻的样子
/// 按窗口动画那条不冲过头的曲线走到目标，目标每帧按当时量出的高重算，中途再改从当时的样子接着走。卡片出现、消失时贴着输入区
/// （随玻璃长高从顶边露出来、收进顶边）；收起、展开、换题时卡片贴着顶边，标题行跟着玻璃的顶边走，卡片自己的内容淡入淡出、超出的裁掉。
/// 原生输入区（MacControlsBar、PhoneControlsBar）用显示链接逐帧取样，Mac 窄窗口（ThreadControls）交给 SwiftUI 的动画。
struct ComposerMotion {
    struct Pose {
        var height: CGFloat
        /// 卡片的不透明度。
        var card: CGFloat
    }

    static let duration: TimeInterval = 0.25
    static var animation: Animation { .timingCurve(WindowMotionKind.curve, duration: duration) }

    private var origin: Pose?
    private var start: CFTimeInterval?
    private var progress: CGFloat = 1
    /// 这一段里卡片贴着顶边（收起、展开、换题），否则贴着下面的输入区。
    private(set) var cardOnTop = false

    var moving: Bool { start != nil }

    /// 从 current 起往目标走，从 now 起算；now 为空时当场到。
    mutating func begin(from current: Pose, cardOnTop: Bool, at now: CFTimeInterval?) {
        guard let now else {
            finish()
            return
        }
        origin = current
        start = now
        progress = 0
        self.cardOnTop = cardOnTop
    }

    /// 取 time 那一刻走到哪；走完了返回假。
    mutating func sample(at time: CFTimeInterval) -> Bool {
        guard let start else { return false }
        progress = CGFloat(WindowMotionKind.curve.value(at: min(max((time - start) / Self.duration, 0), 1)))
        guard progress < 1 else {
            finish()
            return false
        }
        return true
    }

    /// 当场走到头（输入区离开了窗口，显示链接不再回调）。
    mutating func finish() {
        origin = nil
        start = nil
        progress = 1
        cardOnTop = false
    }

    /// 目标：card 为空时只有输入区，否则卡片在上、输入区在下。
    static func target(composer: CGFloat, card: CGFloat?) -> Pose {
        guard let card else { return Pose(height: composer, card: 0) }
        return Pose(height: card + composer, card: 1)
    }

    /// 卡片顶边离玻璃顶边多远：贴着顶边时是 0，否则贴着下面的输入区。
    func cardTop(glass: CGFloat, card: CGFloat, composer: CGFloat) -> CGFloat {
        cardOnTop ? 0 : glass - card - composer
    }

    /// 这一刻的样子：没在走就是目标。
    func pose(toward target: Pose) -> Pose {
        guard let origin else { return target }
        return Pose(height: origin.height + (target.height - origin.height) * progress, card: origin.card + (target.card - origin.card) * progress)
    }
}
