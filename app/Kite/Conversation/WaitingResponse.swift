import SwiftUI

/// 等你回应的卡片（docs/工具审批与提问.md）。线程里它摆在输入区上面、和输入区共用同一张玻璃：出现审批或提问时卡片从输入区上方长出来，
/// 回应后收回去；输入区一直在，提问展开时输入框写当前这题的「其他」、底部工具栏翻题和发送答案（见 ThreadControlsModel.answering），
/// 收起、或者是审批时输入框照常发消息，发出去就跳过这一项（见 ThreadControlsModel.skipping）。
/// Line 的收件箱里同一个对象也用它回应，写回原线程所在的工作机；那里没有输入区，卡片自己带「其他」和按钮。
/// 提问一题一题答，单选、多选都能写「其他」；审批三个决定，必问的没有「允许并记住」，次级的拒绝、允许并记住带灰底。
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
                    if let asking { question(asking) } else { approval.padding(.horizontal, inset ? ComposerLayout.fieldInset : 0) }
                    if let failure = state.failure {
                        Text(failure).font(Theme.secondary).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, inset ? ComposerLayout.fieldInset : 0)
                    }
                    if let asking {
                        if answers == nil { standalone(asking) }
                    } else {
                        approvalActions
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
                        Text(waiting.isQuestion ? "等你回答" : "等你批准").font(Theme.status.weight(.semibold))
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
            .buttonStyle(.plain)
            .clickPointer()
            .accessibilityLabel(waiting.isQuestion ? "等你回答" : "等你批准")
            .accessibilityValue(state.collapsed ? "已收起" : "已展开")
            if let delegate, !state.collapsed {
                Button { state.run { try await delegate() } } label: { Image(systemName: "arrowshape.turn.up.right") }
                    .buttonStyle(PaneButtonStyle())
                    .accessibilityLabel("交给 Line")
                    .help("交给 Line")
            }
            Button(action: toggleCollapsed) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(state.collapsed ? 0 : 90))
            }
            .buttonStyle(PaneButtonStyle())
            .accessibilityLabel(state.collapsed ? "展开" : "收起")
            .help(state.collapsed ? "展开" : "收起")
        }
    }

    /// 灰底的圆角：线程里和玻璃同心（ComposerLayout.fieldFillRadius），收件箱里按列表的。
    private var fillRadius: CGFloat { inset ? ComposerLayout.fieldFillRadius : 10 }

    private func toggleCollapsed() {
        let state = state
        withAnimation(ComposerMotion.animation) { state.collapsed.toggle() }
    }

    // MARK: - 提问

    /// 问题正文和输入框的字对齐；选项的灰底同作答时输入框的灰底，离玻璃边 controlInset，里面的字仍和正文对齐。
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
        .buttonStyle(.plain)
        .clickPointer()
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// 收件箱里没有输入区：卡片自己带「其他」，下面一行左边上一题、下一题，右边发送（答齐了才能按）。
    private func standalone(_ question: RemoteWaiting.Question) -> some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: ComposerLayout.rowSpacing) {
            TextField("其他", text: $state.currentOther, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...4)
                .padding(.horizontal, ComposerLayout.fieldInset - Metrics.controlInset)
                .padding(.vertical, ComposerLayout.fieldPadding)
                .background(ComposerLayout.fieldFill, in: RoundedRectangle(cornerRadius: fillRadius, style: .continuous))
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

    private func submitAnswers() {
        let state = state
        guard state.complete else { return }
        send(.answers(state.replies))
    }

    // MARK: - 审批

    private var approval: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(approvalTitle).font(Theme.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            // 出沙箱的申请：命令原文、代理写的用途，再提示命令会执行代理能改的脚本
            if waiting.outside == true, let command = waiting.target {
                Text(verbatim: command).font(Theme.code).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let reason = waiting.reason {
                Text(reason).font(Theme.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if waiting.outside == true {
                Text("以你的用户身份运行，不受执行授权限制；命令会执行工作区里的脚本（如 package.json、Makefile），代理能修改它们。")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var approvalTitle: String {
        if waiting.outside == true { return "运行命令（不在沙箱里）" }
        let target = waiting.target ?? ""
        return waiting.tool == "shell" ? "命令要连 \(target)" : target
    }

    /// 一行靠右：灰底的拒绝、允许并记住，主题色的允许一次。停止在下面输入区的主按钮上。
    private var approvalActions: some View {
        HStack(spacing: ThreadControlsModel.actionGap) {
            Spacer(minLength: 0)
            Button("拒绝") { send(.decision("deny")) }
                .buttonStyle(PaneButtonStyle(text: true, foreground: Theme.danger, secondary: true))
            if waiting.mustAsk != true {
                Button("允许并记住") { send(.decision("remember")) }
                    .buttonStyle(PaneButtonStyle(text: true, foreground: .primary, secondary: true))
            }
            Button(waiting.mustAsk == true ? "批准这一次" : "允许一次") { send(.decision("once")) }
                .buttonStyle(PaneButtonStyle(text: true, fill: .accentColor))
        }
        .padding(.horizontal, inset ? Metrics.controlButtonInset : 0)
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
    private(set) var busy = false
    private(set) var failure: String?

    init(_ waiting: RemoteWaiting? = nil) {
        if let waiting { adopt(waiting) }
    }

    func adopt(_ waiting: RemoteWaiting) {
        guard self.waiting?.id != waiting.id else { return }
        self.waiting = waiting
        step = 0
        selected = [:]
        other = [:]
        collapsed = false
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

/// 多题作答时的上一题、下一题：收件箱里的卡片和 SwiftUI 输入区共用。
struct QuestionStepButtons: View {
    let answers: WaitingAnswers

    var body: some View {
        HStack(spacing: 0) {
            Button(action: answers.back) { Image(systemName: "arrow.left") }
                .buttonStyle(PaneButtonStyle())
                .disabled(!answers.canGoBack)
                .accessibilityLabel("上一题").help("上一题")
            Button(action: answers.forward) { Image(systemName: "arrow.right") }
                .buttonStyle(PaneButtonStyle())
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
