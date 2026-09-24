import SwiftUI

#if os(macOS)
extension EnvironmentValues {
    /// 卡片换位置时，用它把同一张卡片的新旧位置连起来做动画。
    @Entry var tileNamespace: Namespace.ID?
}

struct TileView: View {
    let tile: Tile
    @Environment(\.tileNamespace) private var namespace

    var body: some View {
        switch tile {
        case .pane(let pane):
            PaneCard(pane: pane).matched(pane, in: namespace)
        case .placeholder:
            // 拖动卡片时预览它放下后的位置
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(Color.accentColor.opacity(0.08))
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        case .split(let split):
            SplitView(split: split)
        }
    }
}

private extension View {
    @ViewBuilder
    func matched(_ pane: Pane, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedGeometryEffect(id: pane, in: namespace) } else { self }
    }
}

/// 两块之间留一道缝，拖动它调整比例。
struct SplitView: View {
    let split: Split

    var body: some View {
        GeometryReader { geo in
            let horizontal = split.axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let first = split.firstLength(in: total)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                TileView(tile: split.first)
                    .frame(width: horizontal ? first : nil, height: horizontal ? nil : first)
                handle(horizontal: horizontal, origin: geo.frame(in: .global).origin, available: max(total - Metrics.gap, 0))
                TileView(tile: split.second)
            }
        }
    }

    private func handle(horizontal: Bool, origin: CGPoint, available: CGFloat) -> some View {
        MouseDragArea(cursor: horizontal ? .columnResize : .rowResize) { point in
            guard available > 0 else { return }
            let position = (horizontal ? point.x - origin.x : point.y - origin.y) - Metrics.gap / 2
            let lower = min(Metrics.minPane / available, 0.5)
            split.ratio = min(max(position / available, lower), 1 - lower)
        }
        .frame(width: horizontal ? Metrics.gap : nil, height: horizontal ? nil : Metrics.gap)
    }
}

/// Mac 上的一张卡片。按住标题栏拖出去换位置，见 CardDrag。
struct PaneCard: View {
    let pane: Pane
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PaneTitle(pane: pane)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.cardHeader)
            .overlay {
                MouseDragArea(cursor: .openHand, activeCursor: .closedHand, minimumDistance: 4) { point in
                    workspace.drag(pane, to: point)
                } onEnded: {
                    workspace.drop()
                }
            }
            PaneBody(pane: pane)
                .padding([.horizontal, .bottom], 14)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }
}

/// 脱离布局的卡片，变成一个圆跟着指针。
struct DragBubble: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.tileNamespace) private var namespace

    var body: some View {
        ZStack {
            if let drag = workspace.drag, drag.detached {
                Circle()
                    .fill(drag.pane.tint)
                    .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                    .matched(drag.pane, in: namespace)
                    .position(workspace.pointer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
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
    var tint: Color {
        switch self {
        case .session: .blue
        case .files: .green
        case .terminal: .gray
        case .preview: .orange
        }
    }
}
