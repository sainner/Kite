import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Markdown 表格排成和代码块一样的卡片：标题栏右边导出为图片或复制为 Markdown，表格太宽时横着滚。
/// 行与行之间有分割线，顶到卡片两侧；表格比卡片窄时最后一列补足宽度。
/// 导出的图片是不透明的整张表格，按当前外观、字号和屏幕倍率渲染。
struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    @Environment(\.toast) private var toast
    @Environment(\.font) private var font
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        BlockCard(label: "表格", copyLabel: "复制表格") {
            copyToPasteboard(markdown, toast: toast)
        } actions: { press in
            #if os(macOS)
            BlockCardButton("ImageExport", label: "导出为图片", press: press, action: exportImage)
            #else
            ShareLink(item: snapshot, preview: SharePreview("表格")) {
                BlockCardIcon("ImageExport")
            }
            .help("导出为图片")
            .accessibilityLabel("导出为图片")
            .modifier(BlockCardPressable(press: press))
            #endif
        } content: {
            ScrollView(.horizontal, showsIndicators: false) {
                MarkdownTableGrid(header: header, rows: rows, edgeInset: 10, minWidth: viewportWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        }
    }

    /// 单元格里的行内样式还原成 Markdown；竖线一律转义，换行并成空格，保证仍是一行一格。
    private var markdown: String {
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        var lines = [line(header.map(Self.markdown)), line(header.map { _ in "---" })]
        lines += rows.map { line($0.map(Self.markdown)) }
        return lines.joined(separator: "\n")
    }

    private static func markdown(_ text: AttributedString) -> String {
        var result = ""
        for run in text.runs {
            var part = String(text[run.range].characters).replacingOccurrences(of: "|", with: "\\|")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                part = "`\(part)`"
            } else {
                if intent.contains(.stronglyEmphasized) { part = "**\(part)**" }
                if intent.contains(.emphasized) { part = "*\(part)*" }
                if intent.contains(.strikethrough) { part = "~~\(part)~~" }
            }
            if let link = run.link { part = "[\(part)](\(link.absoluteString))" }
            result += part
        }
        return result.replacingOccurrences(of: "\n", with: " ")
    }

    private var snapshot: MarkdownTableImage {
        MarkdownTableImage(header: header, rows: rows, font: font ?? Theme.body, colorScheme: colorScheme, scale: displayScale)
    }

    #if os(macOS)
    private func exportImage() {
        guard let data = snapshot.png() else {
            toast?.show("导出失败", systemImage: "exclamationmark.triangle")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "表格.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            toast?.show("导出失败", systemImage: "exclamationmark.triangle")
        }
    }
    #endif
}

/// 表格本体，卡片和导出的图片共用。分割线占整个表格宽度，两侧留白放在首尾两列的格子里，线才能顶到边。
private struct MarkdownTableGrid: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let edgeInset: CGFloat
    var minWidth: CGFloat = 0

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    cell(header[column], column: column, count: header.count).fontWeight(.semibold)
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        cell(rows[row][column], column: column, count: rows[row].count)
                    }
                }
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
    }

    private func cell(_ text: AttributedString, column: Int, count: Int) -> some View {
        let last = column == count - 1
        return ReferenceLabel(text)
            .padding(.vertical, 8)
            .padding(.leading, column == 0 ? edgeInset : 0)
            .padding(.trailing, last ? edgeInset : 0)
            .frame(maxWidth: last ? .infinity : nil, alignment: .leading)
    }
}

/// 导出用的表格图片；分享时才渲染。
struct MarkdownTableImage: Transferable {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let font: Font
    let colorScheme: ColorScheme
    let scale: CGFloat

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { image in
            guard let data = await image.png() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
        .suggestedFileName("表格.png")
    }

    @MainActor
    func png() -> Data? {
        let content = MarkdownTableGrid(header: header, rows: rows, edgeInset: 20)
            .font(font)
            .foregroundStyle(.primary)
            .padding(.vertical, 12)
            .background(Theme.codeBackground)
            .background(Theme.card)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
