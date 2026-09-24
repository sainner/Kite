import SwiftUI

#if os(macOS)
/// 内容区：各张卡片、占位、卡片之间的缝按排布算好的位置摆在同一层。卡片始终是同一个视图，
/// 排布变了、拖出去缩成圆、松手展开，都只是它的位置和大小在变，动画连贯，不会出现新旧两份交叠。
/// 拖动报的是窗口坐标，在这里换算成内容区里的坐标再交给窗口组。
struct TilesLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let origin = geo.frame(in: .global).origin
            let local = { (point: CGPoint) in CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
            let layout = workspace.shown?.layout(in: bounds) ?? TileLayout()
            ZStack(alignment: .topLeading) {
                ForEach(layout.gaps) { gap in
                    MouseDragArea(cursor: gap.split.axis == .horizontal ? .columnResize : .rowResize) { drag in
                        workspace.resize(gap, to: local(drag.location))
                    }
                    .placed(gap.rect)
                }
                if let rect = layout.placeholder {
                    // 拖动卡片时预览它放下后的位置
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .fill(Color.accentColor.opacity(0.08))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .placed(rect)
                }
                ForEach(Pane.allCases, id: \.self) { pane in
                    CardSlot(pane: pane, rect: layout.panes[pane]) { point in
                        workspace.drag(pane, to: local(point), in: bounds)
                    } onDrop: {
                        workspace.drop(in: bounds)
                    }
                    .zIndex(workspace.drag?.pane == pane ? 1 : 0)
                }
            }
        }
        .disablesWindowDragging()
    }
}

/// 一张卡片摆在哪。拖出去的那张不在排布里，按拖动的阶段摆：跟着指针时缩成圆，松手后展开到落点。
/// 只有它读指针位置，指针一动只重画这一张，不重算整个排布。
private struct CardSlot: View {
    let pane: Pane
    /// 在排布里的位置，不在排布里为 nil。
    let rect: CGRect?
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let (frame, circle) = place {
            PaneCard(pane: pane, circle: circle, onDrag: onDrag, onDrop: onDrop)
                .placed(frame)
        }
    }

    private var place: (CGRect, Bool)? {
        guard let drag = workspace.drag, drag.pane == pane, drag.phase != .attached else {
            return rect.map { ($0, false) }
        }
        if case .landing(let rect) = drag.phase { return (rect, false) }
        let size = Metrics.dragBubble
        return (CGRect(x: workspace.pointer.x - size / 2, y: workspace.pointer.y - size / 2, width: size, height: size), true)
    }
}

private extension View {
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

/// Mac 上的一张卡片，里面是窗口（PaneWindow）。按住标题栏拖出去换位置，见 CardDrag；拖出去后缩成圆，内容淡出，出现图标。
struct PaneCard: View {
    let pane: Pane
    let circle: Bool
    /// 拖动中的指针位置，窗口坐标。
    var onDrag: (CGPoint) -> Void
    var onDrop: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? Metrics.dragBubble / 2 : Metrics.cardRadius)
        // 底下的形状定大小，内容放在 overlay 里：缩成圆时内容比圆大，不能把它撑开
        shape
            .fill(circle ? pane.tint : Theme.card)
            .overlay(alignment: .topLeading) {
                PaneBody(pane: pane).opacity(circle ? 0 : 1)
            }
            .overlay(alignment: .top) {
                // 拖动的把手：顶上和标题栏一样高的一条，不管标题栏里放了什么
                MouseDragArea(cursor: .openHand, activeCursor: .closedHand, minimumDistance: Metrics.dragThreshold) { drag in
                    onDrag(drag.location)
                } onEnded: {
                    onDrop()
                }
                .frame(height: Metrics.header)
            }
            .overlay {
                Image(systemName: pane.icon)
                    .font(Theme.title)
                    .foregroundStyle(.white)
                    .opacity(circle ? 1 : 0)
            }
            .clipShape(shape)
    }
}
#endif

extension Pane {
    var name: String {
        switch self {
        case .session: "对话"
        case .files: "文件"
        case .terminal: "终端"
        case .preview: "预览"
        }
    }

    var icon: String {
        switch self {
        case .session: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .terminal: "terminal"
        case .preview: "eye"
        }
    }

    var tint: Color {
        switch self {
        case .session: .blue
        case .files: .green
        case .terminal: .gray
        case .preview: .orange
        }
    }
}
