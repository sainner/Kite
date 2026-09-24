#if os(macOS)
import AppKit
import SwiftUI

/// 按住拖动的区域，鼠标事件由 AppKit 接。窗口没有标题栏，顶部那一条仍按标题栏处理：
/// 在那里按下鼠标，系统会拖动整个窗口，SwiftUI 的手势拦不住，AppKit 视图声明不能拖窗口才行。
/// 卡片的标题栏、卡片之间的缝都可能顶到窗口顶部，所以都用它。
struct MouseDragArea: NSViewRepresentable {
    var cursor: NSCursor
    /// 拖动中的指针样式，不给就不变。
    var activeCursor: NSCursor?
    /// 挪动多少才算拖动，免得单击也算。
    var minimumDistance: CGFloat = 0
    /// 指针位置，相对这块区域的左上角。
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
        private var start: CGPoint?
        private var dragging = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = convert(event.locationInWindow, from: nil)
            if !dragging {
                guard hypot(point.x - start.x, point.y - start.y) >= minimumDistance else { return }
                dragging = true
                activeCursor?.push()
            }
            onChanged?(point)
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
#endif
