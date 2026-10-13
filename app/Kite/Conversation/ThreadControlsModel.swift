import SwiftUI

/// 会话输入区的状态，建好不换：每个输入区（原生的 MacControlsBar、ControlsBarView，Mac 窄窗口的 SwiftUI 版 ThreadControls）各持一份。
@Observable final class ThreadControlsState {
    /// 刚发出去、正在淡掉的字，见 ThreadControlsModel.submit。控制区里由 SwiftUI 逐帧驱动的动画会和对话滑动抢同一帧，
    /// 发送时掉帧（2026-10-11 Mac 实测，字的模糊淡出和发送键的淡出各自都会）：输入框先藏起来，字画成图盖在原处
    /// 交给 Core Animation 淡掉（见 FadingSnapshotView），发送键直接消失。
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

    /// 附件、语音这组按钮与后面停止、继续、发送键的间距，比通用的按钮间距紧，发送键贴着左边的按钮组。
    static let actionGap: CGFloat = 4

    var placeholder: String { thread.transcriptRunning ? "插话，agent 做完手上这一步就会看到" : "回复" }
    var listening: Bool { model.voice.owner == voiceOwner }
    var blank: Bool { thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 发送键：空草稿、发出去的字还在淡的时候不显示。
    var showsSend: Bool { !blank && state.fading == nil }
    var showsStop: Bool { thread.showStop }
    var showsResume: Bool { thread.state?.capabilities.resume == true }

    func stop() { thread.stop() }
    func resume() { thread.control("resume") }

    /// 开始或结束录语音。识别出的字接在开录时的草稿后面，每次都是到目前为止的全文；started 在开录以后调。
    func toggleVoice(started: @escaping @MainActor () -> Void = {}) {
        let voice = model.voice
        if listening {
            voice.stop()
            return
        }
        let base = thread.draft
        let thread = thread, model = model, area = area, owner = voiceOwner, state = state
        Task {
            do {
                let client = try thread.client ?? model.activeClient(in: area)
                try await voice.start(owner: owner, target: VoiceTarget(client: client, thread: thread.isDraft ? nil : thread.id)) { text in
                    switch text {
                    case .partial(let value), .final(let value): thread.draft = base + value
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
        send(Message(typed: sent.trimmingCharacters(in: .whitespacesAndNewlines))) {
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
