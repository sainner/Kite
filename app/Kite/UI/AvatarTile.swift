import SwiftUI

/// 一个圆形头像、下面配名字的入口，同停靠栏的格子一个样子、大一圈：新建页里的角色、工具与预览目标。
/// 头像由用的地方给（代理是签名头像，别的是工具图标，见 DockFace）；名字一行，放不下截断，下面可以再跟一行次要的说明。
/// large 用在宽排的起始页上，头像再大一圈。
/// 指针悬停时整块垫一层浅灰、按下加深，同 PaneButtonHover 的反馈；触屏只有按下的反馈，没有要悬停才看得到的东西。
struct AvatarTile<Face: View>: View {
    let title: String
    var detail: String?
    var large = false
    let action: () -> Void
    @ViewBuilder let face: Face

    var body: some View {
        let diameter: CGFloat = (InputMode.current.isTouch ? 56 : 48) + (large ? 8 : 0)
        Button(action: action) {
            VStack(spacing: 6) {
                face.frame(width: diameter, height: diameter)
                VStack(spacing: 1) {
                    Text(title).font(Theme.secondary).foregroundStyle(.primary)
                    if let detail { Text(detail).font(Theme.status).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            // 头像左右各留 12，和组标题（CardLabel）的字对齐
            .frame(width: diameter + 24)
            .padding(.vertical, 10)
        }
        .buttonStyle(AvatarTileStyle())
    }
}

private struct AvatarTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Metrics.dockRadius, style: .continuous)
            configuration.label
                .background(feedback, in: shape)
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .clickPointer()
        }

        private var feedback: Color {
            guard enabled else { return .clear }
            if configuration.isPressed { return Color.gray.opacity(0.20) }
            return Color.gray.opacity(hovered ? 0.10 : 0)
        }
    }
}

/// 一样大的格子一个挨一个排，放不下就换行；每行顶端对齐，centered 时各行居中，否则靠左。宽度是最宽那一行。
/// 同 AttachmentFlow，只是格子的高矮不同（有的多一行说明）时头像仍在一条线上。
struct TileFlow: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = centered ? bounds.midX - row.width / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.indices.last, rows[last].width + spacing + size.width <= width {
                rows[last].indices.append(index)
                rows[last].width += spacing + size.width
                rows[last].height = max(rows[last].height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
