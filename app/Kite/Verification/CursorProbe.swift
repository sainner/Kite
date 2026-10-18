#if DEBUG && os(macOS)
import AppKit
import os

/// 临时探针（2026-10-18，查完就删）：输入框点进去光标变回箭头。记下每次光标换成别的样子时是谁设的（调用栈）、指针下是哪一串视图，
/// 以及每次按下鼠标时指针下的视图，写系统日志：/usr/bin/log show --last 5m --predicate 'subsystem == "kite.cursor-probe"'。
enum CursorProbe {
    static let log = Logger(subsystem: "kite.cursor-probe", category: "cursor")
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) fileprivate static var last: NSCursor?

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        if let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set)),
           let probe = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.probeSet)) {
            method_exchangeImplementations(original, probe)
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            log.notice("mouseDown 指针下：\(underPointer(), privacy: .public)")
            return event
        }
        log.notice("探针已装上，pid \(ProcessInfo.processInfo.processIdentifier)")
    }

    static func name(_ cursor: NSCursor) -> String {
        if cursor === NSCursor.arrow { return "箭头" }
        if cursor === NSCursor.iBeam { return "文字" }
        if cursor === NSCursor.pointingHand { return "手形" }
        return "其他"
    }

    @MainActor static func underPointer() -> String {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let root = window.contentView?.superview else { return "没有窗口" }
        var view = root.hitTest(window.mouseLocationOutsideOfEventStream)
        var chain: [String] = []
        while let current = view, chain.count < 12 {
            chain.append(String(describing: type(of: current)))
            view = current.superview
        }
        return chain.joined(separator: " < ")
    }
}

extension NSCursor {
    @objc fileprivate func probeSet() {
        probeSet()
        guard CursorProbe.last !== self else { return }
        CursorProbe.last = self
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(14).joined(separator: "\n")
        let under = Thread.isMainThread ? MainActor.assumeIsolated { CursorProbe.underPointer() } : "不在主线程"
        CursorProbe.log.notice("设成\(CursorProbe.name(self), privacy: .public)；指针下：\(under, privacy: .public)\n\(stack, privacy: .public)")
    }
}
#endif
