import SwiftUI

/// 格子一个挨一个排，放不下就换行，宽度是最宽那一行。alignment 的水平方向定各行靠哪边，竖直方向定同一行里高矮不同的格子怎么对齐：
/// 附件在气泡上面靠右、在输入框上面靠左，同一行里竖着居中；新建页的头像格子顶端对齐，有的多一行说明时头像仍在一条线上。
struct FlowLayout: Layout {
    var spacing: CGFloat
    /// 行与行之间，没给时同 spacing。
    var rowSpacing: CGFloat?
    let alignment: Alignment

    private var lineSpacing: CGFloat { rowSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = alignment.horizontal == .trailing ? bounds.maxX - row.width
                : alignment.horizontal == .center ? bounds.midX - row.width / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let top = alignment.vertical == .center ? (row.height - size.height) / 2 : 0
                subviews[index].place(at: CGPoint(x: x, y: y + top), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
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
