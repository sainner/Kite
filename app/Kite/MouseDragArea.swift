#if os(macOS)
import AppKit
import SwiftUI

/// 按住拖动的区域，鼠标事件由 AppKit 接。窗口没有标题栏，顶部那一条仍由系统当作标题栏：
/// 在那里按下鼠标，窗口服务器直接拖动整个窗口，不经过应用。卡片的标题栏、卡片之间的缝都可能顶到窗口顶部，
/// 所以指针停在这块区域上时把窗口设成不可拖动（isMovable），离开后恢复；侧边栏和别的空白处照常拖窗口。
struct MouseDragArea: NSViewRepresentable {
    var cursor: NSCursor
    /// 拖动中的指针样式，不给就不变。
    var activeCursor: NSCursor?
    /// 挪动多少才算拖动，免得单击也算。
    var minimumDistance: CGFloat = 0
    /// 指针位置，窗口坐标，和 SwiftUI 的 .global 一致：左上角是原点。
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
        private var tracking = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            window?.isMovable = false
        }

        override func mouseExited(with event: NSEvent) {
            if !tracking { window?.isMovable = true }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, !tracking { window?.isMovable = true }
            super.viewWillMove(toWindow: newWindow)
        }

        // 按下后自己跟踪到松手：拖动中这块区域可能被移出窗口（卡片脱离布局），之后的事件就不会再送到它
        override func mouseDown(with event: NSEvent) {
            guard let window, let content = window.contentView else { return }
            let start = event.locationInWindow
            var dragging = false
            tracking = true
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
                guard let event, event.type == .leftMouseDragged else {
                    if dragging {
                        if self.activeCursor != nil { NSCursor.pop() }
                        self.onEnded?()
                    }
                    stop.pointee = true
                    return
                }
                let location = event.locationInWindow
                if !dragging {
                    guard hypot(location.x - start.x, location.y - start.y) >= self.minimumDistance else { return }
                    dragging = true
                    self.activeCursor?.push()
                }
                let point = content.convert(location, from: nil)
                self.onChanged?(content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y))
            }
            tracking = false
            // 松手时指针还在这块区域上就保持不可拖动，否则恢复
            let inside = self.window != nil && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            window.isMovable = !inside
        }
    }
}
#endif
