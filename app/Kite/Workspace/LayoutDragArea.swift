import SwiftUI

/// 排布手势共用窗口坐标；只有 Mac 需要 AppKit 阻止拖动整个系统窗口。
struct LayoutDragArea: View {
    enum Cursor { case columnResize, rowResize, pointingHand, openHand, closedHand }
    var cursor: Cursor
    var activeCursor: Cursor?
    var minimumDistance: CGFloat = 0
    var excluded: [CGRect] = []
    var onChanged: (LayoutDrag) -> Void
    var onEnded: () -> Void = {}
    var onCancelled: () -> Void = {}
    var onClick: (() -> Void)?
    @GestureState private var pressed = false
    @State private var dragging = false

    var body: some View {
        #if os(macOS)
        MouseDragArea(cursor: cursor.native, activeCursor: activeCursor?.native,
                      minimumDistance: minimumDistance, excluded: excluded,
                      onChanged: onChanged, onEnded: onEnded, onClick: onClick)
        // SwiftUI 的命中也在可点控件上挖空，与 AppKit 视图的 hitTest 一致。
        .contentShape(DragShape(holes: excluded), eoFill: true)
        #else
        Color.clear
            .contentShape(DragShape(holes: excluded), eoFill: true)
            .gesture(DragGesture(minimumDistance: max(minimumDistance, Metrics.dragThreshold), coordinateSpace: .global)
                .updating($pressed) { _, value, _ in value = true }
                .onChanged { value in
                    dragging = true
                    onChanged(LayoutDrag(location: value.location, translation: value.translation))
                }
                .onEnded { _ in
                    dragging = false
                    onEnded()
                })
            .onTapGesture { onClick?() }
            .onChange(of: pressed) { _, value in
                if !value && dragging {
                    dragging = false
                    onCancelled()
                }
            }
            .onDisappear {
                if dragging { onCancelled() }
            }
        #endif
    }
}

/// 拖动的指针位置和从按下起挪了多少，窗口坐标。
struct LayoutDrag {
    let location: CGPoint
    let translation: CGSize
}

nonisolated private struct DragShape: Shape {
    let holes: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        holes.forEach { path.addRect($0) }
        return path
    }
}

#if os(macOS)
import AppKit
private extension LayoutDragArea.Cursor {
    var native: NSCursor {
        switch self {
        case .columnResize: .columnResize
        case .rowResize: .rowResize
        case .pointingHand: .pointingHand
        case .openHand: .openHand
        case .closedHand: .closedHand
        }
    }
}
#else
extension View {
    func disablesWindowDragging() -> some View { self }
}
#endif
