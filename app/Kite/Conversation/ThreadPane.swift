import SwiftUI

/// 会话窗口：标题显示会话名称，控制区包含输入框和一行按钮。
/// 人发的消息靠右、带气泡；agent 的话铺满这一栏；两段话之间 agent 做的事折成一行，点开看每一步。
struct ThreadPane: View {
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    /// 对话怎么滚：跟不跟着最底下、发送后滑到哪、底下留多少空白。
    @State private var scroll = TranscriptScroll()
    /// 刚发出、气泡还在下面、没开始往上浮的消息。
    @State private var arriving: Set<String> = []
    /// 点开了操作栏的那一行。
    @State private var selected: RowID?
    @State private var titleError: String?

    var body: some View {
        let items = thread.transcript.items
        let pending = thread.transcript.pending
        return PaneWindow(header: PaneHeader(title: thread.title, titleRefresh: .init(
            actionLabel: "重新生成会话标题", progressLabel: "正在重新生成会话标题",
            isRefreshing: thread.regeneratingTitle, enabled: thread.canRegenerateTitle, action: regenerateTitle))) {
            if items.isEmpty && pending.isEmpty {
                VStack(spacing: 20) {
                    Text("说说要做什么")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                    NewThreadContextTemplate()
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            } else {
                // 可见区多高在排版时当场算出来（GeometryReader），留白和它同一次排好。这里的尺寸已经扣掉了
                // 标题栏、控制区和键盘让出的那一截，滚动视图照样伸到它们后面（实测）
                GeometryReader { proxy in
                    ScrollView {
                        TranscriptView(items: items, pending: pending, actionable: true, tail: scroll.tail(visible: proxy.size.height))
                            .font(Theme.body)
                            .frame(maxWidth: Metrics.transcriptWidth)
                            .padding(.horizontal, 16)
                            .padding(.vertical, Metrics.transcriptPadding)
                            .frame(maxWidth: .infinity)
                            // 操作栏开着时，点对话里别的地方收起；点到按钮、别的气泡由它们自己接
                            .contentShape(Rectangle())
                            #if os(iOS)
                            // 收起浮层与子视图的链接点击同时发生，不抢走引用跳转。
                            .simultaneousGesture(TapGesture().onEnded { $selected.close() }, isEnabled: selected != nil)
                            #else
                            .gesture(TapGesture().onEnded { $selected.close() }, isEnabled: selected != nil)
                            #endif
                            .separateScrollPocket()
                    }
                    // 手指一滚就收起操作栏
                    .transcriptScroll(scroll, visibleHeight: proxy.size.height) {
                        if selected != nil { $selected.close() }
                    }
                }
            }
        } controls: { typing in
            ThreadControls(typing: typing, send: send)
                .disabled(area.creatingThread || thread.configuringTemplate)
                .frame(maxWidth: Metrics.transcriptWidth)
        } status: {
            #if os(iOS)
            ThreadStatusChip()
                .offset(y: -1)
            #endif
        } headerActions: {
            ThreadHeaderActions()
        }
        .environment(\.workingDirectory, thread.transcript.root)
        .task(id: "\(thread.previewRun):\(thread.client?.identity.uuidString ?? "")") {
            if thread.isStreamingPreview { await thread.playStreamingPreview() }
            else { await thread.observe() }
        }
        .environment(\.arrivingMessages, arriving)
        .environment(\.selectedRow, $selected)
        .alert("重新生成标题失败", isPresented: Binding(
            get: { titleError != nil }, set: { if !$0 { titleError = nil } }
        )) {
            Button("好", role: .cancel) { titleError = nil }
        } message: { Text(titleError ?? "") }
    }

    private func regenerateTitle() {
        Task {
            do { try await thread.regenerateTitle() }
            catch { titleError = error.localizedDescription }
        }
    }

    /// 发一条消息：先排进队里，对话滑过去（见 TranscriptScroll.send），气泡同时从下往上浮进来。
    private func send(_ message: Message) {
        if thread.isDraft {
            if area.isDraft { model.showNewWorkspace = true }
            else {
                guard !area.creatingThread else { return }
                area.creatingThread = true
                thread.error = nil
                Task {
                    defer { area.creatingThread = false }
                    do { try await model.startThread(in: area, prompt: message.typed) }
                    catch { thread.error = error.localizedDescription }
                }
            }
            return
        }
        arriving.insert(message.id)
        scroll.send { thread.send(message) } alongside: { arriving.remove(message.id) }
    }
}
