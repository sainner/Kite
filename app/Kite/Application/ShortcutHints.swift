import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 按住修饰键时标出的编号：⌘ 标停靠栏各格（⌘数字打开，见 DockModel.topToBottom），⌃⌘ 标侧栏各工作区（⌃⌘数字切换），见 KiteCommands。
enum ShortcutHint {
    case dock, workspaces
}

extension AppModel {
    /// ⌃⌘1～9 切换的工作区：侧栏工作区一栏的顺序，收起时那一列圆点同序，不含 Line。
    var numberedWorkspaces: [WorkArea] { Array(workspaceGroups.flatMap(\.workspaces).prefix(9)) }

    /// 按住 ⌃⌘ 时这个工作区标的编号；没在标、排在第 9 个以后为 nil。
    func workspaceHint(_ area: WorkArea) -> Int? {
        guard shortcutHint == .workspaces, let index = numberedWorkspaces.firstIndex(where: { $0 === area }) else { return nil }
        return index + 1
    }
}

/// 标出的编号：圈在一个细描边圆里。停靠栏标签尾部、侧栏工作区行的控制区都用它，一样大。
struct ShortcutNumber: View {
    static let diameter: CGFloat = 14
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(Theme.status)
            .monospacedDigit()
            .frame(width: Self.diameter, height: Self.diameter)
            .overlay(Circle().strokeBorder(lineWidth: 1))
            .foregroundStyle(.tertiary)
    }
}

#if os(macOS)
/// 只按着 ⌘ 或 ⌃⌘ 时当场标出编号。松开、换了修饰键、按了别的键、点了鼠标或 App 退到后台就收起；收起后要松开再按住才重新标。
@MainActor final class ShortcutHintMonitor {
    static let shared = ShortcutHintMonitor()
    private weak var model: AppModel?
    private var monitor: Any?
    private var observer: NSObjectProtocol?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShortcutHintMonitor.shared.clear() }
        }
    }

    private func handle(_ event: NSEvent) {
        // 按了别的键、点了鼠标都收起
        let held = event.type == .flagsChanged ? event.modifierFlags.intersection([.command, .control, .option, .shift]) : []
        let hint: ShortcutHint? = switch held {
        case [.command]: .dock
        case [.control, .command]: .workspaces
        default: nil
        }
        if model?.shortcutHint != hint { model?.shortcutHint = hint }
    }

    private func clear() {
        if model?.shortcutHint != nil { model?.shortcutHint = nil }
    }
}
#endif
