import QuartzCore
import SwiftUI

/// 临时测量：带 --drawer-bench 启动时自动开合侧栏与底栏，记录每帧间隔。
@MainActor
enum DrawerBench {
    static let requested = true
    static var counters: [String: Int] = [:]

    static func count(_ name: String) {
        guard requested else { return }
        counters[name, default: 0] += 1
    }
}

#if DEBUG && os(iOS)
extension DrawerBench {

    static var settle: ((WorkspaceDrawer?) -> Void)?
    static var pull: ((WorkspaceDrawer) -> DrawerPull)?
    static var sidebarWidth: CGFloat = 0
    static var actionsHeight: CGFloat = 0

    /// 每次窗口 body 求值时登记当前的闭包与尺寸。
    static func register(settle: @escaping (WorkspaceDrawer?) -> Void, pull: @escaping (WorkspaceDrawer) -> DrawerPull,
                         sidebarWidth: CGFloat, actionsHeight: CGFloat) {
        self.settle = settle
        self.pull = pull
        self.sidebarWidth = sidebarWidth
        self.actionsHeight = actionsHeight
    }

    /// 等 Caches/drawer-bench.go 出现就跑一轮，跑完删掉。
    static func watch() async {
        let go = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("drawer-bench.go")
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard FileManager.default.fileExists(atPath: go.path) else { continue }
            let note = (try? String(contentsOf: go, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: go)
            guard let settle, let pull else { continue }
            await run(note: note, settle: settle, pull: { pull($0) }, sidebarWidth: sidebarWidth, actionsHeight: actionsHeight)
        }
    }

    static func run(note: String, settle: @escaping (WorkspaceDrawer?) -> Void, pull: @escaping (WorkspaceDrawer) -> DrawerPull,
                    sidebarWidth: CGFloat, actionsHeight: CGFloat) async {
        log("—— bench start \(Date()) \(note)")
        for round in 1...3 {
            await measure("r\(round) 按钮 打开侧栏") { settle(.sidebar) }
            await measure("r\(round) 按钮 收起侧栏") { settle(nil) }
            await measure("r\(round) 按钮 打开底栏") { settle(.actions) }
            await measure("r\(round) 按钮 收起底栏") { settle(nil) }
        }
        for round in 1...2 {
            await drag("r\(round) 拖动 打开侧栏", pull: pull(.sidebar), to: CGSize(width: sidebarWidth * 0.8, height: 0),
                       velocity: CGSize(width: 800, height: 0))
            await drag("r\(round) 拖动 收起侧栏", pull: pull(.sidebar), to: CGSize(width: -sidebarWidth * 0.8, height: 0),
                       velocity: CGSize(width: -800, height: 0))
            await drag("r\(round) 拖动 打开底栏", pull: pull(.actions), to: CGSize(width: 0, height: -actionsHeight * 0.8),
                       velocity: CGSize(width: 0, height: -800))
            await drag("r\(round) 拖动 收起底栏", pull: pull(.actions), to: CGSize(width: 0, height: actionsHeight * 0.8),
                       velocity: CGSize(width: 0, height: 800))
        }
        log("—— bench end")
    }

    private static func measure(_ name: String, _ action: () -> Void) async {
        let meter = FrameMeter()
        counters = [:]
        meter.start()
        // 先空跑两帧，记下静止时的帧间隔
        try? await Task.sleep(for: .milliseconds(40))
        let actionAt = CACurrentMediaTime()
        action()
        let afterAction = CACurrentMediaTime()
        try? await Task.sleep(for: .milliseconds(900))
        meter.stop()
        report(name, meter: meter, actionAt: actionAt, actionCost: afterAction - actionAt)
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func drag(_ name: String, pull: DrawerPull, to end: CGSize, velocity: CGSize) async {
        let meter = FrameMeter()
        counters = [:]
        meter.start()
        try? await Task.sleep(for: .milliseconds(40))
        let actionAt = CACurrentMediaTime()
        // 每帧挪一次，约 0.3 秒走完
        let steps = 36
        meter.onFrame = { index in
            guard index <= steps else { return }
            let t = CGFloat(index) / CGFloat(steps)
            let moved = CGSize(width: end.width * t + (end.width == 0 ? 0 : (end.width > 0 ? 12 : -12)),
                               height: end.height * t + (end.height == 0 ? 0 : (end.height > 0 ? 12 : -12)))
            pull.changed(moved, velocity)
            if index == steps { pull.ended(velocity) }
        }
        try? await Task.sleep(for: .milliseconds(1100))
        meter.stop()
        report(name, meter: meter, actionAt: actionAt, actionCost: 0)
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func report(_ name: String, meter: FrameMeter, actionAt: CFTimeInterval, actionCost: CFTimeInterval) {
        let frames = meter.frames.filter { $0.timestamp >= actionAt - 0.001 }
        guard frames.count > 1 else { log("\(name)：没有帧"); return }
        let expected = frames.map(\.expected).min() ?? 1.0 / 120
        var deltas: [Double] = []
        for i in 1..<frames.count { deltas.append(frames[i].timestamp - frames[i - 1].timestamp) }
        let hitches = deltas.filter { $0 > expected * 1.5 }
        let missed = hitches.reduce(0) { $0 + Int(($1 / expected).rounded()) - 1 }
        let first = deltas.first ?? 0
        let worst = deltas.max() ?? 0
        let counts = counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log(String(format: "%@：帧 %d，期望 %.1fms，同步耗时 %.1fms，首帧 %.1fms，最长 %.1fms，卡顿 %d 次共丢 %d 帧 %@", name,
                   frames.count, expected * 1000, actionCost * 1000, first * 1000, worst * 1000, hitches.count, missed, counts))
        let slow = deltas.enumerated().filter { $0.element > expected * 1.5 }
            .map { String(format: "#%d:%.1f", $0.offset, $0.element * 1000) }.joined(separator: " ")
        if !slow.isEmpty { log("    慢帧 \(slow)") }
    }

    static func log(_ line: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("drawer-bench.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

@MainActor
private final class FrameMeter: NSObject {
    struct Frame { let timestamp: CFTimeInterval; let expected: CFTimeInterval }
    var frames: [Frame] = []
    var onFrame: ((Int) -> Void)?
    private var link: CADisplayLink?
    private var index = 0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        frames.append(Frame(timestamp: link.timestamp, expected: link.targetTimestamp - link.timestamp))
        if let onFrame {
            index += 1
            onFrame(index)
        }
    }
}
#endif
