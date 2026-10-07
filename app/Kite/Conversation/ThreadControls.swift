import SwiftUI

/// 会话窗口的控制区：输入框与服务支持的操作。发送、打断、继续由真实状态控制，未接通的入口禁用。
/// 发出去的字在输入框里模糊、淡掉，同时气泡在对话里从下往上浮进来（见 ThreadPane.send）。
struct ThreadControls: View {
    var typing: FocusState<Bool>.Binding
    let send: (Message) -> Void
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.paneInstance) private var instance
    @Environment(\.dotStage) private var stage
    /// 控制区在窗口坐标中的位置，发送时点阵的波从这里推开。
    @State private var frame: CGRect = .zero
    /// 刚发出去的字正在淡掉。
    @State private var leaving = false
    @State private var effortDraft: Effort?
    @State private var savingEffort = false
    @State private var effortError: String?

    var body: some View {
        @Bindable var thread = thread
        let running = thread.transcript.running
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        VStack(spacing: 2) {
            TextField(running ? "插话，agent 做完手上这一步就会看到" : "回复", text: $thread.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...8)
                .focused(typing)
                .onSubmit(submit)
                .blur(radius: leaving ? 6 : 0)
                .opacity(leaving ? 0 : 1)
                .padding(.horizontal, Metrics.controlInset + 8)
                .padding(.vertical, 6)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.paneButtonGap) {
                    effortControl.fixedSize()
                    Spacer(minLength: 0)
                    actionButtons.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    effortControl
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        actionButtons
                    }
                }
            }
            .padding(.horizontal, Metrics.controlButtonInset)
        }
        .padding(.top, Metrics.controlInset)
        .padding(.bottom, Metrics.controlButtonInset)
        // 交互玻璃的同心形状有高光退回胶囊的复现；玻璃与交互轮廓统一使用明确圆角。
        .contentShape(.interaction, shape)
        #if os(iOS)
        .contentShape(.hoverEffect, shape)
        #endif
        .glassEffect(.regular.interactive(), in: shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .alert("修改思考强度失败", isPresented: Binding(get: { effortError != nil }, set: { if !$0 { effortError = nil } })) {
            Button("好", role: .cancel) { effortError = nil }
        } message: { Text(effortError ?? "") }
    }

    @ViewBuilder
    private var effortControl: some View {
        if let effort = Effort.allCases.first(where: { $0.name == reasoning }) {
            EffortPicker(effort: Binding(get: { effortDraft ?? effort }, set: { effortDraft = $0 }),
                         allowed: availableEfforts, commit: saveEffort, cancel: { effortDraft = nil })
                .allowsHitTesting(canChangeEffort)
                .help(thread.agentCapabilities?.explanation ?? "正在读取模型能力")
        } else {
            Menu {
                ForEach(availableEfforts, id: \.self) { value in
                    Button(value.name) { effortDraft = value; saveEffort() }
                }
            } label: { Text(reasoning == "default" ? "自动" : reasoning).font(Theme.secondary).foregroundStyle(.secondary).padding(.horizontal, 8) }
                .disabled(!canChangeEffort)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            if thread.isStreamingPreview {
                Button("重播") {
                    thread.previewRun += 1
                    stage?.emitWave(from: frame)
                }
                    .buttonStyle(PaneButtonStyle(text: true))
            }

            HStack(spacing: 0) {
                Button {} label: { Image(systemName: "paperclip") }
                    .buttonStyle(PaneButtonStyle())
                    .disabled(true).accessibilityLabel("添加附件")
                Button {} label: { Image(systemName: "mic") }
                    .buttonStyle(PaneButtonStyle())
                    .disabled(true).accessibilityLabel("语音输入")
            }
            if thread.showStop {
                Button {
                    thread.stop()
                } label: { Image(systemName: "stop.fill") }
                .buttonStyle(PaneButtonStyle(fill: Theme.strongPlaceholder))
                .disabled(!thread.canStop)
                .accessibilityLabel("停止")
            }
            if thread.state?.capabilities.resume == true {
                Button("继续") { thread.control("resume") }
                    .buttonStyle(PaneButtonStyle(text: true))
                    .disabled(!thread.canResume)
                    .accessibilityLabel("继续")
            }
            if !blank && !leaving {
                Button(action: submit) { Image(systemName: "arrow.up") }
                    .buttonStyle(PaneButtonStyle(fill: .accentColor))
                    .disabled(!thread.canSend)
                    .accessibilityLabel("发送")
            }
        }
    }

    private var blank: Bool {
        thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var reasoning: String { instance?.config?.agent?.model.reasoning ?? "medium" }
    private var availableEfforts: [Effort] {
        if area.isSample { return Effort.allCases }
        let levels = thread.agentCapabilities?.model(instance?.config?.agent?.model.model ?? "")?.reasoning ?? []
        return Effort.allCases.filter { levels.contains($0.name) }
    }
    private var canChangeEffort: Bool {
        instance != nil && !savingEffort && !availableEfforts.isEmpty
            && (area.isSample || (model.isConnected(area) && thread.agentCapabilities?.canEdit(thread.state) == true))
    }
    private func saveEffort() {
        guard canChangeEffort, let effortDraft, effortDraft.name != reasoning, let instance else { self.effortDraft = nil; return }
        savingEffort = true
        Task {
            defer { savingEffort = false; self.effortDraft = nil }
            do {
                if area.isSample, let index = area.instances.firstIndex(where: { $0.id == instance.id }) {
                    area.instances[index].config?.agent?.model.reasoning = effortDraft.name
                } else {
                    try await model.updateAgent(in: area, id: instance.id) { $0.model.reasoning = effortDraft.name }
                }
            } catch { effortError = error.localizedDescription }
        }
    }

    private func submit() {
        guard !blank, !leaving, thread.canSend else { return }
        let sent = thread.draft
        send(Message(typed: sent.trimmingCharacters(in: .whitespacesAndNewlines)))
        // 新会话先选择项目；关闭选择窗口时仍保留原输入。
        guard !thread.isDraft else { return }
        stage?.emitWave(from: frame)
        let submission = thread.beginDraftSubmission()
        // 淡完才清空，输入框不在淡的时候变矮。淡的时候又打了字的，只去掉发出去的那一截
        withAnimation(.easeOut(duration: 0.3)) {
            leaving = true
        } completion: {
            thread.finishDraftSubmission(submission)
            leaving = false
        }
    }
}
