import AppKit

// 只补齐独立编译所需的宿主环境；滚动实现来自真实 App 文件。
private enum Metrics {
    static let transcriptPadding: CGFloat = 10
}

private struct ContractVisibleHeight: EnvironmentKey {
    nonisolated static let defaultValue: CGFloat = 500
}

extension EnvironmentValues {
    var visibleHeight: CGFloat {
        get { self[ContractVisibleHeight.self] }
        set { self[ContractVisibleHeight.self] = newValue }
    }
}

private enum ScrollContractError: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "滚动合同失败"
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ScrollContractError.failed(message) }
}

@Observable @MainActor
private final class ScrollFixture {
    let scroll = TranscriptScroll()
    var userMessageHeight: CGFloat = 1800
    var geometry: ScrollGeometry?
    var animationCompleted = false
}

private struct ScrollFixtureView: View {
    @Bindable var fixture: ScrollFixture

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: fixture.userMessageHeight)
                Color.clear.frame(height: 300)
            }
        }
        .contentMargins(.top, 37, for: .scrollContent)
        .contentMargins(.bottom, 53, for: .scrollContent)
        .transcriptScroll(fixture.scroll, visibleHeight: 500, userScrollBegan: {})
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            fixture.geometry = geometry
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 31) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 47) }
        .environment(\.visibleHeight, 500)
    }
}

@MainActor @main
private struct TranscriptScrollContract {
    private static func normalizedY(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }

    private static func remaining(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
    }

    // 驱动 AppKit 的真实布局事件，不用 sleep 猜 SwiftUI 完成时间。
    private static func wait(_ label: String, host: NSView, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            try require(Date() < deadline, "等待超时：\(label)")
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let initial = try collapsingOffscreenMessageKeepsLegalReadingPosition()
            try gesturePhasesReleaseTargetsAndResumeAlignment(initial)
            print("滚动两组手动运行时合同验证通过")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    // 真实 bug：长用户消息顶部已离屏，带动画收起后仍钉在超出新末尾的旧坐标，留下大片空白。
    // SwiftUI 对动画 frame、ScrollPosition 绑定与原生 inset 的交接必须实际运行。
    private static func collapsingOffscreenMessageKeepsLegalReadingPosition() throws -> ScrollGeometry {
        let fixture = ScrollFixture()
        let host = NSHostingView(rootView: ScrollFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 480, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try wait("首次定位到底部", host: host) {
            guard let geometry = fixture.geometry else { return false }
            return geometry.contentSize.height == 2100 && geometry.contentInsets.top > 0
                && abs(remaining(geometry)) < 1
        }
        let initial = fixture.geometry!
        print("首次底部：\(initial.debugDescription)")
        let measuredMaximum = normalizedY(initial)
        try require(abs(measuredMaximum - (initial.contentSize.height - initial.containerSize.height)) < 1,
                    "非零 inset 下最大 scrollTo(y:) 与真实底部不一致")

        fixture.scroll.phaseChanged(from: .idle, to: .tracking, geometry: initial)
        fixture.scroll.phaseChanged(from: .tracking, to: .interacting, geometry: initial)
        fixture.scroll.position.scrollTo(y: 900)
        try wait("移至长用户消息中段", host: host) {
            fixture.geometry.map { abs(normalizedY($0) - 900) < 1 } ?? false
        }
        // SDK 与手指滚动的绑定回写一样，清除显式 target；不使用 UI 点按或模拟手势。
        fixture.scroll.position.isPositionedByUser = true
        fixture.scroll.phaseChanged(from: .interacting, to: .idle, geometry: fixture.geometry!)
        let readingY = normalizedY(fixture.geometry!)
        try require(fixture.geometry!.visibleRect.minY > 0, "夹具未把长用户消息顶部滚出屏幕")

        fixture.userMessageHeight = 1500
        try wait("小幅收缩后布局", host: host) { fixture.geometry?.contentSize.height == 1800 }
        try require(abs(normalizedY(fixture.geometry!) - readingY) < 1,
                    "旧坐标仍合法的小幅收缩把阅读位置跳到了底部")
        try require(remaining(fixture.geometry!) > 100, "小幅收缩没有保留足够的非底部阅读区")
        print("小幅收缩保留阅读 y=\(normalizedY(fixture.geometry!))")

        withAnimation(.snappy, completionCriteria: .removed) {
            fixture.userMessageHeight = 80
        } completion: {
            fixture.animationCompleted = true
        }
        try wait("动画收起完成", host: host) { fixture.animationCompleted }
        try wait("动画收起后布局", host: host) { abs((fixture.geometry?.contentSize.height ?? 0) - 380) < 1 }
        let collapsed = fixture.geometry!
        print("动画收起：\(collapsed.debugDescription)，target y=\(String(describing: fixture.scroll.position.y))")
        let maximum = max(0, collapsed.contentSize.height - collapsed.containerSize.height)
        try require(normalizedY(collapsed) >= -1 && normalizedY(collapsed) <= maximum + 1,
                    "动画收起后的偏移越界：\(collapsed.debugDescription)")
        if let target = fixture.scroll.position.y {
            try require(target >= -1 && target <= maximum + 1,
                        "动画收起仍保留越界定位目标 y=\(target)，合法范围为 [0,\(maximum)]")
        }
        try require(collapsed.visibleRect.minY < collapsed.contentSize.height,
                    "动画收起后可见区域只剩内容外空白")
        return initial
    }

    // SDK 在 user 定位时清除目标；phase 与几何连续回调不能把旧 bottom 或新坐标重新写回去抢手势。
    private static func gesturePhasesReleaseTargetsAndResumeAlignment(_ initial: ScrollGeometry) throws {
        let scroll = TranscriptScroll()
        let empty = ScrollGeometry(contentOffset: .zero, contentSize: .zero,
                                   contentInsets: EdgeInsets(), containerSize: initial.containerSize)
        scroll.geometryChanged(from: empty, to: initial)
        try require(scroll.position.edge == .bottom, "夹具未先建立首次 bottom 定位目标")

        var oldPhase = ScrollPhase.idle
        var geometry = initial
        for (index, activePhase) in [ScrollPhase.tracking, .interacting, .decelerating].enumerated() {
            scroll.phaseChanged(from: oldPhase, to: activePhase, geometry: geometry)
            try requireNoTarget(scroll, "进入 \(activePhase)")
            if activePhase != .tracking {
                scroll.position.isPositionedByUser = true
            }
            var moved = geometry
            moved.contentSize.height += 120
            moved.contentOffset.y = initial.contentOffset.y - CGFloat(index + 1) * 100
            scroll.geometryChanged(from: geometry, to: moved)
            try requireNoTarget(scroll, "\(activePhase) 中内容变化与位置回写")
            geometry = moved
            oldPhase = activePhase
        }

        scroll.phaseChanged(from: .decelerating, to: .idle, geometry: geometry)
        var taller = geometry
        taller.contentSize.height += 200
        scroll.geometryChanged(from: geometry, to: taller)
        try require(scroll.position.edge == nil && scroll.position.y.map { abs($0 - normalizedY(geometry)) < 1 } == true,
                    "静止后内容增高未恢复保持原合法阅读坐标")
        print("滚动阶段交接：tracking、interacting、decelerating 无目标，idle 保持 y=\(normalizedY(geometry))")
    }

    private static func requireNoTarget(_ scroll: TranscriptScroll, _ step: String) throws {
        try require(scroll.position.edge == nil && scroll.position.point == nil
                    && scroll.position.x == nil && scroll.position.y == nil && scroll.position.viewID == nil,
                    "\(step) 仍有程序定位目标，与用户滚动竞争")
        try require(scroll.anchor == nil, "\(step) 仍启用默认尺寸对齐，与用户滚动竞争")
    }
}
