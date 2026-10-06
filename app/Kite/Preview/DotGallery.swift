import SwiftUI

/// 点阵视觉语言的样式样本：形变、终态切换、颜色与整片点阵。只在预览样本中出现，不连接服务。
struct DotGallery: View {
    static let renderer = "sample.dots"
    let title: String

    @State private var shape = 1.0
    @State private var form = DotForm.star
    @State private var base = DotColor.palette[0]
    @State private var alpha = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment

    private var color: DotColor {
        var color = base
        color.alpha = alpha
        return color
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: title)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    shapeSection
                    formSection
                    colorSection
                    matrixSection
                }
                .padding(.horizontal, Metrics.paneMargin + 6)
                .padding(.vertical, Metrics.transcriptPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } controls: { _ in
            Color.clear.frame(height: Metrics.paneToolbarHeight)
        }
    }

    /// 同一个 shape 下的全部终态；0 那端全部收成同一颗点。
    private var shapeSection: some View {
        section("形变", detail: String(format: "shape %.2f", shape)) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], alignment: .leading, spacing: 16) {
                ForEach(DotForm.allCases, id: \.self) { form in
                    VStack(spacing: 8) {
                        DotView(Dot(form, shape: shape, color: color))
                            .frame(width: 40, height: 40)
                        Text(form.title).font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                Slider(value: $shape, in: 0...1)
                Button(shape > 0.5 ? "收回点" : "长成") {
                    withAnimation(DotMetrics.morph) { shape = shape > 0.5 ? 0 : 1 }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// 换终态时两条轮廓逐角插值，不经过点。
    private var formSection: some View {
        section("终态", detail: form.title) {
            DotView(Dot(form, shape: shape, color: color))
                .frame(width: 120, height: 120)
                .frame(maxWidth: .infinity)
            chips(DotForm.allCases, selected: form) { item in
                DotView(Dot(item, shape: 1, color: item == form ? color : .rest(in: environment)))
                    .frame(width: 18, height: 18)
            } action: { form = $0 }
        }
    }

    private var colorSection: some View {
        section("颜色", detail: rgba) {
            chips(DotColor.palette + [.rest(in: environment)], selected: base) { item in
                DotView(Dot(.circle, shape: 1, color: item))
                    .frame(width: 18, height: 18)
            } action: { base = $0 }
            HStack(spacing: 12) {
                Text("alpha").font(Theme.secondary).foregroundStyle(.secondary)
                Slider(value: $alpha, in: 0...1)
            }
        }
    }

    /// 波前经过时格子长成当前终态，颜色随 shape 从点色混到五色之一，离开后退回点阵。
    private var matrixSection: some View {
        section("点阵", detail: nil) {
            GeometryReader { proxy in
                let columns = DotMatrix.columns(fitting: proxy.size.width)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    let phase = reduceMotion ? 0.45 : timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 3.2) / 3.2
                    let rest = DotColor.rest(in: environment)
                    DotMatrix(columns: columns, rows: 9) { column, row in
                        let position = (Double(column) + Double(row) * 0.6) / (Double(columns) + 9 * 0.6)
                        let front = phase * 1.6 - 0.3
                        let distance = abs(position - front) / 0.18
                        let shape = distance < 1 ? 1 - distance * distance * (3 - 2 * distance) : 0
                        return Dot(form, shape: shape, color: rest.mixed(with: .palette(column: column, row: row), by: shape))
                    }
                }
            }
            .frame(height: 9 * DotMetrics.pitch - DotMetrics.gap)
        }
    }

    private var rgba: String {
        String(format: "rgba(%d, %d, %d, %.2f)", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()),
               Int((color.blue * 255).rounded()), color.alpha)
    }

    private func section(_ title: String, detail: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.heading3)
                if let detail {
                    Text(detail).font(Theme.code).foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private func chips<Item: Hashable>(_ items: [Item], selected: Item, @ViewBuilder label: @escaping (Item) -> some View,
                                       action: @escaping (Item) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    withAnimation(DotMetrics.morph) { action(item) }
                } label: {
                    label(item)
                        .frame(width: 36, height: 36)
                        .background(item == selected ? Theme.selection : .clear, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
