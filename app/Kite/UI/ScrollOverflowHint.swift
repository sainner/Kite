import SwiftUI

extension View {
    /// 滚动区还有看不到的内容时提醒：被截掉的那一头渐隐，边的正中有箭头指向它。加在 ScrollView 上，axis 是它滚动的方向。
    /// 遮罩同时把内容截在滚动区里。箭头只是提示，不接点击，点到的仍是下面的内容。
    /// caretsDimmed：箭头跟着压暗（停靠栏展开时其余的模糊淡出，见 DockDimmed）。
    func hintsScrollOverflow(_ axis: Axis = .vertical, carets: ScrollOverflowCarets = .apart, caretsDimmed: Bool = false) -> some View {
        modifier(ScrollOverflowHint(axis: axis, carets: carets, dimmed: caretsDimmed))
    }
}

/// 提醒箭头的放法。
enum ScrollOverflowCarets {
    /// 各在被截掉的那一头，两头都渐隐。
    case apart
    /// 两个箭头并排在末端（右边或底边），开头那条边不渐隐。内容靠开头对齐时用，对齐的那条边保持硬边。
    case atEnd
    /// 只提醒末端，开头保持硬边、不放箭头：开头那头滚出去的内容另有表示，例如紧凑布局底栏左边的堆叠。
    case endOnly
}

private struct ScrollOverflowHint: ViewModifier {
    let axis: Axis
    let carets: ScrollOverflowCarets
    let dimmed: Bool
    @State private var overflow = Overflow()

    /// 前后两头各自还有没有内容被截掉。
    nonisolated private struct Overflow: Equatable {
        var before = false
        var after = false
        var any: Bool { before || after }
    }

    /// 一个箭头沿滚动方向占的长度。
    private static let caretExtent = DotMetrics.module
    /// 箭头与滚动区的边之间留的距离。
    private static let caretInset = DotMetrics.module / 2

    /// 渐隐的长度：边上留的距离、箭头，再加一个模数的过渡，箭头落在靠外的一段里；并排的两个箭头占得多，渐隐也长一些。
    private var length: CGFloat {
        Self.caretInset + Self.caretExtent * (carets == .atEnd ? 2 : 1) + DotMetrics.module
    }

    func body(content: Content) -> some View {
        let vertical = axis == .vertical
        content
            .onScrollGeometryChange(for: Overflow.self) { geometry in
                let visible = geometry.visibleRect, size = geometry.contentSize
                return vertical
                    ? Overflow(before: visible.minY > 0.5, after: visible.maxY < size.height - 0.5)
                    : Overflow(before: visible.minX > 0.5, after: visible.maxX < size.width - 0.5)
            } action: { _, new in
                withAnimation(.easeOut(duration: 0.15)) { overflow = new }
            }
            .mask { fade(vertical: vertical) }
            .overlay(alignment: vertical ? .top : .leading) {
                if carets == .apart {
                    caret(vertical: vertical, before: true).padding(vertical ? .top : .leading, Self.caretInset)
                }
            }
            .overlay(alignment: vertical ? .bottom : .trailing) {
                Group {
                    switch carets {
                    case .apart, .endOnly:
                        caret(vertical: vertical, before: false)
                    case .atEnd:
                        let pair = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                        pair {
                            caret(vertical: vertical, before: true)
                            caret(vertical: vertical, before: false)
                        }
                    }
                }
                .padding(vertical ? .bottom : .trailing, Self.caretInset)
            }
    }

    /// 两头的渐隐与中间不透明的部分是同一条渐变，没有拼接的缝。
    /// 箭头并排时开头保持硬边，末端只要有一头被截掉就渐隐，给箭头留出干净的底。
    private func fade(vertical: Bool) -> some View {
        let before = carets == .apart && overflow.before
        let after = carets == .atEnd ? overflow.any : overflow.after
        return GeometryReader { proxy in
            let extent = vertical ? proxy.size.height : proxy.size.width
            let end = min(0.5, length / max(extent, 1))
            LinearGradient(stops: [
                .init(color: before ? .clear : .black, location: 0),
                .init(color: .black, location: end),
                .init(color: .black, location: 1 - end),
                .init(color: after ? .clear : .black, location: 1),
            ], startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
        }
    }

    private func caret(vertical: Bool, before: Bool) -> some View {
        let symbol = vertical ? (before ? "chevron.up" : "chevron.down") : (before ? "chevron.left" : "chevron.right")
        return Image(systemName: symbol)
            .font(Theme.status.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: vertical ? nil : Self.caretExtent, height: vertical ? Self.caretExtent : nil)
            .opacity(opacity(before: before))
            .modifier(DockDimmed(dimmed: dimmed))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 那一头被截掉时显示；并排时只要有一头被截掉两个都在，另一个变淡。
    private func opacity(before: Bool) -> Double {
        if before ? overflow.before : overflow.after { return 1 }
        return carets == .atEnd && overflow.any ? 0.3 : 0
    }
}
