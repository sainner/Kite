#if DEBUG && KITE_LAYOUT_AUDIT
import os
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 性能测量，只编进测量版（KITE_PREVIEW_FLAGS=KITE_LAYOUT_AUDIT）。入口、场景和注意事项见 kited/test/manual/README.md 的「性能测量」。
/// 带 -perfScene 启动时等 -perfAutoStart 秒（默认 8），在当前工作区里自动做一个场景，逐帧记主线程 CPU 和帧间隔；
/// 测的那几段打 Points of Interest 区间，Time Profiler 只算这几段。
/// Mac 的结果 POST 到 -perfPort 给的本机端口（沙盒写不出容器），开测前报到、等脚本放行（脚本在这中间挂上 Time Profiler），测完自己退出；
/// iPad、iPhone 写到 Library/Caches/perf/，脚本用 devicectl 取回。iPhone 测紧凑布局（抽屉、横滑、键盘），见 PerfProbe+Phone。
/// 不留副作用：发送只排进本地（hold），改过的排布和窗口位置测完写回（测量版和用户的 Kite 共用一份 UserDefaults），
/// 选中的工作区只在给了 -perfWorkspace 时切换，切换不存盘。
@MainActor enum PerfProbe {
    static let scene = UserDefaults.standard.string(forKey: "perfScene")
    private static var armed = false
    /// 紧凑布局出现时登记的抽屉和一行窗口（CompactShellView、CompactRowView），iPhone 的场景经它们开合、横滑。
    static weak var drawer: DrawerMotion?
    static weak var row: PaneRow?

    static func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    static func number(_ key: String) -> Double? { string(key).flatMap(Double.init) }
    static func rounds(_ fallback: Int) -> Int { number("perfRounds").map(Int.init) ?? fallback }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - 报告

    /// 某一刻：CACurrentMediaTime（秒），主线程和整个进程到这时用掉的 CPU（毫秒）。
    struct Mark: Encodable {
        let wall: Double
        let cpu: Double
        let process: Double
        static var now: Mark { Mark(wall: CACurrentMediaTime(), cpu: threadCPU(), process: processCPU()) }
    }

    /// 显示链接的一帧：这一帧的时间戳、回调时刻（秒），主线程 CPU（毫秒），被测的量（拖缝时各窗口的宽，侧栏改宽时台面的宽）。
    struct Tick: Encodable {
        let time: Double
        let wall: Double
        let cpu: Double
        var widths: [Double] = []

        init(_ link: CADisplayLink, widths: [Double] = []) {
            time = link.timestamp
            wall = CACurrentMediaTime()
            cpu = PerfProbe.threadCPU()
            self.widths = widths
        }
    }

    /// 测的一段：drag、sidebar 是一轮摆动，minimize、restore 是一次排布动画，idle 是一段静息，key、send 是一次按键、一次发送；
    /// iPhone 的见 PerfProbe+Phone（抽屉开合、手指拉抽屉、横滑、键盘升降，各是一次动作到动画走完）。
    struct Segment: Encodable {
        let name: String
        let index: Int
        let start: Mark
        var ticks: [Tick] = []
        var end: Mark?
        /// 拖缝、侧栏松手后 1.2 秒的主线程（毫秒）。
        var settleCpuMs: Double?
    }

    struct Report: Encodable {
        let scene: String
        /// 脚本给这一次的编号（-perfRun），认得出取回的不是上一次留下的。
        var run = PerfProbe.string("perfRun")
        var platform = ""
        var refreshRate = 0
        /// Mac：开测时测量版在不在最前、窗口露没露出来，不在时记下最前的是谁。不在前面时系统不正常出图，结果不能用。
        var active = true
        var visible = true
        var frontmost: String?
        var conversations = 0
        /// 摆台面之前台面上有哪些会话（id）：和上一次不同说明共用的排布被别的 Kite 改过。
        var stageAtStart: [String] = []
        var status = "running"
        var failure: String?
        var segments: [Segment] = []
        /// 测完写回的 UserDefaults 键。
        var restored: [String] = []
    }

    /// 一次测量：场景改过的状态登记在这里，测完倒着撤回。
    final class Session {
        let model: AppModel
        let area: WorkArea
        var report: Report
        private var undo: [() -> Void] = []

        init(model: AppModel, area: WorkArea, report: Report) {
            self.model = model
            self.area = area
            self.report = report
        }

        func onFinish(_ action: @escaping () -> Void) { undo.append(action) }

        func finish() {
            for action in undo.reversed() { action() }
            undo = []
        }

        func record(_ segment: Segment) {
            report.segments.append(segment)
            // iPad 每段都写一次，中途出事也取得回已经测完的
            #if os(iOS)
            PerfProbe.write("report.json", report)
            #endif
        }
    }

    // MARK: - 入口

    /// KiteApp 建好模型就调；不带 -perfScene 时什么也不做。
    static func arm(model: AppModel) {
        guard let scene, !armed else { return }
        armed = true
        Task {
            try? await Task.sleep(for: .seconds(number("perfAutoStart") ?? 8))
            await run(scene, model: model)
        }
    }

    private static func run(_ scene: String, model: AppModel) async {
        let defaults = savedDefaults()
        var report = Report(scene: scene)
        describe(&report)
        if let id = string("perfWorkspace"), model.selected != id || model.sidebarSection != .workspaces || model.selectedProjectID != nil {
            model.sidebarSection = .workspaces
            model.selectWorkspace(id)
        }
        var session: Session?
        do {
            #if os(iOS)
            let compact = isPhone
            let area = try await compact ? compactStage(model) : stage(model)
            #else
            let compact = false
            let area = try await stage(model)
            #endif
            let current = Session(model: model, area: area, report: report)
            session = current
            #if os(macOS)
            try await prepareWindow(current)
            #endif
            current.report.stageAtStart = (compact ? area.layout.panes : area.layout.shown?.panes ?? []).compactMap { area.thread(in: $0)?.id }
            #if os(iOS)
            if compact { try await arrangeCompact(area) } else { try await arrange(area) }
            #else
            try await arrange(area)
            #endif
            try await historyLoaded(area)
            #if os(macOS)
            try await waitForRows(current)
            #endif
            try await Task.sleep(for: .seconds(2))
            try await perform(scene, current)
            current.report.status = "completed"
        } catch {
            session?.report.status = "failed"
            session?.report.failure = "\(error)"
            report.status = "failed"
            report.failure = "\(error)"
            #if os(macOS)
            // 失败时当时的样子
            window = window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
            await capture("failure")
            #endif
        }
        session?.finish()
        // 侧栏改宽后排布 0.5 秒才存（WindowLayout.saveSoon），等它存完再写回
        try? await Task.sleep(for: .seconds(1.2))
        var final = session?.report ?? report
        final.restored = restore(defaults)
        await deliver("report.json", final)
        #if os(macOS)
        NSApp.terminate(nil)
        #endif
    }

    private static func describe(_ report: inout Report) {
        #if os(macOS)
        report.platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        report.refreshRate = NSScreen.main?.maximumFramesPerSecond ?? 0
        #else
        report.platform = "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)"
        report.refreshRate = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }.first ?? 0
        #endif
    }

    private static func perform(_ scene: String, _ session: Session) async throws {
        switch scene {
        case "sidebar": try await sidebar(session)
        case "motion": try await motion(session)
        case let name where name.hasPrefix("drag-"):
            try await prepareDrag(String(name.dropFirst("drag-".count)), session)
            try await drag(session)
        default:
            #if os(macOS)
            try await performMac(scene, session)
            #else
            try await performPhone(scene, session)
            #endif
        }
    }

    /// 等宽屏工作区出来、排布静止。
    private static func stage(_ model: AppModel) async throws -> WorkArea {
        for _ in 0..<120 {
            if model.sidebarSection == .workspaces, model.selectedProjectID == nil, let area = model.current,
               area.layout.availableSize != nil, area.layout.presentation == .tiled, !area.layout.transitioning {
                return area
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let layout = model.current?.layout
        throw Failure("60 秒内没等到宽屏工作区：栏目 \(model.sidebarSection)，工作区 \(model.current?.id ?? "无")，"
                      + "台面 \(layout?.availableSize.map { "\($0)" } ?? "无") \(layout.map { "\($0.presentation)" } ?? "")，"
                      + "拖动 \(layout?.drag != nil)、拖缝 \(layout?.resizing != nil)、动画中的窗口 \(layout?.settling.count ?? 0)")
    }

    /// 摆好台面：排布存在和用户的 Kite 共用的 UserDefaults 里，别的 Kite、别的测量版都可能改过，所以每次自己摆，测完写回。
    /// 给了 -perfThreads（会话 id，逗号分开）就只留这几个会话、按给的次序从停靠栏恢复；没给时台面上的会话不到两个，就按停靠栏的次序恢复到两个。
    private static func arrange(_ area: WorkArea) async throws {
        let layout = area.layout
        guard let viewport = layout.availableSize else { return }
        let bounds = CGRect(origin: .zero, size: viewport)
        let conversation = { (pane: Pane) in area.thread(in: pane).map { !$0.isDraft } ?? false }
        if let wanted = string("perfThreads")?.split(separator: ",").map(String.init), !wanted.isEmpty {
            for pane in layout.shown?.panes ?? [] where !wanted.contains(area.thread(in: pane)?.id ?? "") {
                layout.minimize(pane)
                try await Task.sleep(for: .seconds(0.8))
            }
            for id in wanted {
                guard let pane = layout.docked.first(where: { area.thread(in: $0)?.id == id }) else { continue }
                layout.restore(pane, in: bounds)
                try await Task.sleep(for: .seconds(0.8))
            }
        } else {
            while (layout.shown?.panes ?? []).filter(conversation).count < 2, let pane = layout.docked.first(where: conversation) {
                layout.restore(pane, in: bounds)
                try await Task.sleep(for: .seconds(0.8))
            }
        }
    }

    /// 等台面上各会话（紧凑布局是当前窗口）的历史读完，最多 30 秒；读不完照样测，报告里看得出对话是空的。
    private static func historyLoaded(_ area: WorkArea) async throws {
        for _ in 0..<60 {
            let panes = area.layout.presentation == .compact ? area.layout.focused.map { [$0] } ?? [] : area.layout.shown?.panes ?? []
            let threads = panes.compactMap { area.thread(in: $0) }.filter { !$0.isDraft }
            if threads.allSatisfy(\.historyLoaded) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - 拖缝

    /// 拖缝：左右分栏的缝从可拖范围的正中起，按正弦来回摆一趟（90 步），每帧挪一步；两个窗口都窄于对话最大宽度，正文每步都重排。
    private static func drag(_ session: Session) async throws {
        let layout = session.area.layout
        guard !layout.isFixed, layout.presentation == .tiled, !layout.transitioning, let viewport = layout.availableSize else {
            throw Failure("排布不在静止的宽屏分栏")
        }
        let canvas = layout.regions(in: CGRect(origin: .zero, size: viewport)).canvas
        let gaps = layout.shown?.layout(in: canvas).gaps.filter { $0.split.axis == .horizontal } ?? []
        // 优先左右各一个窗口的那道缝
        guard let gap = gaps.first(where: { $0.split.first.panes.count == 1 && $0.split.second.panes.count == 1 }) ?? gaps.first else {
            throw Failure("当前排布没有左右分栏")
        }
        let id = gap.id
        let available = gap.region.width - Metrics.gap
        let lower = max(gap.split.first.minimumSize.width + 4, available - Metrics.transcriptWidth + 4)
        let upper = min(available - gap.split.second.minimumSize.width - 4, Metrics.transcriptWidth - 4)
        let center = ((lower + upper) / 2).rounded()
        let amplitude = min(96, (upper - lower) / 2)
        guard amplitude >= 24 else { throw Failure("缝两侧改宽的余量不足：lower=\(lower) upper=\(upper)") }
        let original = gap.rect.minX - gap.region.minX

        func move(to position: CGFloat) throws {
            guard layout.availableSize == viewport, layout.drag == nil,
                  let gap = layout.shown?.layout(in: canvas).gaps.first(where: { $0.id == id }) else {
                throw Failure("测量中窗口尺寸或排布变了")
            }
            layout.resize(gap, to: CGPoint(x: gap.region.minX + position + Metrics.gap / 2, y: gap.rect.midY))
        }
        func widths() -> [Double] {
            (layout.shown?.layout(in: canvas).panes.values.map { Double($0.width) } ?? []).sorted()
        }
        session.onFinish {
            try? move(to: original)
            layout.finishResize()
        }
        try await ready(session)
        let positions = sweep(center: center, amplitude: amplitude)
        for index in 0..<rounds(isMac ? 2 : 3) {
            try move(to: center)
            layout.finishResize()
            try await Task.sleep(for: .seconds(1.2))
            var segment = Segment(name: "drag", index: index, start: .now)
            var step = 0
            try await measuring {
                try await Clock().run { link in
                    segment.ticks.append(Tick(link, widths: widths()))
                    guard step < positions.count else { return false }
                    try move(to: positions[step])
                    step += 1
                    return true
                }
            }
            segment.end = .now
            try await Task.sleep(for: .milliseconds(400))
            let settle = Mark.now
            layout.finishResize()
            try await Task.sleep(for: .seconds(1.2))
            segment.settleCpuMs = threadCPU() - settle.cpu
            session.record(segment)
            if index == 0 { await capture("drag-settled") }
        }
    }

    /// 90 步正弦：从 center 出发摆到两侧再回到 center。
    private static func sweep(center: CGFloat, amplitude: CGFloat) -> [CGFloat] {
        (0..<90).map { step in
            guard step != 0, step != 89 else { return center }
            return center + amplitude * CGFloat(sin(Double(step) * 2 * .pi / 89))
        }
    }

    // MARK: - 侧栏改宽

    /// 侧栏改宽：对话停在底部，经模型逐帧改侧栏宽度（同拖侧栏的边），在可拖范围正中按正弦摆一趟 90 步；台面贴着侧栏的那一列跟着改宽。
    /// 照 MainWindow 拖动时的走法：拖动中设 sidebarResizing；iPad 上宽不进 SwiftUI，交给原生台面（SidebarDrag），一轮完了才交给 sidebarWidth。
    private static func sidebar(_ session: Session) async throws {
        let model = session.model, layout = session.area.layout
        let width = model.sidebarWidth, collapsed = model.sidebarCollapsed
        session.onFinish {
            model.sidebarWidth = width
            model.sidebarCollapsed = collapsed
        }
        if collapsed {
            model.sidebarCollapsed = false
            try await Task.sleep(for: .seconds(1))
        }
        // 对话停在底部，同拖缝贴底
        try await prepareDrag("bottom", session)
        let lower = Metrics.sidebarMin + 2, upper = Metrics.sidebarMax - 2
        let center = ((lower + upper) / 2).rounded()
        let positions = sweep(center: center, amplitude: min(96, (upper - lower) / 2))
        func stageWidth() -> [Double] { [Double(layout.availableSize?.width ?? 0)] }
        try await ready(session)
        for index in 0..<rounds(isMac ? 2 : 3) {
            model.sidebarWidth = center
            try await Task.sleep(for: .seconds(1.2))
            var segment = Segment(name: "sidebar", index: index, start: .now)
            var step = 0
            model.sidebarResizing = true
            try await measuring {
                try await Clock().run { link in
                    segment.ticks.append(Tick(link, widths: stageWidth()))
                    guard step < positions.count else { return false }
                    #if os(iOS)
                    model.sidebarDrag.move(to: positions[step], base: center)
                    #else
                    model.sidebarWidth = positions[step]
                    #endif
                    step += 1
                    return true
                }
            }
            if let width = model.sidebarDrag.end() { model.sidebarWidth = width }
            model.sidebarResizing = false
            segment.end = .now
            try await Task.sleep(for: .milliseconds(400))
            let settle = Mark.now
            try await Task.sleep(for: .seconds(1.2))
            segment.settleCpuMs = threadCPU() - settle.cpu
            session.record(segment)
            if index == 0 { await capture("sidebar-settled") }
        }
    }

    // MARK: - 缩小、恢复

    /// 把台面上最后一个窗口缩小、恢复，-perfPairs 次（默认 4）；每次从动作起逐帧记到排布动画走完再过 40ms。
    private static func motion(_ session: Session) async throws {
        let layout = session.area.layout
        guard let viewport = layout.availableSize, let panes = layout.shown?.panes, panes.count >= 2, let pane = panes.last else {
            throw Failure("台面上没有两个窗口")
        }
        let bounds = CGRect(origin: .zero, size: viewport)
        session.onFinish { if layout.docked.contains(pane) { layout.restore(pane, in: bounds) } }
        try await ready(session)
        for index in 0..<(number("perfPairs").map(Int.init) ?? 4) {
            session.record(try await settling("minimize", index, layout) { layout.minimize(pane) })
            if index == 0 { await capture("motion-minimized") }
            try await Task.sleep(for: .seconds(1.2))
            session.record(try await settling("restore", index, layout) { layout.restore(pane, in: bounds) })
            try await Task.sleep(for: .seconds(1.2))
        }
    }

    /// 做 action，逐帧记到排布动画走完（WindowLayout.settling 空了 40ms）或 2 秒。
    private static func settling(_ name: String, _ index: Int, _ layout: WindowLayout, _ action: () -> Void) async throws -> Segment {
        var segment = Segment(name: name, index: index, start: .now)
        var began = false
        var quiet: Double?
        try await measuring {
            action()
            try await Clock().run { link in
                let tick = Tick(link)
                segment.ticks.append(tick)
                if !layout.settling.isEmpty {
                    began = true
                    quiet = nil
                } else if began, quiet == nil {
                    quiet = tick.wall
                }
                if tick.wall - segment.start.wall > 2 { return false }
                if let quiet, tick.wall - quiet >= 0.04 { return false }
                return true
            }
        }
        segment.end = .now
        return segment
    }

    // MARK: - 发送

    /// 测发送时 WorkThread.send 先问这里：消息只排进本地的 pending、不发给工作机，返回会不会开启新的一轮；平常返回 nil。
    static func hold(_ message: Message, in thread: WorkThread) -> Bool? {
        guard holdsSends else { return nil }
        let startsTurn = !thread.transcript.running && thread.transcript.pending.isEmpty
        thread.transcript.pending.append(message)
        held.append(Held(thread: thread, id: message.id))
        return startsTurn
    }

    static var holdsSends = false
    private struct Held {
        weak var thread: WorkThread?
        let id: String
    }
    private static var held: [Held] = []

    /// 撤掉排进本地的消息。
    static func releaseHeld() {
        for item in held { item.thread?.transcript.pending.removeAll { $0.id == item.id } }
        held = []
    }

    // MARK: - 共用

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private static let signposter = OSSignposter(subsystem: "com.sainner.kite.perf", category: .pointsOfInterest)

    /// 测的那一段：打一个 Points of Interest 区间，脚本只把区间里的 Time Profiler 采样算进去。
    static func measuring(_ body: () async throws -> Void) async throws {
        let state = signposter.beginInterval("measure")
        defer { signposter.endInterval("measure", state) }
        try await body()
    }

    /// 开测前：Mac 向脚本报到、等它放行（挂 Time Profiler 要几秒），只做一次。
    private static var released = false
    static func ready(_ session: Session) async throws {
        guard !released else { return }
        released = true
        defer {
            #if os(macOS)
            session.report.active = NSApp.isActive
            session.report.visible = window?.occlusionState.contains(.visible) == true
            if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication {
                session.report.frontmost = "\(front.localizedName ?? "?") \(front.processIdentifier) \(front.executableURL?.path ?? "")"
            }
            #endif
        }
        guard let port else { return }
        await deliver("ready.json", ["pid": Int(getpid())])
        for _ in 0..<1200 {
            if let url = URL(string: "http://127.0.0.1:\(port)/go"),
               let result = try? await URLSession.shared.data(from: url),
               (result.1 as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure("5 分钟内脚本没有放行")
    }

    private static var port: Int? { number("perfPort").map(Int.init) }

    /// 交出结果：有 -perfPort 时 POST 到本机端口，没有时写到 Library/Caches/perf/。
    static func deliver(_ name: String, _ data: Data) async {
        if let port, let url = URL(string: "http://127.0.0.1:\(port)/\(name)") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.upload(for: request, from: data)
        } else {
            write(name, data)
        }
    }

    static func deliver<T: Encodable>(_ name: String, _ value: T) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        await deliver(name, data)
    }

    static func write(_ name: String, _ data: Data) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("perf") else { return }
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try? data.write(to: caches.appendingPathComponent(name), options: .atomic)
    }

    static func write<T: Encodable>(_ name: String, _ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value) { write(name, data) }
    }

    /// 测量会改的 UserDefaults：排布（拖缝、侧栏改宽、缩小）和窗口位置。测量版和用户的 Kite 共用一份，测完写回原样。
    private static let restoredPrefixes = ["KiteWindowLayout.", "NSWindow Frame "]

    private static func savedDefaults() -> [String: Any] {
        guard let id = Bundle.main.bundleIdentifier else { return [:] }
        return (UserDefaults.standard.persistentDomain(forName: id) ?? [:]).filter { key, _ in restoredPrefixes.contains { key.hasPrefix($0) } }
    }

    private static func restore(_ saved: [String: Any]) -> [String] {
        let current = savedDefaults()
        var restored: [String] = []
        for key in Set(saved.keys).union(current.keys) {
            let old = saved[key], now = current[key]
            if let old, let now, (old as AnyObject).isEqual(now) { continue }
            if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            restored.append(key)
        }
        return restored.sorted()
    }

    static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    /// 屏幕刷新驱动每一步：每帧调一次 callback，返回 false 或抛错就停。iPad 要 120Hz，量跟不跟得上真实手指拖动。
    final class Clock: NSObject {
        private var link: CADisplayLink?
        private var callback: ((CADisplayLink) throws -> Bool)?
        private var continuation: CheckedContinuation<Void, Error>?

        func run(_ callback: @escaping (CADisplayLink) throws -> Bool) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.callback = callback
                self.continuation = continuation
                #if os(macOS)
                guard let window = PerfProbe.window else { return finish(Failure("没有测量的窗口")) }
                let link = window.displayLink(target: self, selector: #selector(tick(_:)))
                #else
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                #endif
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            do {
                if try callback?(link) == false { finish(nil) }
            } catch { finish(error) }
        }

        private func finish(_ error: Error?) {
            link?.invalidate()
            link = nil
            callback = nil
            let continuation = continuation
            self.continuation = nil
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        }
    }

    /// 后台一直跑的显示链接，记下每一帧；事件前后打 Mark，事后按时刻切段。
    final class Recorder {
        private(set) var ticks: [Tick] = []
        private var running = true
        private var task: Task<Void, Error>?

        func start() {
            task = Task { try await Clock().run { [self] link in
                ticks.append(Tick(link))
                return running
            } }
        }

        func stop() async {
            running = false
            _ = try? await task?.value
        }

        /// mark 之后的帧：最多 frames 帧、最多 seconds 秒。
        func after(_ mark: Mark, frames: Int = .max, seconds: Double = .infinity) -> [Tick] {
            Array(ticks.filter { $0.wall > mark.wall && $0.wall <= mark.wall + seconds }.prefix(frames))
        }
    }
}

#if os(iOS)
extension PerfProbe {
    /// iPad 只有拖缝贴底：对话打开时就停在底部。
    fileprivate static func prepareDrag(_ kind: String, _ session: Session) async throws {
        guard kind == "bottom" else { throw Failure("iPad 只有 drag-bottom，没有 drag-\(kind)") }
    }

    /// iPad 不截图。
    fileprivate static func capture(_ name: String) async {}
}
#endif
#endif
