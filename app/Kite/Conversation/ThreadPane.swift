import SwiftUI

/// 会话窗口：标题显示会话名称，控制区包含输入框和一行按钮。
/// 人发的消息靠右、带气泡；agent 的话铺满这一栏；两段话之间 agent 做的事折成一行，点开看每一步。
struct ThreadPane: View {
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(\.windowMotion) private var windowMotion
    @Environment(WorkArea.self) private var area
    /// 对话怎么滚：跟不跟着最底下、发送后滑到哪、底下留多少空白。
    @State private var scroll = TranscriptScroll()
    /// 刚发出、气泡还在下面、没开始往上浮的消息。
    @State private var arriving = ArrivingMessages()
    /// 点开了操作栏的那一行。
    @State private var selected: RowID?
    @State private var titleError: String?
    /// 标题栏模板菜单里「基于…新建模板」打开的编辑器，与模板读取、套用失败的说明。
    @State private var roleEdit: RoleDefinition?
    @State private var roleError: String?
    /// 空会话铺在窗口上的点阵签名，见 NewThreadStage。也是这个窗口录语音时的标识，见 VoiceInput.owner。
    @State private var patternSlot = "pattern.\(UUID().uuidString)"
    /// 已有对话时，语音输入铺在窗口底部一带的签名，见 VoiceBand。
    @State private var voiceSlot = "voice.\(UUID().uuidString)"
    @Environment(\.dotStage) private var stage
    @Environment(\.self) private var environment

    var body: some View {
        let empty = !thread.hasTranscript
        // 已有代理的历史还没到时先什么也不画，不铺新代理的点阵图案，免得长出来又马上收回
        let initial = empty && (thread.isDraft || thread.historyLoaded)
        return PaneWindow(header: header(initial: initial), usesDots: true, notice: thread.problem.map(PaneNotice.failure)) {
            if initial {
                NewThreadStage(slot: patternSlot, roleError: $roleError)
            } else if !empty {
                // 可见区多高在排版时当场算出来（GeometryReader），留白和它同一次排好。这里的尺寸已经扣掉了
                // 标题栏、控制区和键盘让出的那一截，滚动视图照样伸到它们后面（实测）
                GeometryReader { proxy in
                    ScrollView {
                        ThreadTranscript(scroll: scroll, arriving: arriving, visibleHeight: proxy.size.height, lazy: Self.lazyTranscript)
                            .font(Theme.body)
                            .frame(maxWidth: Metrics.transcriptWidth)
                            .padding(.horizontal, Metrics.padding * 2)
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
                .background { VoiceBand(pattern: listening ? emblem : nil, slot: voiceSlot) }
            }
        } controls: { typing in
            ThreadControls(typing: typing, send: send, voiceOwner: patternSlot)
                .disabled(area.creatingWindow != nil || thread.configuringTemplate)
                .frame(maxWidth: Metrics.transcriptWidth)
        } headerStatus: {
            ThreadStatusRing()
        } headerActions: {
            ThreadHeaderActions()
        }
        #if os(macOS)
        // 指针移到标题栏、输入区上时图案照样跟着
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case .active(let point) = phase { stage?.patternPointer(point, slot: patternSlot) }
            else { stage?.patternPointer(nil, slot: patternSlot) }
        }
        #endif
        .environment(\.workingDirectory, thread.transcriptRoot)
        // 空会话的签名和底部那一带都随录音的响度起伏
        .onChange(of: listening, initial: true) {
            for slot in [patternSlot, voiceSlot] { stage?.patternSound(listening ? model.voice.level : nil, slot: slot) }
        }
        .onDisappear { model.voice.stop(owner: patternSlot) }
        .task(id: thread.client?.identity) {
            // 打开时先完成窗口的移动，再接收并排版历史；不在每次拖动时重连已经建立的订阅。
            await Task.yield()
            while windowMotion?.moving == true || windowMotion?.interacting == true {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await thread.observe()
        }
        .environment(\.selectedRow, $selected)
        .alert("重新生成标题失败", isPresented: Binding(
            get: { titleError != nil }, set: { if !$0 { titleError = nil } }
        )) {
            Button("好", role: .cancel) { titleError = nil }
        } message: { Text(titleError ?? "") }
        .sheet(item: $roleEdit) { role in
            RoleEditor(role: role, connection: model.revision(for: area)) { selectRole($0) }
                .environment(model)
        }
    }

    private var listening: Bool { model.voice.owner == patternSlot }

    /// 这个代理的角色签名；角色列表还没读到或角色没有签名时用默认图案。
    private var emblem: DotPattern? {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        return (model.emblem(for: thread.id, in: area) ?? .fallback).pattern(accent: accent)
    }

    /// 只在 Mac 上按需排版：长会话改窗口宽度时只重排看得见的。iPhone 上窗口宽度不变，省不下重排；
    /// 按需排版后在底部展开工具行出现过先原地跳一下、再往下展开（2026-10-09 用户在 iPhone 上实测），所以仍整个排。
    #if os(macOS)
    private static let lazyTranscript = true
    #else
    private static let lazyTranscript = false
    #endif

    /// 副标题是代理的角色。还没有对话时副标题带下拉箭头，在这里换角色；标题还没生成，不给重新生成。
    private func header(initial: Bool) -> PaneHeader {
        PaneHeader(title: thread.title, subtitle: model.roleTitle(for: thread, in: area),
            subtitleMenu: initial ? .init(label: "角色", isBusy: thread.configuringTemplate,
                enabled: model.canSelectRole(for: thread, in: area),
                content: AnyView(NewThreadRoleMenu(select: selectRole) { roleEdit = $0.role.copy() }))
                : nil,
            titleRefresh: initial ? nil : .init(
                actionLabel: "重新生成标题", progressLabel: "正在重新生成标题",
                isRefreshing: thread.regeneratingTitle, enabled: thread.canRegenerateTitle, action: regenerateTitle))
    }

    private func selectRole(_ role: AgentRole) {
        roleError = nil
        Task {
            do { try await model.selectNewThreadRole(role, for: thread, in: area) }
            catch { roleError = error.localizedDescription }
        }
    }

    private func regenerateTitle() {
        Task {
            do { try await thread.regenerateTitle() }
            catch { titleError = error.localizedDescription }
        }
    }

    /// 发一条消息：先排进队里，对话滑过去（见 TranscriptScroll.send），气泡同时从下往上浮进来，alongside 也和滑同一次更新。
    /// 草稿的第一条也这样走，同时创建代理；建好后同一个会话对象原地变成这个代理，窗口不换，失败时消息退回输入框。
    private func send(_ message: Message, alongside: @escaping () -> Void) {
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
        arriving.ids.insert(message.id)
        scroll.send { thread.send(message) } alongside: {
            arriving.ids.remove(message.id)
            alongside()
        }
    }
}

/// 语音输入时铺在窗口底部一带的签名：从窗口底边往上，盖过控制区再高出几格，随录音的响度（v）起伏、往上涨，停下就收回。
/// 大半在控制区的玻璃后面，透出来的是模糊的光，高出来的几格和两侧露出图案本身。
private struct VoiceBand: View {
    let pattern: DotPattern?
    let slot: String

    /// 静音时高出控制区的格数，和响度到 1 时涨到的格数。
    private static let quiet: CGFloat = 3
    private static let loud: CGFloat = 9

    var body: some View {
        GeometryReader { proxy in
            DotPatternArea(pattern: pattern, rise: proxy.safeAreaInsets.bottom + Self.quiet * DotMetrics.pitch, slot: slot)
                .frame(height: proxy.safeAreaInsets.bottom + Self.loud * DotMetrics.pitch)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(false)
    }
}

/// 对话本身：窗口里只有它读 transcript，收发消息和流式刷新只重算这一块，不牵动标题栏和控制区。
private struct ThreadTranscript: View {
    let scroll: TranscriptScroll
    let arriving: ArrivingMessages
    let visibleHeight: CGFloat
    let lazy: Bool
    @Environment(WorkThread.self) private var thread

    var body: some View {
        TranscriptView(items: thread.transcript.items, pending: thread.transcript.pending, actionable: true,
                       window: lazy ? scroll.window : nil,
                       tail: scroll.tail(visible: visibleHeight))
            .environment(\.arrivingMessages, arriving.ids)
    }
}

/// 刚发出、还没浮上来的消息，只由对话那一块读，发送时不重算整个窗口。
@Observable private final class ArrivingMessages {
    var ids: Set<String> = []
}
