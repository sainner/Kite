import SwiftUI

/// 紧凑布局的窗口按底栏的顺序排成一行，铺满时只露出当前窗口；控制区横滑时整行跟着手指走，松手滑到相邻窗口或回原处。
/// 标题栏和控制区由外壳统一显示（CompactPaneHeaderHost），换窗口时原地过渡；这里平移的是窗口本身。
///
/// 窗口建好就一直留着，滑动时不新建也不回收：新建会话窗口要把整段对话重新建一遍、排一遍、画一遍，重新订阅还会收到整段历史再排一遍，
/// iPhone 上一次卡 120～440 毫秒（2026-10-11 真机 Time Profiler）。当前窗口先建，其余的等它出来以后由近到远一个个建，
/// 不赶在滑动和抽屉开合的时候；手指比预热先到时，当场建出相邻的那个。
///
/// 放进窗口环境的东西（横滑动作）建好就不再换：环境一变，SwiftUI 要把它推给窗口里的每个 UIKit 视图，
/// 对话里每段字都是一个 UITextView，一次 60～90 毫秒（同上实测），横滑开始、松手、停稳各来一次。
struct CompactPaneStack: View {
    let group: PaneGroup
    let motion: DrawerMotion
    let width: CGFloat
    let keyboardShown: Bool
    @State private var row: PaneRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(group: PaneGroup, motion: DrawerMotion, width: CGFloat, keyboardShown: Bool) {
        self.group = group
        self.motion = motion
        self.width = width
        self.keyboardShown = keyboardShown
        _row = State(initialValue: PaneRow(layout: group.layout, drawer: motion, width: width))
    }

    var body: some View {
        let panes = group.layout.panes
        let focused = group.layout.focused
        let swipe = row.swipe
        ZStack {
            ForEach(panes.filter { row.warm.contains($0) || $0 == focused }, id: \.self) { pane in
                let index = panes.firstIndex(of: pane) ?? 0
                let current = pane == focused
                // 滑动途中，开始时那个窗口两旁的都可能露出来
                let exposed = current || swipe.map { abs(index - $0.page) <= 1 } == true
                RowPlacement(motion: row.slide, offset: CGFloat(index) * width) {
                    PaneBody(group: group, pane: pane)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                    // 键盘升没升只告诉当前窗口：收起键盘的按钮只插进它的控制区，见 KeyboardDismissButton
                    .environment(\.keyboardShown, current && keyboardShown)
                    .modifier(DotsPresence(presented: current && swipe == nil))
                    // 没露出来的窗口不要窗口的点阵层
                    .transformPreference(WindowDotsActive.self) { if !exposed { $0 = false } }
                    .allowsHitTesting(current)
                    .accessibilityHidden(!current)
                    .transition(.identity)
            }
        }
        .environment(\.windowMotion, row.slide)
        .environment(\.switchPane, row.switchPane)
        .environment(\.trackPaneSwipe, row.track)
        .environment(\.endPaneSwipe, row.end)
        .environment(\.cancelPaneSwipe, row.cancel)
        .onChange(of: row.slide.moving) { _, moving in if !moving { row.settled() } }
        // 底栏点了别的窗口、窗口增删挪了序号：直接停到当前窗口上；松手时已经朝它滑过去的不打断
        .onChange(of: row.page) { row.follow() }
        // 当过当前窗口的也记进预热过的，换走以后留着
        .onChange(of: focused, initial: true) { if let focused { row.keep(focused) } }
        .onChange(of: width) { row.width = width; row.snap() }
        .onChange(of: motion.collapsed) { _, collapsed in if !collapsed { row.snap() } }
        .onChange(of: reduceMotion, initial: true) { row.reduceMotion = reduceMotion }
        .task(id: panes) { await row.warmUp() }
    }
}

/// 一行窗口的横滑状态与手势处理，CompactPaneStack 持有一个。
@MainActor @Observable
final class PaneRow {
    /// 整行的横向位置，记在 frame.minX：第 i 个窗口铺满时是 -i × 宽。
    let slide: WindowMotion
    /// 预热过的窗口；当前窗口不在里面也照样建。
    private(set) var warm: Set<Pane> = []
    /// 从开始拖到停稳的这一次横滑。
    private(set) var swipe: Swipe?

    struct Swipe {
        /// 开始时整行的位置（半路接住正在滑的，就是那一帧的位置）。
        var origin: CGFloat
        /// 开始时当前窗口的序号；这次只能滑到它两旁。
        var page: Int
        var dragging: Bool
    }

    @ObservationIgnored let layout: WindowLayout
    @ObservationIgnored let drawer: DrawerMotion
    @ObservationIgnored var width: CGFloat
    @ObservationIgnored var reduceMotion = false
    /// 放进环境的动作，建好就不再换。
    @ObservationIgnored private(set) var track: @MainActor (CGFloat) -> Void = { _ in }
    @ObservationIgnored private(set) var end: @MainActor (CGFloat, CGFloat) -> Void = { _, _ in }
    @ObservationIgnored private(set) var cancel: @MainActor () -> Void = {}
    @ObservationIgnored private(set) var switchPane: @MainActor (Int) -> Void = { _ in }

    init(layout: WindowLayout, drawer: DrawerMotion, width: CGFloat) {
        self.layout = layout
        self.drawer = drawer
        self.width = width
        // 一开始就停在当前窗口上，第一帧不从第一个窗口挪过来
        let page = layout.focused.flatMap { layout.panes.firstIndex(of: $0) } ?? 0
        slide = WindowMotion(WindowPose(frame: CGRect(x: -CGFloat(page) * width, y: 0, width: 0, height: 0)))
        track = { [weak self] in self?.drag($0) }
        end = { [weak self] in self?.release($0, predicted: $1) }
        cancel = { [weak self] in self?.abandon() }
        switchPane = { [weak self] in self?.step($0) }
    }

    /// 当前窗口的序号。
    var page: Int? { layout.focused.flatMap { layout.panes.firstIndex(of: $0) } }

    private func rest(_ page: Int?) -> CGFloat { -CGFloat(page ?? 0) * width }

    func keep(_ pane: Pane) {
        if !warm.contains(pane) { warm.insert(pane) }
    }

    /// 当前窗口出来以后，由近到远把其余窗口一个个建好；滑动、抽屉开合时等它停下。
    func warmUp() async {
        do {
            try await Task.sleep(for: .milliseconds(400))
            while true {
                let panes = layout.panes
                guard let page else { return }
                let cold = panes.indices.filter { !warm.contains(panes[$0]) && $0 != page }
                guard let next = cold.min(by: { abs($0 - page) < abs($1 - page) }) else { return }
                while swipe != nil || !drawer.collapsed {
                    try await Task.sleep(for: .milliseconds(100))
                }
                warm.insert(panes[next])
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {}
    }

    private func drag(_ translation: CGFloat) {
        guard drawer.collapsed, width > 0, let page else { return }
        if swipe?.dragging != true {
            // 正在滑的半路接住：从这一帧实际的位置接着拖
            swipe = Swipe(origin: slide.presentation(at: .now).frame.minX, page: page, dragging: true)
            slide.interacting = true
            let panes = layout.panes
            let neighbours = [page - 1, page + 1].filter(panes.indices.contains).map { panes[$0] }
            if !warm.isSuperset(of: neighbours) { warm.formUnion(neighbours) }
        }
        guard let swipe else { return }
        // 只能滑到开始时那个窗口的两旁，到头或滑过一个窗口后越拖越吃力
        let low = rest(min(swipe.page + 1, layout.panes.count - 1)), high = rest(max(swipe.page - 1, 0))
        let x = swipe.origin + translation
        move(x > high ? high + (x - high) * 0.2 : x < low ? low + (x - low) * 0.2 : x, kind: .immediate)
    }

    private func release(_ translation: CGFloat, predicted: CGFloat) {
        guard let swipe, swipe.dragging else { return }
        let distance = swipe.origin + translation - rest(swipe.page)
        let projected = swipe.origin + predicted - rest(swipe.page)
        let commit = abs(distance) >= width * 0.25 || (abs(projected) >= width * 0.4 && projected * distance > 0)
        settle(to: commit ? swipe.page + (distance < 0 ? 1 : -1) : swipe.page)
    }

    /// 没有拖动过程的切换：直接滑到相邻窗口。
    private func step(_ direction: Int) {
        guard drawer.collapsed, swipe == nil, let page, layout.panes.indices.contains(page + direction) else { return }
        warm.insert(layout.panes[page + direction])
        swipe = Swipe(origin: slide.target.frame.minX, page: page, dragging: false)
        settle(to: page + direction)
    }

    private func abandon() {
        if let swipe, swipe.dragging { settle(to: swipe.page) }
    }

    /// 松手：当前窗口当场换成要去的那个（标题栏的渐变、点按都跟着它），整行接着滑过去。
    private func settle(to target: Int) {
        let panes = layout.panes
        guard panes.indices.contains(target) else { snap(); return }
        swipe?.dragging = false
        slide.interacting = false
        move(rest(target), kind: reduceMotion ? .immediate : .settle)
        layout.focus(panes[target])
        settled()
    }

    /// 整行停稳了，这次横滑结束。
    func settled() {
        if swipe?.dragging == false, !slide.moving { swipe = nil }
    }

    /// 当前窗口换了：已经朝它滑过去的不管，否则直接停过去。
    func follow() {
        if slide.target.frame.minX != rest(page) { snap() }
    }

    /// 不带动画停到当前窗口上，丢掉这次横滑。
    func snap() {
        swipe = nil
        slide.interacting = false
        move(rest(page), kind: .immediate)
    }

    private func move(_ x: CGFloat, kind: WindowMotionKind) {
        slide.move(to: WindowPose(frame: CGRect(x: x, y: 0, width: 0, height: 0)), kind: kind)
    }
}

/// 窗口摆到行里的位置：只在渲染时平移已经排好的窗口，不把逐帧进度传进窗口内容与安全区排版。
private struct RowPlacement<Content: View>: View {
    let motion: WindowMotion
    /// 窗口在行里的位置：序号 × 宽。
    let offset: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.animation(paused: !motion.moving)) { clock in
            content.modifier(WindowTranslation(point: CGPoint(x: motion.presentation(at: clock.date).frame.minX + offset, y: 0)).ignoredByLayout())
        }
    }
}
