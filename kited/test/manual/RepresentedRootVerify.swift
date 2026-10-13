import AppKit
import SwiftUI

// RepresentedRoot 原生合同。生产的 RepresentedRoot 编进来，放在屏上小窗口里一个 NSViewRepresentable 下面，外面窗口根是一个
// 在 placeSubviews 里计数的自定义 Layout，里面一个 NSHostingView（岛）放 TimelineView(.animation)，在内容闭包里计数。
// 挡的是 AppKit 与 SwiftUI 没公开的配合，读代码推不出：
// - 岛每次更新都要更新约束，AppKit 沿父视图往上报（_informContainerThatSubviewsNeedUpdateConstraints），报到 representable 的宿主
//   （SwiftUI 的 AppKitPlatformViewHost）时外面整张图重排一轮。系统一改，RepresentedRoot 截不住，外面又每帧整轮重排（性能退回）；
// - 岛的更新要靠约束这一趟才处理：截住上报却不自己更新约束，岛的 TimelineView 停住（2026-10-14 单独试验程序里试过）。
//   系统一改，RepresentedRoot 自己补的那一趟不够，岛停住不动（功能坏了）。
// 对照场景换成普通 NSView，外面应每帧重排，保证这份合同测得出差别。
// TimelineView(.animation) 要窗口在屏上才走，所以用屏上的测试窗口；不读屏幕像素，不碰剪贴板和 UserDefaults。

private enum RootFailure: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "RepresentedRoot 原生验证失败"
    }
}

/// 一个场景里的计数，都在主线程上加。
private final class Counts {
    /// 外面窗口根的 Layout 摆了几次子视图。
    var rootPlacements = 0
    /// 岛里 TimelineView 的内容闭包走了几次。
    var islandFrames = 0
    /// 普通子视图的 layout() 被调了几次。
    var childLayouts = 0
    /// display link 走了几帧。
    var ticks = 0

    func islandFrame() { islandFrames += 1 }

    func reset() {
        rootPlacements = 0
        islandFrames = 0
        childLayouts = 0
        ticks = 0
    }
}

/// 窗口根：铺满给的大小，在 placeSubviews 里计数。外面那张图每整轮重排一次，这里就加一。
private struct CountingRoot: Layout {
    let counts: Counts

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Layout 的要求不隔离，实际在主线程上调
        MainActor.assumeIsolated { counts.rootPlacements += 1 }
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// 放原生根的 representable，大小由外面给，不随里面变（同生产的用法）。
private struct Represented: NSViewRepresentable {
    let make: () -> NSView

    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ view: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// 岛里的动画：内容随时间变，每帧都是一次真的更新。
private struct Animated: View {
    let counts: Counts

    var body: some View {
        TimelineView(.animation) { context in
            let _ = counts.islandFrame()
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Rectangle()
                .fill(Color.blue)
                .frame(width: 20 + 100 * phase, height: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 岛：同生产 StageIsland 的设置，不报固有尺寸、不加安全区。
private func island(_ counts: Counts) -> NSView {
    let host = NSHostingView(rootView: Animated(counts: counts))
    host.sizingOptions = []
    host.safeAreaRegions = []
    return host
}

/// 普通子视图：layout() 里计数。
private final class LayoutCounter: NSView {
    var counts: Counts?

    override func layout() {
        super.layout()
        counts?.childLayouts += 1
    }
}

/// 被测：生产的 RepresentedRoot 的子类，里面放岛，需要时再放一个普通子视图。
private final class InterceptingRoot: RepresentedRoot {
    init(subviews: [NSView]) {
        super.init(frame: CGRect(x: 0, y: 0, width: Stage.size.width, height: Stage.size.height))
        for view in subviews {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 对照：结构一样，换成普通 NSView。
private final class PlainRoot: NSView {
    init(subviews: [NSView]) {
        super.init(frame: CGRect(x: 0, y: 0, width: Stage.size.width, height: Stage.size.height))
        for view in subviews {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class Ticker: NSObject {
    var onTick: () -> Void = {}
    @objc func tick(_ link: CADisplayLink) { onTick() }
}

/// 屏上的测试窗口：等 1 秒让窗口稳定，再记 2 秒。
/// 必须在 NSApp.run 的事件循环里跑：自己用 RunLoop.main.run(mode:before:) 转时，对照场景里外面的根每帧重排四五百次、主线程占满，
/// 和 App 里每帧一次对不上（2026-10-14 试过）。
private enum Stage {
    static let size = CGSize(width: 320, height: 200)
    static let settle: Duration = .seconds(1)
    static let measured: Duration = .seconds(2)

    static func run(_ label: String, root: @escaping (Counts) -> NSView, everyFrame: ((Counts) -> Void)? = nil) async throws -> Counts {
        let counts = Counts()
        let host = NSHostingView(rootView: CountingRoot(counts: counts) {
            Represented(make: { root(counts) })
        })
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: visible.minX + 40, y: visible.minY + 40), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = host
        window.orderFrontRegardless()
        let ticker = Ticker()
        ticker.onTick = {
            counts.ticks += 1
            everyFrame?(counts)
        }
        let link = window.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        defer {
            link.invalidate()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        try await Task.sleep(for: settle)
        guard window.occlusionState.contains(.visible), counts.ticks > 0 else {
            throw RootFailure.failed("\(label)：测试窗口不在屏上或没有 display link（\(counts.ticks) 帧）；检查锁屏和显示器，不是被测代码的问题")
        }
        counts.reset()
        try await Task.sleep(for: measured)
        print("\(label)：2 秒 \(counts.ticks) 帧，岛走 \(counts.islandFrames) 次，外面的根重排 \(counts.rootPlacements) 次，普通子视图排版 \(counts.childLayouts) 次")
        return counts
    }
}

@MainActor @main
private struct RepresentedRootContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let checks: [(String, () async throws -> Void)] = [
            ("RepresentedRoot 里的岛按帧走，外面的根不再随岛每帧重排", islandAnimatesWithoutRelayingOutside),
            ("对照：普通 NSView 里的岛每帧都让外面的根整轮重排", plainRootRelaysOutsideEveryFrame),
            ("RepresentedRoot 里的普通子视图逐帧标排版，layout() 照常按帧被调", childLayoutStillRunsEveryFrame),
        ]
        Task {
            var failures = [String]()
            for (name, check) in checks {
                do {
                    try await check()
                    print("通过：\(name)")
                } catch {
                    failures.append("\(name)：\(error)")
                }
            }
            if failures.isEmpty {
                print("RepresentedRoot 的三个原生场景验证通过")
                exit(0)
            }
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        NSApp.run()
    }

    // 1. 截住约束上报：外面不随岛重排，岛照常按帧走。60Hz 下 2 秒约 120 帧，阈值放宽到每秒 40 帧；
    // 外面的根稳定后不该随帧增长，允许零星几次（窗口自己的事件）。
    private static func islandAnimatesWithoutRelayingOutside() async throws {
        let counts = try await Stage.run("RepresentedRoot") { counts in InterceptingRoot(subviews: [island(counts)]) }
        try require(counts.islandFrames >= 80,
                    "岛的 TimelineView 2 秒只走了 \(counts.islandFrames) 次（\(counts.ticks) 帧），应按帧走（≥ 80）：截住上报后岛的约束更新没有补上")
        try require(counts.rootPlacements <= 3,
                    "外面的根 2 秒重排了 \(counts.rootPlacements) 次（岛走 \(counts.islandFrames) 次），应几乎不重排（≤ 3）：约束失效没截住，仍报到了 representable 的宿主")
    }

    // 2. 对照：普通 NSView 不截，外面每帧整轮重排。这条不过，说明系统已不再沿这条路上报，第 1 条失去判别力。
    private static func plainRootRelaysOutsideEveryFrame() async throws {
        let counts = try await Stage.run("普通 NSView") { counts in PlainRoot(subviews: [island(counts)]) }
        try require(counts.islandFrames >= 80,
                    "对照里岛 2 秒只走了 \(counts.islandFrames) 次（\(counts.ticks) 帧），应按帧走（≥ 80）")
        try require(counts.rootPlacements >= 80,
                    "对照里外面的根 2 秒只重排 \(counts.rootPlacements) 次（岛走 \(counts.islandFrames) 次），应接近帧数：岛更新已不再让外面重排，第 1 条场景测不出差别")
    }

    // 3. 截住的只是约束上报：同一个 RepresentedRoot 里，岛照常走，旁边一个普通子视图逐帧标 needsLayout，layout() 照常按帧被调。
    private static func childLayoutStillRunsEveryFrame() async throws {
        let child = LayoutCounter()
        let counts = try await Stage.run("RepresentedRoot 加普通子视图", root: { counts in
            child.counts = counts
            return InterceptingRoot(subviews: [island(counts), child])
        }, everyFrame: { _ in child.needsLayout = true })
        try require(counts.childLayouts >= 80,
                    "普通子视图逐帧标 needsLayout，2 秒只排了 \(counts.childLayouts) 次（\(counts.ticks) 帧），应按帧排（≥ 80）：截住约束上报连排版也挡了")
        try require(counts.islandFrames >= 80,
                    "有普通子视图逐帧排版时岛 2 秒只走了 \(counts.islandFrames) 次（\(counts.ticks) 帧），应按帧走（≥ 80）")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RootFailure.failed(message) }
    }
}
