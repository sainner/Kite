#if DEBUG && KITE_LAYOUT_AUDIT && os(iOS)
import SwiftUI
import UIKit

/// 性能测量的 iPhone 部分：紧凑布局的抽屉开合、手指拉抽屉、控制区横滑、键盘升降。见 PerfProbe。
/// 抽屉和横滑经模型走（DrawerMotion、PaneRow，紧凑布局出现时登记），和点按钮、拖手指走同一条路，只是不经过手势识别；
/// 键盘让当前窗口的输入框接焦点、放焦点。每次动作逐帧记到动画走完，各做 -perfPairs 次（默认 4）。
extension PerfProbe {
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// 等紧凑布局开着窗口、抽屉配好、一行窗口建好。
    static func compactStage(_ model: AppModel) async throws -> WorkArea {
        for _ in 0..<120 {
            if model.sidebarSection == .workspaces, model.selectedProjectID == nil, let area = model.current,
               area.layout.presentation == .compact, area.layout.focused != nil, drawer?.configured == true, row != nil {
                return area
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure("60 秒内没等到开着窗口的紧凑布局：栏目 \(model.sidebarSection)，工作区 \(model.current?.id ?? "无")，"
                      + "当前窗口 \(model.current?.layout.focused == nil ? "无" : "有")，抽屉 \(drawer?.configured == true)，一行窗口 \(row != nil)")
    }

    /// 给了 -perfThreads 时把第一个会话换成当前窗口；再等一行窗口都预热好，同平常用了一阵的样子（见 PaneRow.warmUp）。
    static func arrangeCompact(_ area: WorkArea) async throws {
        let layout = area.layout
        if let id = string("perfThreads")?.split(separator: ",").first.map(String.init),
           let pane = layout.panes.first(where: { area.thread(in: $0)?.id == id }), pane != layout.focused {
            layout.focus(pane)
            try await Task.sleep(for: .seconds(1))
        }
        for _ in 0..<60 {
            if let row, layout.panes.allSatisfy({ row.warm.contains($0) || $0 == layout.focused }) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    static func performPhone(_ scene: String, _ session: Session) async throws {
        guard isPhone else { throw Failure("iPad 只有 drag-bottom、sidebar、motion，没有 \(scene)") }
        switch scene {
        case "drawer": try await drawers(session)
        case "pull": try await pulls(session)
        case "swipe": try await swipes(session)
        case "keyboard": try await keyboard(session)
        default: throw Failure("iPhone 只有 drawer、pull、swipe、keyboard，没有 \(scene)")
        }
    }

    private static var pairs: Int { number("perfPairs").map(Int.init) ?? 4 }

    /// 点按钮开合：拉开、收起侧栏，再拉开、收起底栏（开着窗口时才有）。
    private static func drawers(_ session: Session) async throws {
        guard let drawer else { throw Failure("抽屉没登记") }
        session.onFinish { drawer.settle(nil) }
        try await ready(session)
        for side in [WorkspaceDrawer.sidebar, .actions] {
            if side == .actions, drawer.rule != .free { continue }
            let name = side == .sidebar ? "sidebar" : "actions"
            for index in 0..<pairs {
                session.record(try await timed("\(name)-open", index) { drawer.settle(side) })
                try await Task.sleep(for: .seconds(0.8))
                session.record(try await timed("\(name)-close", index) { drawer.settle(nil) })
                try await Task.sleep(for: .seconds(0.8))
            }
        }
    }

    /// 手指拉侧栏：从左边缘往右，0.2 秒拖到侧栏宽的 6 成后甩开；再从窗口上往左拖回去同样甩回。
    private static func pulls(_ session: Session) async throws {
        guard let drawer else { throw Failure("抽屉没登记") }
        let extent = drawer.extents.sidebar
        guard extent > 0 else { throw Failure("侧栏宽度还没量出来") }
        session.onFinish { drawer.settle(nil) }
        try await ready(session)
        for index in 0..<pairs {
            session.record(try await dragged("pull-open", index, distance: extent * 0.6) { drawer.sidebarPull.changed($0, $1) } ended: { drawer.sidebarPull.ended($0) })
            try await Task.sleep(for: .seconds(0.8))
            session.record(try await dragged("pull-close", index, distance: -extent * 0.6) { drawer.sidebarPull.changed($0, $1) } ended: { drawer.sidebarPull.ended($0) })
            try await Task.sleep(for: .seconds(0.8))
        }
    }

    /// 控制区横滑：0.2 秒滑过 0.45 屏宽后松手，换到相邻窗口；再滑回来。当前窗口在最后时往前滑。
    private static func swipes(_ session: Session) async throws {
        guard let row else { throw Failure("一行窗口没登记") }
        let layout = session.area.layout
        guard layout.panes.count > 1, let focused = layout.focused else { throw Failure("一行里只有一个窗口，不能横滑") }
        session.onFinish { layout.focus(focused) }
        let forward: CGFloat = focused == layout.panes.last ? 1 : -1
        let distance = forward * row.width * 0.45
        try await ready(session)
        for index in 0..<pairs {
            for (name, moved) in [("swipe-next", distance), ("swipe-back", -distance)] {
                session.record(try await dragged(name, index, distance: moved) { translation, _ in
                    row.swipeActions.track(translation.width)
                } ended: { _ in
                    row.swipeActions.end(moved, moved * 1.3)
                })
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 键盘升降：当前窗口的输入框接焦点、放焦点。
    private static func keyboard(_ session: Session) async throws {
        try await ready(session)
        for index in 0..<pairs {
            guard let field = composer() else { throw Failure("当前窗口没有输入框") }
            session.record(try await timed("keyboard-show", index, seconds: 1) { _ = field.becomeFirstResponder() })
            try await Task.sleep(for: .seconds(0.8))
            session.record(try await timed("keyboard-hide", index, seconds: 1) { _ = field.resignFirstResponder() })
            try await Task.sleep(for: .seconds(0.8))
        }
    }

    /// 屏上最下面那个可编辑的文本视图：当前窗口的输入框（对话里的字都不可编辑）。
    private static func composer() -> UITextView? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        func all(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap(all)
        }
        let screen = window.bounds
        return all(window).filter { field in
            let frame = field.convert(field.bounds, to: window)
            return screen.contains(CGPoint(x: frame.midX, y: frame.midY)) && !field.isHidden && field.alpha > 0
        }.max { $0.convert($0.bounds, to: window).maxY < $1.convert($1.bounds, to: window).maxY }
    }

    /// 做 action，逐帧记 seconds 秒：抽屉的弹簧约 0.4 秒、键盘约 0.35 秒，都留足走完。
    private static func timed(_ name: String, _ index: Int, seconds: Double = 0.8, _ action: () -> Void) async throws -> Segment {
        var segment = Segment(name: name, index: index, start: .now)
        try await measuring {
            action()
            try await Clock().run { link in
                let tick = Tick(link)
                segment.ticks.append(tick)
                return tick.wall - segment.start.wall < seconds
            }
        }
        segment.end = .now
        return segment
    }

    /// 手指拖：每帧挪一截，24 帧（120Hz 下 0.2 秒）挪完 distance，按这个速度松手，接着记到第 seconds 秒。
    private static func dragged(_ name: String, _ index: Int, distance: CGFloat, seconds: Double = 1,
                                changed: @escaping (CGSize, CGSize) -> Void, ended: @escaping (CGSize) -> Void) async throws -> Segment {
        let frames = 24
        let velocity = CGSize(width: distance / 0.2, height: 0)
        var segment = Segment(name: name, index: index, start: .now)
        var frame = 0
        try await measuring {
            try await Clock().run { link in
                let tick = Tick(link)
                segment.ticks.append(tick)
                if frame < frames {
                    frame += 1
                    changed(CGSize(width: distance * CGFloat(frame) / CGFloat(frames), height: 0), velocity)
                } else if frame == frames {
                    frame += 1
                    ended(velocity)
                }
                return tick.wall - segment.start.wall < seconds
            }
        }
        segment.end = .now
        return segment
    }
}
#endif
