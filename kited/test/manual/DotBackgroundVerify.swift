import AppKit
import SwiftUI

private enum DotBackgroundError: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "窗口点阵原生验证失败"
    }
}

@Observable @MainActor
private final class DotBackgroundFixture {
    var enabled = true
    var focused: Bool?
    var present = true
}

@MainActor
private final class DotPreferenceRecorder {
    var events = [Bool]()

    func record(_ active: Bool) { events.append(active) }
}

private struct DotBackgroundFixtureView: View {
    @Bindable var fixture: DotBackgroundFixture
    let recorder: DotPreferenceRecorder

    var body: some View {
        HStack {
            if fixture.present {
                if let focused = fixture.focused {
                    dotWindow.environment(\.windowDotsFocused, focused)
                } else {
                    dotWindow
                }
            }
            // 始终保留一个明确停用、仍有焦点的窗口，防止它在另一窗口释放时继续占用。
            Color.clear.frame(width: 80, height: 80)
                .windowDots(false)
                .environment(\.windowDotsFocused, true)
        }
        .appDotBackground()
        .onPreferenceChange(WindowDotsActive.self) { active in
            recorder.record(active)
        }
    }

    private var dotWindow: some View {
        Color.clear.frame(width: 80, height: 80).windowDots(fixture.enabled)
    }
}

@MainActor @main
private struct DotBackgroundContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try focusedWindowReleasesDotsWhenDefocusedDisabledOrRemoved()
            print("窗口聚焦、失焦、停用与移除的点阵交接验证通过")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    // SwiftUI 运行时约束：Environment 应穿过窗口 modifier，Preference 应穿过 App 宿主，
    // 原本贡献 true 的子视图移除后应重新归约到 false；单看各部分无法确认这段交接。
    private static func focusedWindowReleasesDotsWhenDefocusedDisabledOrRemoved() throws {
        let fixture = DotBackgroundFixture()
        let recorder = DotPreferenceRecorder()
        let host = NSHostingView(rootView: DotBackgroundFixtureView(fixture: fixture, recorder: recorder))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 240, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        try waitForPreference(true, "默认聚焦的点阵窗口占用 App 点阵", host: host, recorder: recorder)

        var since = recorder.events.count
        fixture.focused = false
        try waitForPreference(false, "失焦后恢复，停用窗口不能继续占用", since: since, host: host, recorder: recorder)

        since = recorder.events.count
        fixture.focused = true
        try waitForPreference(true, "再次聚焦后重新占用", since: since, host: host, recorder: recorder)

        since = recorder.events.count
        fixture.enabled = false
        try waitForPreference(false, "保持聚焦但停用点阵后恢复", since: since, host: host, recorder: recorder)

        since = recorder.events.count
        fixture.enabled = true
        try waitForPreference(true, "重新启用点阵后占用", since: since, host: host, recorder: recorder)

        since = recorder.events.count
        fixture.present = false
        try waitForPreference(false, "移除聚焦的点阵窗口后恢复默认值", since: since, host: host, recorder: recorder)
    }

    // 等真实布局和 preference 事件，不用 sleep 猜 SwiftUI 完成时间。
    private static func waitForPreference(_ expected: Bool, _ label: String, since: Int = 0,
                                          host: NSView, recorder: DotPreferenceRecorder) throws {
        let deadline = Date().addingTimeInterval(5)
        while recorder.events.count <= since || recorder.events.last != expected {
            guard Date() < deadline else {
                throw DotBackgroundError.failed("\(label)：等待超时；期望 \(expected)，实际事件 \(recorder.events)")
            }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: deadline)
        }
        print("通过：\(label)")
    }
}
