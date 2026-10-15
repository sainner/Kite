import SwiftUI

/// 等你回应的卡片内容（docs/工具审批与提问.md）。线程里它代替输入框，和输入框共用同一张玻璃：出现审批或提问时输入框换成它，
/// 回应后换回来；Line 的收件箱里同一个对象也用它回应，写回原线程所在的工作机。
/// 提问一题一题答，单选、多选都能写「其他」；审批三个决定，必问的没有「允许并记住」。线程里左下角的停止按未回答处理。
/// 版式同输入区：内容左右留 controlInset + 8，按钮行左右、底留 controlButtonInset；inset 为假时不留（收件箱里按列表的边距）。
struct WaitingResponseCard: View {
    let waiting: RemoteWaiting
    let respond: (WaitingReply) async throws -> Void
    /// 停止这个回合；收件箱里没有。
    var stop: (() -> Void)? = nil
    var canStop = true
    /// 交给 Line 代处理；没有 Line，或这是 Line 自己发起的请求时为空。
    var delegate: (() async throws -> Void)? = nil
    var inset = true

    @State private var step = 0
    @State private var selected: [Int: [String]] = [:]
    @State private var other: [Int: String] = [:]
    @State private var busy = false
    @State private var failure: String?

    private var questions: [RemoteWaiting.Question] { waiting.questions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if waiting.isQuestion, questions.indices.contains(step) { question(questions[step]) } else { approval }
            if let failure {
                Text(failure).font(Theme.secondary).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(.horizontal, inset ? Metrics.controlInset + 8 : 0)
        .padding(.top, inset ? Metrics.controlInset + 4 : 0)
        .padding(.bottom, inset ? Metrics.controlButtonInset : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(busy)
        .onChange(of: waiting.id) {
            step = 0
            selected = [:]
            other = [:]
            failure = nil
        }
    }

    // MARK: - 标题行

    private var header: some View {
        HStack(spacing: 6) {
            Text(waiting.isQuestion ? "等你回答" : "等你批准")
                .font(Theme.status.weight(.semibold))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.warning.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(subtitle).font(Theme.status).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if questions.count > 1 {
                HStack(spacing: 4) {
                    ForEach(questions.indices, id: \.self) { index in
                        Circle().fill(index == step ? Color.accentColor : Theme.rule).frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("第 \(step + 1) 题，共 \(questions.count) 题")
            }
        }
    }

    private var subtitle: String {
        if waiting.isQuestion { return questions.indices.contains(step) ? questions[step].header : "" }
        if waiting.mustAsk == true { return "必问" }
        return waiting.tool == "shell" ? "运行命令" : waiting.tool ?? ""
    }

    // MARK: - 提问

    private func question(_ question: RemoteWaiting.Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.question).font(Theme.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(question.options, id: \.label) { option in
                optionRow(option, multi: question.multiSelect)
            }
            otherField(multi: question.multiSelect)
        }
    }

    private func optionRow(_ option: RemoteWaiting.Option, multi: Bool) -> some View {
        let chosen = (selected[step] ?? []).contains(option.label)
        return Button {
            var labels = selected[step] ?? []
            if multi {
                if chosen { labels.removeAll { $0 == option.label } } else { labels.append(option.label) }
            } else {
                labels = [option.label]
                // 单选只能有一个答案，选了选项就清掉「其他」
                other[step] = nil
            }
            selected[step] = labels
        } label: {
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
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(chosen ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func otherField(multi: Bool) -> some View {
        let text = Binding<String>(get: { other[step] ?? "" }, set: { value in
            other[step] = value
            // 单选写了「其他」就不再选选项
            if !multi, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { selected[step] = [] }
        })
        return TextField("其他：写你自己的回答", text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.body)
            .lineLimit(1...4)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule))
            .onSubmit { if answered(step) { advance() } }
    }

    private func answered(_ index: Int) -> Bool {
        !(selected[index] ?? []).isEmpty || !(other[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func advance() {
        if step + 1 < questions.count { step += 1 } else { submitAnswers() }
    }

    private func submitAnswers() {
        let answers = questions.indices.map { index in
            let labels = selected[index] ?? []
            let text = (other[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return WaitingReply.Answer(selected: labels.isEmpty ? nil : labels, other: text.isEmpty ? nil : text)
        }
        send(.answers(answers))
    }

    // MARK: - 审批

    private var approval: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(approvalTitle).font(Theme.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let reason = waiting.reason {
                Text(reason).font(Theme.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var approvalTitle: String {
        let target = waiting.target ?? ""
        return waiting.tool == "shell" ? "命令要连 \(target)" : target
    }

    // MARK: - 按钮

    private var actions: some View {
        HStack(spacing: Metrics.paneButtonGap / 2) {
            if let stop {
                Button("停止", action: stop)
                    .buttonStyle(PaneButtonStyle(text: true))
                    .disabled(!canStop)
                    .help("停止这个回合，按没有回应处理")
            }
            Spacer(minLength: 0)
            if let delegate {
                Button("交给 Line") { run { try await delegate() } }
                    .buttonStyle(PaneButtonStyle(text: true, foreground: .accentColor))
            }
            if waiting.isQuestion {
                if step > 0 {
                    Button("上一题") { step -= 1 }.buttonStyle(PaneButtonStyle(text: true))
                }
                Button(step + 1 < questions.count ? "下一题" : "提交", action: advance)
                    .buttonStyle(PaneButtonStyle(text: true, fill: .accentColor))
                    .disabled(!answered(step))
            } else {
                Button("拒绝") { send(.decision("deny")) }
                    .buttonStyle(PaneButtonStyle(text: true, foreground: Theme.danger))
                if waiting.mustAsk != true {
                    Button("允许并记住") { send(.decision("remember")) }.buttonStyle(PaneButtonStyle(text: true, foreground: .primary))
                }
                Button(waiting.mustAsk == true ? "批准这一次" : "允许一次") { send(.decision("once")) }
                    .buttonStyle(PaneButtonStyle(text: true, fill: .accentColor))
            }
        }
    }

    private func send(_ reply: WaitingReply) {
        run { try await respond(reply) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { failure = (error as? KitedError)?.status == 409 ? "这一项已经回应或作废了" : error.localizedDescription }
        }
    }
}

/// 原生输入区里回应卡片的托管视图按它换：这几样变了才重建，免得每次读模型都让 SwiftUI 整个重新比对、重新量高。
struct WaitingResponseKey: Equatable {
    let waiting: RemoteWaiting
    let canStop: Bool
    let delegable: Bool
    let colorScheme: ColorScheme?
    let dynamicTypeSize: DynamicTypeSize?
}
