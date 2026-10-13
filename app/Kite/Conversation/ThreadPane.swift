import SwiftUI

/// 会话窗口：标题显示会话名称，控制区包含输入框和一行按钮。
/// 人发的消息靠右、带气泡；agent 的话铺满这一栏；两段话之间 agent 做的事折成一行，点开看每一步。
struct ThreadPane: View {
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var pane = ThreadPaneModel()

    var body: some View {
        let empty = !thread.hasTranscript
        let initial = pane.initial(thread)
        let send = { (message: Message, alongside: @escaping () -> Void) in
            pane.send(message, thread: thread, model: model, area: area, alongside: alongside)
        }
        return PaneWindow(header: pane.header(thread: thread, model: model, area: area, initial: initial), usesDots: true,
                          notice: thread.problem.map(PaneNotice.failure)) {
            if initial {
                NewThreadStage(slot: pane.patternSlot, roleError: Bindable(pane).roleError)
            } else if !empty {
                scrollingTranscript
            }
        } controls: { typing in
            ThreadControls(typing: typing, send: send, voiceOwner: pane.patternSlot)
                .disabled(area.creatingWindow != nil || thread.configuringTemplate)
                .frame(maxWidth: Metrics.transcriptWidth)
        } headerStatus: {
            ThreadStatusRing()
        } headerActions: {
            ThreadHeaderActions()
        }
        #if os(macOS)
        .wideControls { typing in
            MacControlsBar(typing: typing, send: send, voiceOwner: pane.patternSlot)
                .disabled(area.creatingWindow != nil || thread.configuringTemplate)
        }
        // 指针移到标题栏、输入区上时图案照样跟着
        .modifier(ThreadPatternPointer(slot: pane.patternSlot))
        #endif
        .environment(\.workingDirectory, thread.transcriptRoot)
        .modifier(ThreadPaneSupport(pane: pane))
    }

    /// 可见区多高在排版时当场算出来（GeometryReader），留白和它同一次排好。这里的尺寸已经扣掉了
    /// 标题栏、控制区和键盘让出的那一截，滚动视图照样伸到它们后面（实测）。
    private var scrollingTranscript: some View {
        @Bindable var pane = pane
        return GeometryReader { proxy in
            #if os(macOS)
            // 选中的行显式传进去：列表是原生的，不在这个视图层级里，只靠环境里的绑定收不到它变了
            MacThreadTranscript(scroll: pane.scroll, arriving: pane.arriving, insets: proxy.safeAreaInsets, selected: pane.selected)
                .ignoresSafeArea()
            #else
            ScrollView {
                ThreadTranscript(scroll: pane.scroll, arriving: pane.arriving, visibleHeight: proxy.size.height)
                    .font(Theme.body)
                    .frame(maxWidth: Metrics.transcriptWidth)
                    .padding(.horizontal, Metrics.padding * 2)
                    .padding(.vertical, Metrics.transcriptPadding)
                    .frame(maxWidth: .infinity)
                    // 操作栏开着时，点对话里别的地方收起；点到按钮、别的气泡由它们自己接
                    .contentShape(Rectangle())
                    // 收起浮层与子视图的链接点击同时发生，不抢走引用跳转。
                    .simultaneousGesture(TapGesture().onEnded { $pane.selected.close() }, isEnabled: pane.selected != nil)
            }
            // 手指一滚就收起操作栏
            .transcriptScroll(pane.scroll, visibleHeight: proxy.size.height) {
                if pane.selected != nil { $pane.selected.close() }
            }
            #endif
        }
        .background {
            GeometryReader { proxy in
                ThreadVoiceBand(pane: pane, bottom: proxy.safeAreaInsets.bottom)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// 会话窗口的状态和动作，SwiftUI 版（ThreadPane）和 Mac 宽屏的原生外框（ThreadWindowView）共用。窗口在就一直是同一个。
@MainActor @Observable final class ThreadPaneModel {
    /// 对话怎么滚：跟不跟着最底下、发送后滑到哪、底下留多少空白。Mac 上是原生列表，见 TranscriptListView。
    #if os(macOS)
    @ObservationIgnored let scroll = MacTranscriptScroll()
    #else
    @ObservationIgnored let scroll = TranscriptScroll()
    #endif
    /// 刚发出、气泡还在下面、没开始往上浮的消息。
    @ObservationIgnored let arriving = ArrivingMessages()
    /// 点开了操作栏的那一行。
    var selected: RowID?
    var titleError: String?
    /// 标题栏模板菜单里「基于…新建模板」打开的编辑器，与模板读取、套用失败的说明。
    var roleEdit: RoleDefinition?
    var roleError: String?
    /// 空会话铺在窗口上的点阵签名，见 NewThreadStage。也是这个窗口录语音时的标识，见 VoiceInput.owner。
    @ObservationIgnored let patternSlot = "pattern.\(UUID().uuidString)"
    /// 已有对话时，语音输入铺在窗口底部一带的签名，见 VoiceBand。
    @ObservationIgnored let voiceSlot = "voice.\(UUID().uuidString)"

    /// 还没有消息的代理，铺满整窗的点阵签名。已有代理的历史还没到时先什么也不画，不铺新代理的点阵图案，免得长出来又马上收回。
    func initial(_ thread: WorkThread) -> Bool {
        !thread.hasTranscript && (thread.isDraft || thread.historyLoaded)
    }

    func listening(_ model: AppModel) -> Bool { model.voice.owner == patternSlot }

    /// 这个代理的角色签名；角色列表还没读到或角色没有签名时用默认图案。
    func emblem(thread: WorkThread, model: AppModel, area: WorkArea, environment: EnvironmentValues) -> DotPattern? {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        return (model.emblem(for: thread.id, in: area) ?? .fallback).pattern(accent: accent)
    }

    /// 副标题是代理的角色。还没有对话时副标题带下拉箭头，在这里换角色；标题还没生成，不给重新生成。
    func header(thread: WorkThread, model: AppModel, area: WorkArea, initial: Bool) -> PaneHeader {
        PaneHeader(title: thread.title, subtitle: model.roleTitle(for: thread, in: area),
            subtitleMenu: initial ? .init(label: "角色", isBusy: thread.configuringTemplate,
                enabled: model.canSelectRole(for: thread, in: area),
                content: AnyView(NewThreadRoleMenu(select: { [weak self] in self?.selectRole($0, thread: thread, model: model, area: area) }) {
                    [weak self] in self?.roleEdit = $0.role.copy()
                }))
                : nil,
            titleRefresh: initial ? nil : .init(
                actionLabel: "重新生成标题", progressLabel: "正在重新生成标题",
                isRefreshing: thread.regeneratingTitle, enabled: thread.canRegenerateTitle,
                action: { [weak self] in self?.regenerateTitle(thread) }))
    }

    func selectRole(_ role: AgentRole, thread: WorkThread, model: AppModel, area: WorkArea) {
        roleError = nil
        Task {
            do { try await model.selectNewThreadRole(role, for: thread, in: area) }
            catch { roleError = error.localizedDescription }
        }
    }

    func regenerateTitle(_ thread: WorkThread) {
        Task {
            do { try await thread.regenerateTitle() }
            catch { titleError = error.localizedDescription }
        }
    }

    /// 发一条消息：先排进队里，对话滑过去（见 TranscriptScroll.send），气泡同时从下往上浮进来，alongside 也和滑同一次更新。
    /// 草稿的第一条也这样走，同时创建代理；建好后同一个会话对象原地变成这个代理，窗口不换，失败时消息退回输入框。
    func send(_ message: Message, thread: WorkThread, model: AppModel, area: WorkArea, alongside: @escaping () -> Void) {
        if thread.isDraft {
            if area.isDraft { model.newWorkspace = .session; return }
            guard area.creatingWindow == nil, let window = area.draftWindow else { return }
            area.creatingWindow = window
            thread.error = nil
            let draft = thread
            Task {
                defer { area.creatingWindow = nil }
                do { try await model.startThread(in: area, message: message, window: window) }
                catch { draft.firstMessageFailed(message, error: error.localizedDescription) }
            }
        }
        let arriving = arriving
        arriving.ids.insert(message.id)
        scroll.send { thread.send(message) } alongside: {
            arriving.ids.remove(message.id)
            alongside()
        }
    }
}

/// 会话窗口里不占地方的几样：录音时空会话的签名和底部那一带随响度起伏、窗口关掉时停掉自己的录音、
/// 窗口动画走完才订阅历史、选中的行、标题和角色的弹窗。SwiftUI 版挂在 ThreadPane 上，Mac 原生外框挂在 ThreadPaneBridge 上。
struct ThreadPaneSupport: ViewModifier {
    let pane: ThreadPaneModel
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.windowMotion) private var windowMotion
    @Environment(\.dotStage) private var stage

    func body(content: Content) -> some View {
        @Bindable var pane = pane
        let listening = pane.listening(model)
        content
            // 空会话的签名和底部那一带都随录音的响度起伏
            .onChange(of: listening, initial: true) {
                for slot in [pane.patternSlot, pane.voiceSlot] { stage?.patternSound(listening ? model.voice.level : nil, slot: slot) }
            }
            .onDisappear { model.voice.stop(owner: pane.patternSlot) }
            .task(id: thread.client?.identity) {
                // 打开时先完成窗口的移动，再接收并排版历史；不在每次拖动时重连已经建立的订阅。
                await Task.yield()
                while windowMotion?.moving == true || windowMotion?.interacting == true {
                    do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                await thread.observe()
            }
            .environment(\.selectedRow, $pane.selected)
            .alert("重新生成标题失败", isPresented: Binding(
                get: { pane.titleError != nil }, set: { if !$0 { pane.titleError = nil } }
            )) {
                Button("好", role: .cancel) { pane.titleError = nil }
            } message: { Text(pane.titleError ?? "") }
            .sheet(item: $pane.roleEdit) { role in
                RoleEditor(role: role, connection: model.revision(for: area)) {
                    pane.selectRole($0, thread: thread, model: model, area: area)
                }
                .environment(model)
            }
    }
}

#if os(macOS)
/// Mac 上指针在整个窗口里移动，空会话的签名都跟着。
private struct ThreadPatternPointer: ViewModifier {
    let slot: String
    @Environment(\.dotStage) private var stage

    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .global) { phase in
            if case .active(let point) = phase { stage?.patternPointer(point, slot: slot) }
            else { stage?.patternPointer(nil, slot: slot) }
        }
    }
}
#endif

/// 录音时铺在窗口底部一带的签名，录着才有图案。bottom 是控制区的高。
struct ThreadVoiceBand: View {
    let pane: ThreadPaneModel
    let bottom: CGFloat
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.self) private var environment

    var body: some View {
        VoiceBand(pattern: pane.listening(model) ? pane.emblem(thread: thread, model: model, area: area, environment: environment) : nil,
                  slot: pane.voiceSlot, bottom: bottom)
    }
}

/// 语音输入时铺在窗口底部一带的签名：从窗口底边往上，盖过控制区再高出几格，随录音的响度（v）起伏、往上涨，停下就收回。
/// 大半在控制区的玻璃后面，透出来的是模糊的光，高出来的几格和两侧露出图案本身。bottom 是控制区的高，图案铺到窗口底边。
private struct VoiceBand: View {
    let pattern: DotPattern?
    let slot: String
    let bottom: CGFloat

    /// 静音时高出控制区的格数，和响度到 1 时涨到的格数。
    private static let quiet: CGFloat = 3
    private static let loud: CGFloat = 9

    var body: some View {
        DotPatternArea(pattern: pattern, rise: bottom + Self.quiet * DotMetrics.pitch, slot: slot)
            .frame(height: bottom + Self.loud * DotMetrics.pitch)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }
}

/// 对话本身：窗口里只有它读 transcript，收发消息和流式刷新只重算这一块，不牵动标题栏和控制区。
#if os(macOS)
private struct MacThreadTranscript: View {
    let scroll: MacTranscriptScroll
    let arriving: ArrivingMessages
    let insets: EdgeInsets
    let selected: RowID?
    @Environment(WorkThread.self) private var thread

    var body: some View {
        MacTranscript(rows: TranscriptRow.rows(items: thread.transcript.items, pending: thread.transcript.pending),
                      scroll: scroll, insets: insets, selected: selected)
            .font(Theme.body)
            .environment(\.arrivingMessages, arriving.ids)
    }
}
#else
private struct ThreadTranscript: View {
    let scroll: TranscriptScroll
    let arriving: ArrivingMessages
    let visibleHeight: CGFloat
    @Environment(WorkThread.self) private var thread

    var body: some View {
        TranscriptView(items: thread.transcript.items, pending: thread.transcript.pending, actionable: true,
                       tail: scroll.tail(visible: visibleHeight))
            .environment(\.arrivingMessages, arriving.ids)
    }
}
#endif

/// 刚发出、还没浮上来的消息，只由对话那一块读，发送时不重算整个窗口。
@Observable final class ArrivingMessages {
    var ids: Set<String> = []
}
