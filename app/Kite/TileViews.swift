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
                    MouseDragArea(cursor: gap.split.axis == .horizontal ? .columnResize : .rowResize) { point in
                        workspace.resize(gap, to: local(point))
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
                    if let (rect, circle) = place(pane, in: layout) {
                        PaneCard(pane: pane, circle: circle) { point in
                            workspace.drag(pane, to: local(point), in: bounds)
                        } onDrop: {
                            workspace.drop(in: bounds)
                        }
                        .placed(rect)
                        .zIndex(workspace.drag?.pane == pane ? 1 : 0)
                    }
                }
            }
        }
        .disablesWindowDragging()
    }

    /// 卡片在哪、是不是缩成了圆。拖出去的卡片不在排布里，按拖动的阶段摆。
    private func place(_ pane: Pane, in layout: TileLayout) -> (CGRect, Bool)? {
        guard let drag = workspace.drag, drag.pane == pane, drag.phase != .attached else {
            return layout.panes[pane].map { ($0, false) }
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

/// Mac 上的一张卡片。按住标题栏拖出去换位置，见 CardDrag；拖出去后缩成圆，内容淡出，出现图标。
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
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        PaneTitle(pane: pane)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Metrics.cardHeader)
                    .overlay {
                        MouseDragArea(cursor: .openHand, activeCursor: .closedHand, minimumDistance: 4, onChanged: onDrag, onEnded: onDrop)
                    }
                    PaneBody(pane: pane)
                        .padding([.horizontal, .bottom], 14)
                }
                .opacity(circle ? 0 : 1)
            }
            .overlay {
                Image(systemName: pane.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .opacity(circle ? 1 : 0)
            }
            .clipShape(shape)
    }
}
#endif

/// 窗口的标题。现在只有占位色块，颜色用来区分是哪个窗口。
struct PaneTitle: View {
    let pane: Pane

    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(pane.tint).frame(width: 96, height: 14)
    }
}

/// 窗口的内容。现在只有占位色块。
struct PaneBody: View {
    let pane: Pane

    var body: some View {
        RoundedRectangle(cornerRadius: 8).fill(pane.tint.opacity(0.12))
    }
}

extension Pane {
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
