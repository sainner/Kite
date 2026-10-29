#if os(macOS)
import AppKit
import SwiftUI

/// 单按一下右 Option：开始或结束台面上聚焦的会话的语音输入，同输入区的麦克风按钮（经 WorkThread.voiceToggles）。
/// 松开时才切换；按着的时候又按了别的键、别的修饰键或点了鼠标就不算，右 Option 加字母打特殊字符、加点按照常用。
/// 挂在每个工作区的窗口组上（WorkspaceContent），只管自己所在窗口里的按键，聚焦的窗口不是会话时什么也不做。
struct VoiceShortcut: NSViewRepresentable {
    let area: WorkArea

    func makeNSView(context: Context) -> VoiceShortcutView { VoiceShortcutView() }

    func updateNSView(_ view: VoiceShortcutView, context: Context) { view.area = area }
}

final class VoiceShortcutView: NSView {
    weak var area: WorkArea?
    private var monitor: Any?
    /// 只按着右 Option，还没碰别的键。
    private var armed = false

    /// 右 Option 的键码（kVK_RightOption），以及修饰键里分左右的那两位（NX_DEVICERALTKEYMASK、NX_DEVICELALTKEYMASK）。
    private static let rightOption: UInt16 = 0x3D
    private static let rightOptionBit: UInt = 0x40
    private static let leftOptionBit: UInt = 0x20

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        armed = false
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                self?.handle(event)
                return event
            }
        } else if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.window === window else { return }
        guard event.type == .flagsChanged, event.keyCode == Self.rightOption else {
            armed = false
            return
        }
        let flags = event.modifierFlags
        if flags.rawValue & Self.rightOptionBit != 0 {
            armed = flags.intersection([.command, .control, .option, .shift]) == .option && flags.rawValue & Self.leftOptionBit == 0
        } else {
            if armed { toggle() }
            armed = false
        }
    }

    /// 同菜单命令（KiteCommands.onFocusedPane）：拖动、改尺寸途中不算，只认台面上聚焦且显示着的窗口。
    private func toggle() {
        guard let area, area.pluginClient != nil else { return }
        let layout = area.layout
        guard layout.drag == nil, layout.resizing == nil, let pane = layout.focused, layout.shown?.panes.contains(pane) == true,
              let thread = area.thread(in: pane) else { return }
        thread.voiceToggles += 1
    }
}
#endif
