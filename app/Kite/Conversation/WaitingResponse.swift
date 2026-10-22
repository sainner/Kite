import SwiftUI

/// 等你回应的卡片（docs/工具审批与提问.md）。线程里它摆在输入区上面、和输入区共用同一张玻璃：出现审批、提问或密钥请求时卡片从输入区上方长出来，
/// 回应后收回去；连着的几项同类请求合成一张（见 WorkThread.waiting）。输入区一直在，提问展开时输入框写当前这题的「其他」、底部工具栏翻题和发送答案
/// （见 ThreadControlsModel.answering），审批、密钥请求展开时底部工具栏放拒绝和次级的决定，主按钮是主决定（见 ThreadControlsModel.deciding）；
/// 其余时候输入框照常发消息，只有审批会因此按拒绝交回（见 ThreadControlsModel.skipping），提问与密钥请求不阻塞，留着等用户回应。
/// 提问不回答点标题行的叉。
/// Line 的收件箱里同一个对象也用它回应，写回原线程所在的工作机；那里没有输入区，卡片自己带「其他」和按钮。
/// 提问一题一题答，单选、多选都能写「其他」；审批与密钥请求的决定见 WaitingDecision。
/// 密钥请求一次可以要几项，用户在卡片里逐项填值（代理给了值时预先填好），填了几项存几项；只能由用户填，不给交给 Line。
/// 标题行和按钮行一样高，chip（多题时里面带题号点）竖直居中、离左边和上边一样远；点标题行收起到只剩这一行。
/// 内容左右和输入框的字对齐（ComposerLayout）；inset 为假时都不留（收件箱里按列表的边距）。
struct WaitingResponseCard: View {
    let waiting: RemoteWaiting
    let respond: (WaitingReply) async throws -> Void
    /// 交给 Line 代处理；没有 Line，或这是 Line 自己发起的请求时为空。
    var delegate: (() async throws -> Void)?
    /// 线程里和输入区共用的作答（WorkThread.answers）；收件箱里为空，卡片自己带一份，也自己摆「其他」和按钮。
    var answers: WaitingAnswers?
    var inset: Bool

    @State private var own: WaitingAnswers
    /// chip 的高：它在标题行里竖直居中，离左边留得和离上边一样多要用到。
    @State private var chipHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var commandHeight = Metrics.approvalCommandHeight
    /// 密钥请求里正在填第几项：回车跳到下一项，最后一项回车才保存，免得填了第一项就把其余的当作没填存下去。
    @FocusState private var focusedSecret: Int?

    init(waiting: RemoteWaiting, respond: @escaping (WaitingReply) async throws -> Void, delegate: (() async throws -> Void)? = nil,
         answers: WaitingAnswers? = nil, inset: Bool = true) {
        self.waiting = waiting
        self.respond = respond
        self.delegate = delegate
        self.answers = answers
        self.inset = inset
        _own = State(initialValue: WaitingAnswers(waiting))
    }

    private var state: WaitingAnswers { answers ?? own }
    private var questions: [RemoteWaiting.Question] { waiting.questions ?? [] }
    private var asking: RemoteWaiting.Question? {
        waiting.isQuestion && questions.indices.contains(state.step) ? questions[state.step] : nil
    }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: 6) {
            header
                .padding(.leading, inset ? Metrics.controlRadius - chipHeight / 2 : 0)
                .padding(.trailing, inset ? Metrics.controlButtonInset : 0)
            if !state.collapsed {
                VStack(alignment: .leading, spacing: 6) {
                    if let asking { question(asking) }
                    else if waiting.isSecret { secret }
                    else { approval }
                    if let failure = state.failure {
                        Text(failure).font(Theme.secondary).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, inset ? ComposerLayout.fieldInset : 0)
                    }
                    if let asking {
                        if answers == nil { standalone(asking) }
                    } else if answers == nil {
                        decisionActions
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.top, inset ? Metrics.controlButtonInset : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(state.busy)
        .onChange(of: waiting.id) { own.adopt(waiting) }
    }

    // MARK: - 标题行

    /// 左边 chip，右边交给 Line（收起时不显示）和收起、展开的 caret；一个按钮高，点 chip 这一侧的空白处也收起、展开。
    private var header: some View {
        let state = state
        return HStack(spacing: 0) {
            Button(action: toggleCollapsed) {
                HStack {
                    HStack(spacing: 4) {
                        Text(chipTitle).font(Theme.status.weight(.semibold))
                        if questions.count > 1 {
                            HStack(spacing: 3) {
                                ForEach(questions.indices, id: \.self) { index in
                                    Circle().fill(Theme.warning.opacity(index == state.step ? 1 : 0.35)).frame(width: 4, height: 4)
                                }
                            }
                            .accessibilityElement()
                            .accessibilityLabel("第 \(state.step + 1) 题，共 \(questions.count) 题")
                        }
                    }
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.warning.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chipHeight = $0 }
                    Spacer(minLength: 0)
                }
                .frame(height: Metrics.paneButton)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointingPlain)
            .accessibilityLabel(chipTitle)
            .accessibilityValue(state.collapsed ? "已收起" : "已展开")
            if let delegate, !state.collapsed, !waiting.isSecret {
                Button { state.run { try await delegate() } } label: { Image(systemName: "arrowshape.turn.up.right") }
                    .buttonStyle(PaneButtonStyle())
                    .accessibilityLabel("交给 Line")
                    .help("交给 Line")
            }
            if waiting.isQuestion, !state.collapsed {
                Button { send(.decision("deny")) } label: { Image(systemName: "xmark") }
                    .buttonStyle(PaneButtonStyle())
                    .accessibilityLabel("不回答")
                    .help("不回答")
            }
            Button(action: toggleCollapsed) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(state.collapsed ? 0 : 90))
            }
            .buttonStyle(PaneButtonStyle())
            .accessibilityLabel(state.collapsed ? "展开" : "收起")
            .help(state.collapsed ? "展开" : "收起")
        }
    }

    private var chipTitle: String { RemoteWaiting.title(of: waiting.kind) }

    /// 选项、卡片里的输入框灰底的圆角：线程里和玻璃同心（ComposerLayout.fieldFillRadius），收件箱里按列表的。
    private var fillRadius: CGFloat { inset ? ComposerLayout.fieldFillRadius : 10 }

    private func toggleCollapsed() {
        let state = state
        withAnimation(ComposerMotion.animation) { state.collapsed.toggle() }
    }

    // MARK: - 提问

    /// 问题正文和输入框的字对齐；选项带灰底，离玻璃边 controlInset，里面的字仍和正文对齐。
    private func question(_ question: RemoteWaiting.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question).font(Theme.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, inset ? ComposerLayout.fieldInset : 0)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options, id: \.label) { option in
                    optionRow(option, multi: question.multiSelect)
                }
            }
            .padding(.horizontal, inset ? Metrics.controlInset : 0)
        }
    }

    private func optionRow(_ option: RemoteWaiting.Option, multi: Bool) -> some View {
        let state = state
        let chosen = state.chosen(option.label)
        return Button { state.choose(option.label) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: multi ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(Theme.body.weight(.semibold))
                    Text(option.description).font(Theme.secondary).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ComposerLayout.fieldInset - Metrics.controlInset).padding(.vertical, 6)
            .background(chosen ? Color.accentColor.opacity(0.12) : ComposerLayout.fieldFill, in: RoundedRectangle(cornerRadius: fillRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: fillRadius, style: .continuous))
        }
        .buttonStyle(.pointingPlain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// 收件箱里没有输入区：卡片自己带「其他」，下面一行左边上一题、下一题，右边发送（答齐了才能按）。
    private func standalone(_ question: RemoteWaiting.Question) -> some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: ComposerLayout.rowSpacing) {
            cardField(TextField("填写其他回答", text: $state.currentOther, axis: .vertical).font(Theme.body).lineLimit(1...4))
                .onSubmit { state.advance(submit: submitAnswers) }
            HStack(spacing: 0) {
                if questions.count > 1 { QuestionStepButtons(answers: state) }
                Spacer(minLength: Metrics.paneButtonGap)
                Button(action: submitAnswers) { Image(systemName: "arrow.up") }
                    .buttonStyle(PaneButtonStyle(fill: state.complete ? .accentColor : Theme.strongPlaceholder))
                    .disabled(!state.complete)
                    .accessibilityLabel("发送").help("发送")
            }
        }
    }

    /// 卡片里的输入框：灰底圆角，文字与选项行的文字对齐。下面输入区的输入框不带底。
    private func cardField(_ field: some View) -> some View {
        field
            .textFieldStyle(.plain)
            .padding(.horizontal, ComposerLayout.fieldInset - Metrics.controlInset)
            .padding(.vertical, ComposerLayout.fieldPadding)
            .background(ComposerLayout.fieldFill, in: RoundedRectangle(cornerRadius: fillRadius, style: .continuous))
    }

    private func submitAnswers() {
        let state = state
        guard state.complete else { return }
        send(.answers(state.replies))
    }

    // MARK: - 审批

    /// 出沙箱的申请：标题是代理写的用途，带密钥时下面写明带着哪几个，命令原文放在代码块里（同对话里的，太长的折起来，展开全部后代码区最高 commandHeight，
    /// 再长在里面滚动），灰底和选项一样离玻璃边 controlInset、圆角同心。连网和必问的动作：标题是要连的主机或动作，下面是为什么要问。
    /// 预置脚本：标题是脚本名，下面是为什么要问，脚本内容同命令原文放在代码块里。
    /// 线程里的决定在输入区的按钮行上（ThreadControlsModel.deciding），收件箱里在卡片底下（decisionActions）。
    private var approval: some View {
        let outside = waiting.outside == true
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(approvalTitle).font(Theme.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if !outside, let reason = waiting.reason {
                    Text(reason).font(Theme.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if outside, let references = waiting.secretReferences, !references.isEmpty {
                    Text("带着密钥 \(references.joined(separator: "、"))").font(Theme.secondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, inset ? ComposerLayout.fieldInset : 0)
            if let code = outside ? waiting.target : waiting.script {
                CodeBlock(text: code, language: "sh", maxLines: 6, radius: fillRadius, terminal: false, maxHeight: commandHeight)
                    .padding(.horizontal, inset ? Metrics.controlInset : 0)
            }
        }
    }

    private var approvalTitle: String {
        if waiting.outside == true { return waiting.reason ?? "运行命令（不在沙箱里）" }
        let target = waiting.target ?? ""
        switch waiting.tool {
        case "shell": return "命令要连 \(target)"
        case "preview_open": return waiting.mustAsk == true ? "装到真机 \(target)" : "运行预览目标 \(target)"
        default: return target
        }
    }

    // MARK: - 密钥请求

    /// 一次要的几项依次排下来。同审批：每项的标题是要的那一项，下面是代理写的用途，同名的已经存在时写明保存是替换；
    /// 值填在灰底的框里，和审批的代码块一样离玻璃边 controlInset、圆角同心，代理给了值时显示出来，没给时按密码遮住。
    /// 线程里的决定在输入区的按钮行上（ThreadControlsModel.deciding），收件箱里在卡片底下（decisionActions）。
    private var secret: some View {
        let secrets = waiting.secrets ?? []
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(secrets.indices, id: \.self) { index in
                secretItem(secrets[index], index: index, last: index == secrets.count - 1)
            }
        }
    }

    private func secretItem(_ item: RemoteWaiting.Secret, index: Int, last: Bool) -> some View {
        let state = state
        let value = Binding(get: { state.secretValues.indices.contains(index) ? state.secretValues[index] : "" },
                            set: { if state.secretValues.indices.contains(index) { state.secretValues[index] = $0 } })
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(item.reason).font(Theme.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if item.exists == true {
                    Text("已经有了，保存会替换原来的值").font(Theme.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, inset ? ComposerLayout.fieldInset : 0)
            cardField(Group {
                if item.value != nil || item.secretKind == "file" {
                    TextField("填写值", text: value, axis: .vertical).lineLimit(1...6)
                } else {
                    SecureField("填写值", text: value)
                }
            }
            .font(Theme.code)
            .autocorrectionDisabled())
            .focused($focusedSecret, equals: index)
            .padding(.horizontal, inset ? Metrics.controlInset : 0)
            .onSubmit { if last { decide(.primary(for: waiting)) } else { focusedSecret = index + 1 } }
        }
    }

    // MARK: - 决定

    /// 收件箱里没有输入区：审批与密钥请求的决定摆在卡片底下一行靠右。
    private var decisionActions: some View {
        HStack(spacing: ThreadControlsModel.actionGap) {
            Spacer(minLength: 0)
            ForEach(WaitingDecision.all(for: waiting), id: \.reply) { decision in
                Button(decision.title) { decide(decision) }
                    .buttonStyle(decision.style)
                    .disabled(decision.response(state) == nil)
            }
        }
        .padding(.horizontal, inset ? Metrics.controlButtonInset : 0)
    }

    private func decide(_ decision: WaitingDecision) {
        if let reply = decision.response(state) { send(reply) }
    }

    private func send(_ reply: WaitingReply) {
        let respond = respond
        state.run { try await respond(reply) }
    }
}

/// 一项等待的作答：答到第几题、各题选了什么、「其他」写了什么，卡片收起没有，回应途中和失败的说明。
/// 线程里卡片和输入区共用一份（WorkThread.answers）：卡片摆选项，输入框写当前这题的「其他」，底部工具栏翻题、发送答案；
/// 收件箱里卡片自己带一份。换成另一项等待时从头来，同一项（比如断线重连后又收到）保留答到一半的。
@Observable final class WaitingAnswers {
    private(set) var waiting: RemoteWaiting?
    var step = 0
    private(set) var selected: [Int: [String]] = [:]
    private(set) var other: [Int: String] = [:]
    var collapsed = false
    /// 密钥请求逐项填的值，空的是没填；只在这台设备的内存里，发给工作机后存进凭据，存的范围按所选的决定（WaitingDecision）。
    var secretValues: [String] = []
    private(set) var busy = false
    private(set) var failure: String?

    init(_ waiting: RemoteWaiting? = nil) {
        if let waiting { adopt(waiting) }
    }

    func adopt(_ waiting: RemoteWaiting) {
        guard self.waiting?.id != waiting.id else { return }
        // 合成的一项后面又连上了同类的新请求：答了的、填了的留着，新的接在后面（见 WorkThread.waiting）
        if let old = self.waiting, old.kind == waiting.kind, waiting.id.hasPrefix(old.id + "|") {
            self.waiting = waiting
            secretValues += (waiting.secrets ?? []).dropFirst(secretValues.count).map { $0.value ?? "" }
            return
        }
        self.waiting = waiting
        step = 0
        selected = [:]
        other = [:]
        collapsed = false
        secretValues = waiting.secrets?.map { $0.value ?? "" } ?? []
        busy = false
        failure = nil
    }

    var questions: [RemoteWaiting.Question] { waiting?.questions ?? [] }

    func answered(_ index: Int) -> Bool {
        !(selected[index] ?? []).isEmpty || !(other[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 每一题都答了，可以发送。
    var complete: Bool { !questions.isEmpty && questions.indices.allSatisfy(answered) }

    var canGoBack: Bool { step > 0 }
    var canGoForward: Bool { step + 1 < questions.count }
    func back() { if canGoBack { step -= 1 } }
    func forward() { if canGoForward { step += 1 } }

    /// 回车：这题答了就去下一题，最后一题交给 submit，答齐没有由它核对。
    func advance(submit: () -> Void) {
        guard answered(step) else { return }
        if canGoForward { step += 1 } else { submit() }
    }

    func chosen(_ label: String) -> Bool { (selected[step] ?? []).contains(label) }

    func choose(_ label: String) {
        var labels = selected[step] ?? []
        if questions.indices.contains(step), questions[step].multiSelect {
            if labels.contains(label) { labels.removeAll { $0 == label } } else { labels.append(label) }
        } else {
            labels = [label]
            // 单选只能有一个答案，选了选项就清掉「其他」
            other[step] = nil
        }
        selected[step] = labels
    }

    /// 当前这题的「其他」。
    var currentOther: String {
        get { other[step] ?? "" }
        set { setOther(newValue, at: step) }
    }

    func setOther(_ value: String, at index: Int) {
        other[index] = value
        // 单选写了「其他」就不再选选项
        let multi = questions.indices.contains(index) && questions[index].multiSelect
        if !multi, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { selected[index] = [] }
    }

    var replies: [WaitingReply.Answer] {
        questions.indices.map { index in
            let labels = selected[index] ?? []
            let text = (other[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return WaitingReply.Answer(selected: labels.isEmpty ? nil : labels, other: text.isEmpty ? nil : text)
        }
    }

    /// 回应（答复、审批、交给 Line）：途中卡片和输入区都不能再按，失败的说明写在卡片上。
    func run(_ action: @escaping () async throws -> Void) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { failure = (error as? KitedError)?.status == 409 ? "这一项已经回应或作废了" : error.localizedDescription }
        }
    }
}

/// 审批与密钥请求的决定：灰底的拒绝（红字）和次级的那一项，主题色的主决定。
/// 审批的次级是允许并记住（必问的没有），主决定是允许一次（必问的叫「批准这一次」）；密钥请求的次级是存为账号共享
/// （只对独立的密钥，环境变量文件里的项总是项目专用；全是文件里的项时没有），主决定是存为项目专用（全是文件里的项时叫「保存」）。
/// 存的两个至少填好一项，填了的都要合规；没填的交回时是没提供。
/// 线程里拒绝和次级的摆在输入区按钮行的左边（ThreadControlsModel.deciding），主决定在主按钮上；收件箱里都摆在卡片底下。
struct WaitingDecision: Equatable {
    /// 审批是 once、remember 或 deny；密钥请求是存的范围 project、account，或 deny。
    let reply: String
    let title: String
    /// 密钥请求的存：回应带上填的值，reply 是范围。
    var saves = false

    static func all(for waiting: RemoteWaiting) -> [WaitingDecision] {
        others(for: waiting) + [primary(for: waiting)]
    }

    static func others(for waiting: RemoteWaiting) -> [WaitingDecision] {
        let deny = WaitingDecision(reply: "deny", title: "拒绝")
        if waiting.isSecret { return [deny] + (waiting.hasStandaloneSecret ? [WaitingDecision(reply: "account", title: "存为账号共享", saves: true)] : []) }
        return [deny] + (waiting.mustAsk == true ? [] : [WaitingDecision(reply: "remember", title: "允许并记住")])
    }

    static func primary(for waiting: RemoteWaiting) -> WaitingDecision {
        if waiting.isSecret { return WaitingDecision(reply: "project", title: waiting.hasStandaloneSecret ? "存为项目专用" : "保存", saves: true) }
        return WaitingDecision(reply: "once", title: waiting.mustAsk == true ? "批准这一次" : "允许一次")
    }

    /// 按这个决定的回应；要存却一项都没填，或填了的有不合规的时为空。
    func response(_ answers: WaitingAnswers) -> WaitingReply? {
        guard saves else { return .decision(reply) }
        let values = answers.secretValues.map { $0.isEmpty ? nil : $0 }
        guard values.contains(where: { $0 != nil }), values.allSatisfy({ $0.map(validSecretValue) ?? true }) else { return nil }
        return .secret(.init(values: values, scope: reply))
    }

    var fill: Color? { reply == "once" || reply == "project" ? .accentColor : nil }
    var secondary: Bool { fill == nil }
    var foreground: Color { reply == "deny" ? Theme.danger : .primary }
    var style: PaneButtonStyle { PaneButtonStyle(text: true, fill: fill, foreground: foreground, secondary: secondary) }
}

/// 多题作答时的上一题、下一题，灰底同次级的决定：收件箱里的卡片和 SwiftUI 输入区共用。
struct QuestionStepButtons: View {
    let answers: WaitingAnswers

    var body: some View {
        HStack(spacing: 0) {
            Button(action: answers.back) { Image(systemName: "arrow.left") }
                .buttonStyle(PaneButtonStyle(secondary: true))
                .disabled(!answers.canGoBack)
                .accessibilityLabel("上一题").help("上一题")
            Button(action: answers.forward) { Image(systemName: "arrow.right") }
                .buttonStyle(PaneButtonStyle(secondary: true))
                .disabled(!answers.canGoForward)
                .accessibilityLabel("下一题").help("下一题")
        }
    }
}

/// 原生输入区里回应卡片的托管视图按它换：这几样变了才重建，免得每次读模型都让 SwiftUI 整个重新比对、重新量高。
struct WaitingResponseKey: Equatable {
    let waiting: RemoteWaiting
    let delegable: Bool
    let colorScheme: ColorScheme?
    let dynamicTypeSize: DynamicTypeSize?
}
