#if DEBUG && KITE_LAYOUT_AUDIT && os(macOS)
import AppKit
import SwiftUI

/// 性能测量的 Mac 部分：测量窗口、滚到要测的那一段、拖缝前的布置、静息占用、打字和发送、截图。见 PerfProbe。
extension PerfProbe {
    static var window: NSWindow?

    /// 带到最前，-perfWindowSize 宽x高（脚本默认 1200x924，两个窗口都窄于对话最大宽度，拖缝时正文每步都重排）。
    static func prepareWindow(_ session: Session) async throws {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            throw Failure("没有主窗口")
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if let size = string("perfWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            let frame = window.frame
            session.onFinish { window.setFrame(frame, display: true) }
            // 左上角不动
            window.setFrame(CGRect(x: frame.minX, y: frame.maxY - size[1], width: size[0], height: size[1]), display: true)
        }
    }

    /// 等各会话窗口的对话排出行来，最多 20 秒。
    static func waitForRows(_ session: Session) async throws {
        for _ in 0..<40 {
            let lists = conversations(session).map(\.list)
            if !lists.isEmpty, lists.allSatisfy({ !$0.arrangement.slots.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        session.report.conversations = conversations(session).count
    }

    // MARK: - 会话窗口

    /// 台面上的一个会话窗口：原生列表和它的会话、窗口状态，由原生外框（ThreadWindowView）给出。
    struct Conversation {
        let list: TranscriptListView
        let thread: WorkThread
        let pane: ThreadPaneModel
    }

    static func conversations(_ session: Session) -> [Conversation] {
        let lists = views(TranscriptListView.self).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 100 }.sorted(by: leftToRight)
        let hosts = views(ThreadWindowView.self)
        return lists.compactMap { list in
            hosts.first(where: { $0.pane.scroll.list === list }).map { Conversation(list: list, thread: $0.thread, pane: $0.pane) }
        }
    }

    private static func views<T: NSView>(_ type: T.Type) -> [T] {
        var found: [T] = []
        func visit(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            for child in view.subviews { visit(child) }
        }
        if let root = window?.contentView?.superview { visit(root) }
        return found
    }

    /// 窗口坐标里从左到右、从上到下。
    private static func leftToRight(_ a: NSView, _ b: NSView) -> Bool {
        let first = a.convert(a.bounds, to: nil), second = b.convert(b.bounds, to: nil)
        return first.minX != second.minX ? first.minX < second.minX : first.maxY > second.maxY
    }

    // MARK: - 拖缝前的布置

    /// 拖缝场景的布置：bottom 停在底部，work 把最后一个工具行滚到顶上，long 是嵌卡片最多的那段回复，
    /// fold 本地造一次压缩并展开摘要和原文，running 加一个在跑的工具调用，actions 在工具行那一段开着操作栏。
    /// -perfScrollTop 给了就先把每个列表滚到离文档顶这么远。
    static func prepareDrag(_ kind: String, _ session: Session) async throws {
        let conversations = conversations(session)
        guard !conversations.isEmpty else { throw Failure("台面上没有会话窗口") }
        let lists = conversations.map(\.list)
        if let top = number("perfScrollTop") {
            for list in lists { scroll(list, toTop: top) }
            try await Task.sleep(for: .seconds(1))
        }
        switch kind {
        case "bottom":
            if number("perfScrollTop") == nil { for list in lists { scroll(list, toTop: .greatestFiniteMagnitude) } }
        case "work", "long", "actions":
            if number("perfScrollTop") == nil { try await scroll(lists, to: kind == "long" ? "block" : "work") }
            if kind == "actions" {
                try await Task.sleep(for: .seconds(0.5))
                for conversation in conversations {
                    let pane = conversation.pane, list = conversation.list, shown = visible(list)
                    // 可见区上半截的一段回复或一个气泡
                    guard let slot = list.arrangement.slots.first(where: {
                        ($0 is ProseRowSlot || $0 is BubbleRowSlot) && $0.frame.minY > shown.minY + 20 && $0.frame.minY < shown.midY
                    }) ?? list.arrangement.slots.first(where: { $0 is ProseRowSlot && $0.frame.intersects(shown) }) else { continue }
                    let selected = pane.selected
                    session.onFinish { pane.selected = selected }
                    pane.selected = slot.id
                }
            }
        case "fold":
            for conversation in conversations {
                let thread = conversation.thread, transcript = thread.transcript
                session.onFinish { thread.transcript = transcript }
                injectCompaction(thread)
            }
            try await Task.sleep(for: .seconds(1))
            for list in lists {
                guard let view = row("compaction", in: list)?.view as? CompactionRowView else { continue }
                if !view.header.expanded { view.header.action?() }
                if !view.buttons.original.isHidden { view.buttons.original.action?() }
            }
            try await Task.sleep(for: .seconds(1.2))
            try await scroll(lists, to: "compaction")
        case "running":
            for conversation in conversations {
                let thread = conversation.thread, transcript = thread.transcript, state = thread.state
                session.onFinish {
                    thread.transcript = transcript
                    thread.state = state
                }
                injectRunningTool(thread)
                if let running = runningState(state) { thread.state = running }
            }
            try await Task.sleep(for: .seconds(1))
            for list in lists { scroll(list, toTop: .greatestFiniteMagnitude) }
        default:
            throw Failure("没有 drag-\(kind) 这个场景")
        }
        try await Task.sleep(for: .seconds(1))
        await capture("setup")
    }

    /// 把列表滚到可见区顶上离文档顶 top 的地方，夹在文档范围里：滚动视图自己不夹，滚过头整窗是空的。
    static func scroll(_ list: TranscriptListView, toTop top: CGFloat) {
        let insets = list.contentInsets
        let most = (list.documentView?.frame.height ?? 0) + insets.bottom - list.contentView.bounds.height
        let y = min(max(top - insets.top, -insets.top), max(most, -insets.top))
        list.contentView.scroll(to: CGPoint(x: 0, y: y))
        list.reflectScrolledClipView(list.contentView)
    }

    /// 把各列表里 kind 那一行滚到顶上。屏外的行高是估的，滚过去才排准，滚三遍。
    private static func scroll(_ lists: [TranscriptListView], to kind: String) async throws {
        for _ in 0..<3 {
            for list in lists {
                if let slot = row(kind, in: list) { scroll(list, toTop: slot.frame.minY - 24) }
            }
            try await Task.sleep(for: .seconds(0.8))
        }
    }

    /// 可见区：滚动区去掉标题栏、输入区让出的高，文档坐标。
    static func visible(_ list: TranscriptListView) -> CGRect {
        let bounds = list.contentView.bounds
        return CGRect(x: bounds.minX, y: bounds.minY + list.contentInsets.top, width: bounds.width,
                      height: bounds.height - list.contentInsets.top - list.contentInsets.bottom)
    }

    private static func row(_ kind: String, in list: TranscriptListView) -> TranscriptRowSlot? {
        let slots = list.arrangement.slots
        switch kind {
        case "compaction": return slots.first { $0 is CompactionRowSlot }
        case "work": return slots.last { $0 is WorkRowSlot }
        case "block":
            // 嵌卡片最多的那段回复，一样多取靠后的
            var best: (slot: TranscriptRowSlot, count: Int)?
            for slot in slots where slot is ProseRowSlot {
                let count = blockCount(slot)
                if count > 0, count >= (best?.count ?? 0) { best = (slot, count) }
            }
            return best?.slot
        default: return nil
        }
    }

    private static func blockCount(_ slot: TranscriptRowSlot) -> Int {
        guard let storage = (slot.view as? NSTextView)?.textStorage else { return 0 }
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value is BlockAttachment { count += 1 }
        }
        return count
    }

    /// 本地造一次压缩：一段顶层记录收进摘要，原文可以展开。
    private static func injectCompaction(_ thread: WorkThread) {
        var transcript = thread.transcript
        let top = transcript.records.indices.filter { transcript.records[$0].parent == nil }
        guard top.count > 8 else { return }
        let start = top.count > 60 ? 12 : 2
        let end = min(top.count - 2, start + 28)
        let id = "perf-compaction"
        for index in top[start..<end] { transcript.records[index].folded = id }
        let summary = """
        之前的对话主要在测试 Kite 的消息收发：发了几条短消息确认来回正常，又让 agent 回复一段带代码块和表格的长文，用来看 TextKit 2 的视口排版。
        - 短消息：收发都正常，气泡贴字宽。
        - 长回复：代码块、表格嵌在正文里，改宽时跟着重排。
        - 折叠：超过一定高度的人发消息折起来，点开展开。
        接下来继续看拖缝改宽时的帧率，和发送时对话往上滑的那一下。
        """
        transcript.records.append(Record(parent: nil, block: .compacted(Compaction(id: id, summary: summary, automatic: false)), generation: nil))
        thread.transcript = transcript
    }

    private static func injectRunningTool(_ thread: WorkThread) {
        var transcript = thread.transcript
        let use = ToolUse(id: "perf-\(UUID().uuidString)", name: "Bash",
                          input: .object(["command": .string("sleep 600"), "description": .string("测量用的长命令")]), stage: "running")
        transcript.records.append(Record(parent: nil, block: .toolUse(use), generation: nil))
        transcript.running = true
        thread.transcript = transcript
    }

    private static func runningState(_ state: RemoteState?) -> RemoteState? {
        guard let state else { return nil }
        return RemoteState(phase: "running", busy: true, compacting: state.compacting, waitingForResume: false,
                           lastOutcome: state.lastOutcome, recovery: state.recovery, context: state.context,
                           status: state.status, error: state.error, capabilities: state.capabilities)
    }

    // MARK: - Mac 才有的场景

    static func performMac(_ scene: String, _ session: Session) async throws {
        switch scene {
        case let name where name.hasPrefix("idle-"): try await idle(String(name.dropFirst("idle-".count)), session)
        case "type": try await typing(session, send: false)
        case "send": try await typing(session, send: true)
        default: throw Failure("没有 \(scene) 这个场景")
        }
    }

    /// 静息占用：摆好一种状态，等 3 秒稳下来，记 -perfSeconds 秒（默认 10）里主线程和整个进程的 CPU。
    /// normal 什么也不改；ring 标题栏圆环转着（会话在跑）；pulse 停靠栏头像脉冲；sweep 对话里有个工具调用在跑；empty 全部缩小、只剩空画板。
    private static func idle(_ condition: String, _ session: Session) async throws {
        let area = session.area
        let conversations = conversations(session)
        switch condition {
        case "normal": break
        case "ring":
            for conversation in conversations {
                let thread = conversation.thread
                guard let running = runningState(thread.state) else { continue }
                let state = thread.state
                session.onFinish { thread.state = state }
                thread.state = running
            }
        case "pulse":
            // 活动只认更新的游标，收不回来；测完 App 就退出，不影响别处
            for instance in area.instances where area.isAgent(instance) {
                if let cursor = EventCursor("\(UUID().uuidString):1") {
                    area.updateActivity(instance.id, ThreadActivity(phase: "running", waitingForResume: false), cursor: cursor)
                }
            }
        case "sweep":
            for conversation in conversations {
                let thread = conversation.thread, transcript = thread.transcript
                session.onFinish { thread.transcript = transcript }
                injectRunningTool(thread)
            }
            try await Task.sleep(for: .seconds(0.8))
            for conversation in conversations { scroll(conversation.list, toTop: .greatestFiniteMagnitude) }
        case "empty":
            // 排布存盘的部分测完写回；内存里的不用还原，测完 App 就退出
            for pane in area.layout.shown?.panes ?? [] { area.layout.minimize(pane) }
        default:
            throw Failure("没有 idle-\(condition) 这个场景")
        }
        try await Task.sleep(for: .seconds(3))
        await capture("setup")
        try await Task.sleep(for: .seconds(1))
        try await ready(session)
        var segment = Segment(name: "idle", index: 0, start: .now)
        try await measuring { try await Task.sleep(for: .seconds(number("perfSeconds") ?? 10)) }
        segment.end = .now
        session.record(segment)
    }

    /// 打字：在最左边一个已建好代理、没在等回应的会话里，每 100ms 打一个字，每轮 -perfKeys 个（默认 20），-perfRounds 轮（默认 3）；
    /// 每个键记之后 4 帧。send 时每轮打完再发出去，记发送后 1.5 秒；消息只排进本地（hold），每轮后撤掉。
    /// -perfSendLive 1 时真的发给工作机（只在测试用的会话里用，回复留在对话里）：每轮先等上一轮回复完，发送后另记 4 秒（send-live），
    /// 工作机确认、开始回复都在里面。
    private static func typing(_ session: Session, send: Bool) async throws {
        guard let window, let (field, thread) = composer() else { throw Failure("没有已建好代理的会话输入框") }
        let live = send && number("perfSendLive") == 1
        holdsSends = send && !live
        session.onFinish {
            holdsSends = false
            releaseHeld()
        }
        let keys = number("perfKeys").map(Int.init) ?? 20
        // 真发时打一句让代理只回两个字的话，不打乱码：乱码代理会去查是什么
        let letters = live ? Array("这是发送测量：只回复收到两字，别调用工具") : Array("abcdefghijklmnopqrstuvwxyz")
        try await ready(session)
        for round in 0..<rounds(3) {
            if live { try await untilIdle(thread) }
            window.makeFirstResponder(field)
            try await Task.sleep(for: .seconds(0.6))
            guard let editor = window.firstResponder as? NSTextView else { throw Failure("输入框没接到焦点") }
            let recorder = Recorder()
            recorder.start()
            try await Task.sleep(for: .seconds(0.5))
            try await measuring {
                for index in 0..<keys {
                    let mark = Mark.now
                    editor.insertText(String(letters[index % letters.count]) + (index % 5 == 4 && !live ? " " : ""),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
                    try await Task.sleep(for: .milliseconds(100))
                    session.record(Segment(name: "key", index: round * keys + index, start: mark, ticks: recorder.after(mark, frames: 4)))
                }
                try await Task.sleep(for: .milliseconds(400))
                if send {
                    let mark = Mark.now
                    field.submit?()
                    try await Task.sleep(for: .seconds(live ? 4.1 : 1.6))
                    session.record(Segment(name: "send", index: round, start: mark, ticks: recorder.after(mark, seconds: 1.5)))
                    if live { session.record(Segment(name: "send-live", index: round, start: mark, ticks: recorder.after(mark, seconds: 4))) }
                }
            }
            await recorder.stop()
            if round == 0 { await capture(send ? "sent" : "typed") }
            if send {
                if !live { releaseHeld() }
            } else {
                editor.selectAll(nil)
                editor.delete(nil)
            }
            try await Task.sleep(for: .seconds(1.5))
        }
    }

    /// 最左边一个已建好代理（不是草稿：草稿发送会真的建代理）、没有回应卡片（等着审批时发出去是拒绝，提问展开时输入框写的是「其他」，都不是平常的发送）的会话的输入框。
    private static func composer() -> (ComposerField, WorkThread)? {
        let fields = views(ComposerField.self).filter { !$0.isHiddenOrHasHiddenAncestor }.sorted(by: leftToRight)
        for field in fields {
            var host: NSView? = field
            while let view = host, !(view is ThreadWindowView) { host = view.superview }
            if let thread = (host as? ThreadWindowView)?.thread, !thread.isDraft, thread.waiting == nil { return (field, thread) }
        }
        return nil
    }

    /// 等会话回复完、能发：最多 2 分钟。
    private static func untilIdle(_ thread: WorkThread) async throws {
        let deadline = Date.now.addingTimeInterval(120)
        while thread.transcript.running || !thread.transcript.pending.isEmpty || thread.waiting != nil || !thread.canSend {
            guard Date.now < deadline else { throw Failure("会话 2 分钟没回复完") }
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .seconds(1))
    }

    // MARK: - 截图

    typealias CreateWindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// 截测量窗口（经 dlsym 调 CGWindowListCreateImage，只截自己的窗口，不需要录屏权限），交给脚本存成 name.png。
    static func capture(_ name: String) async {
        guard let window, let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: CreateWindowImage.self)
        guard let image = create(.null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
                                 CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue)?
            .takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        await deliver("\(name).png", png)
    }
}
#endif
