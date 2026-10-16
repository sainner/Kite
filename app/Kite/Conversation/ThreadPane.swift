import SwiftUI

#if os(macOS)
/// Mac 窄窗口（紧凑布局）里的会话窗口：标题显示会话名称，控制区包含输入框和一行按钮，都由外壳统一显示（CompactPaneHeaderHost），
/// 对话是原生列表（TranscriptListView）。宽屏的会话窗口外框是原生的 ThreadWindowView，iPhone、iPad 的是 PhoneThreadWindowView；
/// 那几处在 SwiftUI 正文里只放 ThreadPaneBridge。
struct ThreadPane: View {
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var pane = ThreadPaneModel()

    var body: some View {
        let empty = !thread.hasTranscript
        let initial = thread.isInitial
        let send = { (message: Message, alongside: @escaping () -> Void) in
            pane.send(message, thread: thread, model: model, area: area, alongside: alongside)
        }
        // 圆环和菜单自己带着会话，同 PhoneThreadWindowView 的紧凑标题栏
        return PaneWindow(header: pane.header(thread: thread, model: model, area: area, initial: initial), usesDots: true,
                          notice: model.threadNotice(thread, in: area), status: AnyView(ThreadStatusRing().environment(thread)),
                          actions: PaneHeaderActions(menus: AnyView(ThreadHeaderActions().environment(thread)))) {
            if initial {
                NewThreadStage(slot: pane.patternSlot)
            } else if !empty {
                scrollingTranscript
            }
        } controls: { typing in
            ThreadControls(typing: typing, send: send, voiceOwner: pane.patternSlot)
                .disabled(area.creatingWindow != nil || thread.configuringTemplate)
                .frame(maxWidth: Metrics.transcriptWidth)
        }
        // 指针移到标题栏、输入区上时图案照样跟着
        .modifier(ThreadPatternPointer(slot: pane.patternSlot))
        .environment(\.workingDirectory, thread.transcriptRoot)
        .modifier(ThreadPaneSupport(pane: pane))
    }

    /// 列表铺满窗口，标题栏、控制区让出的距离量出来交给它（GeometryReader 的安全区），
    /// 内容从它们后面滚过去。选中的行显式传进去：列表是原生的，不在这个视图层级里，只靠环境里的绑定收不到它变了。
    private var scrollingTranscript: some View {
        @Bindable var pane = pane
        return GeometryReader { proxy in
            MacThreadTranscript(scroll: pane.scroll, arriving: pane.arriving, insets: proxy.safeAreaInsets, selected: pane.selected)
                .ignoresSafeArea()
        }
        .background {
            GeometryReader { proxy in
                ThreadVoiceBand(pane: pane, bottom: proxy.safeAreaInsets.bottom)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

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

/// 对话本身：窗口里只有它读 transcript，收发消息和流式刷新只重算这一块，不牵动标题栏和控制区。
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
#endif

/// 会话窗口的状态和动作，建好就一直是同一个：Mac 窄窗口的 ThreadPane、各个原生会话窗口外框（ThreadWindowView、
/// PhoneThreadWindowView、紧凑布局里的原生会话窗口）经 ThreadPaneBridge 各持一个。
@MainActor @Observable final class ThreadPaneModel {
    /// 对话怎么滚：跟不跟着最底下、发送后滑到哪、底下留多少空白。两端都是原生列表，见 TranscriptListView、PhoneTranscriptView。
    #if os(macOS)
    @ObservationIgnored let scroll = MacTranscriptScroll()
    #else
    @ObservationIgnored let scroll = PhoneTranscriptScroll()
    #endif
    /// 刚发出、气泡还在下面、没开始往上浮的消息。
    @ObservationIgnored let arriving = ArrivingMessages()
    /// 点开了操作栏的那一行。
    var selected: RowID?
    var titleError: String?
    /// 标题栏模板菜单里「基于…新建模板」打开的编辑器；读取、套用失败的说明在会话的 roleError。
    var roleEdit: RoleDefinition?
    /// 空会话铺在窗口上的点阵签名，见 NewThreadStage。也是这个窗口录语音时的标识，见 VoiceInput.owner。
    @ObservationIgnored let patternSlot = "pattern.\(UUID().uuidString)"
    /// 已有对话时，语音输入铺在窗口底部一带的签名，见 VoiceBand。
    @ObservationIgnored let voiceSlot = "voice.\(UUID().uuidString)"

    func listening(_ model: AppModel) -> Bool { model.voice.owner == patternSlot }

    /// 这个代理的角色签名；角色列表还没读到或角色没有签名时用默认图案。
    func emblem(thread: WorkThread, model: AppModel, area: WorkArea, environment: EnvironmentValues) -> DotPattern? {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        return (model.emblem(for: thread.id, in: area) ?? .fallback).pattern(accent: accent)
    }

    /// 副标题是代理的角色。还没有对话时副标题带下拉箭头，在这里换角色，角色没读到时在这里重读；标题还没生成，不给重新生成。
    func header(thread: WorkThread, model: AppModel, area: WorkArea, initial: Bool) -> PaneHeader {
        PaneHeader(title: thread.title, subtitle: model.roleTitle(for: thread, in: area),
            subtitleMenu: initial ? .init(label: "角色", isBusy: thread.configuringTemplate,
                enabled: model.canSelectRole(for: thread, in: area) || model.canReloadNewThreadRoles(for: thread, in: area),
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
        thread.roleError = nil
        Task {
            do { try await model.selectNewThreadRole(role, for: thread, in: area) }
            catch { thread.roleError = error.localizedDescription }
        }
    }

    func regenerateTitle(_ thread: WorkThread) {
        Task {
            do { try await thread.regenerateTitle() }
            catch { titleError = error.localizedDescription }
        }
    }

    /// 发一条消息：先排进队里，对话滑过去（见 TranscriptFollow.send），气泡同时从下往上浮进来，alongside 也和滑同一次更新。
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
/// 窗口动画走完才订阅历史、选中的行、标题和角色的弹窗。Mac 窄窗口挂在 ThreadPane 上，原生外框挂在 ThreadPaneBridge 上。
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

/// 语音输入时铺在窗口底部一带的签名：从窗口底边往上，盖过控制区、占到窗口的大半截，随录音的响度（v）起伏、往上涨，停下就收回。
/// 控制区的玻璃后面透出来的是模糊的光，上面和两侧露出图案本身。bottom 是控制区的高，图案铺到窗口底边。
private struct VoiceBand: View {
    let pattern: DotPattern?
    let slot: String
    let bottom: CGFloat

    /// 响度到 1 时中间涨到窗口高的几成，静音时铺到其中的几成；静音时至少高出控制区几格。
    private static let loud: CGFloat = 0.6
    private static let quiet: CGFloat = 0.6
    private static let above: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height * Self.loud
            DotPatternArea(pattern: pattern, rise: min(max(height * Self.quiet, bottom + Self.above * DotMetrics.pitch), height), slot: slot)
                .frame(height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}


/// 刚发出、还没浮上来的消息，只由对话那一块读，发送时不重算整个窗口。
@Observable final class ArrivingMessages {
    var ids: Set<String> = []
}
