#if os(macOS)
import AppKit
import SwiftUI

/// 按下、挪过 minimumDistance 才算拖动的 AppKit 视图，这里按下不拖窗口。卡片拖动、缝、侧边栏里的会话都从它派生。
class PressDragView: NSView {
    var minimumDistance: CGFloat = 0
    /// 按下的位置，窗口坐标；没按着为 nil。
    private(set) var pressedAt: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        pressedAt = nil
    }

    /// 这次按下不再算数：之后挪多远都不算挪够，没按着一样。
    func cancelPress() {
        pressedAt = nil
    }

    /// 从按下到 event 挪够了距离。
    func movedEnough(_ event: NSEvent) -> Bool {
        guard let pressedAt else { return false }
        let at = event.locationInWindow
        return hypot(at.x - pressedAt.x, at.y - pressedAt.y) >= minimumDistance
    }

    /// 在窗口内容里的坐标，左上角是原点，和 SwiftUI 的 .global 一致。
    func windowPoint(_ location: NSPoint) -> CGPoint {
        guard let content = window?.contentView else { return location }
        let point = content.convert(location, from: nil)
        return content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
    }
}

/// 按住拖动的区域，鼠标事件由 AppKit 接。用 AppKit 是为了声明这里按下不拖窗口；标题栏那一条另见 disablesWindowDragging。
struct MouseDragArea: NSViewRepresentable {
    var cursor: NSCursor
    /// 拖动中的指针样式，不给就不变。
    var activeCursor: NSCursor?
    /// 挪动多少才算拖动，免得单击也算，见 Metrics.dragThreshold。
    var minimumDistance: CGFloat = 0
    /// 不接鼠标的范围，本区域的坐标、左上角为原点。落在这里的点击交给下面的 SwiftUI 控件，指针样式也不变。
    var excluded: [CGRect] = []
    var onChanged: (LayoutDrag) -> Void
    var onEnded: () -> Void = {}
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        // 拖动时每动一下都会走到这里，指针样式变了才让窗口重设
        if view.cursor !== cursor {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
        view.activeCursor = activeCursor
        view.minimumDistance = minimumDistance
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onClick = onClick
        view.excluded = excluded
    }

    final class DragView: PressDragView {
        var cursor = NSCursor.arrow
        var activeCursor: NSCursor?
        var onChanged: ((LayoutDrag) -> Void)?
        var onEnded: (() -> Void)?
        var onClick: (() -> Void)?
        var excluded: [CGRect] = [] {
            didSet { if excluded != oldValue { window?.invalidateCursorRects(for: self) } }
        }
        private var dragging = false

        // 与 SwiftUI 一致，左上角为原点，excluded 不用换算
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return excluded.contains { $0.contains(local) } ? nil : super.hitTest(point)
        }

        override func resetCursorRects() {
            for rect in Self.subtract(excluded, from: bounds) {
                addCursorRect(rect, cursor: cursor)
            }
        }

        /// rect 去掉 holes 后剩下的部分，拆成互不重叠的矩形。
        private static func subtract(_ holes: [CGRect], from rect: CGRect) -> [CGRect] {
            holes.reduce([rect]) { pieces, hole in
                pieces.flatMap { piece -> [CGRect] in
                    let cut = piece.intersection(hole)
                    guard !cut.isEmpty else { return [piece] }
                    return [
                        CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                        CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                        CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                    ].filter { !$0.isEmpty }
                }
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressedAt else { return }
            if !dragging {
                guard movedEnough(event) else { return }
                dragging = true
                activeCursor?.push()
            }
            let start = windowPoint(pressedAt)
            let location = windowPoint(event.locationInWindow)
            onChanged?(LayoutDrag(location: location, translation: CGSize(width: location.x - start.x, height: location.y - start.y)))
        }

        override func mouseUp(with event: NSEvent) {
            if dragging {
                if activeCursor != nil { NSCursor.pop() }
                onEnded?()
            } else if pressedAt != nil { onClick?() }
            dragging = false
            super.mouseUp(with: event)
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
