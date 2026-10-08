import AppKit
import SwiftUI

struct Pane: Hashable {
    let id: Int
}

@Observable @MainActor
final class WindowLayout {
    let panes: [Pane]
    var focused: Pane?

    init(panes: [Pane]) {
        self.panes = panes
        focused = panes.first
    }

    func focus(_ pane: Pane) { focused = pane }
}

struct PaneGroup {
    let layout: WindowLayout
    let recorder: CompactPaneRecorder
    let lively: Bool
}

enum Theme {
    static let card = Color.white
}

extension EnvironmentValues {
    @Entry var switchPane: (@MainActor (Int) -> Void)? = nil
}

private enum CompactPaneError: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "紧凑卡片原生验证失败"
    }
}

@MainActor
final class CompactPaneRecorder {
    struct Control {
        let view: NSView
        let switchPane: (@MainActor (Int) -> Void)?
        let revision: Int
    }

    var controls = [Pane: Control]()
    var observations = [(pane: Pane, control: Control)]()
    var clicks = [Pane]()
    var updates = [String]()
    var redraws = [Pane: Int]()
    private var revision = 0

    func record(_ pane: Pane, view: NSView, switchPane: (@MainActor (Int) -> Void)?) {
        revision += 1
        let control = Control(view: view, switchPane: switchPane, revision: revision)
        controls[pane] = control
        observations.append((pane, control))
        updates.append("\(pane.id):\(switchPane == nil ? "禁止" : "可切换")")
    }

    var mark: Int { revision }
}

private struct NativeButton: NSViewRepresentable {
    let pane: Pane
    let recorder: CompactPaneRecorder
    let switchPane: (@MainActor (Int) -> Void)?

    final class Coordinator: NSObject {
        var pane: Pane
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
        context.coordinator.pane = pane
        recorder.record(pane, view: view, switchPane: switchPane)
    }
}

struct PaneBody: View {
    let group: PaneGroup
    let pane: Pane
    @Environment(\.switchPane) private var switchPane

    var body: some View {
        if group.lively {
            content
                .background {
                    TimelineView(.animation) { context in
                        RedrawProbe(pane: pane, recorder: group.recorder, date: context.date)
                    }
                }
                .safeAreaBar(edge: .top) {
                    GlassEffectContainer {
                        HStack {
                            Text("控制区")
                            AnimatedStatus()
                        }
                        .padding(8)
                        .glassEffect()
                    }
                }
                .safeAreaBar(edge: .bottom) {
                    GlassEffectContainer {
                        Text("状态区").padding(8).glassEffect()
                    }
                }
        } else {
            content
        }
    }

    private var content: some View {
        VStack {
            Text("卡片 \(pane.id)")
            NativeButton(pane: pane, recorder: group.recorder, switchPane: switchPane)
                .frame(width: 120, height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AnimatedStatus: View {
    @State private var expanded = false

    var body: some View {
        Circle().fill(.blue).frame(width: 12, height: 12)
            .scaleEffect(expanded ? 1.2 : 0.8)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.1).repeatForever(autoreverses: true)) {
                    expanded = true
                }
            }
    }
}

private struct RedrawProbe: NSViewRepresentable {
    let pane: Pane
    let recorder: CompactPaneRecorder
    let date: Date

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.redraws[pane, default: 0] += 1
    }
}

@MainActor @main
private struct CompactPaneStackContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try repeatedSwitchesRestoreControlsAndButtonHitTesting(lively: false)
            try repeatedSwitchesRestoreControlsAndButtonHitTesting(lively: true)
            print("静态与持续动画卡片连续左右切换后的入口恢复和按钮命中验证通过")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    // 真实回归：窄屏控制区第一次滑动后，新卡片的后续滑动和所有按钮失效。
    // 必须在 SwiftUI 宿主里经历动画、插入/移出和鼠标派发，类型检查不能保证 hit testing 交接。
    // 第二个场景保留真实页面的 safeAreaBar / GlassEffectContainer、重复状态动画和 TimelineView 重绘。
    // 子视图继续更新时，卡片完成回调也必须恢复整个新卡片的交互。
    private static func repeatedSwitchesRestoreControlsAndButtonHitTesting(lively: Bool) throws {
        let panes = [Pane(id: 0), Pane(id: 1)]
        let layout = WindowLayout(panes: panes)
        let recorder = CompactPaneRecorder()
        let group = PaneGroup(layout: layout, recorder: recorder, lively: lively)
        let host = NSHostingView(rootView: CompactPaneStack(group: group, width: 360, canSwitch: true))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 360, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        try wait("初始卡片切换入口出现", host: host) {
            recorder.controls[panes[0]]?.switchPane != nil
        }
        if lively {
            try wait("初始卡片的 TimelineView 已持续重绘", host: host) {
                recorder.redraws[panes[0], default: 0] >= 2
            }
        }
        try clickButton(on: panes[0], host: host, window: window, recorder: recorder)
        print("通过：\(lively ? "持续动画" : "静态")卡片初始原生按钮可命中且动作响应")

        if lively {
            guard let firstSwitch = recorder.controls[panes[0]]?.switchPane else {
                throw CompactPaneError.failed("连续反向切换前缺少初始入口")
            }
            var since = recorder.mark
            firstSwitch(1)
            try wait("新卡片首次提供环境", host: host,
                     diagnostics: { "焦点 \(String(describing: layout.focused))；事件 \(recorder.updates)" }) {
                layout.focused == panes[1] && recorder.observations.contains {
                    $0.pane == panes[1] && $0.control.revision > since
                }
            }
            guard let incoming = recorder.observations.first(where: {
                $0.pane == panes[1] && $0.control.revision > since
            }), let reverse = incoming.control.switchPane else {
                throw CompactPaneError.failed("新卡片首次出现时没有立即反向切换的入口；事件 \(recorder.updates)")
            }
            // 新卡片入口出现就反向，期间不等待按钮命中或动画落稳。
            since = recorder.mark
            reverse(-1)
            try waitForSwitch(on: panes[0], since: since, host: host, window: window,
                              layout: layout, recorder: recorder)
            try clickButton(on: panes[0], host: host, window: window, recorder: recorder)
            print("通过：持续动画卡片出现后立即反向，最终目标按钮可命中且响应")
        }

        for (direction, target) in [(1, panes[1]), (-1, panes[0]), (1, panes[1]), (-1, panes[0])] {
            guard let current = layout.focused,
                  let switchPane = recorder.controls[current]?.switchPane else {
                throw CompactPaneError.failed("当前卡片没有恢复切换入口；事件 \(recorder.updates)")
            }
            let since = recorder.mark
            switchPane(direction)
            try waitForSwitch(on: target, since: since, host: host, window: window,
                              layout: layout, recorder: recorder)
            if lively {
                let previous = recorder.redraws[target, default: 0]
                try wait("切换后的卡片 \(target.id) 仍持续重绘", host: host) {
                    recorder.redraws[target, default: 0] > previous
                }
            }
            try clickButton(on: target, host: host, window: window, recorder: recorder)
            print("通过：方向 \(direction) 切到卡片 \(target.id) 后入口恢复且按钮响应")
        }
    }

    private static func waitForSwitch(on pane: Pane, since: Int, host: NSView, window: NSWindow,
                                     layout: WindowLayout, recorder: CompactPaneRecorder) throws {
        try wait("卡片 \(pane.id) 出现并提供切换入口", host: host,
                 diagnostics: { "焦点 \(String(describing: layout.focused))；事件 \(recorder.updates)；重绘 \(recorder.redraws)" }) {
            layout.focused == pane && recorder.controls[pane].map {
                $0.revision > since && $0.switchPane != nil && $0.view.window === window
            } == true
        }
    }

    // SwiftUI 的离屏鼠标派发无法稳定触发 Button，使用原生 NSButton 验证祖先的真实命中路径。
    // 先从 NSHostingView 命中按钮才允许发动作，不能用 performClick 绕过被卡片禁用的 hit testing。
    private static func clickButton(on pane: Pane, host: NSView, window: NSWindow,
                                    recorder: CompactPaneRecorder) throws {
        try wait("卡片 \(pane.id) 的原生按钮从宿主可命中", host: host,
                 diagnostics: { "\(hitDescription(on: pane, host: host, recorder: recorder))；事件 \(recorder.updates)" }) {
            guard let button = recorder.controls[pane]?.view as? NSButton,
                  button.window === window, button.bounds.width > 0, button.bounds.height > 0,
                  let hit = hit(on: button, host: host) else { return false }
            return hit === button || hit.isDescendant(of: button)
        }
        guard let button = recorder.controls[pane]?.view as? NSButton else {
            throw CompactPaneError.failed("已命中的卡片 \(pane.id) 缺少原生按钮")
        }
        let since = recorder.clicks.count
        button.performClick(nil)
        try wait("卡片 \(pane.id) 的按钮应响应", host: host) {
            recorder.clicks.count == since + 1 && recorder.clicks.last == pane
        }
    }

    private static func hit(on button: NSView, host: NSView) -> NSView? {
        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        // NSView.hitTest 接受接收者 superview 坐标，NSHostingView 自身的坐标可能是 flipped。
        return host.hitTest(button.convert(center, to: host.superview))
    }

    private static func hitDescription(on pane: Pane, host: NSView, recorder: CompactPaneRecorder) -> String {
        guard let button = recorder.controls[pane]?.view else { return "按钮尚未出现" }
        return "命中 \(String(describing: hit(on: button, host: host)))；按钮布局 \(button.frame)"
    }

    private static func wait(_ label: String, host: NSView, diagnostics: () -> String = { "" },
                             until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw CompactPaneError.failed("\(label)：等待超时；\(diagnostics())") }
            host.layoutSubtreeIfNeeded()
            if !predicate() { RunLoop.main.run(mode: .default, before: deadline) }
        }
    }
}
