import AppKit
import SwiftUI

// 和生产的 CompactPaneStack.swift、WindowMotion.swift、CompactPaneHeader.swift、PaneControlSwipe.swift 一起编译。
// 下面只给这几份文件用到、而所在文件又牵着整个 App 的类型补最小定义，不复制任何被测逻辑。

struct Pane: Hashable {
    let id: Int
}

@Observable @MainActor
final class WindowLayout {
    let panes: [Pane]
    private(set) var focused: Pane?

    init(panes: [Pane]) {
        self.panes = panes
        focused = panes.first
    }

    func focus(_ pane: Pane) { focused = pane }
}

@Observable @MainActor
final class DrawerMotion {
    // 抽屉一直收着：横滑只在收着时可用，这里不验证抽屉。
    var collapsed = true
}

struct PaneGroup {
    let layout: WindowLayout
    let recorder: CompactPaneRecorder
}

/// 真实定义在 PaneWindow.swift，那份文件牵着整个窗口；这里只要「建好不换、只改 onScreen」的盒子。
@MainActor @Observable final class PanePresence {
    var onScreen = true
}

extension EnvironmentValues {
    @Entry var panePresence: PanePresence?
    @Entry var keyboardShown = false
    @Entry var paneTopSafeInset: CGFloat = 0
}

// 夹具没有点阵舞台，不验证点阵生命周期。
struct DotsPresence: ViewModifier {
    let presented: Bool

    func body(content: Content) -> some View { content }
}

struct WindowDotsActive: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

enum Metrics {
    static let paneMargin: CGFloat = 12
    static let paneButtonGap: CGFloat = 8
    static let paneHeaderButton: CGFloat = 36
    static let paneToolbarHeight: CGFloat = 44
    static let dragThreshold: CGFloat = 10
}

struct PaneHeader {}

nonisolated struct PaneHeaderHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PaneHeaderBar<Status: View, Actions: View>: View {
    let header: PaneHeader
    let status: Status
    let actions: Actions
    let openSidebar: (@MainActor () -> Void)?

    var body: some View {
        HStack {
            status
            Text("标题")
            actions
        }
    }
}

struct ScrollEdgeDots: View {
    var body: some View { Color.clear }
}

extension View {
    func drawerShift(_ edge: VerticalEdge) -> some View { self }
}

/// PaneControlSwipe 只在手势里调它，合同不发手势。
struct DrawerPull {
    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }
}

// MARK: - 夹具

private enum CompactPaneError: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "紧凑窗口行原生验证失败"
    }
}

@MainActor
final class CompactPaneRecorder {
    /// 窗口正文里的原生按钮每次更新时读到的环境。
    struct Body {
        let button: NSButton
        let presence: PanePresence?
        let motion: WindowMotion?
        let paneSwipe: PaneSwipeActions?
    }

    /// 外壳控制区里的探针每次更新时读到的环境，按先后记录。
    struct Controls {
        let pane: Pane
        let keyboardShown: Bool
        let paneSwipe: PaneSwipeActions?
    }

    var bodies = [Pane: Body]()
    var controls = [Controls]()
    var clicks = [Pane]()

    func latestControls(for pane: Pane) -> Controls? { controls.last { $0.pane == pane } }
}

@MainActor @Observable
final class Shell {
    var keyboardShown = false
}

/// 窗口正文里的原生按钮：验证祖先的真实命中路径，SwiftUI Button 在离屏鼠标派发下不稳定。
private struct NativeButton: NSViewRepresentable {
    let pane: Pane
    let recorder: CompactPaneRecorder
    let presence: PanePresence?
    let motion: WindowMotion?
    let paneSwipe: PaneSwipeActions?

    final class Coordinator: NSObject {
        let pane: Pane
        let recorder: CompactPaneRecorder

        init(pane: Pane, recorder: CompactPaneRecorder) {
            self.pane = pane
            self.recorder = recorder
        }

        @objc func click() { recorder.clicks.append(pane) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pane: pane, recorder: recorder) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "记录点击", target: context.coordinator, action: #selector(Coordinator.click))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {
        recorder.bodies[pane] = .init(button: view, presence: presence, motion: motion, paneSwipe: paneSwipe)
    }
}

/// 放进外壳控制区的探针：记下它在外壳上实际读到的键盘状态和横滑动作。
private struct ControlsProbe: NSViewRepresentable {
    let pane: Pane
    let recorder: CompactPaneRecorder
    let keyboardShown: Bool
    let paneSwipe: PaneSwipeActions?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.controls.append(.init(pane: pane, keyboardShown: keyboardShown, paneSwipe: paneSwipe))
    }
}

private struct ShellControls: View {
    let pane: Pane
    let recorder: CompactPaneRecorder
    @Environment(\.keyboardShown) private var keyboardShown
    @Environment(\.paneSwipe) private var paneSwipe

    var body: some View {
        ControlsProbe(pane: pane, recorder: recorder, keyboardShown: keyboardShown, paneSwipe: paneSwipe)
            .frame(width: 80, height: 24)
    }
}

/// 替代生产 PaneBody：正文里放一个读环境的原生按钮，并像 PaneWindow 一样把自己的控制区连同所处环境报给外壳。
struct PaneBody: View {
    let group: PaneGroup
    let pane: Pane
    @Environment(\.paneSwipe) private var paneSwipe
    @Environment(\.panePresence) private var presence
    @Environment(\.windowMotion) private var motion
    @Environment(\.self) private var environment

    var body: some View {
        VStack {
            Text("窗口 \(pane.id)")
            NativeButton(pane: pane, recorder: group.recorder, presence: presence, motion: motion, paneSwipe: paneSwipe)
                .frame(width: 120, height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.clear.preference(key: CompactPaneHeaders.self, value: [
                CompactPaneHeader(pane: pane, header: PaneHeader(), status: nil, actions: AnyView(EmptyView()),
                                  controls: AnyView(ShellControls(pane: pane, recorder: group.recorder)),
                                  environment: environment, openSidebar: nil, endTyping: {}),
            ])
        }
    }
}

/// 按 CompactWindow 的接法：窗口行外面套外壳的标题栏与控制区。
private struct Fixture: View {
    let group: PaneGroup
    let drawer: DrawerMotion
    let shell: Shell
    static let width: CGFloat = 360

    var body: some View {
        CompactPaneStack(group: group, motion: drawer, width: Self.width)
            .modifier(CompactPaneHeaderHost(focused: group.layout.focused, keyboardShown: shell.keyboardShown))
    }
}

// MARK: - 合同

// 真实回归：窄屏控制区第一次滑动后，新窗口的后续滑动和所有按钮失效（旧的插入/移出设计）。
// 新设计里窗口全部保活、只平移，同样要在 SwiftUI 宿主里跑过动画、焦点切换和鼠标派发才知道对不对：
// - 横滑松手后焦点换到相邻窗口，行停稳后新的当前窗口的原生按钮从宿主可命中，换走的那个被平移到屏外；
// - 窗口还没当过当前窗口时拿到的 paneSwipe，在它成为当前窗口后仍指向同一个 PaneRow，能横滑切回去；
// - 外壳控制区整份接回源窗口环境后，写在里面的 keyboardShown 仍覆盖到控件，源环境里的 paneSwipe 也能从外壳横滑切换；
// - PanePresence 滑动中对露出来的相邻窗口为 true，停稳后换走的窗口翻成 false。
@MainActor @main
private struct CompactPaneStackContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try swipeAndSwitchKeepHandoffsIntact()
            print("紧凑窗口行横滑、保活窗口的环境动作、外壳控制区环境与在屏状态验证通过")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func swipeAndSwitchKeepHandoffsIntact() throws {
        let panes = [Pane(id: 0), Pane(id: 1)]
        let layout = WindowLayout(panes: panes)
        let recorder = CompactPaneRecorder()
        let shell = Shell()
        let group = PaneGroup(layout: layout, recorder: recorder)
        let host = NSHostingView(rootView: Fixture(group: group, drawer: DrawerMotion(), shell: shell))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: Fixture.width, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        // 初始：当前窗口拿到横滑动作、在屏盒子和行的运动，按钮可命中
        try wait("初始窗口拿到横滑动作与在屏盒子", host: host) {
            let body = recorder.bodies[panes[0]]
            return body?.paneSwipe != nil && body?.presence?.onScreen == true && body?.motion != nil
        }
        guard let first = recorder.bodies[panes[0]], let motion = first.motion, let presence0 = first.presence,
              let swipe = first.paneSwipe else {
            throw CompactPaneError.failed("初始窗口环境不完整")
        }
        try clickButton(on: panes[0], host: host, window: window, recorder: recorder)
        print("通过：初始窗口的原生按钮可命中且响应")

        // 外壳控制区：整份接回源窗口环境后，外壳写进去的 keyboardShown 仍要盖过源环境里的默认值
        try wait("外壳显示当前窗口的控制区", host: host) { recorder.latestControls(for: panes[0]) != nil }
        guard recorder.latestControls(for: panes[0])?.keyboardShown == false else {
            throw CompactPaneError.failed("键盘未升起时外壳控制区却读到 keyboardShown 为 true")
        }
        shell.keyboardShown = true
        try wait("键盘升起后外壳控制区读到 keyboardShown", host: host,
                 diagnostics: { "控制区观测 \(recorder.controls.map { "\($0.pane.id):\($0.keyboardShown)" })" }) {
            recorder.latestControls(for: panes[0])?.keyboardShown == true
        }
        guard recorder.bodies[panes[0]]?.presence != nil else { throw CompactPaneError.failed("正文丢了在屏盒子") }
        print("通过：外壳控制区接回源窗口环境后仍读到外壳写入的 keyboardShown")

        // 拖动：相邻窗口当场建出来、算露出来；焦点还没换
        swipe.track(-120)
        try wait("拖动中相邻窗口建出并算在屏上", host: host,
                 diagnostics: { "焦点 \(String(describing: layout.focused))；在屏 \(recorder.bodies.mapValues { $0.presence?.onScreen })" }) {
            layout.focused == panes[0] && recorder.bodies[panes[1]]?.presence?.onScreen == true && presence0.onScreen
        }
        guard let second = recorder.bodies[panes[1]], let presence1 = second.presence, let reverse = second.paneSwipe else {
            throw CompactPaneError.failed("相邻窗口建出时没有拿到横滑动作")
        }
        print("通过：拖动中相邻窗口建出，PanePresence 为在屏，焦点未换")

        // 松手：过了四分之一宽，焦点换到相邻窗口；行停稳后换走的窗口不在屏上、新的当前窗口可命中
        swipe.end(-120, -200)
        try waitSettled(on: panes[1], host: host, window: window, layout: layout, motion: motion, recorder: recorder,
                        presences: [panes[0]: presence0, panes[1]: presence1])
        try clickButton(on: panes[1], host: host, window: window, recorder: recorder)
        print("通过：松手后焦点换到相邻窗口，停稳后它的按钮可命中，换走的窗口平移到屏外且不在屏上")

        // 外壳控制区换到新窗口的源环境，keyboardShown 仍是外壳写的值
        try wait("外壳控制区换到新窗口并保留 keyboardShown", host: host,
                 diagnostics: { "控制区观测 \(recorder.controls.map { "\($0.pane.id):\($0.keyboardShown)" })" }) {
            recorder.latestControls(for: panes[1])?.keyboardShown == true
        }
        print("通过：外壳控制区换到新窗口后仍读到外壳写入的 keyboardShown")

        // 保活窗口还没当过当前窗口时拿到的动作，现在仍指向同一个 PaneRow：用它右滑回去
        reverse.track(120)
        reverse.end(120, 200)
        try waitSettled(on: panes[0], host: host, window: window, layout: layout, motion: motion, recorder: recorder,
                        presences: [panes[0]: presence0, panes[1]: presence1])
        try clickButton(on: panes[0], host: host, window: window, recorder: recorder)
        print("通过：相邻窗口建出时拿到的 paneSwipe 在它成为当前窗口后仍能横滑切回")

        // 外壳控制区从源环境拿到的横滑动作也能切换
        try wait("外壳控制区换回原窗口", host: host) { recorder.latestControls(for: panes[0])?.paneSwipe != nil }
        guard let fromShell = recorder.latestControls(for: panes[0])?.paneSwipe else {
            throw CompactPaneError.failed("外壳控制区没有从源环境拿到 paneSwipe")
        }
        fromShell.track(-120)
        fromShell.end(-120, -200)
        try waitSettled(on: panes[1], host: host, window: window, layout: layout, motion: motion, recorder: recorder,
                        presences: [panes[0]: presence0, panes[1]: presence1])
        try clickButton(on: panes[1], host: host, window: window, recorder: recorder)
        print("通过：外壳控制区从源环境拿到的 paneSwipe 能横滑切换窗口")

        guard recorder.clicks == [panes[0], panes[1], panes[0], panes[1]] else {
            throw CompactPaneError.failed("点击记录不符：\(recorder.clicks.map(\.id))")
        }
    }

    /// 等焦点换到目标窗口、整行停稳：目标在屏内且 onScreen，另一个平移到屏外且 onScreen 为 false。
    private static func waitSettled(on target: Pane, host: NSView, window: NSWindow, layout: WindowLayout,
                                    motion: WindowMotion, recorder: CompactPaneRecorder,
                                    presences: [Pane: PanePresence]) throws {
        try wait("焦点换到窗口 \(target.id)", host: host,
                 diagnostics: { "焦点 \(String(describing: layout.focused))" }) { layout.focused == target }
        try wait("窗口 \(target.id) 停稳后在屏、其余窗口离屏", host: host, diagnostics: {
            "moving \(motion.moving)；在屏 \(presences.map { "\($0.key.id):\($0.value.onScreen)" })；按钮 \(recorder.bodies.map { "\($0.key.id):\(frameInHost($0.value.button, host: host))" })"
        }) {
            guard !motion.moving else { return false }
            return presences.allSatisfy { pane, presence in
                guard let button = recorder.bodies[pane]?.button, button.window === window else { return false }
                let midX = frameInHost(button, host: host).midX
                let inside = midX > 0 && midX < host.bounds.width
                return pane == target ? presence.onScreen && inside : !presence.onScreen && !inside
            }
        }
    }

    // 先从 NSHostingView 命中按钮才允许发动作，不能用 performClick 绕过被 allowsHitTesting 关掉的窗口。
    private static func clickButton(on pane: Pane, host: NSView, window: NSWindow,
                                    recorder: CompactPaneRecorder) throws {
        try wait("窗口 \(pane.id) 的原生按钮从宿主可命中", host: host,
                 diagnostics: { hitDescription(on: pane, host: host, recorder: recorder) }) {
            guard let button = recorder.bodies[pane]?.button,
                  button.window === window, button.bounds.width > 0, button.bounds.height > 0,
                  let hit = hit(on: button, host: host) else { return false }
            return hit === button || hit.isDescendant(of: button)
        }
        guard let button = recorder.bodies[pane]?.button else {
            throw CompactPaneError.failed("已命中的窗口 \(pane.id) 缺少原生按钮")
        }
        let since = recorder.clicks.count
        button.performClick(nil)
        try wait("窗口 \(pane.id) 的按钮应响应", host: host) {
            recorder.clicks.count == since + 1 && recorder.clicks.last == pane
        }
    }

    private static func frameInHost(_ view: NSView, host: NSView) -> CGRect {
        view.convert(view.bounds, to: host)
    }

    private static func hit(on button: NSView, host: NSView) -> NSView? {
        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        // NSView.hitTest 接受接收者 superview 坐标，NSHostingView 自身的坐标可能是 flipped。
        return host.hitTest(button.convert(center, to: host.superview))
    }

    private static func hitDescription(on pane: Pane, host: NSView, recorder: CompactPaneRecorder) -> String {
        guard let button = recorder.bodies[pane]?.button else { return "按钮尚未出现" }
        return "命中 \(String(describing: hit(on: button, host: host)))；按钮在宿主里 \(frameInHost(button, host: host))"
    }

    private static func wait(_ label: String, host: NSView, diagnostics: () -> String = { "" },
                             until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw CompactPaneError.failed("\(label)：等待超时；\(diagnostics())") }
            host.layoutSubtreeIfNeeded()
            if !predicate() { RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05))) }
        }
    }
}
