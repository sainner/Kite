import SwiftUI

/// 侧栏的「Kite」字标：平常是字标字体；指针进到标志栏时换成手写标志，当场写一遍，离开换回字标。
/// 手写标志叠在字标上，不占布局，比字标大，单独往左下挪一点。每次指针进来都重新插入，从头写。
struct KiteWordmark: View {
    /// 指针在标志栏里。
    var hovering: Bool
    #if os(macOS)
    @ScaledMetric(relativeTo: .title3) private var nudge: CGFloat = 3
    @ScaledMetric(relativeTo: .title3) private var drop: CGFloat = 3
    #else
    @ScaledMetric(relativeTo: .title3) private var nudge: CGFloat = 4
    @ScaledMetric(relativeTo: .title3) private var drop: CGFloat = 4
    #endif

    var body: some View {
        Text("Kite")
            .font(Theme.wordmark)
            .opacity(hovering ? 0 : 1)
            .overlay(alignment: .leading) {
                if hovering {
                    HandwrittenLogo()
                        .offset(x: -nudge, y: drop)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// 手写标志「kite」：出现时按书写顺序一笔一笔写出来，写完停住；减弱动态效果时直接显示写完的样子。
/// 墨色跟文字一样取前景色，高度随系统字号缩放。
struct HandwrittenLogo: View {
    #if os(macOS)
    @ScaledMetric(relativeTo: .title3) private var height: CGFloat = 26
    #else
    @ScaledMetric(relativeTo: .title3) private var height: CGFloat = 33
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started: Date?
    @State private var finished = false

    var body: some View {
        let ink = LogoInk.shared, done = finished || reduceMotion
        // 落笔时刻要在 body 里读出来：只在 TimelineView 的闭包里读 @State 不算依赖，设了也不重算，闭包一直拿着 nil
        let start = started
        TimelineView(.animation(paused: done)) { context in
            let elapsed = done ? .infinity : start.map { context.date.timeIntervalSince($0) } ?? 0
            Canvas { canvas, size in
                ink.draw(at: elapsed, in: canvas, size: size)
            }
        }
        .frame(width: height * ink.aspect, height: height)
        .accessibilityElement()
        .accessibilityLabel("Kite")
        .task {
            started = .now
            try? await Task.sleep(for: .seconds(ink.duration))
            finished = true
        }
    }
}

/// 标志的墨迹：每一笔按弧长采好的点、笔宽和「写到这里用了多久」，只算一次。
/// 笔画和参数在 spikes/logo-writing 里调定后抄过来，算法只留了用到的部分：
/// 速度按 1 / (1 + 转弯减速 × 曲率) 降、起收笔在 0.3 倍速和全速之间过渡；笔宽是行书笔刷的起笔、出锋、扁笔笔锋，再乘 1 + 转弯加粗 × (1 − 速度比)。
struct LogoInk {
    /// 一笔。路径只认绝对坐标的 M 和 C，和设计稿导出的一致；长度都是设计稿的 viewBox 单位。
    struct Stroke {
        var path: String
        /// 笔刷粗细的倍数。
        var size: Double
        var cornering: Double
        /// 起笔后、收笔前多长距离内在 0.3 倍速和全速之间过渡。
        var easeIn: Double
        var easeOut: Double
        var pressure: Double
        var taperExit: Bool
        /// 上一笔写完到这一笔落笔之间停多久，秒。
        var pause: Double
    }

    /// 按书写顺序：先写主体，再点 i。
    static let strokes = [
        Stroke(path: "M7.28788 0.301392C11.3224 13.0629 4.15753 23.8578 1.27388 26.0173C-1.60977 28.1767 19.3063 4.1895 15.8528 6.27651C12.3993 8.36352 9.49626 12.1821 9.10987 14.672C8.55665 18.2369 13.0934 21.0869 15.8528 20.3446C20.5395 19.0838 25.0251 11.4495 23.3239 10.8125C21.6227 10.1755 19.4085 19.7562 23.9618 20.3446C28.515 20.933 32.8 14.3695 34.5312 11.6466C36.2624 8.92377 35.1532 3.82851 32.3444 8.62123C29.5357 13.4139 31.2553 20.2527 34.5312 20.3446C37.8072 20.4364 42.7346 18.1131 46.8028 14.672C50.8711 11.2308 46.8028 8.75455 43.3365 10.0054C39.8702 11.2563 36.6638 19.3549 51.0131 21.0907",
               size: 0.685, cornering: 8.32, easeIn: 17.47, easeOut: 7.41, pressure: 0.38, taperExit: false, pause: 0),
        Stroke(path: "M25.2448 4.64514C24.7679 5.86404 24.3335 6.36962 22.8755 6.61157",
               size: 1, cornering: 8.09, easeIn: 4, easeOut: 7.41, pressure: 0.5, taperExit: true, pause: 0.54),
    ]
    /// 直线上的全速，单位每秒。
    static let speed = 480.0
    // 行书笔刷：笔宽、起笔（尖起）、出锋，扁笔笔锋的扁度和角度（度，屏幕上逆时针）
    static let brushSize = 2.2
    static let entryLength = 2.0, entryWeight = 0.5
    static let exitLength = 8.0, exitWeight = 0.1
    static let flatness = 0.3, nibAngle = 40.0
    static let step = 0.1

    static let shared = LogoInk(strokes)

    private struct Track {
        var points: [CGPoint]
        var widths: [Double]
        var times: [Double]
        var start = 0.0
    }

    private let tracks: [Track]
    /// 墨迹连同笔宽的外框。
    private let bounds: CGRect
    /// 从出现到最后一笔写完，秒。
    let duration: Double
    var aspect: CGFloat { bounds.width / bounds.height }

    private init(_ strokes: [Stroke]) {
        var tracks: [Track] = [], bounds = CGRect.null, t = 0.0
        for (n, stroke) in strokes.enumerated() {
            var track = Self.track(stroke)
            if n > 0 { t += stroke.pause }
            track.start = t
            t += track.times.last ?? 0
            for (p, w) in zip(track.points, track.widths) {
                bounds = bounds.union(CGRect(x: p.x - w / 2, y: p.y - w / 2, width: w, height: w))
            }
            tracks.append(track)
        }
        self.tracks = tracks
        self.bounds = bounds
        duration = t
    }

    func draw(at elapsed: Double, in canvas: GraphicsContext, size: CGSize) {
        let k = size.height / bounds.height
        let m = CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                  tx: (size.width - bounds.width * k) / 2 - bounds.minX * k, ty: -bounds.minY * k)
        for track in tracks {
            let local = elapsed - track.start
            guard local > 0, track.points.count > 1 else { continue }
            // 写到的最后一个采样点，再往下一个点插一截
            var lo = 0, hi = track.times.count - 1
            if local >= track.times[hi] { lo = hi } else {
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if track.times[mid] <= local { lo = mid } else { hi = mid }
                }
            }
            var samples = (0...lo).map { (track.points[$0], track.widths[$0]) }
            if lo + 1 < track.points.count {
                let f = (local - track.times[lo]) / max(track.times[lo + 1] - track.times[lo], 1e-9)
                let a = track.points[lo], b = track.points[lo + 1]
                samples.append((CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f),
                                track.widths[lo] + (track.widths[lo + 1] - track.widths[lo]) * f))
            }
            if samples.count == 1 { samples.append(samples[0]) }
            stroke(samples, in: canvas, transform: m, scale: k)
        }
    }

    /// 笔宽按半点分档，同一档的连续采样合成一条圆头折线描一次。
    private func stroke(_ samples: [(CGPoint, Double)], in canvas: GraphicsContext, transform m: CGAffineTransform, scale k: CGFloat) {
        var run = Path(), level = 0
        for (j, (point, width)) in samples.enumerated() {
            let p = point.applying(m), w = Int((width * k * 2).rounded())
            if j == 0 {
                run.move(to: p)
                level = w
                continue
            }
            run.addLine(to: p)
            if w != level || j == samples.count - 1 {
                canvas.stroke(run, with: .foreground,
                              style: StrokeStyle(lineWidth: max(CGFloat(level) / 2, 0.25), lineCap: .round, lineJoin: .round))
                run = Path()
                run.move(to: p)
                level = w
            }
        }
    }

    // MARK: 采样与时间表

    private static func track(_ stroke: Stroke) -> Track {
        let points = resample(dense(stroke.path))
        var lengths = [0.0]
        for i in points.indices.dropFirst() {
            lengths.append(lengths[i - 1] + Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)))
        }
        let total = lengths.last ?? 0
        let bend = curvature(points, lengths)
        let ratio = lengths.indices.map { i in
            let ends = ramp(lengths[i], over: stroke.easeIn, from: 0.3) * ramp(total - lengths[i], over: stroke.easeOut, from: 0.3)
            return max(ends / (1 + stroke.cornering * bend[i]), 0.03)
        }
        var times = [0.0]
        for i in lengths.indices.dropFirst() {
            times.append(times[i - 1] + (lengths[i] - lengths[i - 1]) / (0.5 * (ratio[i - 1] + ratio[i])) / speed)
        }
        // 短笔起笔最多占三成、出锋最多占一半，不然整笔都落在出锋里
        let entry = min(entryLength, total * 0.3), exit = stroke.taperExit ? min(exitLength, total * 0.5) : 0
        let nib = -nibAngle * .pi / 180, base = brushSize * stroke.size
        let widths = lengths.indices.map { i in
            // 扁笔：笔锋是一条斜放的椭圆，宽度取它在行进方向法线上的投影
            let a = points[max(i - 3, 0)], b = points[min(i + 3, points.count - 1)]
            let d = Double(atan2(b.y - a.y, b.x - a.x)) - nib
            let flat = (sin(d) * sin(d) + (1 - flatness) * (1 - flatness) * cos(d) * cos(d)).squareRoot()
            let ends = ramp(lengths[i], over: entry, from: entryWeight) * ramp(total - lengths[i], over: exit, from: exitWeight)
            return max(base * ends * (1 + stroke.pressure * (1 - ratio[i])) * flat, base * 0.04)
        }
        return Track(points: points, widths: widths, times: times)
    }

    /// 从 from 平滑过渡到 1；d 是离起点（或终点）的距离。
    private static func ramp(_ d: Double, over length: Double, from start: Double) -> Double {
        guard length > 0 else { return 1 }
        let x = min(max(d / length, 0), 1)
        return start + (1 - start) * x * x * (3 - 2 * x)
    }

    /// 每段三次贝塞尔取 96 个点。
    private static func dense(_ path: String) -> [CGPoint] {
        var numbers: [CGFloat] = [], token = ""
        func flush() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }
        for c in path {
            if c.isNumber || c == "." {
                token.append(c)
            } else if c == "-" {
                flush()
                token = "-"
            } else {
                flush()
            }
        }
        flush()
        guard numbers.count >= 8 else { return [] }
        var points = [CGPoint(x: numbers[0], y: numbers[1])]
        for s in stride(from: 2, to: numbers.count - 5, by: 6) {
            let p0 = points[points.count - 1]
            let c1 = CGPoint(x: numbers[s], y: numbers[s + 1]), c2 = CGPoint(x: numbers[s + 2], y: numbers[s + 3])
            let p3 = CGPoint(x: numbers[s + 4], y: numbers[s + 5])
            for n in 1...96 {
                let t = CGFloat(n) / 96, u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                points.append(CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
                                      y: a * p0.y + b * c1.y + c * c2.y + d * p3.y))
            }
        }
        return points
    }

    /// 按弧长每 step 单位重采样。
    private static func resample(_ dense: [CGPoint]) -> [CGPoint] {
        guard let first = dense.first else { return [] }
        let step = CGFloat(Self.step)
        var out = [first], carried: CGFloat = 0
        for k in dense.indices.dropFirst() {
            let a = dense[k - 1], b = dense[k], length = hypot(b.x - a.x, b.y - a.y)
            var position: CGFloat = 0
            while carried + (length - position) >= step {
                position += step - carried
                carried = 0
                out.append(CGPoint(x: a.x + (b.x - a.x) * position / length, y: a.y + (b.y - a.y) * position / length))
            }
            carried += length - position
        }
        if carried > step * 0.05 || out.count == 1 { out.append(dense[dense.count - 1]) }
        return out
    }

    /// 曲率取相邻方向角之差，再做 0.6 单位的高斯平滑。
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
        let sigma = 0.6 / step, radius = Int(sigma * 3)
        let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        return (0..<n).map { i in
            var sum = 0.0, weight = 0.0
            for (k, w) in kernel.enumerated() where i + k - radius >= 0 && i + k - radius < n {
                sum += raw[i + k - radius] * w
                weight += w
            }
            return sum / weight
        }
    }
}
