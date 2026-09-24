#if os(macOS)
import AppKit
import SwiftUI

/// 按住拖动的区域，鼠标事件由 AppKit 接，报的是窗口坐标（左上角是原点，和 SwiftUI 的 .global 一致）。
/// 用 AppKit 是为了声明这里按下不拖窗口；标题栏那一条另见 disablesWindowDragging。
struct MouseDragArea: NSViewRepresentable {
    var cursor: NSCursor
    /// 拖动中的指针样式，不给就不变。
    var activeCursor: NSCursor?
    /// 挪动多少才算拖动，免得单击也算。
    var minimumDistance: CGFloat = 0
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void = {}

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.cursor = cursor
        view.activeCursor = activeCursor
        view.minimumDistance = minimumDistance
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.window?.invalidateCursorRects(for: view)
    }

    final class DragView: NSView {
        var cursor = NSCursor.arrow
        var activeCursor: NSCursor?
        var minimumDistance: CGFloat = 0
        var onChanged: ((CGPoint) -> Void)?
        var onEnded: (() -> Void)?
        private var start: NSPoint?
        private var dragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let content = window?.contentView else { return }
            let location = event.locationInWindow
            if !dragging {
                guard hypot(location.x - start.x, location.y - start.y) >= minimumDistance else { return }
                dragging = true
                activeCursor?.push()
            }
            let point = content.convert(location, from: nil)
            onChanged?(content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y))
        }

        override func mouseUp(with event: NSEvent) {
            if dragging {
                if activeCursor != nil { NSCursor.pop() }
                onEnded?()
            }
            start = nil
            dragging = false
        }
    }
}

extension View {
    /// 这块区域上不拖窗口。窗口没有标题栏，顶部那一条仍由系统当作标题栏：在那里按下鼠标，
    /// 窗口服务器直接拖动整个窗口，不经过应用，普通视图挡不住。所以指针在这块区域上时把窗口设成不可拖动，
    /// 离开后恢复；拖窗口交给侧边栏这些空白处，系统的贴边分屏、拖到别的桌面照常可用。
    func disablesWindowDragging() -> some View {
        background(WindowDragBlocker())
    }
}

private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView {
        BlockerView()
    }

    func updateNSView(_ view: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            window?.isMovable = false
        }

        override func mouseExited(with event: NSEvent) {
            window?.isMovable = true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { window?.isMovable = true }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
#endif
