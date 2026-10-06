import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 图案创造台：从图片、GIF 或视频转出点阵图案或帧动画，可调亮度曲线、逐格手画，导出 DotFigure 的 Swift 写法。
/// 只在预览样本中出现，不连接服务。
struct DotStudio: View {
    static let renderer = "sample.dotStudio"
    let title: String

    @State private var model = DotStudioModel()
    @State private var importing = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment

    var body: some View {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        PaneWindow(header: PaneHeader(title: title)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    sourceSection
                    gridSection
                    curveSection
                    colorSection
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 40) {
                            canvasSection
                            previewSection
                        }
                        VStack(alignment: .leading, spacing: 32) {
                            canvasSection
                            previewSection
                        }
                    }
                    framesSection
                }
                .padding(.horizontal, Metrics.paneMargin + 6)
                .padding(.vertical, Metrics.transcriptPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.importFile(url)
                return true
            }
        } controls: { _ in
            Color.clear.frame(height: Metrics.paneToolbarHeight)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie]) { result in
            if case .success(let url) = result { model.importFile(url) }
        }
        .onChange(of: accent, initial: true) { model.accent = accent }
        .task(id: model.video) { await model.extractVideo() }
    }

    // MARK: 素材

    private var sourceSection: some View {
        section("素材", detail: model.sourceName ?? "空白画布") {
            HStack(spacing: 12) {
                Button("导入图片、GIF 或视频…") { importing = true }
                Button("新建空白") { model.newCanvas() }
                if model.loading { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            Text("也可以把文件拖进来。动图和视频至多取 24 帧。").font(Theme.caption).foregroundStyle(.secondary)
            if let failure = model.failure {
                Text(failure).font(Theme.caption).foregroundStyle(Theme.danger)
            }
            if let clip = model.video {
                let longest = min(clip.duration - clip.start, Double(StudioDecoder.maxFrames) / clip.fps)
                slider("开始", value: clipBinding(\.start), in: 0...max(clip.duration - 0.1, 0.01), format: seconds)
                slider("长度", value: clipBinding(\.length), in: 0.1...max(longest, 0.11), format: seconds)
                slider("帧率", value: clipBinding(\.fps), in: 2...24, step: 1) { "\(Int($0)) 帧/秒" }
            }
        }
    }

    private func clipBinding(_ keyPath: WritableKeyPath<VideoClip, Double>) -> Binding<Double> {
        Binding {
            model.video?[keyPath: keyPath] ?? 0
        } set: { value in
            guard var clip = model.video else { return }
            clip[keyPath: keyPath] = value
            clip.length = min(clip.length, clip.duration - clip.start, Double(StudioDecoder.maxFrames) / clip.fps)
            model.video = clip
        }
    }

    // MARK: 格子

    private var gridSection: some View {
        section("格子", detail: "\(model.columns)×\(model.rows)") {
            HStack(spacing: 20) {
                Stepper("列 \(model.columns)", value: $model.columns, in: 1...DotStudioModel.maxSide)
                Stepper("行 \(model.rows)", value: $model.rows, in: 1...DotStudioModel.maxSide)
                    .disabled(model.keepsAspect && model.hasSource)
                Toggle("跟随素材比例", isOn: $model.keepsAspect)
            }
            .fixedSize()
            Picker("背景", selection: $model.background) {
                ForEach(StudioBackground.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if model.background == .auto {
                slider("容差", value: $model.tolerance, in: 0.02...0.4) { String(format: "%.2f", $0) }
                Text("有透明通道时按透明度去除；否则以四角的颜色为背景，相近的都去掉。")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 曲线

    private var curveSection: some View {
        section("曲线", detail: "亮度 → 点大小") {
            HStack(alignment: .top, spacing: 20) {
                CurveEditor(points: $model.curve)
                    .frame(width: 220, height: 140)
                VStack(alignment: .leading, spacing: 8) {
                    Button("全部满格") { model.curve = [1, 1, 1, 1, 1] }
                    Button("暗处大") { model.curve = [1, 0.8, 0.55, 0.3, 0] }
                    Button("亮处大") { model.curve = [0, 0.3, 0.55, 0.8, 1] }
                }
                .buttonStyle(.bordered)
            }
            Text("横轴是格子的亮度，纵轴是点长多大，拖动圆点调整。虚线是分档：最低一条以下留空，往上依次是小、中、满。")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 配色

    private var colorSection: some View {
        section("配色", detail: "\(model.inks.count) 色") {
            HStack(spacing: 16) {
                Picker("配色", selection: $model.colorMode) {
                    ForEach(StudioColorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.colorMode == .image {
                    Stepper("\(model.colorCount) 色", value: $model.colorCount, in: 2...16).fixedSize()
                    Button("重新取色") { model.applyColorMode() }
                        .buttonStyle(.bordered)
                        .disabled(!model.hasSource)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(model.inks) { ink in
                    Button {
                        model.brushInk = ink.id
                        model.tool = .brush
                    } label: {
                        DotView(Dot(.circle, shape: 1, color: model.color(of: ink)))
                            .frame(width: 18, height: 18)
                            .overlay {
                                // 跟随主题色的颜色加一圈
                                if ink.color == nil { Circle().stroke(Color.primary.opacity(0.5), lineWidth: 1).frame(width: 24, height: 24) }
                            }
                            .frame(width: 32, height: 32)
                            .background(ink.id == model.currentInk?.id ? Theme.selection : .clear, in: .circle)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(ink.color == nil ? "跟随主题色" : model.color(of: ink).hex)
                }
            }
            HStack(spacing: 12) {
                if let ink = model.currentInk {
                    ColorPicker("当前颜色", selection: Binding {
                        model.color(of: ink).color
                    } set: {
                        model.setColor(DotColor($0.resolve(in: environment)), of: ink.id)
                    }, supportsOpacity: false)
                    .fixedSize()
                    Button("改用主题色") { model.setColor(nil, of: ink.id) }
                        .disabled(ink.color == nil)
                }
                Group {
                    Button("加一色") { model.addInk(themed: false) }
                    Button("加主题色") { model.addInk(themed: true) }
                }
                .disabled(model.inks.count >= DotStudioModel.maxInks)
                if let ink = model.currentInk {
                    Button("删掉这色", role: .destructive) { model.removeInk(ink.id) }
                        .disabled(model.inks.count <= 1)
                }
            }
            .buttonStyle(.bordered)
            Text("原图取色从素材里取出代表色；主题色是点阵的五种效果色。带圈的颜色跟随主题色，换外观时一起变。")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 画布

    private var canvasSection: some View {
        let frame = model.frames[model.selected]
        return section("画布", detail: "第 \(model.selected + 1) 帧") {
            HStack(spacing: 8) {
                toolButton(.brush, symbol: "paintbrush.pointed", help: "画笔")
                toolButton(.eraser, symbol: "eraser", help: "橡皮")
                toolButton(.picker, symbol: "eyedropper", help: "吸管")
                Divider().frame(height: 20)
                ForEach(StudioDot.sizes.indices, id: \.self) { size in
                    Button {
                        model.brushSize = size
                        model.tool = .brush
                    } label: {
                        DotView(Dot(.square, shape: StudioDot.sizes[size], color: model.currentInk.map(model.color(of:)) ?? .accent))
                            .frame(width: 16, height: 16)
                            .frame(width: 28, height: 28)
                            .background(size == model.brushSize ? Theme.selection : .clear, in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(StudioDot.sizeTitles[size])
                }
            }
            HStack(spacing: 8) {
                Toggle("洋葱皮", isOn: $model.onionSkin).toggleStyle(.button)
                Button("撤销") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("还原本帧") { model.resetEdits() }
                    .disabled(frame.edits.isEmpty)
                Button("清空本帧") { model.clearFrame() }
            }
            .buttonStyle(.bordered)
            StudioCanvas(model: model, rest: DotColor.rest(in: environment))
            Text("洋葱皮淡淡显示上一帧，方便画动画。转换参数改了，手画的格子仍盖在上面。")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func toolButton(_ tool: StudioTool, symbol: String, help: String) -> some View {
        Button { model.tool = tool } label: {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .background(model.tool == tool ? Theme.selection : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 预览

    private var previewSection: some View {
        let encoding = model.encoding()
        let detail = encoding.map { "\($0.columns)×\($0.rows) · \($0.frames.count) 帧 · \(Set($0.letters.map(\.ink.id)).count) 色" }
        return section("预览", detail: detail) {
            if let encoding {
                let figure = model.figure(encoding)
                let placed = PlacedFigure(figure, in: CGRect(x: 0, y: 0, width: CGFloat(figure.columns) * DotMetrics.pitch,
                                                             height: CGFloat(figure.rows) * DotMetrics.pitch))
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || encoding.frames.count < 2)) { timeline in
                    let rest = DotColor.rest(in: environment)
                    DotMatrix(columns: figure.columns, rows: figure.rows) { column, row in
                        guard let cell = placed.sample(column: column, row: row, at: timeline.date,
                                                       amplitude: reduceMotion ? 0 : 1) else { return Dot(color: rest) }
                        return Dot(.square, shape: cell.shape, color: cell.color)
                    }
                }
                Button(copied ? "已复制" : "复制 Swift 代码") { copy(model.code(encoding)) }
                    .buttonStyle(.borderedProminent)
                DisclosureGroup("代码") {
                    Text(model.code(encoding))
                        .font(Theme.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("还没有内容：导入素材，或者在画布上画几格。").font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ code: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    // MARK: 帧

    private var framesSection: some View {
        section("帧", detail: "\(model.frames.count) 帧") {
            let colors = model.inkColors
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.frames.indices, id: \.self) { index in
                        thumbnail(index, colors: colors)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("加空白帧") { model.addFrame() }
                Button("复制本帧") { model.duplicateFrame() }
                Button("删除本帧", role: .destructive) { model.deleteFrame() }
                    .disabled(model.frames.count <= 1)
                Button { model.moveFrame(by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.selected == 0)
                    .help("前移")
                Button { model.moveFrame(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.selected == model.frames.count - 1)
                    .help("后移")
            }
            .buttonStyle(.bordered)
            slider("本帧时长", value: Binding {
                model.frames[model.selected].duration
            } set: {
                model.frames[model.selected].duration = $0
            }, in: 0.04...2, format: seconds)
            slider("速度", value: $model.speed, in: 0.25...4) { String(format: "%.2f×", $0) }
            slider("过渡", value: $model.transition, in: 0...1, format: seconds)
            slider("错开", value: $model.stagger, in: 0...1, format: seconds)
            Text("帧时长含过渡：每帧先停一会儿，再用过渡时间逐格变到下一帧。错开让过渡从左上到右下依次出发，不超过过渡时长。")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func thumbnail(_ index: Int, colors: [UUID: DotColor]) -> some View {
        let grid = model.grid(index)
        let columns = model.columns, rows = model.rows
        let pitch = max(2, min(6, 72 / CGFloat(max(columns, rows))))
        return Button { model.selected = index } label: {
            VStack(spacing: 4) {
                Canvas { context, _ in
                    for row in 0..<rows {
                        for column in 0..<columns {
                            guard let dot = grid[row * columns + column], let color = colors[dot.ink] else { continue }
                            let side = pitch * 0.85 * StudioDot.sizes[dot.size].squareRoot()
                            let rect = CGRect(x: CGFloat(column) * pitch + (pitch - side) / 2, y: CGFloat(row) * pitch + (pitch - side) / 2,
                                              width: side, height: side)
                            context.fill(Path(rect), with: .color(color.color))
                        }
                    }
                }
                .frame(width: CGFloat(columns) * pitch, height: CGFloat(rows) * pitch)
                .padding(6)
                .background(index == model.selected ? Theme.selection : Theme.codeBackground, in: .rect(cornerRadius: 6))
                Text("\(index + 1) · \(seconds(model.frames[index].duration))").font(Theme.status).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 通用

    private func seconds(_ value: Double) -> String { String(format: "%.2fs", value) }

    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
                        format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.secondary).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(format(value.wrappedValue)).font(Theme.code).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
        }
        .frame(maxWidth: 480)
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
}

/// 逐格手画的画布：按下拖动连续涂抹，两次取样之间按直线补齐。
private struct StudioCanvas: View {
    let model: DotStudioModel
    let rest: DotColor
    @State private var last: StudioPoint?
    @State private var picking = false

    /// 格子少时放大，便于点中。
    private var pitch: CGFloat { model.columns <= 16 ? 24 : model.columns <= 32 ? 16 : 12 }

    var body: some View {
        let pitch = pitch
        let columns = model.columns, rows = model.rows
        let grid = model.grid(model.selected)
        let ghost = model.onionSkin && model.frames.count > 1
            ? model.grid((model.selected + model.frames.count - 1) % model.frames.count) : []
        let colors = model.inkColors
        let cell = pitch * DotMetrics.cell / DotMetrics.pitch
        Canvas { context, _ in
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    let rect = CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: cell, height: cell)
                    let dot: Dot
                    if let painted = grid[index], let color = colors[painted.ink] {
                        dot = Dot(.square, shape: StudioDot.sizes[painted.size], color: color)
                    } else if ghost.indices.contains(index), let faint = ghost[index], var color = colors[faint.ink] {
                        color.alpha = 0.25
                        dot = Dot(.square, shape: StudioDot.sizes[faint.size], color: color)
                    } else {
                        dot = Dot(color: rest)
                    }
                    context.fill(dot.path(in: rect), with: .color(dot.color.color))
                }
            }
        }
        .frame(width: CGFloat(columns) * pitch - (pitch - cell), height: CGFloat(rows) * pitch - (pitch - cell))
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard !picking else { return }
            let point = StudioPoint(column: Int((value.location.x / pitch).rounded(.down)),
                                    row: Int((value.location.y / pitch).rounded(.down)))
            guard (0..<columns).contains(point.column), (0..<rows).contains(point.row) else { return }
            if model.tool == .picker {
                model.pick(point)
                picking = true
                return
            }
            if let last {
                for step in Self.line(from: last, to: point).dropFirst() { model.paint(step) }
            } else {
                model.beginStroke()
                model.paint(point)
            }
            last = point
        }.onEnded { _ in
            last = nil
            picking = false
        })
    }

    /// 两格之间的直线（Bresenham），含两端。
    static func line(from start: StudioPoint, to end: StudioPoint) -> [StudioPoint] {
        var points: [StudioPoint] = []
        var x = start.column, y = start.row
        let dx = abs(end.column - x), dy = -abs(end.row - y)
        let sx = x < end.column ? 1 : -1, sy = y < end.row ? 1 : -1
        var error = dx + dy
        while true {
            points.append(StudioPoint(column: x, row: y))
            if x == end.column && y == end.row { break }
            let doubled = 2 * error
            if doubled >= dy { error += dy; x += sx }
            if doubled <= dx { error += dx; y += sy }
        }
        return points
    }
}

/// 亮度曲线：均匀分布的控制点只能上下拖，拖动时取离按下位置最近的那个。
private struct CurveEditor: View {
    @Binding var points: [Double]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, size in
                    for level in [0.15, 0.45, 0.8] {
                        let y = size.height * (1 - level)
                        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                       with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    var path = Path()
                    for step in 0...100 {
                        let x = Double(step) / 100
                        let point = CGPoint(x: x * size.width, y: (1 - StudioConverter.curve(points, at: x)) * size.height)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                }
                .background(Theme.codeBackground, in: .rect(cornerRadius: 6))
                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(Theme.card)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 12, height: 12)
                        .position(x: size.width * Double(index) / Double(points.count - 1), y: size.height * (1 - points[index]))
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let last = points.count - 1
                let index = min(max(Int((value.startLocation.x / size.width * Double(last)).rounded()), 0), last)
                points[index] = min(max(1 - value.location.y / size.height, 0), 1)
            })
        }
    }
}
