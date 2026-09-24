import SwiftUI

extension EnvironmentValues {
    /// 卡片换位置时，用它把同一张卡片的新旧位置连起来做动画。
    @Entry var tileNamespace: Namespace.ID?
}

struct TileView: View {
    let tile: Tile
    @Environment(Workspace.self) private var workspace
    @Environment(\.tileNamespace) private var namespace

    var body: some View {
        switch tile {
        case .pane(let pane):
            PaneCard(pane: pane)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Workspace.space)) } action: {
                    workspace.frames[pane] = $0
                }
                .matched(pane, in: namespace)
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

/// Mac 上的一张卡片。按住标题栏拖到另一张卡片上换位置。
struct PaneCard: View {
    let pane: Pane
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let dragged = workspace.dragging?.pane == pane
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PaneTitle(pane: pane)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.cardHeader)
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(dragged ? .grabActive : .grabIdle)
            #endif
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Workspace.space))
                    .onChanged { workspace.drag(pane, to: $0.location) }
                    .onEnded { _ in workspace.drop() }
            )
            PaneBody(pane: pane)
                .padding([.horizontal, .bottom], 14)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .opacity(dragged ? 0.5 : 1)
    }
}

/// 拖动卡片时，高亮松手后它会占的位置，指针旁边跟着它的标题。
struct DropIndicator: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = workspace.dropRect {
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            if let (pane, location) = workspace.dragging {
                PaneTitle(pane: pane).offset(x: location.x + 12, y: location.y + 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.15), value: workspace.dropRect)
    }
}

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
