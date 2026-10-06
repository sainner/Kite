import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 图案创造台里的一种颜色；color 为 nil 时跟随主题色。custom 是手动加的，换配色方式时保留。
nonisolated struct StudioInk: Identifiable, Hashable, Sendable {
    var id = UUID()
    var color: DotColor?
    var custom = false
}

/// 一格用哪种颜色、长多大；size 是 sizes 的下标。
nonisolated struct StudioDot: Hashable, Sendable {
    static let sizes: [Double] = [1, 0.6, 0.3]
    static let sizeTitles = ["满", "中", "小"]
    var ink: UUID
    var size: Int
}

nonisolated struct StudioPoint: Hashable, Sendable {
    var column: Int
    var row: Int
}

/// 一帧：source 是取自素材的第几张，nil 是空白画布；edits 是手画的覆盖，值为 nil 表示这一格擦掉。
nonisolated struct StudioFrame: Identifiable, Hashable, Sendable {
    var id = UUID()
    var source: Int?
    /// 这一帧从出现到下一帧出现的时长，含过渡。
    var duration: TimeInterval
    var edits: [StudioPoint: StudioDot?] = [:]
}

nonisolated enum StudioBackground: String, CaseIterable, Identifiable, Sendable {
    case auto, keep
    var id: Self { self }
    var title: String { self == .auto ? "去除背景" : "保留背景" }
}

nonisolated enum StudioColorMode: String, CaseIterable, Identifiable, Sendable {
    case image, theme
    var id: Self { self }
    var title: String { self == .image ? "原图取色" : "主题色" }
}

nonisolated enum StudioTool: Sendable { case brush, eraser, picker }

/// 视频素材截取的一段。
nonisolated struct VideoClip: Hashable, Sendable {
    var url: URL
    var name: String
    var duration: TimeInterval
    var start: TimeInterval = 0
    var length: TimeInterval
    var fps: Double = 8
}

/// 图案创造台的状态：素材按格子取样，再经亮度曲线和配色转成每帧的点阵，手画的格子盖在上面。
@MainActor @Observable
final class DotStudioModel {
    static let maxSide = 64
    static let maxInks = 24
    nonisolated static let defaultDuration: TimeInterval = 0.4

    private(set) var sourceName: String?
    private var images: [CGImage] = []
    private var sourceVersion = 0
    var hasSource: Bool { !images.isEmpty }
    var video: VideoClip?
    private(set) var loading = false
    private(set) var failure: String?

    var columns = 23 { didSet { fitRows(); resample() } }
    var rows = 23 { didSet { resample() } }
    var keepsAspect = true { didSet { fitRows() } }
    var background = StudioBackground.auto { didSet { resample() } }
    var tolerance = 0.12 { didSet { resample() } }
    /// 亮度 0、0.25 … 1 处的点大小，中间平滑插值。
    var curve = [1.0, 1, 1, 1, 1] { didSet { remap() } }

    var colorMode = StudioColorMode.image { didSet { applyColorMode() } }
    var colorCount = 8 { didSet { if colorMode == .image { applyColorMode() } } }
    private(set) var inks = DotStudioModel.themeInks() { didSet { remap() } }
    /// 解析后的主题色，由界面按当前外观传进来。
    var accent = DotColor.accent { didSet { if accent != oldValue { remap() } } }

    var frames = [StudioFrame(duration: defaultDuration)]
    var selected = 0
    var speed = 1.0
    var transition = 0.2
    var stagger = 0.0

    var tool = StudioTool.brush
    var brushInk: UUID?
    var brushSize = 0
    var onionSkin = true

    private var samples: [[StudioConverter.Sample?]] = []
    private var sampledKey: [Int]?
    private var converted: [[StudioDot?]] = []
    private var history: [[StudioFrame]] = []
    var canUndo: Bool { !history.isEmpty }

    static func themeInks() -> [StudioInk] {
        [StudioInk(color: nil)] + [DotColor.morningBreeze, .dewyBlue, .sunwashed, .sunwashedDeep].map { StudioInk(color: $0) }
    }

    func color(of ink: StudioInk) -> DotColor { ink.color ?? accent }
    var inkColors: [UUID: DotColor] { Dictionary(uniqueKeysWithValues: inks.map { ($0.id, color(of: $0)) }) }
    var currentInk: StudioInk? { inks.first { $0.id == brushInk } ?? inks.first }

    // MARK: 素材

    /// 先把文件复制到临时目录：沙盒里拿到的地址离开这次访问就读不了，视频还要反复抽帧。
    func importFile(_ url: URL) {
        failure = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "dot-studio-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            failure = "读不了这个文件：\(error.localizedDescription)"
            return
        }
        let name = url.lastPathComponent
        loading = true
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true {
            Task {
                do {
                    let duration = try await StudioDecoder.duration(of: copy)
                    video = VideoClip(url: copy, name: name, duration: duration,
                                      length: min(duration, Double(StudioDecoder.maxFrames) / 8))
                } catch {
                    failure = "打不开这个视频：\(error.localizedDescription)"
                    loading = false
                }
            }
        } else {
            Task {
                let decoded = await StudioDecoder.images(at: copy)
                loading = false
                guard let decoded else {
                    failure = "认不出这个图片。"
                    return
                }
                video = nil
                adopt(decoded, name: name)
            }
        }
    }

    /// 视频的截取范围变了就重新抽帧；连续拖动时只取停下来的那次。
    func extractVideo() async {
        guard let clip = video else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        loading = true
        do {
            let decoded = try await StudioDecoder.frames(of: clip)
            guard !Task.isCancelled else { return }
            loading = false
            adopt(decoded, name: clip.name)
        } catch is CancellationError {
        } catch {
            loading = false
            failure = "抽不出视频帧：\(error.localizedDescription)"
        }
    }

    func newCanvas() {
        video = nil
        failure = nil
        images = []
        sourceName = nil
        sourceVersion += 1
        frames = [StudioFrame(duration: Self.defaultDuration)]
        selected = 0
        history = []
        resample()
    }

    private func adopt(_ decoded: StudioImages, name: String) {
        images = decoded.images
        sourceName = name
        sourceVersion += 1
        frames = decoded.durations.indices.map { StudioFrame(source: $0, duration: decoded.durations[$0]) }
        selected = 0
        history = []
        // 动图的帧往往很短，过渡长过帧时长会把整段拖慢
        if decoded.images.count > 1, let shortest = decoded.durations.min() { transition = min(transition, shortest / 2) }
        fitRows()
        resample()
        if colorMode == .image { applyColorMode() }
    }

    private func fitRows() {
        guard keepsAspect, let image = images.first, image.width > 0 else { return }
        let fitted = min(max(Int((Double(columns) * Double(image.height) / Double(image.width)).rounded()), 1), Self.maxSide)
        if fitted != rows { rows = fitted }
    }

    // MARK: 转换

    private func resample() {
        let key = [sourceVersion, columns, rows, background == .auto ? 1 : 0, Int(tolerance * 10_000)]
        guard key != sampledKey else { return }
        sampledKey = key
        samples = images.map {
            StudioConverter.sample($0, columns: columns, rows: rows, background: background, tolerance: tolerance)
        }
        remap()
    }

    private func remap() {
        let palette = inks.map { (id: $0.id, color: color(of: $0).oklab) }
        converted = samples.map { StudioConverter.dots($0, curve: curve, inks: palette) }
    }

    /// 第 index 帧最终的样子：素材转出来的格子，盖上手画的；颜色被删掉的手画格子退回素材的样子。
    func grid(_ index: Int) -> [StudioDot?] {
        guard frames.indices.contains(index) else { return [] }
        let frame = frames[index]
        var cells: [StudioDot?]
        if let source = frame.source, converted.indices.contains(source), converted[source].count == columns * rows {
            cells = converted[source]
        } else {
            cells = Array(repeating: nil, count: columns * rows)
        }
        let live = Set(inks.map(\.id))
        for (point, dot) in frame.edits where point.column < columns && point.row < rows {
            if let dot, !live.contains(dot.ink) { continue }
            cells[point.row * columns + point.column] = dot
        }
        return cells
    }

    // MARK: 配色

    func applyColorMode() {
        let generated: [StudioInk] = switch colorMode {
        case .theme: Self.themeInks()
        case .image: StudioConverter.palette(from: samples, count: colorCount).map { StudioInk(color: $0) }
        }
        guard !generated.isEmpty else { return }
        // 手画的格子换到颜色最近的新颜色上
        var mapping: [UUID: UUID] = [:]
        for old in inks where !old.custom {
            let lab = color(of: old).oklab
            mapping[old.id] = generated.min {
                StudioConverter.distance(color(of: $0).oklab, lab) < StudioConverter.distance(color(of: $1).oklab, lab)
            }?.id
        }
        func moved(_ frames: [StudioFrame]) -> [StudioFrame] {
            frames.map { frame in
                var frame = frame
                frame.edits = frame.edits.mapValues { dot in dot.map { StudioDot(ink: mapping[$0.ink] ?? $0.ink, size: $0.size) } }
                return frame
            }
        }
        frames = moved(frames)
        history = history.map(moved)
        if let brush = brushInk { brushInk = mapping[brush] ?? brush }
        inks = generated + inks.filter(\.custom)
    }

    func addInk(themed: Bool) {
        guard inks.count < Self.maxInks else { return }
        let ink = StudioInk(color: themed ? nil : currentInk.map(color(of:)) ?? .morningBreeze, custom: true)
        inks.append(ink)
        brushInk = ink.id
        tool = .brush
    }

    func removeInk(_ id: UUID) {
        guard inks.count > 1 else { return }
        inks.removeAll { $0.id == id }
        if brushInk == id { brushInk = inks.first?.id }
    }

    /// nil 改为跟随主题色。
    func setColor(_ color: DotColor?, of id: UUID) {
        guard let index = inks.firstIndex(where: { $0.id == id }) else { return }
        inks[index].color = color.map {
            DotColor(red: min(max($0.red, 0), 1), green: min(max($0.green, 0), 1), blue: min(max($0.blue, 0), 1))
        }
    }

    // MARK: 手画

    func beginStroke() { pushHistory() }

    func paint(_ point: StudioPoint) {
        guard frames.indices.contains(selected), (0..<columns).contains(point.column), (0..<rows).contains(point.row) else { return }
        switch tool {
        case .brush:
            guard let ink = currentInk?.id else { return }
            frames[selected].edits[point] = StudioDot(ink: ink, size: brushSize)
        case .eraser:
            frames[selected].edits.updateValue(nil, forKey: point)
        case .picker:
            break
        }
    }

    /// 吸取一格的颜色和大小，换回画笔。
    func pick(_ point: StudioPoint) {
        guard (0..<columns).contains(point.column), (0..<rows).contains(point.row) else { return }
        if let dot = grid(selected)[point.row * columns + point.column] {
            brushInk = dot.ink
            brushSize = dot.size
        }
        tool = .brush
    }

    func undo() {
        guard let last = history.popLast() else { return }
        frames = last
        selected = min(selected, frames.count - 1)
    }

    private func pushHistory() {
        history.append(frames)
        if history.count > 60 { history.removeFirst() }
    }

    // MARK: 帧

    func addFrame() {
        pushHistory()
        frames.insert(StudioFrame(duration: frames[selected].duration), at: selected + 1)
        selected += 1
    }

    func duplicateFrame() {
        pushHistory()
        var copy = frames[selected]
        copy.id = UUID()
        frames.insert(copy, at: selected + 1)
        selected += 1
    }

    func deleteFrame() {
        guard frames.count > 1 else { return }
        pushHistory()
        frames.remove(at: selected)
        selected = min(selected, frames.count - 1)
    }

    func moveFrame(by offset: Int) {
        let target = selected + offset
        guard frames.indices.contains(target) else { return }
        pushHistory()
        frames.swapAt(selected, target)
        selected = target
    }

    /// 去掉本帧手画的部分。
    func resetEdits() {
        pushHistory()
        frames[selected].edits = [:]
    }

    /// 本帧变成空白画布。
    func clearFrame() {
        pushHistory()
        frames[selected].source = nil
        frames[selected].edits = [:]
    }

    // MARK: 导出

    struct Encoding {
        var frames: [[String]]
        var holds: [TimeInterval]
        var letters: [(character: Character, ink: StudioInk, size: Double)]
        var columns: Int { frames.first?.first?.count ?? 0 }
        var rows: Int { frames.first?.count ?? 0 }
    }

    /// 主题五色在 DotFigure.letters 里的写法，满格时沿用。
    private static let standard: [(Character, DotColor?, String)] = [
        ("B", nil, "accent"), ("M", .morningBreeze, ".morningBreeze"), ("L", .dewyBlue, ".dewyBlue"),
        ("Y", .sunwashed, ".sunwashed"), ("D", .sunwashedDeep, ".sunwashedDeep"),
    ]
    private static let characterPool = Array("ACEFGHIJKNOPQRSTUVWXZabcdefghijklmnopqrstuvwxyz0123456789#$%&*+=@?!~^<>/|:;")

    /// 把各帧写成字符画：相邻相同的帧并成一帧，所有帧裁到共同的内容范围。全空时为 nil。
    func encoding() -> Encoding? {
        var grids: [[StudioDot?]] = []
        var durations: [TimeInterval] = []
        for index in frames.indices {
            let grid = grid(index)
            if grid == grids.last {
                durations[durations.count - 1] += frames[index].duration
            } else {
                grids.append(grid)
                durations.append(frames[index].duration)
            }
        }
        var bounds = (minX: columns, minY: rows, maxX: -1, maxY: -1)
        for grid in grids {
            for row in 0..<rows {
                for column in 0..<columns where grid[row * columns + column] != nil {
                    bounds = (min(bounds.minX, column), min(bounds.minY, row), max(bounds.maxX, column), max(bounds.maxY, row))
                }
            }
        }
        guard bounds.maxX >= 0 else { return nil }

        let byID = Dictionary(uniqueKeysWithValues: inks.map { ($0.id, $0) })
        var characters: [StudioDot: Character] = [:]
        var letters: [(character: Character, ink: StudioInk, size: Double)] = []
        var pool = Self.characterPool.makeIterator()
        func character(for dot: StudioDot) -> Character {
            if let character = characters[dot] { return character }
            let ink = byID[dot.ink]!
            let used = Set(letters.map(\.character))
            let preferred = dot.size == 0 ? Self.standard.first { $0.1 == ink.color }?.0 : nil
            let character = preferred.flatMap { used.contains($0) ? nil : $0 } ?? pool.next() ?? "?"
            characters[dot] = character
            letters.append((character, ink, StudioDot.sizes[dot.size]))
            return character
        }
        let encoded = grids.map { grid in
            (bounds.minY...bounds.maxY).map { row in
                String((bounds.minX...bounds.maxX).map { column in
                    grid[row * columns + column].map(character(for:)) ?? "."
                })
            }
        }
        return Encoding(frames: encoded, holds: durations.map { max($0 / speed - transition, 0.02) }, letters: letters)
    }

    func figure(_ encoding: Encoding) -> DotFigure {
        let colors = Dictionary(uniqueKeysWithValues: encoding.letters.map { ($0.character, color(of: $0.ink)) })
        let shapes = Dictionary(uniqueKeysWithValues: encoding.letters.map { ($0.character, $0.size) })
        guard encoding.frames.count > 1 else { return DotFigure(encoding.frames[0], colors: colors, shapes: shapes) }
        return DotFigure(frames: encoding.frames, colors: colors, shapes: shapes, holds: encoding.holds,
                         transition: transition, stagger: stagger)
    }

    /// 能直接贴进项目的 DotFigure 写法。
    func code(_ encoding: Encoding) -> String {
        func number(_ value: Double) -> String {
            var text = String(format: "%.2f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
        func literal(_ ink: StudioInk) -> String {
            if let name = Self.standard.first(where: { $0.1 == ink.color })?.2 { return name }
            return "DotColor(hex: 0x\(color(of: ink).hex.dropFirst()))"
        }
        func lines(_ frame: [String], indent: String) -> String {
            frame.map { "\(indent)\"\($0)\"," }.joined(separator: "\n")
        }
        let usesAccent = encoding.letters.contains { $0.ink.color == nil }
        let standardOnly = encoding.letters.allSatisfy { letter in
            letter.size == 1 && Self.standard.contains { $0.0 == letter.character && $0.1 == letter.ink.color }
        }
        let colors = standardOnly && usesAccent ? "DotFigure.letters(accent: accent)"
            : "[" + encoding.letters.map { "\"\($0.character)\": \(literal($0.ink))" }.joined(separator: ", ") + "]"
        let sized = encoding.letters.filter { $0.size != 1 }
        let shapes = sized.isEmpty ? ""
            : ", shapes: [" + sized.map { "\"\($0.character)\": \(number($0.size))" }.joined(separator: ", ") + "]"

        var header = ["// 图案创造台导出：\(encoding.columns)×\(encoding.rows)，\(encoding.frames.count) 帧。"]
        if usesAccent { header.append("// accent 是解析后的主题色，如 DotColor(Color.accentColor.resolve(in: environment))。") }
        let body: String
        if encoding.frames.count == 1 {
            body = "DotFigure([\n\(lines(encoding.frames[0], indent: "    "))\n], colors: \(colors)\(shapes))"
        } else {
            let frames = encoding.frames.map { "    [\n\(lines($0, indent: "        "))\n    ]," }.joined(separator: "\n")
            body = "DotFigure(frames: [\n\(frames)\n], colors: \(colors)\(shapes),\n"
                + "holds: [\(encoding.holds.map(number).joined(separator: ", "))], "
                + "transition: \(number(transition)), stagger: \(number(stagger)))"
        }
        return (header + [body]).joined(separator: "\n")
    }
}

/// 素材到点阵：按格子取样、按亮度曲线定大小、按最近色配色，以及从素材里取色。
nonisolated enum StudioConverter {
    /// 一格里前景部分的平均色与占比。
    struct Sample: Sendable {
        var color: DotColor.Oklab
        var coverage: Double
    }

    /// 每格取 4×4 个像素。
    static let supersample = 4

    /// 素材按比例缩进 columns×rows 格并居中，四周空出的部分算背景。去除背景时有透明通道就按透明度，
    /// 否则以四个角里最有代表性的颜色为背景色，与它相差不超过 tolerance 的像素算背景。
    static func sample(_ image: CGImage, columns: Int, rows: Int, background: StudioBackground, tolerance: Double) -> [Sample?] {
        let sub = supersample, width = columns * sub, height = rows * sub
        guard width > 0, height > 0, image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return [] }
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        let rect = CGRect(x: (Double(width) - size.width) / 2, y: (Double(height) - size.height) / 2,
                          width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        func pixel(_ x: Int, _ y: Int) -> DotColor {
            let index = (y * width + x) * 4
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0 else { return DotColor(red: 0, green: 0, blue: 0, alpha: 0) }
            return DotColor(red: min(Double(pixels[index]) / 255 / alpha, 1), green: min(Double(pixels[index + 1]) / 255 / alpha, 1),
                            blue: min(Double(pixels[index + 2]) / 255 / alpha, 1), alpha: alpha)
        }

        // 居中摆放上下对称，内存里自上而下的行范围与 rect 一致
        let minX = min(max(Int(rect.minX.rounded(.up)), 0), width - 1), maxX = max(min(Int(rect.maxX.rounded(.down)) - 1, width - 1), minX)
        let minY = min(max(Int(rect.minY.rounded(.up)), 0), height - 1), maxY = max(min(Int(rect.maxY.rounded(.down)) - 1, height - 1), minY)
        var key: DotColor.Oklab?
        if background == .auto {
            var transparent = false
            outer: for y in minY...maxY {
                for x in minX...maxX where pixels[(y * width + x) * 4 + 3] < 230 {
                    transparent = true
                    break outer
                }
            }
            if !transparent {
                let corners = [pixel(minX, minY), pixel(maxX, minY), pixel(minX, maxY), pixel(maxX, maxY)].map(\.oklab)
                key = corners.min { a, b in
                    corners.reduce(0) { $0 + distance(a, $1) } < corners.reduce(0) { $0 + distance(b, $1) }
                }
            }
        }

        var result: [Sample?] = []
        result.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var red = 0.0, green = 0.0, blue = 0.0, count = 0
                for y in row * sub..<(row + 1) * sub {
                    for x in column * sub..<(column + 1) * sub {
                        let color = pixel(x, y)
                        guard color.alpha >= 0.5 else { continue }
                        if let key, distance(color.oklab, key) <= tolerance { continue }
                        red += color.red
                        green += color.green
                        blue += color.blue
                        count += 1
                    }
                }
                guard count > 0 else {
                    result.append(nil)
                    continue
                }
                let n = Double(count)
                result.append(Sample(color: DotColor(red: red / n, green: green / n, blue: blue / n).oklab,
                                     coverage: n / Double(sub * sub)))
            }
        }
        return result
    }

    /// 曲线值乘上前景占比定大小：不到 0.15 留空，其余分满、中、小三档；颜色取最近的一种。
    static func dots(_ samples: [Sample?], curve: [Double], inks: [(id: UUID, color: DotColor.Oklab)]) -> [StudioDot?] {
        samples.map { sample -> StudioDot? in
            guard let sample, let first = inks.first else { return nil }
            let value = self.curve(curve, at: sample.color.lightness) * sample.coverage
            let size: Int
            switch value {
            case 0.8...: size = 0
            case 0.45...: size = 1
            case 0.15...: size = 2
            default: return nil
            }
            var best = first
            var nearest = distance(first.color, sample.color)
            for ink in inks.dropFirst() {
                let d = distance(ink.color, sample.color)
                if d < nearest { (best, nearest) = (ink, d) }
            }
            return StudioDot(ink: best.id, size: size)
        }
    }

    /// 均匀分布的控制点之间按 Catmull-Rom 插值，截在 0…1。
    static func curve(_ points: [Double], at x: Double) -> Double {
        guard points.count > 1 else { return points.first ?? 1 }
        let last = points.count - 1
        let position = min(max(x, 0), 1) * Double(last)
        let i = min(Int(position), last - 1), t = position - Double(i)
        let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, last)]
        let value = 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t)
        return min(max(value, 0), 1)
    }

    /// 从所有帧的格子里取 count 种代表色（oklab 里 k-means，最远点起步），按格子数从多到少排。
    static func palette(from samples: [[Sample?]], count: Int) -> [DotColor] {
        var points = samples.flatMap { $0.compactMap { $0?.color } }
        if points.count > 6000 {
            let step = Double(points.count) / 6000
            points = (0..<6000).map { points[Int(Double($0) * step)] }
        }
        guard let first = points.first else { return [] }
        var centers = [first]
        var nearest = points.map { distance($0, first) }
        while centers.count < count, let far = nearest.indices.max(by: { nearest[$0] < nearest[$1] }), nearest[far] > 0.02 {
            centers.append(points[far])
            for index in points.indices { nearest[index] = min(nearest[index], distance(points[index], points[far])) }
        }
        var members = Array(repeating: 0, count: centers.count)
        for _ in 0..<12 {
            var sums = Array(repeating: DotColor.Oklab.zero, count: centers.count)
            members = Array(repeating: 0, count: centers.count)
            for point in points {
                let index = centers.indices.min { distance(centers[$0], point) < distance(centers[$1], point) }!
                sums[index] = sums[index] + point
                members[index] += 1
            }
            for index in centers.indices where members[index] > 0 {
                centers[index] = sums[index].scaled(by: 1 / Double(members[index]))
            }
        }
        return centers.indices.filter { members[$0] > 0 }.sorted { members[$0] > members[$1] }.map { DotColor(centers[$0]) }
    }

    static func distance(_ a: DotColor.Oklab, _ b: DotColor.Oklab) -> Double {
        let l = a.lightness - b.lightness, da = a.a - b.a, db = a.b - b.b
        return (l * l + da * da + db * db).squareRoot()
    }
}

/// 解码出来的素材帧与每帧时长。
nonisolated struct StudioImages: @unchecked Sendable {
    var images: [CGImage]
    var durations: [TimeInterval]
}

/// 读图片、GIF（及 APNG、WebP 动图）与视频，至多取 24 帧，缩到边长 320 以内。
nonisolated enum StudioDecoder {
    static let maxFrames = 24
    static let maxPixels = 320

    /// 帧数超出上限时均匀分组，每组取第一帧，时长取整组之和。
    @concurrent static func images(at url: URL) async -> StudioImages? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        let delays = (0..<count).map { delay(of: source, at: $0) }
        let groups = min(count, maxFrames)
        var result = StudioImages(images: [], durations: [])
        for group in 0..<groups {
            let lower = group * count / groups, upper = (group + 1) * count / groups
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, lower, options) else { continue }
            result.images.append(image)
            result.durations.append(delays[lower..<upper].reduce(0, +))
        }
        return result.images.isEmpty ? nil : result
    }

    private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let keys = [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                    (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
                    (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)]
        for (dictionary, unclamped, clamped) in keys {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0
            // 同浏览器的惯例：过短的延迟按 0.1 秒
            return delay < 0.02 ? 0.1 : delay
        }
        return DotStudioModel.defaultDuration
    }

    @concurrent static func duration(of url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @concurrent static func frames(of clip: VideoClip) async throws -> StudioImages {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let fps = max(clip.fps, 1)
        let count = max(1, min(maxFrames, Int((clip.length * fps).rounded())))
        var result = StudioImages(images: [], durations: [])
        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = min(clip.start + Double(index) / fps, max(clip.duration - 0.05, 0))
            result.images.append(try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
            result.durations.append(1 / fps)
        }
        return result
    }
}
