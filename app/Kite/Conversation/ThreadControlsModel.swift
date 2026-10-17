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

    var placeholder: String {
        if answering != nil { return "其他" }
        if thread.state?.recovery != nil { return "核查上次执行后，再继续或回复" }
        if let waiting = skipping { return waiting.isQuestion ? "跳过问题" : waiting.isSecret ? "不提供密钥" : "跳过审批" }
        return thread.transcriptRunning ? "插话，agent 做完手上这一步就会看到" : "回复"
    }

    // MARK: - 回应卡片

    /// 提问的卡片展开着：输入框写当前这题的「其他」，左边是上一题、下一题，主按钮发送答案（没答齐时是停止）。
    var answering: WaitingAnswers? {
        let answers = thread.answers
        guard let waiting = thread.waiting, waiting.isQuestion, answers.waiting?.id == waiting.id, !answers.collapsed else { return nil }
        return answers
    }

    /// 输入框发的消息会跳过的那一项：收起着的提问，或审批（审批的决定在卡片的按钮上）。见 WorkThread.skip。
    var skipping: RemoteWaiting? {
        guard let waiting = thread.waiting, !waiting.isQuestion || thread.answers.collapsed else { return nil }
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
    var blank: Bool { thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    enum PrimaryAction {
        case send, stop, resume

        var symbol: String {
            switch self {
            case .send: "arrow.up"
            case .stop: "stop.fill"
            case .resume: "play.fill"
            }
        }

        var title: String {
            switch self {
            case .send: "发送"
            case .stop: "停止"
            case .resume: "继续"
            }
        }
    }

    /// 草稿优先；暂停着能继续时继续优先于停止（排着的消息逐条可撤回），停止没确认时先重试停止；
    /// 空闲时仍保留发送键，由可用状态把它置灰。
    var primaryAction: PrimaryAction {
        if let answers = answering { return answers.complete ? .send : .stop }
        if !blank { return .send }
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

    /// 回车、发送键能不能发：草稿不空、上一条的字淡完了、会话能收。
    var canSubmit: Bool { !blank && state.fading == nil && thread.canSend }

    /// 发送。frame 是控制区（玻璃那一块）在窗口坐标中的位置，点阵的波从这里推开；fieldHeight 是输入框此刻的高，
    /// 输入框撑着它淡完再变矮。新工作区先选择项目，这时不清草稿、不淡出，关闭选择窗口时仍保留原输入。
    func submit(from frame: CGRect, fieldHeight: CGFloat) {
        guard canSubmit else { return }
        let sent = thread.draft
        // 波只画在窗口里，朝窗口顶边走，和对话往上滑同一次更新起步
        let stage = stage, scope = scope
        let reach = frame.minY - (scope?.frame.minY ?? frame.minY)
        let message = Message(typed: sent.trimmingCharacters(in: .whitespacesAndNewlines))
        if let waiting = skipping { thread.skip(waiting, sending: message) }
        send(message) {
            stage?.emitWave(from: frame, parameters: Self.sendWave(from: frame, reach: reach), in: scope)
        }
        guard !area.isDraft else { return }
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
enum ComposerLayout {
    static let fieldInset = Metrics.controlInset + 8
    static let fieldPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 2
    /// 输入框的顶边。
    static let fieldTop = Metrics.controlInset + fieldPadding
    /// 作答时输入框和回应卡片选项的灰底：左右离玻璃边 controlInset，上下包住输入框的 fieldPadding，圆角和玻璃同心。
    static let fieldFill = Color.gray.opacity(0.12)
    static var fieldFillRadius: CGFloat { Metrics.controlRadius - Metrics.controlInset }

    /// 输入框灰底的框（输入框那一边的坐标，顶边往下量）。
    static func fieldFillFrame(width: CGFloat, plan: Plan) -> CGRect {
        CGRect(x: Metrics.controlInset, y: Metrics.controlInset, width: max(width - 2 * Metrics.controlInset, 0), height: plan.field + 2 * fieldPadding)
    }

    struct Plan {
        var height: CGFloat
        var field: CGFloat
        var effort: CGSize
        var hidesActions: Bool
    }

    /// 输入框（连同淡出的字）排出 field 高、思考强度是 effort 大时：玻璃多高，按钮行还放不放得下附件、语音和主按钮。
    static func plan(width: CGFloat, field: CGFloat, effort: CGSize) -> Plan {
        let buttons = 3 * Metrics.paneButton + ThreadControlsModel.actionGap
        let hidesActions = effort.width + 2 * Metrics.paneButtonGap + buttons > width - 2 * Metrics.controlButtonInset
        let row = max(effort.height, Metrics.paneButton)
        let height = Metrics.controlInset + 2 * fieldPadding + field + rowSpacing + row + Metrics.controlButtonInset
        return Plan(height: height, field: field, effort: effort, hidesActions: hidesActions)
    }

    /// 按钮行：思考强度靠左，附件、语音、主按钮靠右，都在这一行里竖直居中。
    static func row(width: CGFloat, plan: Plan) -> (effort: CGRect, attach: CGRect, voice: CGRect, primary: CGRect) {
        let top = fieldTop + plan.field + fieldPadding + rowSpacing
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
