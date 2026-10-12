import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 调 Kite 手写 logo 的书写动画。
//
// 三种 SVG：
// - 只有描边路径（单线）：每个子路径当一笔，按这一笔选的毛笔笔刷预设画（起收笔、慢处变粗、扁笔笔锋、飞白）。
// - 只有填充轮廓（笔刷字形）：栅格化后细化出中心线，按「最顺的方向接着走、走到头就回笔」排出书写路线；
//   墨迹是填充形状本身，沿路线用一支随局部笔宽变粗细的圆头笔画遮罩，逐步显露。
// - 填充轮廓加描边路径：描边路径当引导线，书写路线以它为准，遮罩宽度仍取形状的局部笔宽。
// 每一笔按弧长等距重采样，用速度剖面（转弯减速、起笔加速、收笔减速）积分出「写到多长用了多久」的时间表；
// 书写顺序、笔刷和节奏可以逐笔设。
// 参数即时生效，SVG 改动后自动重新载入。编译运行见 README.md。

// MARK: - 几何

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

func pointDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(b.x - a.x, b.y - a.y)
}

struct Cubic {
    var p0, c1, c2, p3: CGPoint

    static func line(_ a: CGPoint, _ b: CGPoint) -> Cubic {
        Cubic(p0: a, c1: lerp(a, b, 1.0 / 3), c2: lerp(a, b, 2.0 / 3), p3: b)
    }

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        let x = a * p0.x + b * c1.x + c * c2.x + d * p3.x
        let y = a * p0.y + b * c1.y + c * c2.y + d * p3.y
        return CGPoint(x: x, y: y)
    }
}

/// SVG 里的一个子路径。描边时就是一笔，抬笔才算下一笔。
struct Stroke {
    var segments: [Cubic]

    var path: Path {
        var path = Path()
        guard let first = segments.first else { return path }
        path.move(to: first.p0)
        for s in segments { path.addCurve(to: s.p3, control1: s.c1, control2: s.c2) }
        return path
    }

    /// 每段贝塞尔取 96 个点，供按弧长重采样。
    var dense: [CGPoint] {
        var points: [CGPoint] = []
        for segment in segments {
            let n = 96
            for k in (points.isEmpty ? 0 : 1)...n { points.append(segment.point(at: CGFloat(k) / CGFloat(n))) }
        }
        return points
    }
}

struct FillShape {
    var subpaths: [Stroke]
    var evenOdd: Bool

    var path: Path {
        var path = Path()
        for s in subpaths {
            path.addPath(s.path)
            path.closeSubpath()
        }
        return path
    }
}

struct Logo {
    var strokes: [Stroke]
    var fills: [FillShape]
    var viewBox: CGRect
}

// MARK: - SVG

struct SVGError: LocalizedError {
    var errorDescription: String?
}

enum SVG {
    /// 认 `<path>`、`<circle>`、`<ellipse>`，按 fill / stroke 属性分成填充和描边；
    /// transform、style 里的样式都不处理，arc 按直线连到终点。
    static func parse(_ text: String) throws -> Logo {
        let root = text.firstMatch(of: try Regex(#"<svg\b[^>]*>"#)).map { String(text[$0.range]) } ?? ""
        let rootFill = attribute("fill", in: root) ?? "black"
        let rootStroke = attribute("stroke", in: root) ?? "none"
        var strokes: [Stroke] = [], fills: [FillShape] = []
        for match in text.matches(of: try Regex(#"<(path|circle|ellipse)\b[^>]*>"#)) {
            let tag = String(text[match.range])
            var subpaths: [Stroke]
            switch match.output[1].substring.map(String.init) ?? "" {
            case "path":
                guard let d = attribute("d", in: tag) else { continue }
                subpaths = self.strokes(fromPathData: d)
            default:
                let number = { (name: String) in attribute(name, in: tag).flatMap { Double($0) }.map { CGFloat($0) } }
                guard let cx = number("cx"), let cy = number("cy"), let rx = number("rx") ?? number("r") else { continue }
                subpaths = [ellipse(center: CGPoint(x: cx, y: cy), rx: rx, ry: number("ry") ?? rx)]
            }
            if (attribute("fill", in: tag) ?? rootFill) != "none" {
                fills.append(FillShape(subpaths: subpaths, evenOdd: attribute("fill-rule", in: tag) == "evenodd"))
            } else if (attribute("stroke", in: tag) ?? rootStroke) != "none" {
                strokes += subpaths
            }
        }
        guard !strokes.isEmpty || !fills.isEmpty else { throw SVGError(errorDescription: "文件里没有可用的路径") }

        var box = CGRect.null
        if let value = attribute("viewBox", in: root) {
            var scanner = PathScanner(value)
            if let x = scanner.number(), let y = scanner.number(), let w = scanner.number(), let h = scanner.number(), w > 0, h > 0 {
                box = CGRect(x: x, y: y, width: w, height: h)
            }
        }
        if box.isNull {
            for s in strokes { box = box.union(s.path.boundingRect) }
            for f in fills { box = box.union(f.path.boundingRect) }
            box = box.insetBy(dx: -1, dy: -1)
        }
        return Logo(strokes: strokes, fills: fills, viewBox: box)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex(#"\s"# + name + #"\s*=\s*["']([^"']*)["']"#),
              let value = tag.firstMatch(of: regex)?.output[1].substring else { return nil }
        return value.trimmingCharacters(in: .whitespaces)
    }

    static func ellipse(center c: CGPoint, rx: CGFloat, ry: CGFloat) -> Stroke {
        let k: CGFloat = 0.5522847498
        let e = CGPoint(x: c.x + rx, y: c.y), s = CGPoint(x: c.x, y: c.y + ry)
        let w = CGPoint(x: c.x - rx, y: c.y), n = CGPoint(x: c.x, y: c.y - ry)
        return Stroke(segments: [
            Cubic(p0: e, c1: CGPoint(x: e.x, y: e.y + ry * k), c2: CGPoint(x: s.x + rx * k, y: s.y), p3: s),
            Cubic(p0: s, c1: CGPoint(x: s.x - rx * k, y: s.y), c2: CGPoint(x: w.x, y: w.y + ry * k), p3: w),
            Cubic(p0: w, c1: CGPoint(x: w.x, y: w.y - ry * k), c2: CGPoint(x: n.x - rx * k, y: n.y), p3: n),
            Cubic(p0: n, c1: CGPoint(x: n.x + rx * k, y: n.y), c2: CGPoint(x: e.x, y: e.y - ry * k), p3: e),
        ])
    }

    static func strokes(fromPathData d: String) -> [Stroke] {
        var scanner = PathScanner(d)
        var strokes: [Stroke] = [], segments: [Cubic] = []
        var pos = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var command: UInt8 = 0

        func finish() {
            if !segments.isEmpty { strokes.append(Stroke(segments: segments)) }
            segments = []
        }
        func reflect(_ c: CGPoint?, about p: CGPoint) -> CGPoint {
            guard let c else { return p }
            return CGPoint(x: 2 * p.x - c.x, y: 2 * p.y - c.y)
        }

        parsing: while true {
            if let letter = scanner.command() {
                command = letter
            } else if scanner.atEnd || command == 0 {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? pos : .zero
            func resolve(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }
            var cubicControl: CGPoint?, quadControl: CGPoint?

            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = scanner.point() else { break parsing }
                finish()
                pos = resolve(p)
                start = pos
                // M 后面成对的数字按 L 处理
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = scanner.point() else { break parsing }
                let q = resolve(p)
                segments.append(.line(pos, q))
                pos = q
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { break parsing }
                let q = CGPoint(x: relative ? pos.x + x : x, y: pos.y)
                segments.append(.line(pos, q))
                pos = q
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { break parsing }
                let q = CGPoint(x: pos.x, y: relative ? pos.y + y : y)
                segments.append(.line(pos, q))
                pos = q
            case UInt8(ascii: "c"):
                guard let a = scanner.point(), let b = scanner.point(), let p = scanner.point() else { break parsing }
                let c2 = resolve(b), q = resolve(p)
                segments.append(Cubic(p0: pos, c1: resolve(a), c2: c2, p3: q))
                cubicControl = c2
                pos = q
            case UInt8(ascii: "s"):
                guard let b = scanner.point(), let p = scanner.point() else { break parsing }
                let c2 = resolve(b), q = resolve(p)
                segments.append(Cubic(p0: pos, c1: reflect(lastCubic, about: pos), c2: c2, p3: q))
                cubicControl = c2
                pos = q
            case UInt8(ascii: "q"), UInt8(ascii: "t"):
                let control: CGPoint
                if command | 0x20 == UInt8(ascii: "q") {
                    guard let c = scanner.point() else { break parsing }
                    control = resolve(c)
                } else {
                    control = reflect(lastQuad, about: pos)
                }
                guard let p = scanner.point() else { break parsing }
                let q = resolve(p)
                segments.append(Cubic(p0: pos, c1: lerp(pos, control, 2.0 / 3), c2: lerp(q, control, 2.0 / 3), p3: q))
                quadControl = control
                pos = q
            case UInt8(ascii: "a"):
                guard scanner.number() != nil, scanner.number() != nil, scanner.number() != nil,
                      scanner.flag() != nil, scanner.flag() != nil, let p = scanner.point() else { break parsing }
                let q = resolve(p)
                segments.append(.line(pos, q))
                pos = q
            case UInt8(ascii: "z"):
                if pos != start { segments.append(.line(pos, start)) }
                pos = start
                command = 0
            default:
                break parsing
            }
            lastCubic = cubicControl
            lastQuad = quadControl
        }
        finish()
        return strokes
    }
}

struct PathScanner {
    private static let commands = Set("MmLlHhVvCcSsQqTtAaZz".utf8)
    private let bytes: [UInt8]
    private var i = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    var atEnd: Bool {
        mutating get {
            skipSeparators()
            return i >= bytes.count
        }
    }

    private mutating func skipSeparators() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x2C].contains(bytes[i]) { i += 1 }
    }

    private func digit(_ j: Int) -> Bool {
        j < bytes.count && bytes[j] >= UInt8(ascii: "0") && bytes[j] <= UInt8(ascii: "9")
    }

    mutating func command() -> UInt8? {
        skipSeparators()
        guard i < bytes.count, Self.commands.contains(bytes[i]) else { return nil }
        defer { i += 1 }
        return bytes[i]
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
        var digits = false
        while digit(i) { i += 1; digits = true }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            while digit(i) { i += 1; digits = true }
        }
        guard digits else { i = start; return nil }
        if i < bytes.count, bytes[i] | 0x20 == UInt8(ascii: "e") {
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
            if digit(j) {
                i = j
                while digit(i) { i += 1 }
            }
        }
        return Double(String(decoding: bytes[start..<i], as: UTF8.self)).map { CGFloat($0) }
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < bytes.count, bytes[i] == UInt8(ascii: "0") || bytes[i] == UInt8(ascii: "1") else { return nil }
        defer { i += 1 }
        return bytes[i] == UInt8(ascii: "1")
    }

    mutating func point() -> CGPoint? {
        guard let x = number(), let y = number() else { return nil }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - 填充轮廓的中心线

/// 填充形状栅格化后的距离场和骨架图，载入时算一次。
struct Outline {
    struct Node {
        var pixels: [Int]
        var center = CGPoint.zero
        /// 节点处的半笔宽，像素。
        var radius: Double = 0
        var edges: [Int] = []
    }

    struct Edge {
        var a: Int
        var b: Int
        /// 从 a 一侧到 b 一侧的骨架像素，不含两端节点。
        var pixels: [Int]
    }

    let width: Int
    let height: Int
    /// 每个 viewBox 单位多少像素。
    let scale: CGFloat
    /// 像素 (0, 0) 左上角的 viewBox 坐标。
    let origin: CGPoint
    /// 每个像素到原形状外的距离，像素。
    let distance: [Float]
    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    /// 每个连通块的节点，按最左边的位置排序；一块写一笔。
    private(set) var components: [[Int]] = []
    /// 骨架上半笔宽的九成分位，viewBox 单位；引导线找局部笔宽时用作搜索半径。
    private(set) var typicalRadius: Double = 0

    /// gap：比这个窄的缝隙在排路线前先补上（闭运算），viewBox 单位。只影响路线和遮罩，不改画出来的形状。
    init?(fills: [FillShape], gap: Double) {
        var bounds = CGRect.null
        for f in fills { bounds = bounds.union(f.path.boundingRect) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 1200 / max(bounds.width, bounds.height)
        let pad = 6
        let w = Int((bounds.width * scale).rounded(.up)) + 2 * pad, h = Int((bounds.height * scale).rounded(.up)) + 2 * pad
        let origin = CGPoint(x: bounds.minX - CGFloat(pad) / scale, y: bounds.minY - CGFloat(pad) / scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // 内存第 j 行对应 y = origin.y + (j + 0.5) / scale
        ctx.translateBy(x: -origin.x * scale, y: CGFloat(h) + origin.y * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(gray: 1, alpha: 1)
        for f in fills {
            ctx.addPath(f.path.cgPath)
            ctx.fillPath(using: f.evenOdd ? .evenOdd : .winding)
        }
        guard let data = ctx.data else { return nil }
        let row = ctx.bytesPerRow
        let raw = data.bindMemory(to: UInt8.self, capacity: row * h)
        var value = [Float](repeating: 0, count: w * h)
        for j in 0..<h { for i in 0..<w { value[j * w + i] = Float(raw[j * row + i]) } }
        // 笔刷轮廓边缘有细碎抖动，先糊一下再取阈值，少出毛刺分支
        Self.blur(&value, w, h, radius: 2)
        var inside = value.map { $0 >= 127.5 ? UInt8(1) : 0 }
        for i in 0..<w { inside[i] = 0; inside[(h - 1) * w + i] = 0 }
        for j in 0..<h { inside[j * w] = 0; inside[j * w + w - 1] = 0 }
        let original = Self.chamfer(inside, w, h)
        let close = Float(gap / 2 * Double(scale))
        if close > 0 {
            let outside = Self.chamfer(inside.map { 1 - $0 }, w, h)
            let grown = outside.indices.map { inside[$0] == 1 || outside[$0] <= close ? UInt8(1) : 0 }
            let depth = Self.chamfer(grown, w, h)
            inside = depth.map { $0 > close ? 1 : 0 }
            for i in 0..<w { inside[i] = 0; inside[(h - 1) * w + i] = 0 }
            for j in 0..<h { inside[j * w] = 0; inside[j * w + w - 1] = 0 }
        }

        self.width = w
        self.height = h
        self.scale = scale
        self.origin = origin
        // 笔宽按原形状量，补上的缝不算笔宽
        self.distance = original
        let skeleton = Self.thin(inside, w, h)
        buildGraph(skeleton)
        let radii = skeleton.indices.filter { skeleton[$0] == 1 }.map { Double(distance[$0]) }.sorted()
        typicalRadius = radii.isEmpty ? 0 : radii[Int(Double(radii.count - 1) * 0.9)] / Double(scale)
    }

    func location(_ k: Int) -> CGPoint {
        CGPoint(x: origin.x + (CGFloat(k % width) + 0.5) / scale, y: origin.y + (CGFloat(k / width) + 0.5) / scale)
    }

    /// p 附近 radius 像素内最大的半笔宽，viewBox 单位。
    func halfWidth(at p: CGPoint, radius: Int = 1) -> Double {
        let i0 = Int(((p.x - origin.x) * scale).rounded(.down)), j0 = Int(((p.y - origin.y) * scale).rounded(.down))
        let jl = max(j0 - radius, 0), jh = min(j0 + radius, height - 1)
        let il = max(i0 - radius, 0), ih = min(i0 + radius, width - 1)
        guard jl <= jh, il <= ih else { return 0 }
        var best: Float = 0
        for j in jl...jh {
            for i in il...ih { best = max(best, distance[j * width + i]) }
        }
        return Double(best) / Double(scale)
    }

    // MARK: 栅格

    private static func blur(_ v: inout [Float], _ w: Int, _ h: Int, radius r: Int) {
        var tmp = v
        for j in 0..<h {
            for i in 0..<w {
                var sum: Float = 0, count: Float = 0
                for d in -r...r where i + d >= 0 && i + d < w { sum += v[j * w + i + d]; count += 1 }
                tmp[j * w + i] = sum / count
            }
        }
        for j in 0..<h {
            for i in 0..<w {
                var sum: Float = 0, count: Float = 0
                for d in -r...r where j + d >= 0 && j + d < h { sum += tmp[(j + d) * w + i]; count += 1 }
                v[j * w + i] = sum / count
            }
        }
    }

    /// 3-4 倒角距离变换，结果换算成像素。
    private static func chamfer(_ inside: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        let far: Int32 = 1 << 28
        var d = inside.map { $0 == 1 ? far : 0 }
        for j in 1..<(h - 1) {
            for i in 1..<(w - 1) {
                let k = j * w + i
                guard d[k] != 0 else { continue }
                d[k] = min(d[k], d[k - 1] + 3, d[k - w] + 3, d[k - w - 1] + 4, d[k - w + 1] + 4)
            }
        }
        for j in stride(from: h - 2, through: 1, by: -1) {
            for i in stride(from: w - 2, through: 1, by: -1) {
                let k = j * w + i
                guard d[k] != 0 else { continue }
                d[k] = min(d[k], d[k + 1] + 3, d[k + w] + 3, d[k + w + 1] + 4, d[k + w - 1] + 4)
            }
        }
        return d.map { Float($0) / 3 }
    }

    /// Zhang-Suen 细化成单像素骨架。
    private static func thin(_ inside: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var s = inside
        var candidates = s.indices.filter { s[$0] == 1 }
        var changed = true
        while changed {
            changed = false
            for step in 0..<2 {
                var remove: [Int] = []
                for k in candidates where s[k] == 1 {
                    let p2 = Int(s[k - w]), p3 = Int(s[k - w + 1]), p4 = Int(s[k + 1]), p5 = Int(s[k + w + 1])
                    let p6 = Int(s[k + w]), p7 = Int(s[k + w - 1]), p8 = Int(s[k - 1]), p9 = Int(s[k - w - 1])
                    let b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
                    guard b >= 2, b <= 6 else { continue }
                    var a = 0
                    if p2 == 0 && p3 == 1 { a += 1 }
                    if p3 == 0 && p4 == 1 { a += 1 }
                    if p4 == 0 && p5 == 1 { a += 1 }
                    if p5 == 0 && p6 == 1 { a += 1 }
                    if p6 == 0 && p7 == 1 { a += 1 }
                    if p7 == 0 && p8 == 1 { a += 1 }
                    if p8 == 0 && p9 == 1 { a += 1 }
                    if p9 == 0 && p2 == 1 { a += 1 }
                    guard a == 1 else { continue }
                    if step == 0 {
                        guard p2 * p4 * p6 == 0, p4 * p6 * p8 == 0 else { continue }
                    } else {
                        guard p2 * p4 * p8 == 0, p2 * p6 * p8 == 0 else { continue }
                    }
                    remove.append(k)
                }
                for k in remove { s[k] = 0 }
                if !remove.isEmpty { changed = true }
            }
            candidates = candidates.filter { s[$0] == 1 }
        }
        return s
    }

    // MARK: 骨架图

    private mutating func buildGraph(_ skeleton: [UInt8]) {
        var s = skeleton
        let w = width
        let ring = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]
        let walkOrder = [-w, 1, w, -1, -w + 1, w + 1, w - 1, -w - 1]
        var pixels = s.indices.filter { s[$0] == 1 }
        for k in pixels where !ring.contains(where: { s[k + $0] == 1 }) { s[k] = 0 }
        pixels = pixels.filter { s[$0] == 1 }

        // 交叉数：一圈邻居里 0→1 的次数，等于从这个像素伸出去的分支数，台阶状的斜线不会误判成分叉
        func crossing(_ k: Int) -> Int {
            var a = 0
            for t in 0..<8 where s[k + ring[t]] == 0 && s[k + ring[(t + 1) % 8]] == 1 { a += 1 }
            return a
        }
        var isNode = [Bool](repeating: false, count: s.count)
        for k in pixels where crossing(k) != 2 { isNode[k] = true }

        var nodeOf = [Int](repeating: -1, count: s.count)
        var nodes: [Node] = []
        for k in pixels where isNode[k] && nodeOf[k] < 0 {
            let id = nodes.count
            var stack = [k], members: [Int] = []
            nodeOf[k] = id
            while let q = stack.popLast() {
                members.append(q)
                for o in ring where isNode[q + o] && nodeOf[q + o] < 0 {
                    nodeOf[q + o] = id
                    stack.append(q + o)
                }
            }
            nodes.append(Node(pixels: members))
        }

        var visited = [Bool](repeating: false, count: s.count)
        var edges: [Edge] = []
        var touching = Set<Int>()
        func trace(from id: Int) {
            for q in nodes[id].pixels {
                for o in ring {
                    let first = q + o
                    guard s[first] == 1, nodeOf[first] != id else { continue }
                    if nodeOf[first] >= 0 {
                        let other = nodeOf[first], key = min(id, other) * 1_000_000 + max(id, other)
                        if touching.insert(key).inserted { edges.append(Edge(a: id, b: other, pixels: [])) }
                        continue
                    }
                    guard !visited[first] else { continue }
                    visited[first] = true
                    var chain = [first], previous = q, current = first, end = -1
                    while true {
                        if let hit = ring.lazy.map({ current + $0 }).first(where: {
                            $0 != previous && nodeOf[$0] >= 0 && (nodeOf[$0] != id || chain.count > 2)
                        }) {
                            end = nodeOf[hit]
                            break
                        }
                        guard let next = walkOrder.lazy.map({ current + $0 }).first(where: {
                            s[$0] == 1 && !visited[$0] && nodeOf[$0] < 0
                        }) else { break }
                        visited[next] = true
                        chain.append(next)
                        previous = current
                        current = next
                    }
                    if end < 0 {
                        // 断头：末端补一个端点
                        end = nodes.count
                        nodes.append(Node(pixels: [current]))
                        nodeOf[current] = end
                        chain.removeLast()
                    }
                    edges.append(Edge(a: id, b: end, pixels: chain))
                }
            }
        }
        for id in nodes.indices { trace(from: id) }
        // 没有分叉也没有端点的闭环（比如 o）
        for k in pixels where nodeOf[k] < 0 && !visited[k] {
            nodeOf[k] = nodes.count
            nodes.append(Node(pixels: [k]))
            trace(from: nodes.count - 1)
        }

        func radius(_ members: [Int]) -> Double { Double(members.map { distance[$0] }.max() ?? 0) }
        func degrees() -> [Int] {
            var d = [Int](repeating: 0, count: nodes.count)
            for e in edges { d[e.a] += 1; d[e.b] += 1 }
            return d
        }

        // 两笔交叉在骨架上常裂成两个挨着的三岔口，离得比笔宽近就并成一个
        var parent = Array(nodes.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var degree = degrees()
        var kept: [Edge] = []
        for e in edges {
            let a = find(e.a), b = find(e.b)
            if a != b, degree[e.a] >= 3, degree[e.b] >= 3,
               Double(e.pixels.count) < 1.5 * max(radius(nodes[a].pixels), radius(nodes[b].pixels)) {
                parent[b] = a
                nodes[a].pixels += nodes[b].pixels + e.pixels
                continue
            }
            kept.append(e)
        }
        edges = kept.map { Edge(a: find($0.a), b: find($0.b), pixels: $0.pixels) }

        // 剪掉毛刺：一头是端点、一头是岔口，而且整根落在岔口的内切圆里（写到岔口时遮罩本来就盖得住）的短枝。
        // 伸出去更远的是真的尖角或回笔，要留着，不然写完之前那块一直露不出来
        let connected = degrees()
        for _ in 0..<2 {
            degree = degrees()
            edges = edges.filter { e in
                let (tip, fork) = degree[e.a] == 1 ? (e.a, e.b) : (e.b, e.a)
                guard e.a != e.b, degree[tip] == 1, degree[fork] >= 3 else { return true }
                return Double(e.pixels.count + 1) + radius(nodes[tip].pixels) > radius(nodes[fork].pixels)
            }
        }

        // 重新编号：并掉的节点和剪毛刺剩下的孤立端点丢掉，本来就没有边的（小圆点细化后只剩一团）保留
        degree = degrees()
        var remap = [Int](repeating: -1, count: nodes.count)
        var compact: [Node] = []
        for id in nodes.indices where find(id) == id && !(degree[id] == 0 && connected[id] > 0) {
            remap[id] = compact.count
            var node = nodes[id]
            let points = node.pixels.map(location)
            node.center = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                  y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            node.radius = radius(node.pixels)
            compact.append(node)
        }
        edges = edges.map { Edge(a: remap[$0.a], b: remap[$0.b], pixels: $0.pixels) }
        for (i, e) in edges.enumerated() {
            compact[e.a].edges.append(i)
            if e.b != e.a { compact[e.b].edges.append(i) }
        }
        self.nodes = compact
        self.edges = edges

        var component = [Int](repeating: -1, count: compact.count)
        var groups: [[Int]] = []
        for start in compact.indices where component[start] < 0 {
            var stack = [start], members: [Int] = []
            component[start] = groups.count
            while let n = stack.popLast() {
                members.append(n)
                for e in compact[n].edges {
                    let other = edges[e].a == n ? edges[e].b : edges[e].a
                    if component[other] < 0 { component[other] = groups.count; stack.append(other) }
                }
            }
            groups.append(members)
        }
        components = groups.sorted { a, b in
            a.map { compact[$0].center.x }.min()! < b.map { compact[$0].center.x }.min()!
        }
    }

    // MARK: 书写路线

    /// 连通块 c 的书写路线：从第 pick 个端点起笔，在岔口挑方向变化最小的没写过的边，
    /// 走到头还有没写的边就沿写过的路回笔到最近的岔口。返回路线点（viewBox 单位）和沿途的半笔宽。
    func route(_ c: Int, pick: Int) -> (points: [CGPoint], half: [Double], options: Int) {
        let members = components[c]
        let ends = members.filter { nodes[$0].edges.count == 1 }
        let candidates = (ends.isEmpty ? members : ends).sorted { nodes[$0].center.x + nodes[$0].center.y < nodes[$1].center.x + nodes[$1].center.y }
        let start = candidates[((pick % candidates.count) + candidates.count) % candidates.count]
        let total = Set(members.flatMap { nodes[$0].edges }).count
        // 收笔落在最右边的端点；通往它的桥留到这一侧都写完再走，免得写到头再长途回笔
        let finish = ends.filter { $0 != start }.max { nodes[$0].center.x < nodes[$1].center.x }

        /// 在没写过的边里拿掉 e 后，e 另一头还能连到的节点；能绕回 node 说明 e 不是桥，返回 nil。
        func beyond(_ e: Int, from node: Int, used: Set<Int>) -> Set<Int>? {
            let far = edges[e].a == node ? edges[e].b : edges[e].a
            guard far != node else { return nil }
            var seen: Set = [far], stack = [far]
            while let n = stack.popLast() {
                for x in nodes[n].edges where x != e && !used.contains(x) {
                    let other = edges[x].a == n ? edges[x].b : edges[x].a
                    if other == node { return nil }
                    if seen.insert(other).inserted { stack.append(other) }
                }
            }
            return seen
        }

        func points(_ e: Int, forward: Bool) -> [CGPoint] {
            let edge = edges[e]
            let middle = edge.pixels.map(location)
            return forward ? [nodes[edge.a].center] + middle + [nodes[edge.b].center]
                           : [nodes[edge.b].center] + middle.reversed() + [nodes[edge.a].center]
        }
        // 离开或到达节点时的方向，跳过节点中心，往里看约两倍笔宽
        func heading(_ pts: [CGPoint], leaving: Bool) -> CGVector {
            let seq = leaving ? pts : pts.reversed()
            let anchor = seq.count > 2 ? seq[1] : seq[0]
            let reach = max(4 * typicalRadius, 0.3)
            var far = seq[seq.count - 1]
            var travelled: CGFloat = 0
            for i in 1..<seq.count {
                travelled += pointDistance(seq[i - 1], seq[i])
                if travelled >= reach { far = seq[i]; break }
            }
            let v = CGVector(dx: far.x - anchor.x, dy: far.y - anchor.y)
            return leaving ? v : CGVector(dx: -v.dx, dy: -v.dy)
        }
        func turn(_ a: CGVector, _ b: CGVector) -> Double {
            let la = hypot(a.dx, a.dy), lb = hypot(b.dx, b.dy)
            guard la > 0, lb > 0 else { return 0 }
            return Double(acos(max(-1, min(1, (a.dx * b.dx + a.dy * b.dy) / (la * lb)))))
        }

        var out = [nodes[start].center]
        var used = Set<Int>()
        var current = start
        var incoming: CGVector?
        while used.count < total {
            let open = nodes[current].edges.filter { !used.contains($0) }
            if open.isEmpty {
                guard let path = retrace(from: current, used: used) else { break }
                for (e, forward) in path {
                    let pts = points(e, forward: forward)
                    out += pts.dropFirst()
                    incoming = heading(pts, leaving: false)
                    current = forward ? edges[e].b : edges[e].a
                }
                continue
            }
            var best: (edge: Int, forward: Bool, cost: Double)?
            let detours = open.filter { e in finish.map { beyond(e, from: current, used: used)?.contains($0) != true } ?? true }
            for e in detours.isEmpty ? open : detours {
                let directions = edges[e].a == edges[e].b ? [true, false] : [edges[e].a == current]
                for forward in directions {
                    let cost = incoming.map { turn($0, heading(points(e, forward: forward), leaving: true)) } ?? 0
                    if best == nil || cost < best!.cost { best = (e, forward, cost) }
                }
            }
            let pts = points(best!.edge, forward: best!.forward)
            out += pts.dropFirst()
            used.insert(best!.edge)
            incoming = heading(pts, leaving: false)
            current = best!.forward ? edges[best!.edge].b : edges[best!.edge].a
        }
        if out.count == 1 {
            // 小圆点：整块只有一个节点
            let pts = nodes[start].pixels.map(location)
            out = [pts.first!, pts.count > 1 ? pts.last! : CGPoint(x: pts[0].x + 0.01, y: pts[0].y)]
        }

        // 像素路线是台阶状的，按点序做一次高斯平滑
        let sigma = 1.5, radius = 4
        let smooth = out.indices.map { i -> CGPoint in
            var x: CGFloat = 0, y: CGFloat = 0, weight: CGFloat = 0
            for d in -radius...radius where i + d >= 0 && i + d < out.count {
                let g = CGFloat(exp(-Double(d * d) / (2 * sigma * sigma)))
                x += out[i + d].x * g; y += out[i + d].y * g; weight += g
            }
            return CGPoint(x: x / weight, y: y / weight)
        }
        // 岔口处内切圆偏大，直接用会在岔口冒出一个圆斑；沿路线取一段笔宽的中位数
        let raw = smooth.map { halfWidth(at: $0) }
        let window = max(Int(3 * typicalRadius * Double(scale)), 3)
        let half = raw.indices.map { i in
            let slice = raw[max(i - window, 0)...min(i + window, raw.count - 1)].sorted()
            return slice[slice.count / 2]
        }
        return (smooth, half, candidates.count)
    }

    /// 沿已经写过的边找到最近的还有没写的边的节点。
    private func retrace(from start: Int, used: Set<Int>) -> [(edge: Int, forward: Bool)]? {
        var best = [start: 0.0]
        var back: [Int: (node: Int, edge: Int, forward: Bool)] = [:]
        var done = Set<Int>()
        while let (node, cost) = best.filter({ !done.contains($0.key) }).min(by: { $0.value < $1.value }) {
            done.insert(node)
            if node != start, nodes[node].edges.contains(where: { !used.contains($0) }) {
                var path: [(edge: Int, forward: Bool)] = []
                var n = node
                while let step = back[n] { path.insert((step.edge, step.forward), at: 0); n = step.node }
                return path
            }
            for e in nodes[node].edges where used.contains(e) {
                let forward = edges[e].a == node
                let other = forward ? edges[e].b : edges[e].a
                let next = cost + Double(edges[e].pixels.count + 1)
                if next < best[other] ?? .infinity {
                    best[other] = next
                    back[other] = (node, e, forward)
                }
            }
        }
        return nil
    }
}

// MARK: - 笔刷与参数

/// 毛笔笔刷预设：决定单线的笔迹怎么画。长度都是 viewBox 单位。
struct Brush: Identifiable {
    var id: String
    var name: String
    /// 笔宽。
    var size = 2.0
    /// 起笔在这段长度内从「起笔粗细」过渡到正常。
    var entry = 0.0
    /// 起笔时是正常粗细的几倍：小于 1 是尖起（露锋），大于 1 是顿笔。
    var entryWeight = 1.0
    var exit = 0.0
    /// 收笔时是正常粗细的几倍：小于 1 是出锋，大于 1 是顿收。
    var exitWeight = 1.0
    /// 扁度：0 是圆笔，各方向一样粗；1 是扁笔，顺着笔锋方向走时最细。
    var flatness = 0.0
    /// 笔锋角度，度，屏幕上从水平向右逆时针量。
    var angle = 45.0
    /// 笔毛根数，少于 2 根按实心画。
    var bristles = 0
    /// 飞白：越大，写得快、写到后段时边上的笔毛越容易断墨。
    var dryness = 0.0
    /// 毛边：笔毛横向抖动的幅度。
    var roughness = 0.0

    static let presets: [Brush] = [
        Brush(id: "uniform", name: "匀线", size: 2),
        Brush(id: "kai", name: "小楷", size: 2, entry: 2.5, entryWeight: 1.4, exit: 5, exitWeight: 0.15,
              flatness: 0.25, angle: 45),
        Brush(id: "xing", name: "行书", size: 2.2, entry: 2, entryWeight: 0.5, exit: 8, exitWeight: 0.1,
              flatness: 0.3, angle: 40),
        Brush(id: "feibai", name: "飞白", size: 2.6, entry: 1.5, entryWeight: 1.2, exit: 10, exitWeight: 0.2,
              flatness: 0.2, angle: 40, bristles: 14, dryness: 0.6, roughness: 0.25),
        Brush(id: "flat", name: "扁笔", size: 2.4, flatness: 0.85, angle: 35),
    ]

    static func named(_ id: String) -> Brush {
        presets.first { $0.id == id } ?? presets[0]
    }
}

/// 一笔自己的设置。
struct StrokeConfig: Codable, Equatable {
    enum Entry: String, Codable, CaseIterable { case brush, custom, flat }

    var enabled = true
    var reversed = false
    var brush = "xing"
    /// 笔刷粗细的倍数。
    var size = 1.0
    /// 起笔：跟随笔刷、用下面两个值自定义，或者平起（一落笔就是正常粗细）。
    var entry = Entry.brush
    /// 自定义起笔时，在这段长度内从起笔粗细过渡到正常，viewBox 单位。
    var entryLength = 2.0
    /// 自定义起笔时，起笔是正常粗细的几倍：小于 1 是尖起（露锋），大于 1 是顿笔。
    var entryWeight = 0.5
    /// 关掉时收笔不按笔刷出锋或顿收，保持原来的粗细。
    var taperExit = true
    /// 越慢越粗：笔宽乘 1 + 转弯加粗 × (1 − 速度比)。转弯减速让转弯处变慢，所以那里最明显。
    var pressure = 0.5
    /// 在全局速度上再乘的倍数。
    var speed = 1.0
    /// 速度按 1 / (1 + 转弯减速 × 曲率) 降，曲率经 0.6 单位的高斯平滑。
    var cornering = 1.5
    /// 起笔后多长距离内从 0.3 倍速加到全速，viewBox 单位。
    var easeIn = 4.0
    /// 收笔前多长距离内从全速降到 0.3 倍速。
    var easeOut = 6.0
    /// 上一笔写完到这一笔落笔之间停多久，第一笔不算。
    var pause = 0.15
    /// 填充轮廓自动排路线时从第几个端点起笔。
    var startPick = 0
}

struct Params: Codable, Equatable {
    enum Timing: String, Codable, CaseIterable { case speed, duration }
    enum Exit: String, Codable, CaseIterable { case stay, fade, unwrite, erase }
    enum Backdrop: String, Codable, CaseIterable { case system, light, dark }

    // 节奏
    var timing = Timing.duration
    /// 直线上的书写速度，viewBox 单位每秒。
    var speed = 100.0
    /// 按总时长计时时，所有要写的笔加起来用的秒数，不含笔间停顿。
    var writeDuration = 1.8
    var lead = 0.3
    var hold = 1.2
    var exit = Exit.fade
    var exitDuration = 0.5

    // 笔画：按 SVG 里的先后（自动排路线时按连通块）编号
    var order: [Int] = []
    var strokes: [StrokeConfig] = []

    // 填充轮廓
    /// 遮罩笔比局部半笔宽多出的量，viewBox 单位。
    var maskMargin = 0.25
    /// 排路线前补上比这窄的缝隙，viewBox 单位。
    var gap = 0.15

    // 显示
    var customInk = false
    var inkR = 0.1, inkG = 0.1, inkB = 0.12
    var backdrop = Backdrop.system
    var zoom = 1.0
    var ghost = true
    var handles = false
    var showStarts = false
    var centerline = false
    var speedColor = false
    var head = false
    var headSize = 3.0
    var bounds = false

    // 播放
    var loop = true
    var rate = 1.0

    func stroke(_ k: Int) -> StrokeConfig {
        k < strokes.count ? strokes[k] : StrokeConfig()
    }

    /// 书写顺序：保存的顺序里去掉越界和重复的，没排进去的按编号接在后面。
    func writingOrder(count n: Int) -> [Int] {
        var seen = Set<Int>()
        let kept = order.filter { $0 >= 0 && $0 < n && seen.insert($0).inserted }
        return kept + (0..<n).filter { !seen.contains($0) }
    }

    /// 按默认值补齐缺的字段再解码，加了新参数以后旧的设置不至于整个作废。
    static func decode(_ data: Data) -> Params? {
        func object(_ value: some Encodable) -> [String: Any] {
            (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        guard var saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let template = object(StrokeConfig())
        // 早先节奏是全局的一组：带到每一笔上（多给几份，超出笔数的用不到）
        if saved["strokes"] == nil, saved["cornering"] != nil {
            let disabled = saved["disabled"] as? [Int] ?? [], reversed = saved["reversed"] as? [Int] ?? []
            saved["strokes"] = (0..<16).map { k in
                var config = template
                for key in ["cornering", "easeIn", "easeOut"] { config[key] = saved[key] ?? config[key] }
                config["pause"] = saved["strokeGap"] ?? config["pause"]
                config["enabled"] = !disabled.contains(k)
                config["reversed"] = reversed.contains(k)
                return config
            }
        }
        if let list = saved["strokes"] as? [[String: Any]] { saved["strokes"] = list.map { template.merging($0) { $1 } } }
        let merged = object(Params()).merging(saved) { $1 }
        guard let json = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(Params.self, from: json)
    }
}

extension Params.Exit {
    var title: String {
        switch self {
        case .stay: "停住"
        case .fade: "淡出"
        case .unwrite: "倒着擦掉"
        case .erase: "顺着擦掉"
        }
    }
}

/// 一维值噪声，0…1，按整数格点平滑插值。
func noise(_ s: Double, seed: Int) -> Double {
    func hash(_ i: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed &* 73_856_093 ^ i &* 19_349_663))
        x = (x ^ (x >> 33)) &* 0xff51_afd7_ed55_8ccd
        x = (x ^ (x >> 33)) &* 0xc4ce_b9fe_1a85_ec53
        x ^= x >> 33
        return Double(x >> 11) / Double(1 << 53)
    }
    let i = Int(s.rounded(.down)), f = s - s.rounded(.down)
    let u = f * f * (3 - 2 * f)
    return hash(i) * (1 - u) + hash(i + 1) * u
}

// MARK: - 时间表

/// 一笔按弧长等距采样后的轨迹，带每个采样点的速度比、累计时间和笔宽。
struct Track {
    static let step: CGFloat = 0.1

    struct Bristle {
        /// 每个采样点上这根笔毛在笔宽里的横向位置，−0.5…0.5。
        var offset: [Double]
        var visible: [Bool]
    }

    struct Sample {
        var point: CGPoint
        var width: Double
        var ratio: Double
        /// 最近的采样点。
        var index: Int
    }

    var points: [CGPoint]
    var lengths: [Double]
    var curvature: [Double]
    /// 行进方向，弧度，viewBox 坐标（y 向下）。
    var heading: [Double]
    /// 填充轮廓时每个采样点的局部半笔宽；单线时为空。
    var half: [Double]
    var ratio: [Double] = []
    var times: [Double] = []
    /// 实际笔宽（单线）或遮罩笔宽（填充轮廓），viewBox 单位。
    var widths: [Double] = []
    var bristles: [Bristle] = []
    /// 单线时这一笔用的笔刷。
    var brush = ""
    /// 自动排路线时可选的起笔端点数。
    var startOptions = 0

    var length: Double { lengths.last ?? 0 }
    var duration: Double { times.last ?? 0 }

    init(dense: [CGPoint], half: [Double] = [], reversed: Bool) {
        var dense = dense, half = half
        if reversed { dense.reverse(); half.reverse() }
        let sampled = Self.resample(dense, half)
        points = sampled.0
        self.half = sampled.1
        lengths = [0]
        for i in points.indices.dropFirst() { lengths.append(lengths[i - 1] + Double(pointDistance(points[i - 1], points[i]))) }
        curvature = Self.curvature(points, lengths)
        let p = points
        heading = p.indices.map { i in
            let a = p[max(i - 3, 0)], b = p[min(i + 3, p.count - 1)]
            return Double(atan2(b.y - a.y, b.x - a.x))
        }
    }

    private static func resample(_ dense: [CGPoint], _ values: [Double]) -> ([CGPoint], [Double]) {
        guard let first = dense.first else { return ([], []) }
        var out = [first], outValues = values.isEmpty ? [] : [values[0]]
        var carried: CGFloat = 0
        for k in dense.indices.dropFirst() {
            let a = dense[k - 1], b = dense[k], length = pointDistance(a, b)
            var position: CGFloat = 0
            while carried + (length - position) >= step {
                position += step - carried
                carried = 0
                let f = position / length
                out.append(lerp(a, b, f))
                if !values.isEmpty { outValues.append(values[k - 1] + (values[k] - values[k - 1]) * Double(f)) }
            }
            carried += length - position
        }
        if carried > step * 0.05 || out.count == 1 {
            out.append(dense[dense.count - 1])
            if !values.isEmpty { outValues.append(values[values.count - 1]) }
        }
        return (out, outValues)
    }

    private static func curvature(_ p: [CGPoint], _ s: [Double]) -> [Double] {
        let n = p.count
        guard n >= 3 else { return Array(repeating: 0, count: n) }
        let angle = (0..<n).map { i in
            let a = p[max(i - 1, 0)], b = p[min(i + 1, n - 1)]
            return Double(atan2(b.y - a.y, b.x - a.x))
        }
        var raw = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            var d = angle[i + 1] - angle[i - 1]
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            raw[i] = abs(d) / max(s[i + 1] - s[i - 1], 1e-6)
        }
        raw[0] = raw[1]
        raw[n - 1] = raw[n - 2]
        let sigma = 0.6 / Double(step), radius = Int(sigma * 3)
        let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        return (0..<n).map { i in
            var sum = 0.0, weight = 0.0
            for (k, w) in kernel.enumerated() {
                let j = i + k - radius
                guard j >= 0, j < n else { continue }
                sum += raw[j] * w
                weight += w
            }
            return sum / weight
        }
    }

    /// 从 floor 平滑过渡到 1；d 是离起点（或终点）的距离。floor 大于 1 时是从粗收到正常。
    private static func ramp(_ d: Double, over length: Double, floor: Double) -> Double {
        guard length > 0 else { return 1 }
        let x = min(max(d / length, 0), 1)
        return floor + (1 - floor) * x * x * (3 - 2 * x)
    }

    /// 按全速 1 单位每秒算时间表，之后由 `scale` 换成真实速度。brush 为 nil 时是填充轮廓的遮罩笔。
    mutating func applyTiming(_ c: StrokeConfig, brush: Brush?, maskMargin: Double, seed: Int) {
        let total = length
        ratio = lengths.indices.map { i in
            let s = lengths[i]
            let ramp = Self.ramp(s, over: c.easeIn, floor: 0.3) * Self.ramp(total - s, over: c.easeOut, floor: 0.3)
            return max(ramp / (1 + c.cornering * curvature[i]), 0.03)
        }
        times = lengths.isEmpty ? [] : [0]
        for i in lengths.indices.dropFirst() {
            times.append(times[i - 1] + (lengths[i] - lengths[i - 1]) / (0.5 * (ratio[i - 1] + ratio[i])))
        }
        self.brush = brush?.id ?? ""
        guard let brush else {
            widths = half.map { 2 * ($0 + maskMargin) }
            bristles = []
            return
        }

        // 扁笔：笔锋是一条斜放的椭圆，宽度取它在行进方向法线上的投影
        let nibAngle = -brush.angle * .pi / 180
        let flat = min(max(brush.flatness, 0), 1)
        let base = brush.size * c.size
        // 短笔（点、小勾）起笔最多占三成、出锋最多占一半，不然整笔都落在出锋里，细成一根丝
        let (entryLength, entryWeight) = switch c.entry {
        case .brush: (brush.entry, brush.entryWeight)
        case .custom: (c.entryLength, c.entryWeight)
        case .flat: (0.0, 1.0)
        }
        let entry = min(entryLength, total * 0.3), exit = c.taperExit ? min(brush.exit, total * 0.5) : 0
        widths = lengths.indices.map { i in
            let s = lengths[i]
            let ends = Self.ramp(s, over: entry, floor: entryWeight)
                * Self.ramp(total - s, over: exit, floor: brush.exitWeight)
            let d = heading[i] - nibAngle
            let nib = (sin(d) * sin(d) + (1 - flat) * (1 - flat) * cos(d) * cos(d)).squareRoot()
            return max(base * ends * (1 + c.pressure * (1 - ratio[i])) * nib, base * 0.04)
        }

        // 飞白：笔毛沿弧长有一条平滑噪声，盖不过「干」的程度就断墨；越快、越靠后越干，边上的笔毛先断。
        // 噪声在相邻几根笔毛之间连续，断墨成片，露出来的是成条的白
        bristles = brush.bristles < 2 ? [] : (0..<brush.bristles).map { j in
            let position = (Double(j) + 0.5) / Double(brush.bristles) - 0.5
            let center = 1 - abs(2 * position)
            let across = Double(j) / 3, group = Int(across.rounded(.down)), blend = across - Double(group)
            let ink = seed &* 7919 &+ group &* 104_729, wobble = seed &* 7919 &+ j &* 15_485_863 &+ 1
            var offset: [Double] = [], visible: [Bool] = []
            offset.reserveCapacity(lengths.count)
            visible.reserveCapacity(lengths.count)
            for i in lengths.indices {
                let s = lengths[i]
                offset.append(position * 0.92 + brush.roughness * 0.24 * (noise(s / 0.8, seed: wobble) - 0.5))
                let dry = brush.dryness * (0.25 + 0.45 * ratio[i] + 0.3 * s / max(total, 1e-6))
                let streak = noise(s / 3, seed: ink) * (1 - blend) + noise(s / 3, seed: ink &+ 104_729) * blend
                visible.append(0.6 * streak + 0.4 * center >= dry)
            }
            return Bristle(offset: offset, visible: visible)
        }
    }

    mutating func scale(_ k: Double) {
        times = times.map { $0 * k }
    }

    /// 落笔后经过 time 秒写到的长度。
    func distance(at time: Double) -> Double {
        guard time > 0, times.count > 1 else { return 0 }
        guard time < duration else { return length }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid } else { hi = mid }
        }
        let f = (time - times[lo]) / max(times[hi] - times[lo], 1e-9)
        return lengths[lo] + f * (lengths[hi] - lengths[lo])
    }

    /// 长度 s 落在第 i 段（i 到 i+1）的 f 处。
    func locate(_ s: Double) -> (Int, Double) {
        let n = points.count
        guard n > 1 else { return (0, 0) }
        var i = min(max(Int(s / Double(Self.step)), 0), n - 2)
        while i < n - 2, lengths[i + 1] < s { i += 1 }
        while i > 0, lengths[i] > s { i -= 1 }
        let f = (s - lengths[i]) / max(lengths[i + 1] - lengths[i], 1e-9)
        return (i, min(max(f, 0), 1))
    }

    func sample(_ i: Int, _ f: Double) -> Sample {
        guard i + 1 < points.count else { return Sample(point: points[i], width: widths[i], ratio: ratio[i], index: i) }
        return Sample(point: lerp(points[i], points[i + 1], f),
                      width: widths[i] + (widths[i + 1] - widths[i]) * f,
                      ratio: ratio[i] + (ratio[i + 1] - ratio[i]) * f,
                      index: f < 0.5 ? i : i + 1)
    }

    /// 区间两端插值，中间取原采样点。
    func samples(_ span: ClosedRange<Double>) -> [Sample] {
        let (ia, fa) = locate(span.lowerBound), (ib, fb) = locate(span.upperBound)
        var out = [sample(ia, fa)]
        if ib > ia {
            for i in (ia + 1)...ib { out.append(Sample(point: points[i], width: widths[i], ratio: ratio[i], index: i)) }
        }
        out.append(sample(ib, fb))
        return out
    }

    func point(at s: Double) -> CGPoint {
        let (i, f) = locate(s)
        return sample(i, f).point
    }
}

/// 墨迹在某一刻的状态：每笔画出的区间、整体不透明度、正在写的笔尖。
struct Ink {
    var spans: [ClosedRange<Double>?]
    var opacity = 1.0
    var head: (track: Int, distance: Double)?
    /// 所有笔都写完了：填充轮廓不再套遮罩，免得遮罩没盖到的边角缺一块。
    var complete = false
}

struct Plan {
    enum Mode { case line, traced, guided }

    var mode: Mode
    /// 单线和引导线时与 SVG 里的描边子路径一一对应；自动排路线时与连通块一一对应。
    var tracks: [Track]
    /// 要写的笔，按书写先后。
    var order: [Int]
    /// 每笔是第几个写的（从 0 起）；不写的笔为 nil。
    var position: [Int?]
    /// 每笔落笔的时刻；不写的笔为 nil。
    var starts: [Double?]
    /// 直线全速，viewBox 单位每秒，不含各笔自己的速度倍数。
    var speed: Double
    var lead: Double
    var writeEnd: Double
    var holdEnd: Double
    var total: Double
    var exit: Params.Exit

    init(logo: Logo, outline: Outline?, params p: Params) {
        if let outline, !logo.fills.isEmpty {
            if logo.strokes.isEmpty {
                mode = .traced
                tracks = outline.components.indices.map { c in
                    let route = outline.route(c, pick: p.stroke(c).startPick)
                    var track = Track(dense: route.points, half: route.half, reversed: p.stroke(c).reversed)
                    track.startOptions = route.options
                    return track
                }
            } else {
                mode = .guided
                let reach = Int((outline.typicalRadius * Double(outline.scale)).rounded()) + 1
                tracks = logo.strokes.enumerated().map { k, stroke in
                    let dense = stroke.dense
                    return Track(dense: dense, half: dense.map { outline.halfWidth(at: $0, radius: reach) }, reversed: p.stroke(k).reversed)
                }
            }
        } else {
            mode = .line
            tracks = logo.strokes.enumerated().map { Track(dense: $1.dense, reversed: p.stroke($0).reversed) }
        }
        let line = mode == .line
        for k in tracks.indices {
            let c = p.stroke(k)
            tracks[k].applyTiming(c, brush: line ? Brush.named(c.brush) : nil, maskMargin: p.maskMargin, seed: k)
        }
        let tracks = tracks
        order = p.writingOrder(count: tracks.count).filter { p.stroke($0).enabled && tracks[$0].points.count > 1 }
        let natural = order.reduce(0.0) { $0 + tracks[$1].duration / max(p.stroke($1).speed, 0.01) }
        speed = p.timing == .speed ? max(p.speed, 0.01) : (natural > 0 ? natural / max(p.writeDuration, 0.01) : 1)
        for k in self.tracks.indices { self.tracks[k].scale(1 / (speed * max(p.stroke(k).speed, 0.01))) }

        position = Array(repeating: nil, count: tracks.count)
        starts = Array(repeating: nil, count: tracks.count)
        var t = p.lead
        for (n, k) in order.enumerated() {
            if n > 0 { t += p.stroke(k).pause }
            position[k] = n
            starts[k] = t
            t += self.tracks[k].duration
        }
        lead = p.lead
        writeEnd = t
        holdEnd = t + p.hold
        exit = p.exit
        total = holdEnd + (p.exit == .stay ? 0 : p.exitDuration)
    }

    private func written(at t: Double) -> [ClosedRange<Double>?] {
        tracks.indices.map { k in
            guard let start = starts[k], t > start else { return nil }
            return 0...tracks[k].distance(at: t - start)
        }
    }

    func ink(at t: Double) -> Ink {
        let everything = order.count == tracks.count
        if t < holdEnd || exit == .stay {
            var ink = Ink(spans: written(at: t), complete: everything && t >= writeEnd)
            if let k = order.first(where: { t >= starts[$0]! && t < starts[$0]! + tracks[$0].duration }) {
                ink.head = (k, tracks[k].distance(at: t - starts[k]!))
            }
            return ink
        }
        let x = min(max((t - holdEnd) / max(total - holdEnd, 1e-6), 0), 1)
        let e = x * x * (3 - 2 * x)
        switch exit {
        case .stay, .fade:
            return Ink(spans: written(at: holdEnd), opacity: 1 - e, complete: everything)
        case .unwrite:
            return Ink(spans: written(at: lead + (writeEnd - lead) * (1 - e)))
        case .erase:
            let erased = written(at: lead + (writeEnd - lead) * e)
            return Ink(spans: tracks.indices.map { k in
                guard starts[k] != nil else { return nil }
                let from = erased[k]?.upperBound ?? 0
                return from < tracks[k].length ? from...tracks[k].length : nil
            })
        }
    }

    func phase(at t: Double) -> String {
        if t < lead { return "开始前" }
        for k in order {
            let start = starts[k]!
            if t < start { return "笔间停顿" }
            if t < start + tracks[k].duration { return "第 \(position[k]! + 1) 笔" }
        }
        if t < holdEnd { return "停留" }
        if t < total { return exit.title }
        return "结束"
    }
}

// MARK: - 绘制

enum Renderer {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.12) : Color(white: 0.985)
    }

    static func ink(_ p: Params, _ scheme: ColorScheme) -> Color {
        if p.customInk { return Color(.sRGB, red: p.inkR, green: p.inkG, blue: p.inkB) }
        return scheme == .dark ? Color(white: 0.95) : Color(white: 0.1)
    }

    /// 慢是红，快是蓝。
    static func heat(_ r: Double) -> Color {
        Color(hue: 0.6 * min(max(r, 0), 1), saturation: 0.75, brightness: 0.9)
    }

    /// 把 box 放进 size 里居中，返回变换和每单位多少点。
    static func fit(_ box: CGRect, in size: CGSize, padding: CGFloat, zoom: Double) -> (CGAffineTransform, CGFloat)? {
        let area = CGRect(origin: .zero, size: size).insetBy(dx: padding, dy: padding)
        guard box.width > 0, box.height > 0, area.width > 0, area.height > 0 else { return nil }
        let k = min(area.width / box.width, area.height / box.height) * zoom
        return (CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: area.midX - box.midX * k, ty: area.midY - box.midY * k), k)
    }

    /// 离 point（视图坐标）最近的一笔。
    static func nearest(_ point: CGPoint, plan: Plan, transform m: CGAffineTransform) -> Int? {
        let q = point.applying(m.inverted())
        var best: (track: Int, distance: CGFloat)?
        for (k, track) in plan.tracks.enumerated() {
            for i in stride(from: 0, to: track.points.count, by: 4) {
                let d = pointDistance(track.points[i], q)
                if best == nil || d < best!.distance { best = (k, d) }
            }
        }
        return best?.track
    }

    static func draw(_ ctx: GraphicsContext, size: CGSize, logo: Logo, plan: Plan, params p: Params,
                     time: Double, padding: CGFloat, stage: Bool, selected: Int?, ink: Color) {
        guard let (m, k) = fit(logo.viewBox, in: size, padding: padding, zoom: stage ? p.zoom : 1) else { return }
        let accent = Color.accentColor
        let filled = plan.mode != .line

        if stage && p.bounds {
            ctx.stroke(Path(logo.viewBox.applying(m)), with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        if stage && p.ghost {
            if filled {
                for f in logo.fills { ctx.fill(f.path.applying(m), with: .color(ink.opacity(0.12)), style: FillStyle(eoFill: f.evenOdd)) }
            } else {
                for track in plan.tracks where track.points.count > 1 {
                    drawSolid(track, 0...track.length, in: ctx, transform: m, scale: k, color: ink.opacity(0.12), heat: false)
                }
            }
        }

        let state = plan.ink(at: time)
        var layer = ctx
        layer.opacity = state.opacity
        layer.drawLayer { layer in
            if filled {
                if !state.complete {
                    layer.clipToLayer { mask in
                        for (index, span) in state.spans.enumerated() {
                            guard let span else { continue }
                            drawSolid(plan.tracks[index], span, in: mask, transform: m, scale: k, color: .black, heat: false)
                        }
                    }
                }
                for f in logo.fills { layer.fill(f.path.applying(m), with: .color(ink), style: FillStyle(eoFill: f.evenOdd)) }
            } else {
                for (index, span) in state.spans.enumerated() {
                    guard let span else { continue }
                    drawInk(plan.tracks[index], span, in: layer, transform: m, scale: k, color: ink, heat: p.speedColor)
                }
            }
        }

        guard stage else { return }
        if filled && (p.centerline || p.speedColor) {
            for index in plan.order {
                let track = plan.tracks[index]
                drawSolid(track, 0...track.length, in: ctx, transform: m, scale: k, color: accent, heat: p.speedColor, fixedWidth: 1.5)
            }
        }
        if p.handles {
            var lines = Path(), controls = Path(), anchors = Path()
            for stroke in logo.strokes + logo.fills.flatMap(\.subpaths) {
                for s in stroke.segments {
                    let p0 = s.p0.applying(m), c1 = s.c1.applying(m), c2 = s.c2.applying(m), p3 = s.p3.applying(m)
                    lines.move(to: p0); lines.addLine(to: c1)
                    lines.move(to: p3); lines.addLine(to: c2)
                    for c in [c1, c2] { controls.addEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)) }
                    for a in [p0, p3] { anchors.addRect(CGRect(x: a.x - 2.5, y: a.y - 2.5, width: 5, height: 5)) }
                }
            }
            ctx.stroke(lines, with: .color(accent.opacity(0.55)), lineWidth: 1)
            ctx.fill(controls, with: .color(accent))
            ctx.fill(anchors, with: .color(background(.light)))
            ctx.stroke(anchors, with: .color(accent), lineWidth: 1)
        }
        if let selected, plan.tracks.indices.contains(selected), plan.tracks[selected].points.count > 1 {
            let track = plan.tracks[selected]
            drawSolid(track, 0...track.length, in: ctx, transform: m, scale: k, color: accent.opacity(0.8), heat: false, fixedWidth: 1.5)
            drawStart(track, label: "#\(selected + 1)", in: ctx, transform: m, color: accent)
        }
        if p.showStarts {
            for index in plan.order where index != selected {
                drawStart(plan.tracks[index], label: "\(plan.position[index]! + 1)", in: ctx, transform: m, color: .orange)
            }
        }
        if p.head, let head = state.head {
            let c = plan.tracks[head.track].point(at: head.distance).applying(m)
            let r = p.headSize
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(accent))
        }
        if p.speedColor {
            let bar = CGRect(x: 16, y: size.height - 24, width: 96, height: 6)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 3),
                     with: .linearGradient(Gradient(colors: stride(from: 0.0, through: 1, by: 0.25).map(heat)),
                                           startPoint: CGPoint(x: bar.minX, y: 0), endPoint: CGPoint(x: bar.maxX, y: 0)))
            ctx.draw(Text("慢").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: bar.minX, y: bar.minY - 9), anchor: .leading)
            ctx.draw(Text("快").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: bar.maxX, y: bar.minY - 9), anchor: .trailing)
        }
    }

    /// 起点圆点加一支顺着书写方向的箭头。
    private static func drawStart(_ track: Track, label: String, in ctx: GraphicsContext, transform m: CGAffineTransform, color: Color) {
        guard let first = track.points.first else { return }
        let a = first.applying(m)
        let b = track.point(at: min(1.5, track.length)).applying(m)
        let len = pointDistance(a, b)
        guard len > 0 else { return }
        let dx = (b.x - a.x) / len, dy = (b.y - a.y) / len
        let tip = CGPoint(x: a.x + dx * 20, y: a.y + dy * 20)
        var arrow = Path()
        arrow.move(to: a)
        arrow.addLine(to: tip)
        arrow.move(to: CGPoint(x: tip.x - dx * 6 - dy * 4, y: tip.y - dy * 6 + dx * 4))
        arrow.addLine(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - dx * 6 + dy * 4, y: tip.y - dy * 6 - dx * 4))
        ctx.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: a.x - 3, y: a.y - 3, width: 6, height: 6)), with: .color(color))
        ctx.draw(Text(label).font(.caption.bold()).foregroundStyle(color), at: CGPoint(x: a.x - dx * 14, y: a.y - dy * 14))
    }

    /// 单线的墨迹：有笔毛的笔刷按笔毛画，按速度上色时一律画实心。
    static func drawInk(_ track: Track, _ span: ClosedRange<Double>, in ctx: GraphicsContext,
                        transform m: CGAffineTransform, scale k: CGFloat, color: Color, heat: Bool) {
        if heat || track.bristles.isEmpty {
            drawSolid(track, span, in: ctx, transform: m, scale: k, color: color, heat: heat)
        } else {
            // 笔芯垫底，越干越窄
            let core = 1 - 0.8 * (Brush.named(track.brush).dryness)
            drawSolid(track, span, in: ctx, transform: m, scale: k, color: color, heat: false, widthScale: core)
            drawBristles(track, span, in: ctx, transform: m, scale: k, color: color)
        }
    }

    /// 宽度（半点一档）和颜色按档位分段，同一档的连续采样合成一条圆头折线描一次。
    private static func drawSolid(_ track: Track, _ span: ClosedRange<Double>, in ctx: GraphicsContext,
                                  transform m: CGAffineTransform, scale k: CGFloat,
                                  color: Color, heat useHeat: Bool, fixedWidth: CGFloat? = nil, widthScale: Double = 1) {
        guard !track.points.isEmpty else { return }
        let samples = track.samples(span)
        func stroke(_ path: Path, _ w: Int, _ c: Int) {
            let lineWidth = fixedWidth ?? max(CGFloat(w) / 2, 0.1)
            ctx.stroke(path, with: .color(c < 0 ? color : heat(Double(c) / 12)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        var run = Path()
        var runW = 0, runC = 0
        for (j, s) in samples.enumerated() {
            let point = s.point.applying(m)
            let w = fixedWidth == nil ? Int((s.width * widthScale * k * 2).rounded()) : 0
            let c = useHeat ? Int((s.ratio * 12).rounded()) : -1
            if j == 0 {
                run.move(to: point)
                runW = w; runC = c
                continue
            }
            run.addLine(to: point)
            if w != runW || c != runC || j == samples.count - 1 {
                stroke(run, runW, runC)
                run = Path()
                run.move(to: point)
                runW = w; runC = c
            }
        }
    }

    /// 每根笔毛是一条细圆头线，沿笔宽法线方向排开、彼此搭叠；断墨处断开。
    private static func drawBristles(_ track: Track, _ span: ClosedRange<Double>, in ctx: GraphicsContext,
                                     transform m: CGAffineTransform, scale k: CGFloat, color: Color) {
        guard !track.points.isEmpty else { return }
        let samples = track.samples(span)
        let share = 1.6 / Double(track.bristles.count)
        for bristle in track.bristles {
            var run = Path()
            var runW = 0, open = false
            func flush() {
                if open {
                    ctx.stroke(run, with: .color(color),
                               style: StrokeStyle(lineWidth: max(CGFloat(runW) / 2, 0.1), lineCap: .round, lineJoin: .round))
                }
                open = false
            }
            for s in samples {
                guard bristle.visible[s.index] else { flush(); continue }
                let theta = track.heading[s.index], off = bristle.offset[s.index] * s.width
                let point = CGPoint(x: s.point.x - CGFloat(sin(theta) * off), y: s.point.y + CGFloat(cos(theta) * off)).applying(m)
                let w = Int((s.width * share * k * 2).rounded())
                if !open {
                    run = Path()
                    run.move(to: point)
                    runW = w
                    open = true
                    continue
                }
                run.addLine(to: point)
                if w != runW {
                    flush()
                    run = Path()
                    run.move(to: point)
                    runW = w
                    open = true
                }
            }
            flush()
        }
    }
}

// MARK: - 模型

@MainActor @Observable
final class Model {
    enum Pane: String, CaseIterable { case rhythm = "节奏", strokes = "笔画", display = "显示" }

    var params: Params { didSet { if persist { save() } } }
    /// 快照模式临时改参数，不写回偏好。
    @ObservationIgnored var persist = true
    private(set) var url: URL
    private(set) var logo: Logo?
    private(set) var error: String?
    private(set) var version = 0
    var pane = Pane.strokes
    /// 笔画页里正在调的那一笔。
    var selected = 0
    var playing = true
    var anchorTime = 0.0
    var anchorDate = Date()
    @ObservationIgnored private var stamp: Date?
    @ObservationIgnored private var cache: (params: Params, version: Int, plan: Plan)?
    @ObservationIgnored private var outlineCache: (version: Int, gap: Double, outline: Outline?)?

    init() {
        let defaults = UserDefaults.standard
        params = defaults.data(forKey: "params").flatMap(Params.decode) ?? Params()
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/line-logo.svg")
        let candidates = [defaults.string(forKey: "svgPath").map { URL(fileURLWithPath: $0) }, desktop,
                          Bundle.main.url(forResource: "line-logo", withExtension: "svg")]
        url = candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) } ?? desktop
        load()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                if self.modification() != self.stamp { self.load() }
            }
        }
    }

    /// 填充轮廓的骨架，随文件和「合并缝隙」重算。
    var outline: Outline? {
        guard let logo, !logo.fills.isEmpty else { return nil }
        if let outlineCache, outlineCache.version == version, outlineCache.gap == params.gap { return outlineCache.outline }
        let outline = Outline(fills: logo.fills, gap: params.gap)
        outlineCache = (version, params.gap, outline)
        return outline
    }

    var plan: Plan? {
        guard let logo else { return nil }
        if let cache, cache.params == params, cache.version == version { return cache.plan }
        let plan = Plan(logo: logo, outline: outline, params: params)
        cache = (params, version, plan)
        return plan
    }

    private func modification() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func load() {
        stamp = modification()
        do {
            logo = try SVG.parse(String(contentsOf: url, encoding: .utf8))
            version += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ url: URL, remember: Bool = true) {
        self.url = url
        if remember { UserDefaults.standard.set(url.path, forKey: "svgPath") }
        load()
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.directoryURL = url.deletingLastPathComponent()
        if panel.runModal() == .OK, let picked = panel.url { open(picked) }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(params), forKey: "params")
    }

    func copyParams() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(params), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // 笔画

    func updateStroke(_ k: Int, _ change: (inout StrokeConfig) -> Void) {
        var p = params
        while p.strokes.count <= k { p.strokes.append(StrokeConfig()) }
        change(&p.strokes[k])
        params = p
    }

    func strokeBinding<T>(_ k: Int, _ key: WritableKeyPath<StrokeConfig, T>) -> Binding<T> {
        Binding(get: { self.params.stroke(k)[keyPath: key] },
                set: { value in self.updateStroke(k) { $0[keyPath: key] = value } })
    }

    /// 在书写顺序里把第 k 笔前移（-1）或后移（+1）一位。
    func move(_ k: Int, by delta: Int, count n: Int) {
        var order = params.writingOrder(count: n)
        guard let i = order.firstIndex(of: k), order.indices.contains(i + delta) else { return }
        order.swapAt(i, i + delta)
        params.order = order
    }

    /// 把第 k 笔的笔刷、粗细和节奏用到所有笔画；写不写、反向、起笔端点各笔保留自己的。
    func applyToAll(from k: Int, count n: Int) {
        let source = params.stroke(k)
        var p = params
        for j in 0..<n {
            while p.strokes.count <= j { p.strokes.append(StrokeConfig()) }
            var c = source
            c.enabled = p.strokes[j].enabled
            c.reversed = p.strokes[j].reversed
            c.startPick = p.strokes[j].startPick
            p.strokes[j] = c
        }
        params = p
    }

    // 播放：暂停时停在 anchorTime；播放时从 anchorDate 起按速率往前走。

    func time(at date: Date) -> Double {
        let total = plan?.total ?? 0
        guard playing else { return min(anchorTime, total) }
        let t = anchorTime + date.timeIntervalSince(anchorDate) * params.rate
        if params.loop { return total > 0 ? t.truncatingRemainder(dividingBy: total) : 0 }
        return min(t, total)
    }

    func atEnd(_ t: Double) -> Bool {
        !params.loop && t >= (plan?.total ?? 0)
    }

    func playPause() {
        let now = Date(), t = time(at: now)
        if atEnd(t) {
            restart()
        } else if playing {
            anchorTime = t
            playing = false
        } else {
            anchorTime = t
            anchorDate = now
            playing = true
        }
    }

    func restart() {
        anchorTime = 0
        anchorDate = Date()
        playing = true
    }

    func scrub(to t: Double) {
        playing = false
        anchorTime = min(max(t, 0), plan?.total ?? 0)
    }

    /// 改速率或循环前先把当前时刻定下来，免得画面跳。
    private func reanchor() {
        let now = Date()
        anchorTime = time(at: now)
        anchorDate = now
    }

    var rate: Double {
        get { params.rate }
        set { reanchor(); params.rate = newValue }
    }

    var loop: Bool {
        get { params.loop }
        set { reanchor(); params.loop = newValue }
    }
}

// MARK: - 界面

struct LogoCanvas: View {
    let logo: Logo
    let plan: Plan
    let params: Params
    let time: Double
    var stage = false
    var selected: Int?
    var padding: CGFloat = 4
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Renderer.ink(params, scheme)
        Canvas { ctx, size in
            Renderer.draw(ctx, size: size, logo: logo, plan: plan, params: params, time: time,
                          padding: padding, stage: stage, selected: selected, ink: ink)
        }
    }
}

struct StageArea: View {
    let logo: Logo
    let plan: Plan
    let params: Params
    let time: Double
    let selected: Int?
    let select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                LogoCanvas(logo: logo, plan: plan, params: params, time: time, stage: true, selected: selected, padding: 48)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let (m, _) = Renderer.fit(logo.viewBox, in: geo.size, padding: 48, zoom: params.zoom),
                              let k = Renderer.nearest(location, plan: plan, transform: m) else { return }
                        select(k)
                    }
            }
            HStack(alignment: .bottom, spacing: 28) {
                ForEach([20.0, 34.0, 68.0], id: \.self) { h in
                    VStack(spacing: 6) {
                        LogoCanvas(logo: logo, plan: plan, params: params, time: time)
                            .frame(width: h * logo.viewBox.width / logo.viewBox.height + 8, height: h + 8)
                        Text("高 \(Int(h)) pt").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Renderer.background(scheme))
    }
}

struct BackdropScheme: ViewModifier {
    let mode: Params.Backdrop
    @Environment(\.colorScheme) private var system

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, mode == .light ? .light : mode == .dark ? .dark : system)
    }
}

/// 样张：同一条 S 形曲线按这一笔的笔刷和起收笔、转弯加粗设置写满。
struct BrushPreview: View {
    let config: StrokeConfig
    let params: Params
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Renderer.ink(params, scheme)
        Canvas { ctx, size in
            let curve = Stroke(segments: [Cubic(p0: CGPoint(x: 2, y: 16), c1: CGPoint(x: 14, y: -6),
                                                c2: CGPoint(x: 30, y: 30), p3: CGPoint(x: 46, y: 6))])
            var track = Track(dense: curve.dense, reversed: false)
            track.applyTiming(config, brush: Brush.named(config.brush), maskMargin: 0, seed: 0)
            guard let (m, k) = Renderer.fit(CGRect(x: 0, y: 0, width: 48, height: 22), in: size, padding: 10, zoom: 1) else { return }
            Renderer.drawInk(track, 0...track.length, in: ctx, transform: m, scale: k, color: ink, heat: false)
        }
        .frame(height: 72)
        .background(Renderer.background(scheme), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TimelineBar: View {
    let plan: Plan
    let time: Double
    let scrub: (Double) -> Void
    private let barHeight: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    scrub(Double(value.location.x / max(geo.size.width, 1)) * plan.total)
                })
        }
        .frame(height: barHeight + 18)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let total = max(plan.total, 1e-6)
        func x(_ t: Double) -> CGFloat { CGFloat(t / total) * size.width }
        func block(_ a: Double, _ b: Double, _ color: Color, _ label: String) {
            let r = CGRect(x: x(a), y: 0, width: max(x(b) - x(a), 0), height: barHeight)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color))
            if r.width > 40 {
                ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: r.midX, y: 9))
            }
        }

        ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: barHeight), cornerRadius: 4),
                 with: .color(.gray.opacity(0.08)))
        if plan.lead > 0 { block(0, plan.lead, .gray.opacity(0.14), "开始前") }
        for k in plan.order {
            let start = plan.starts[k]!, track = plan.tracks[k]
            block(start, start + track.duration, Color.accentColor.opacity(0.2), "第 \(plan.position[k]! + 1) 笔")
            // 速度曲线：越高越快
            var line = Path()
            let every = max(track.times.count / 300, 1)
            for i in stride(from: 0, to: track.times.count, by: every) {
                let p = CGPoint(x: x(start + track.times[i]), y: barHeight - 3 - (barHeight - 18) * track.ratio[i])
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.2)
        }
        if plan.holdEnd > plan.writeEnd { block(plan.writeEnd, plan.holdEnd, .gray.opacity(0.18), "停留") }
        if plan.total > plan.holdEnd { block(plan.holdEnd, plan.total, .orange.opacity(0.2), plan.exit.title) }

        let tick = total > 8 ? 1.0 : total > 3 ? 0.5 : 0.25
        for t in stride(from: 0.0, through: total + 1e-9, by: tick) {
            let major = abs(t.rounded() - t) < 1e-9
            ctx.fill(Path(CGRect(x: x(t) - 0.5, y: barHeight + 2, width: 1, height: major ? 5 : 3)), with: .color(.gray.opacity(0.6)))
            if major {
                ctx.draw(Text("\(Int(t.rounded())) s").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: min(max(x(t), 10), size.width - 10), y: barHeight + 13))
            }
        }
        ctx.fill(Path(CGRect(x: x(time) - 1, y: 0, width: 2, height: barHeight + 4)), with: .color(.primary))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var digits = 2
    var help = ""

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: range).controlSize(.small)
                TextField("", value: $value, format: .number.precision(.fractionLength(digits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
            }
        } label: {
            Text(title)
        }
        .help(help)
    }
}

struct Inspector: View {
    @Bindable var model: Model

    var body: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $model.pane) {
                ForEach(Model.Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            Form {
                switch model.pane {
                case .rhythm: rhythm
                case .strokes: strokes
                case .display: display
                }
            }
            .formStyle(.grouped)
        }
    }

    private var modeTitle: String {
        switch model.plan?.mode {
        case .line: "单线"
        case .traced: "填充轮廓，自动排书写路线"
        case .guided: "填充轮廓，按描边路径写"
        case nil: "—"
        }
    }

    // MARK: 节奏

    @ViewBuilder private var rhythm: some View {
        Section("文件") {
            Text((model.url.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle).help(model.url.path)
            HStack {
                Button("打开…") { model.choose() }
                Button("重新载入") { model.load() }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if let logo = model.logo, let plan = model.plan {
                LabeledContent("类型", value: modeTitle)
                LabeledContent("笔画", value: String(format: "%d 笔，共长 %.1f", plan.tracks.count,
                                                     plan.tracks.reduce(0) { $0 + $1.length }))
                let b = logo.viewBox
                LabeledContent("viewBox", value: String(format: "%g %g %g %g", b.minX, b.minY, b.width, b.height))
            }
            Text("文件保存后自动重新载入，也可以把 SVG 拖进左边。")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("节奏") {
            Picker("计时", selection: $model.params.timing) {
                Text("按速度").tag(Params.Timing.speed)
                Text("按总时长").tag(Params.Timing.duration)
            }
            .pickerStyle(.segmented)
            if model.params.timing == .speed {
                SliderRow(title: "速度（单位/秒）", value: $model.params.speed, range: 10...600, digits: 0,
                          help: "直线上的全速，单位是 viewBox 单位；各笔再乘自己的速度倍数")
            } else {
                SliderRow(title: "书写时长（秒）", value: $model.params.writeDuration, range: 0.2...8,
                          help: "要写的笔加起来用的时间，不含笔间停顿；各笔之间按速度倍数分快慢")
            }
            if let plan = model.plan {
                let written = plan.order.reduce(0.0) { $0 + plan.tracks[$1].duration }
                LabeledContent("实际", value: String(format: "写 %.2f 秒，全速 %.0f 单位/秒", written, plan.speed))
            }
            SliderRow(title: "开始前（秒）", value: $model.params.lead, range: 0...3)
            SliderRow(title: "写完停留（秒）", value: $model.params.hold, range: 0...5)
            Picker("结束", selection: $model.params.exit) {
                ForEach(Params.Exit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if model.params.exit != .stay {
                SliderRow(title: "结束时长（秒）", value: $model.params.exitDuration, range: 0.05...3)
            }
        }

        if let plan = model.plan, plan.mode != .line {
            Section("填充轮廓") {
                SliderRow(title: "合并缝隙（单位）", value: $model.params.gap, range: 0...2,
                          help: "排路线前把比这窄的缝隙补上，原本连着写却在形状上断开的地方就能接成一笔")
                SliderRow(title: "遮罩余量（单位）", value: $model.params.maskMargin, range: 0...1.5,
                          help: "显露用的圆头笔比局部半笔宽多出的量；太小边缘会慢半拍，太大会提前露出旁边的笔画")
                Text("笔宽由形状决定，笔刷不起作用。写完以后去掉遮罩，整个形状完整显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 笔画

    @ViewBuilder private var strokes: some View {
        if let plan = model.plan, !plan.tracks.isEmpty {
            let all = model.params.writingOrder(count: plan.tracks.count)
            Section("书写顺序") {
                ForEach(Array(all.enumerated()), id: \.element) { n, k in
                    orderRow(plan, n, k, last: all.count - 1)
                }
                Text("点一行或点画布上的笔画选中它，下面调它自己的设置。#号是它在 SVG 里的先后。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            strokeSettings(plan, min(max(model.selected, 0), plan.tracks.count - 1))
        }
    }

    private func orderRow(_ plan: Plan, _ n: Int, _ k: Int, last: Int) -> some View {
        let track = plan.tracks[k]
        let config = model.params.stroke(k)
        let detail = plan.starts[k] == nil
            ? String(format: "长 %.1f · 不写", track.length)
            : String(format: "长 %.1f · %.2f 秒", track.length, track.duration)
        return HStack(spacing: 8) {
            Text("\(n + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
            Toggle("写", isOn: model.strokeBinding(k, \.enabled)).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.mode == .line ? "#\(k + 1) · \(Brush.named(config.brush).name)" : "#\(k + 1)")
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button { model.move(k, by: -1, count: plan.tracks.count) } label: { Image(systemName: "chevron.up") }
                .disabled(n == 0)
            Button { model.move(k, by: 1, count: plan.tracks.count) } label: { Image(systemName: "chevron.down") }
                .disabled(n == last)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(k == model.selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.selected = k }
    }

    @ViewBuilder private func strokeSettings(_ plan: Plan, _ k: Int) -> some View {
        Section("#\(k + 1) 的设置") {
            if plan.mode == .line {
                Picker("笔刷", selection: model.strokeBinding(k, \.brush)) {
                    ForEach(Brush.presets) { Text($0.name).tag($0.id) }
                }
                BrushPreview(config: model.params.stroke(k), params: model.params)
                Picker("起笔", selection: Binding(
                    get: { model.params.stroke(k).entry },
                    set: { mode in
                        model.updateStroke(k) { c in
                            // 刚切到自定义时从笔刷原来的起笔出发
                            if mode == .custom && c.entry != .custom {
                                let brush = Brush.named(c.brush)
                                c.entryLength = brush.entry > 0 ? brush.entry : 2
                                c.entryWeight = brush.entry > 0 ? brush.entryWeight : 0.5
                            }
                            c.entry = mode
                        }
                    })) {
                    Text("跟随笔刷").tag(StrokeConfig.Entry.brush)
                    Text("自定义").tag(StrokeConfig.Entry.custom)
                    Text("平起").tag(StrokeConfig.Entry.flat)
                }
                .pickerStyle(.segmented)
                if model.params.stroke(k).entry == .custom {
                    SliderRow(title: "起笔长度（单位）", value: model.strokeBinding(k, \.entryLength), range: 0...20, digits: 1,
                              help: "落笔后在这段长度内从起笔粗细过渡到正常；短笔最多占全长三成")
                    SliderRow(title: "起笔粗细", value: model.strokeBinding(k, \.entryWeight), range: 0...3,
                              help: "落笔那一下是正常粗细的几倍：小于 1 是尖起露锋，大于 1 是顿笔")
                }
                Toggle("收笔出锋", isOn: model.strokeBinding(k, \.taperExit))
                    .help("关掉以后这一笔收尾不变细，保持原来的粗细")
                SliderRow(title: "转弯加粗", value: model.strokeBinding(k, \.pressure), range: 0...3,
                          help: "写得越慢越粗：笔宽乘 1 + 这个值 ×（1 − 速度比）。转弯减速让转弯处变慢，所以那里最明显；0 就是不加粗")
                SliderRow(title: "粗细倍数", value: model.strokeBinding(k, \.size), range: 0.2...3)
            }
            SliderRow(title: "速度倍数", value: model.strokeBinding(k, \.speed), range: 0.2...3,
                      help: "在全局速度上再乘这个数")
            SliderRow(title: "转弯减速", value: model.strokeBinding(k, \.cornering), range: 0...10,
                      help: "速度按 1 / (1 + 这个值 × 曲率) 降，0 就是匀速")
            SliderRow(title: "起笔加速（单位）", value: model.strokeBinding(k, \.easeIn), range: 0...40, digits: 1,
                      help: "落笔后这段距离内从 0.3 倍速加到全速")
            SliderRow(title: "收笔减速（单位）", value: model.strokeBinding(k, \.easeOut), range: 0...40, digits: 1,
                      help: "收笔前这段距离内从全速降到 0.3 倍速")
            SliderRow(title: "落笔前停顿（秒）", value: model.strokeBinding(k, \.pause), range: 0...2,
                      help: "上一笔写完到这一笔落笔之间停多久，第一笔不算")
            Toggle("反向", isOn: model.strokeBinding(k, \.reversed))
            if plan.mode == .traced && plan.tracks[k].startOptions > 1 {
                let options = plan.tracks[k].startOptions
                let pick = model.params.stroke(k).startPick
                HStack {
                    Text("起笔端点 \(pick % options + 1) / \(options)").foregroundStyle(.secondary)
                    Spacer()
                    Button("换一个") { model.updateStroke(k) { $0.startPick = (pick + 1) % options } }
                        .controlSize(.small)
                }
            }
            Button("把这些设置用到所有笔画") { model.applyToAll(from: k, count: plan.tracks.count) }
                .help("笔刷、粗细和节奏都照这一笔；写不写、反向、起笔端点各笔保留自己的")
        }
    }

    // MARK: 显示

    @ViewBuilder private var display: some View {
        Section("画面") {
            Picker("背景", selection: $model.params.backdrop) {
                Text("跟随").tag(Params.Backdrop.system)
                Text("浅").tag(Params.Backdrop.light)
                Text("深").tag(Params.Backdrop.dark)
            }
            .pickerStyle(.segmented)
            SliderRow(title: "缩放", value: $model.params.zoom, range: 0.3...4)
            Toggle("自定墨色", isOn: $model.params.customInk)
            if model.params.customInk {
                ColorPicker("墨色", selection: Binding(
                    get: { Color(.sRGB, red: model.params.inkR, green: model.params.inkG, blue: model.params.inkB) },
                    set: { color in
                        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
                        model.params.inkR = c.redComponent
                        model.params.inkG = c.greenComponent
                        model.params.inkB = c.blueComponent
                    }), supportsOpacity: false)
            }
        }
        Section("辅助") {
            Toggle("底稿", isOn: $model.params.ghost)
            if model.plan?.mode != .line {
                Toggle("书写路线", isOn: $model.params.centerline)
            }
            Toggle("各笔起点和方向", isOn: $model.params.showStarts)
            Toggle("按速度上色", isOn: $model.params.speedColor)
            Toggle("控制点", isOn: $model.params.handles)
            Toggle("笔尖", isOn: $model.params.head)
            if model.params.head {
                SliderRow(title: "笔尖半径（pt）", value: $model.params.headSize, range: 1...10, digits: 1)
            }
            Toggle("viewBox 边框", isOn: $model.params.bounds)
        }
        Section {
            HStack {
                Button("复制参数") { model.copyParams() }
                    .help("把当前参数按 JSON 复制到剪贴板")
                Button("恢复默认") { model.params = Params() }
            }
        }
    }
}

struct RootView: View {
    @Bindable var model: Model

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let logo = model.logo, let plan = model.plan {
                    TimelineView(.animation(paused: !model.playing)) { context in
                        player(logo: logo, plan: plan, time: model.time(at: context.date))
                    }
                } else {
                    Text(model.error ?? "把 SVG 拖进来").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "svg" }) else { return false }
                model.open(url)
                return true
            }
            Divider()
            Inspector(model: model).frame(width: 380)
        }
    }

    private func player(logo: Logo, plan: Plan, time t: Double) -> some View {
        VStack(spacing: 0) {
            StageArea(logo: logo, plan: plan, params: model.params, time: t,
                      selected: model.pane == .strokes ? model.selected : nil) { k in
                model.selected = k
                model.pane = .strokes
            }
            .modifier(BackdropScheme(mode: model.params.backdrop))
            Divider()
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button { model.playPause() } label: {
                        Image(systemName: model.atEnd(t) ? "arrow.counterclockwise" : model.playing ? "pause.fill" : "play.fill")
                            .frame(width: 18)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("播放 / 暂停（空格）")
                    Button { model.restart() } label: { Image(systemName: "backward.end.fill") }
                        .help("从头播放")
                    Text(String(format: "%.2f / %.2f 秒", t, plan.total)).monospacedDigit()
                    Text(plan.phase(at: t)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("速率", selection: $model.rate) {
                        ForEach([0.1, 0.25, 0.5, 1, 2], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Toggle("循环", isOn: $model.loop)
                }
                TimelineBar(plan: plan, time: t) { model.scrub(to: $0) }
            }
            .padding(12)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(into: URL(fileURLWithPath: args[i + 1]), svg: args.firstIndex(of: "--svg").map { URL(fileURLWithPath: args[$0 + 1]) })
            NSApp.terminate(nil)
        }
        NSApp.activate()
    }

    /// 不开窗口，把当前参数下几个时刻的画面渲染成 PNG，并打印时间表。用来在没有截屏权限时核对。
    /// `--set 键=值` 临时改顶层参数，`--stroke 编号:键=值` 临时改某一笔（编号从 1 起），都不写回偏好。
    private func snapshot(into directory: URL, svg: URL?) {
        let started = Date()
        let model = Model()
        model.persist = false
        if let svg { model.open(svg, remember: false) }
        let args = CommandLine.arguments
        func patch(_ data: Data, _ assignment: String) -> Data? {
            let pair = assignment.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            dict[pair[0]] = Double(pair[1]) ?? (pair[1] == "true" ? true : pair[1] == "false" ? false : pair[1] as Any)
            return try? JSONSerialization.data(withJSONObject: dict)
        }
        for (i, arg) in args.enumerated() where i + 1 < args.count {
            if arg == "--set", let data = try? JSONEncoder().encode(model.params),
               let patched = patch(data, args[i + 1]), let params = try? JSONDecoder().decode(Params.self, from: patched) {
                model.params = params
            }
            if arg == "--stroke" {
                let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let k = Int(parts[0]), k >= 1 else { continue }
                model.updateStroke(k - 1) { config in
                    if let data = try? JSONEncoder().encode(config), let patched = patch(data, parts[1]),
                       let decoded = try? JSONDecoder().decode(StrokeConfig.self, from: patched) {
                        config = decoded
                    }
                }
            }
            if arg == "--order" {
                model.params.order = args[i + 1].split(separator: ",").compactMap { Int($0) }.map { $0 - 1 }
            }
        }
        guard let logo = model.logo, let plan = model.plan else {
            print(model.error ?? "没有载入 SVG")
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("文件 \(model.url.path)，类型 \(plan.mode)，载入加排路线 \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms")
        if let outline = model.outline {
            print("骨架：\(outline.nodes.count) 个节点，\(outline.edges.count) 条边，\(outline.components.count) 块，典型半笔宽 \(String(format: "%.2f", outline.typicalRadius))")
        }
        print(String(format: "全速 %.1f 单位/秒，书写结束 %.2f 秒，停留到 %.2f 秒，共 %.2f 秒", plan.speed, plan.writeEnd, plan.holdEnd, plan.total))
        for (k, track) in plan.tracks.enumerated() {
            let config = model.params.stroke(k)
            let when = plan.starts[k].map { String(format: "第 %d 个写，%.3f 秒落笔，用时 %.3f 秒", plan.position[k]! + 1, $0, track.duration) } ?? "不写"
            print(String(format: "#%d：长 %.2f，%@，笔刷 %@，起笔宽 %.2f，笔宽 %.2f～%.2f，笔毛 %d 根", k + 1, track.length, when,
                         Brush.named(config.brush).name, track.widths.first ?? 0, track.widths.min() ?? 0, track.widths.max() ?? 0,
                         track.bristles.count))
        }
        var params = model.params
        params.centerline = true
        params.showStarts = true
        let times = [0.0, 0.2, 0.4, 0.6, 0.8, 0.999].map { plan.lead + (plan.writeEnd - plan.lead) * $0 }
            + [plan.holdEnd - 0.01, plan.holdEnd + (plan.total - plan.holdEnd) / 2]
        for (n, t) in times.enumerated() {
            let view = StageArea(logo: logo, plan: plan, params: params, time: t, selected: nil) { _ in }
                .frame(width: 900, height: 600)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let file = directory.appending(path: String(format: "%d-%.2fs.png", n, t))
            try? png.write(to: file)
            print(String(format: "%.2f 秒 %@ → %@", t, plan.phase(at: t), file.lastPathComponent))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LogoWritingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Model()

    var body: some Scene {
        Window("Kite 写字 logo", id: "logo") {
            RootView(model: model).frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 820)
    }
}
