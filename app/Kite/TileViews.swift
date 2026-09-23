import SwiftUI

struct TileView: View {
    let tile: Tile

    var body: some View {
        switch tile {
        case .pane(let pane): PaneCard(pane: pane)
        case .split(let split): SplitView(split: split)
        }
    }
}

/// 两块之间留一道缝，拖动它调整比例。
struct SplitView: View {
    let split: Split

    var body: some View {
        GeometryReader { geo in
            let horizontal = split.axis == .horizontal
            let available = max((horizontal ? geo.size.width : geo.size.height) - Metrics.gap, 0)
            let first = (available * split.ratio).rounded()
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                TileView(tile: split.first)
                    .frame(width: horizontal ? first : nil, height: horizontal ? nil : first)
                handle(horizontal: horizontal, available: available)
                TileView(tile: split.second)
            }
            .coordinateSpace(.named(ObjectIdentifier(split)))
        }
    }

    private func handle(horizontal: Bool, available: CGFloat) -> some View {
        Color.clear
            .frame(width: horizontal ? Metrics.gap : nil, height: horizontal ? nil : Metrics.gap)
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            #endif
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(ObjectIdentifier(split)))
                    .onChanged { drag in
                        guard available > 0 else { return }
                        let position = (horizontal ? drag.location.x : drag.location.y) - Metrics.gap / 2
                        let lower = min(Metrics.minPane / available, 0.5)
                        split.ratio = min(max(position / available, lower), 1 - lower)
                    }
            )
    }
}

struct PaneCard: View {
    let pane: Pane

    var body: some View {
        PaneContent(pane: pane)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }
}

/// 窗口里的内容。现在只有占位色块，颜色用来区分是哪个窗口。
struct PaneContent: View {
    let pane: Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(pane.tint).frame(width: 96, height: 14)
            RoundedRectangle(cornerRadius: 8).fill(pane.tint.opacity(0.12))
        }
        .padding(14)
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
