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

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        // 按下后自己跟踪到松手：拖动中这块区域可能被移出窗口（卡片脱离布局），之后的事件就不会再送到它
        override func mouseDown(with event: NSEvent) {
            guard let window, let content = window.contentView else { return }
            let start = event.locationInWindow
            var dragging = false
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
        }
    }
}
#endif
