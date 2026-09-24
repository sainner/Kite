#if os(macOS)
import AppKit
import SwiftUI

/// 侧边栏里的会话：点一下选中，拖到主窗口外面松手就分离成独立窗口。
/// 用 AppKit 的拖放，拖动的图像能跟着指针出窗口；拖的内容是 Kite 自己的类型，
/// 桌面、访达这些都不认，不会被别处接住（比如纯文本会在桌面上生成剪贴文件）。
struct SessionDragSource: NSViewRepresentable {
    let tint: Color
    var onClick: () -> Void
    /// 松手的位置，屏幕坐标，左下角是原点。
    var onDetach: (NSPoint) -> Void

    static let type = NSPasteboard.PasteboardType("com.sainner.kite.session")

    func makeNSView(context: Context) -> SourceView {
        SourceView()
    }

    func updateNSView(_ view: SourceView, context: Context) {
        view.tint = NSColor(tint)
        view.onClick = onClick
        view.onDetach = onDetach
    }

    final class SourceView: NSView, NSDraggingSource {
        var tint = NSColor.systemBlue
        var onClick: (() -> Void)?
        var onDetach: ((NSPoint) -> Void)?
        private var start: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let location = event.locationInWindow
            guard hypot(location.x - start.x, location.y - start.y) >= 4 else { return }
            self.start = nil
            let item = NSPasteboardItem()
            item.setString("", forType: SessionDragSource.type)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            // 拖的样子是一个小窗口：白底，顶上一条会话的颜色
            let image = NSImage(size: NSSize(width: 120, height: 80), flipped: true) { rect in
                let window = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
                NSColor.white.setFill()
                window.fill()
                NSColor.black.withAlphaComponent(0.15).setStroke()
                window.stroke()
                self.tint.setFill()
                NSBezierPath(roundedRect: NSRect(x: 10, y: 10, width: 48, height: 8), xRadius: 3, yRadius: 3).fill()
                self.tint.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: NSRect(x: 10, y: 26, width: 100, height: 44), xRadius: 4, yRadius: 4).fill()
                return true
            }
            let point = convert(location, from: nil)
            dragging.setDraggingFrame(NSRect(x: point.x - 20, y: point.y - 12, width: 120, height: 80), contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if start != nil { onClick?() }
            start = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .move
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            // 分离出去时图像不用飞回原处
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // 没有被别处接住，并且松在主窗口外面，才分离
            guard operation.isEmpty, let window, !window.frame.contains(screenPoint) else { return }
            onDetach?(screenPoint)
        }
    }
}
#endif
