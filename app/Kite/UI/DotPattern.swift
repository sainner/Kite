import Accelerate
import SwiftUI

/// 铺满一块区域、按表达式逐格求值的图案，即模板的点阵签名。值的绝对值是点的大小，正负选两种颜色。
nonisolated struct DotPattern: Equatable, Sendable {
    let expression: DotExpression
    var positive: DotColor
    var negative: DotColor
    var form: DotForm

    static func == (a: Self, b: Self) -> Bool {
        a.expression.source == b.expression.source && a.positive == b.positive && a.negative == b.negative && a.form == b.form
    }
}

/// 图案收弱的一块范围：文字压在上面时图案在这里只留 floor 那么多，离开范围 quietReach 格回到原样。
nonisolated struct PatternQuiet: Equatable, Sendable {
    var rect: CGRect
    var floor = PatternMotion.quietFloor

    func mapped(by mapping: DotCarrier.Mapping?) -> PatternQuiet {
        PatternQuiet(rect: mapping?.apply(rect) ?? rect, floor: floor)
    }
}

/// 舞台上一块图案的状态。区域在会移动的卡片里时用卡片坐标，见 DotCarrier。
struct PatternSlot {
    var pattern: DotPattern?
    /// 换图案时的旧图案，形变完就不再用。
    var previous: DotPattern?
    /// 当前图案摆上来的时刻：从无到有时由中心向外长出来，换图案时沿对角线逐格形变。
    var changed: Date
    /// 整块收回的时刻。
    var leaving: Date?
    /// 表达式里 t 的起点。
    var start: Date
    var area: CGRect
    /// 文字压在上面的范围，图案在这里收弱。
    var quiet: [PatternQuiet]
    /// 随声音从底边往上涨：静音时中间只铺到底边往上这么高（同 area 的坐标），响度到 1 时中间涨到顶，两侧低一些；nil 时一直铺满。
    /// 涨的图案以底边中点为原点（见 PatternGrid.originRow），其余以中心为原点。
    var rise: CGFloat?
    var carrier: DotCarrier?
    /// 涨的图案摆上来时从底边升起、收回时沉回底边，不由中心长出、不原地淡掉；其余图案不用它。
    var lift: PatternLift
}

/// 涨的图案升到几成：0 是全沉在底边下，1 是升到该在的高度。升起、沉下都从当时的高度接着走，中途反向不跳；
/// 曲线同窗口动画（WindowMotionKind.curve），不回弹。
nonisolated struct PatternLift: Sendable {
    var from = 0.0
    var to = 1.0
    var at: Date

    func value(at date: Date, live: Bool) -> Double {
        guard live else { return to }
        let duration = to > from ? PatternMotion.riseDuration : PatternMotion.leaveDuration
        let progress = min(max(date.timeIntervalSince(at) / duration, 0), 1)
        return from + (to - from) * WindowMotionKind.curve.value(at: progress)
    }

    /// 从 date 这一刻的高度起，改往 target 走。
    func turned(to target: Double, at date: Date) -> PatternLift {
        PatternLift(from: value(at: date, live: true), to: target, at: date)
    }
}

/// 图案的交互输入：指针所在（窗口坐标）、打字的活跃度与声音的来源。逐帧读取，不引起视图更新。
struct PatternInput {
    var pointer: CGPoint?
    var activity = 0.0
    var activityAt = Date.distantPast
    /// 表达式里的 v（0～1）逐帧从这里取；没有时为 0。现在只有语音输入，系统播放的声音还没接。
    var sound: AudioLevel?

    /// 每敲一下加一截，随后按秒衰减。
    func level(at date: Date) -> Double {
        max(0, activity - date.timeIntervalSince(activityAt) * PatternMotion.activityDecay)
    }
}

nonisolated enum PatternMotion {
    /// 从无到有时由中心向外长出来，最外一圈晚这么久出发。
    static let growSpread: TimeInterval = 0.7
    /// 换图案时沿对角线错开的时长。
    static let morphSpread: TimeInterval = 0.6
    /// 收回的时长：淡掉，涨的图案是沉回底边。
    static let leaveDuration: TimeInterval = 0.45
    /// 涨的图案从底边升起的时长。
    static let riseDuration: TimeInterval = 0.45
    /// 长出来或形变完所需的最长时间，过后不再算旧图案。
    static let settled: TimeInterval = 1.3
    static let activityStep = 0.22
    static let activityDecay = 0.5
    /// 压字的范围里留多少，离开范围多远（格）回到原样。
    static let quietFloor = 0.12
    static let quietReach = 3.0
    /// 响度到 1 时整幅涨大多少：签名里 v 只占一小项，不另外涨的话说话时看不出在听。
    static let soundSwell = 0.8
    /// 随声音往上涨的图案：从底边往上占整块高的几成一直是满的，再往上一路淡到上沿（语音那一带占窗口的六成，这里是窗口的一成）；
    /// 上沿两端比中间低几成，是一道中间高、两侧低的弧，不是一条直线。
    static let riseFloor = 1.0 / 6
    static let riseArch = 0.35
}

/// 一块图案只随位置、大小和压字范围变的逐格量，按行排满整块：表达式里只与格位有关的变量，以及压字处收弱的系数。
/// 舞台按图案记下，这些不变就一直沿用，每帧只算随时间和输入变的部分。
nonisolated struct PatternGrid: Sendable {
    let columns: ClosedRange<Int>
    let rows: ClosedRange<Int>
    let quiet: [PatternQuiet]
    /// 原点在底边中点，见 originRow。
    let bottom: Bool
    /// 各格相对图案左上角的列号、行号。
    let column: [Double]
    let row: [Double]
    /// 表达式里的 x、y、i、r、a。
    let x: [Double]
    let y: [Double]
    let i: [Double]
    let r: [Double]
    let a: [Double]
    /// 收弱的系数；没有压字的范围时为空。
    let quietFactors: [Double]

    init(columns: ClosedRange<Int>, rows: ClosedRange<Int>, quiet: [PatternQuiet], bottom: Bool) {
        self.columns = columns
        self.rows = rows
        self.quiet = quiet
        self.bottom = bottom
        let width = columns.count, count = width * rows.count
        let w = Double(width), h = Double(rows.count)
        let ramp: [Double] = vDSP.ramp(withInitialValue: 0, increment: 1, count: width)
        var column: [Double] = [], row: [Double] = []
        column.reserveCapacity(count)
        row.reserveCapacity(count)
        for line in 0..<rows.count {
            column += ramp
            row += repeatElement(Double(line), count: width)
        }
        let x = vDSP.add(-(w / 2).rounded(.down), column), y = vDSP.add(-Double(Self.originRow(height: rows.count, bottom: bottom)), row)
        self.column = column
        self.row = row
        self.x = x
        self.y = y
        i = vDSP.add(column, vDSP.multiply(w, row))
        r = vDSP.hypot(x, y)
        a = vForce.atan2(x: x, y: y)
        quietFactors = quiet.isEmpty ? [] : Self.factors(quiet, columns: columns, rows: rows)
    }

    func matches(columns: ClosedRange<Int>, rows: ClosedRange<Int>, quiet: [PatternQuiet], bottom: Bool) -> Bool {
        self.columns == columns && self.rows == rows && self.quiet == quiet && self.bottom == bottom
    }

    /// 原点所在的行，相对图案顶行：一般在正中；从底边往上涨的图案在最底一行，签名从窗口底边往上展开。
    static func originRow(height: Int, bottom: Bool) -> Int { bottom ? height - 1 : height / 2 }

    /// 离原点最远的格大约多远，由原点向外长出来时按它错开。
    static func reach(width: Double, height: Double, bottom: Bool) -> Double { hypot(width / 2, bottom ? height : height / 2) }

    /// 文字压着的范围里各格收弱的系数，按行排；同 ResolvedPattern.dot 里的算法。一格到范围的距离拆成列上和行上的两段。
    private static func factors(_ quiet: [PatternQuiet], columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> [Double] {
        let pitch = Double(DotMetrics.pitch)
        var factors = [Double](repeating: 1, count: columns.count * rows.count)
        for quiet in quiet {
            let rect = quiet.rect
            let gapX = columns.map { column in max(Double(rect.minX) - Double(column + 1) * pitch, Double(column) * pitch - Double(rect.maxX), 0) }
            let squaredX = vDSP.multiply(gapX, gapX)
            for (line, row) in rows.enumerated() {
                let gapY = max(Double(rect.minY) - Double(row + 1) * pitch, Double(row) * pitch - Double(rect.maxY), 0)
                let distance = vDSP.multiply(1 / (pitch * PatternMotion.quietReach), vForce.sqrt(vDSP.add(gapY * gapY, squaredX)))
                let t = vDSP.clip(distance, to: 0...1)
                let smooth = vDSP.multiply(vDSP.multiply(t, t), vDSP.add(3, vDSP.multiply(-2, t)))
                let factor = vDSP.add(quiet.floor, vDSP.multiply(1 - quiet.floor, smooth))
                let range = line * columns.count ..< (line + 1) * columns.count
                factors.replaceSubrange(range, with: vDSP.minimum(Array(factors[range]), factor))
            }
        }
        return factors
    }
}

/// 一帧里的一块图案，坐标都已换算到窗口格位。
nonisolated struct ResolvedPattern: Sendable {
    let pattern: DotPattern?
    let previous: DotPattern?
    let changed: Date
    let leaving: Date?
    let start: Date
    let columns: ClosedRange<Int>
    let rows: ClosedRange<Int>
    let quiet: [PatternQuiet]
    /// 指针所在格，相对图案中心。
    let pointer: (x: Double, y: Double)?
    let activity: Double
    let sound: Double
    /// 静音时从底边往上铺几格，见 PatternSlot.rise。
    let rise: Double?
    /// 涨的图案这一帧升到几成，见 PatternSlot.lift。
    let lift: Double
    let grid: PatternGrid

    /// 交给着色器（DotField.metal）的一块图案：可见范围里每格的取值（带正负，已乘上长出、形变、声音、收回和收弱）整批算好，
    /// 按行追加到 values；表头按 patternStride 排，颜色由着色器按取值混。算法与下面逐格的 dot 相同。
    /// hidden 是整格被遮掉的格子：可见的几列全被遮掉的行不算，其余的行按连续的几段各追加一条。
    /// follow 是所在卡片正在走时，屏幕上的一点对应卡片停着时的哪里，见 DotCarrier。
    func appendShaderData(to header: inout [Float], values: inout [Float], columns visibleColumns: ClosedRange<Int>,
                          rows visibleRows: ClosedRange<Int>, hidden: [(columns: Range<Int>, rows: Range<Int>)],
                          follow: DotCarrier.Mapping?, at date: Date, live: Bool) {
        guard let pattern else { return }
        if let follow {
            appendFollowing(pattern, follow: follow, to: &header, values: &values, columns: visibleColumns, rows: visibleRows,
                            at: date, live: live)
            return
        }
        guard columns.overlaps(visibleColumns), rows.overlaps(visibleRows) else { return }
        let shownColumns = columns.clamped(to: visibleColumns)
        func covered(_ row: Int) -> Bool {
            hidden.contains {
                $0.rows.contains(row) && $0.columns.contains(shownColumns.lowerBound) && $0.columns.contains(shownColumns.upperBound)
            }
        }
        var band: ClosedRange<Int>?
        for row in rows.clamped(to: visibleRows) {
            if !covered(row) {
                band = band.map { $0.lowerBound...row } ?? row...row
            } else if let shown = band {
                append(pattern, columns: shownColumns, rows: shown, to: &header, values: &values, at: date, live: live)
                band = nil
            }
        }
        if let band { append(pattern, columns: shownColumns, rows: band, to: &header, values: &values, at: date, live: live) }
    }

    /// 连续几行：按图案的整行求值，取的是 grid 里连成一段的格子，再截出可见的列。
    private func append(_ pattern: DotPattern, columns shownColumns: ClosedRange<Int>, rows shownRows: ClosedRange<Int>,
                        to header: inout [Float], values: inout [Float], at date: Date, live: Bool) {
        let width = columns.count
        let range = (shownRows.lowerBound - rows.lowerBound) * width ..< (shownRows.upperBound - rows.lowerBound + 1) * width
        let value = evaluate(pattern, range: range, at: date, live: live)
        appendHeader(pattern, columns: shownColumns, rows: shownRows, valueOffset: values.count, at: date, live: live, to: &header)
        let floats = vDSP.doubleToFloat(value)
        if shownColumns == columns {
            values += floats
        } else {
            let skip = shownColumns.lowerBound - columns.lowerBound
            for line in 0..<shownRows.count {
                values += floats[line * width + skip ..< line * width + skip + shownColumns.count]
            }
        }
    }

    /// 卡片走着时：整块图案按停着的格位求值，屏幕上的每一格按 follow 换算回停着时的位置，由相邻四格按双线性权重取值，
    /// 图案跟着卡片平移、缩放；表达式里的 x、y、i 仍是停着时的整数格。
    private func appendFollowing(_ pattern: DotPattern, follow: DotCarrier.Mapping, to header: inout [Float], values: inout [Float],
                                 columns visibleColumns: ClosedRange<Int>, rows visibleRows: ClosedRange<Int>, at date: Date, live: Bool) {
        // 屏幕上图案这一帧占到的格子，四边多留一格给插值
        let shown = DotMetrics.cells(covering: follow.inverted.apply(DotMetrics.rect(columns: columns, rows: rows)))
        let reachColumns = (shown.columns.lowerBound - 1)...(shown.columns.upperBound + 1)
        let reachRows = (shown.rows.lowerBound - 1)...(shown.rows.upperBound + 1)
        guard reachColumns.overlaps(visibleColumns), reachRows.overlaps(visibleRows) else { return }
        let shownColumns = reachColumns.clamped(to: visibleColumns), shownRows = reachRows.clamped(to: visibleRows)
        let width = columns.count, height = rows.count
        let lattice = evaluate(pattern, range: 0 ..< width * height, at: date, live: live)
        func value(_ column: Int, _ row: Int) -> Double {
            guard column >= 0, column < width, row >= 0, row < height else { return 0 }
            return lattice[row * width + column]
        }
        // follow 只有等比缩放加平移：屏幕上第 c 列的格心换算回去，落在图案里第 scale × c + offset 列（以格心计，可以在两列之间），
        // 只随屏幕上的列变；行同理。两条轴各算一遍
        let scale = Double(follow.scale)
        func offset(_ origin: CGFloat, first: Int) -> Double { Double(origin / DotMetrics.pitch) + 0.5 * scale - 0.5 - Double(first) }
        let offsetX = offset(follow.origin.x, first: columns.lowerBound), offsetY = offset(follow.origin.y, first: rows.lowerBound)
        // 形变的对角线按图案里的格位走，起点和跨度折算成屏幕上的格子交给着色器
        appendHeader(pattern, columns: shownColumns, rows: shownRows, valueOffset: values.count,
                     diagonal: (-offsetX / scale, -offsetY / scale, Double(columns.count + rows.count - 2) / scale),
                     at: date, live: live, to: &header)
        func axis(_ cells: ClosedRange<Int>, offset: Double) -> [(cell: Int, fraction: Double)] {
            cells.map { cell in
                let u = scale * Double(cell) + offset, u0 = u.rounded(.down)
                return (Int(u0), u - u0)
            }
        }
        let us = axis(shownColumns, offset: offsetX), vs = axis(shownRows, offset: offsetY)
        values.reserveCapacity(values.count + shownColumns.count * shownRows.count)
        for (r, fv) in vs {
            for (c, fu) in us {
                let top = value(c, r) * (1 - fu) + value(c + 1, r) * fu
                let bottom = value(c, r + 1) * (1 - fu) + value(c + 1, r + 1) * fu
                values.append(Float(top * (1 - fv) + bottom * fv))
            }
        }
    }

    /// grid 里 range 这几格的取值，已乘上长出、形变、声音、收回和收弱。
    private func evaluate(_ pattern: DotPattern, range: Range<Int>, at date: Date, live: Bool) -> [Double] {
        let width = columns.count
        let count = range.count
        let w = Double(width), h = Double(rows.count)
        let x = grid.x[range], y = grid.y[range]
        var variables = [ArraySlice<Double>](repeating: [], count: DotExpression.Variable.allCases.count)
        func set(_ variable: DotExpression.Variable, _ value: ArraySlice<Double>) { variables[variable.rawValue] = value }
        set(.t, [live ? date.timeIntervalSince(start) : 0])
        set(.x, x)
        set(.y, y)
        set(.w, [w])
        set(.h, [h])
        set(.i, grid.i[range])
        set(.r, grid.r[range])
        set(.a, grid.a[range])
        if let pointer {
            let px = vDSP.add(-pointer.x, x), py = vDSP.add(-pointer.y, y)
            set(.px, px[...])
            set(.py, py[...])
            set(.d, vDSP.hypot(px, py)[...])
        } else {
            set(.px, [999])
            set(.py, [999])
            set(.d, [hypot(999, 999)])
        }
        set(.k, [activity])
        set(.v, [sound])

        let elapsed = live ? date.timeIntervalSince(changed) : .infinity
        var value = pattern.expression.evaluate(batch: variables, count: count)
        func eased(_ delay: [Double]) -> [Double] {
            let t = vDSP.clip(vDSP.multiply(1 / DotMetrics.morphDuration, vDSP.add(elapsed, vDSP.negative(delay))), to: 0...1)
            let rest = vDSP.add(1, vDSP.negative(t))
            return vDSP.add(1, vDSP.negative(vDSP.multiply(vDSP.multiply(rest, rest), rest)))
        }
        let zeros = { [Double](repeating: 0, count: count) }
        if let previous {
            // 沿对角线从左上到右下逐格换过去
            let span = w + h - 2
            let progress = eased(span > 0 ? vDSP.multiply(PatternMotion.morphSpread / span, vDSP.add(grid.column[range], grid.row[range])) : zeros())
            let old = previous.expression.evaluate(batch: variables, count: count)
            value = vDSP.add(vDSP.multiply(old, vDSP.add(1, vDSP.negative(progress))), vDSP.multiply(value, progress))
        } else if rise == nil, elapsed < PatternMotion.growSpread + DotMetrics.morphDuration {
            // 由原点向外长出来；全部长完后系数都是 1，不用再乘。涨的图案从底边升起，见下
            let reach = PatternGrid.reach(width: w, height: h, bottom: grid.bottom)
            value = vDSP.multiply(value, eased(reach > 0 ? vDSP.multiply(PatternMotion.growSpread / reach, grid.r[range]) : zeros()))
        }
        if sound > 0 {
            value = vDSP.multiply(1 + PatternMotion.soundSwell * sound, value)
        }
        if let rise {
            // 中间从底边往上铺到 reach 格，两侧按离中间的远近平方低下去；底下几格一直是满的，往上到上沿一路淡出。
            // 第 row 行的格心离底边 h − 0.5 − row 格。升起、沉下时整道按 lift 压低
            let reach = lift * (rise + sound * (h - rise))
            let half = max((w - 1) / 2, 1)
            let offset = vDSP.add(-half, grid.column[range])
            let edge = vDSP.add(reach, vDSP.multiply(-reach * PatternMotion.riseArch / (half * half), vDSP.multiply(offset, offset)))
            let span = vDSP.clip(vDSP.add(-h * PatternMotion.riseFloor, edge), to: 1...Double.greatestFiniteMagnitude)
            let t = vDSP.clip(vDSP.divide(vDSP.add(edge, vDSP.add(0.5 - h, grid.row[range])), span), to: 0...1)
            value = vDSP.multiply(value, vDSP.multiply(vDSP.multiply(t, t), vDSP.add(3, vDSP.multiply(-2, t))))
        }
        if let leaving, live, rise == nil {
            value = vDSP.multiply(1 - easeOutCubic(date.timeIntervalSince(leaving) / PatternMotion.leaveDuration), value)
        }
        if !grid.quietFactors.isEmpty {
            value = vDSP.multiply(value, grid.quietFactors[range])
        }
        return value
    }

    /// 一段图案的表头，布局见 patternStride；取值从 values 的 valueOffset 起按行排。
    /// diagonal 是形变对角线的起点（列、行）和跨度，按表头里的格子计；nil 时就是图案自己的格位。
    private func appendHeader(_ pattern: DotPattern, columns shownColumns: ClosedRange<Int>, rows shownRows: ClosedRange<Int>,
                              valueOffset: Int, diagonal: (column: Double, row: Double, span: Double)? = nil, at date: Date, live: Bool,
                              to header: inout [Float]) {
        func color(_ color: DotColor) -> [Float] { [Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha)] }
        let elapsed = live ? date.timeIntervalSince(changed) : .infinity
        let earlier = previous ?? pattern
        let diagonal = diagonal ?? (Double(columns.lowerBound), Double(rows.lowerBound), Double(columns.count + rows.count - 2))
        header += [Float(shownColumns.lowerBound), Float(shownColumns.upperBound), Float(shownRows.lowerBound), Float(shownRows.upperBound),
                   Float(valueOffset), Float(diagonal.column), Float(diagonal.row), Float(diagonal.span),
                   Float(min(elapsed, 1e9)), previous == nil ? 0 : 1, Float(pattern.form.index), Float(earlier.form.index)]
        header += color(pattern.positive) + color(pattern.negative) + color(earlier.positive) + color(earlier.negative)
    }

    /// point（窗口坐标；跟着卡片走时已换算回卡片停着的位置）处的点，算法同 appendShaderData：
    /// 落在格心时就是那一格，落在两格之间时由相邻四格按双线性权重取值。
    func dot(at point: CGPoint, at date: Date, live: Bool, rest: DotColor) -> Dot? {
        guard let pattern else { return nil }
        // 以格心计、相对图案左上角那一格
        let u = Double(point.x / DotMetrics.pitch) - 0.5 - Double(columns.lowerBound)
        let v = Double(point.y / DotMetrics.pitch) - 0.5 - Double(rows.lowerBound)
        let u0 = u.rounded(.down), v0 = v.rounded(.down), fu = u - u0, fv = v - v0
        var value = 0.0
        for (du, dv, weight) in [(0, 0, (1 - fu) * (1 - fv)), (1, 0, fu * (1 - fv)), (0, 1, (1 - fu) * fv), (1, 1, fu * fv)] where weight > 0 {
            value += weight * self.value(pattern, column: Int(u0) + du, row: Int(v0) + dv, at: date, live: live)
        }
        let shape = abs(value)
        guard shape > 1.0 / 512 else { return nil }
        // 还没换过一半的格子用旧图案的颜色与终态
        let colors = previous.map { morphed(u + v, at: date, live: live) < 0.5 ? $0 : pattern } ?? pattern
        let color = rest.mixed(with: value >= 0 ? colors.positive : colors.negative, by: min(1, shape * 1.6))
        return Dot(colors.form, shape: shape, color: color)
    }

    /// 图案里第 (column, row) 格（相对左上角）的取值，同 evaluate；图案外为 0。
    private func value(_ pattern: DotPattern, column: Int, row: Int, at date: Date, live: Bool) -> Double {
        guard column >= 0, column < columns.count, row >= 0, row < rows.count else { return 0 }
        let w = Double(columns.count), h = Double(rows.count)
        let x = Double(column) - (w / 2).rounded(.down), y = Double(row - PatternGrid.originRow(height: rows.count, bottom: grid.bottom))
        var scope = DotExpression.Scope()
        scope[.t] = live ? date.timeIntervalSince(start) : 0
        scope[.x] = x
        scope[.y] = y
        scope[.w] = w
        scope[.h] = h
        scope[.i] = Double(row) * w + Double(column)
        scope[.r] = hypot(x, y)
        scope[.a] = atan2(y, x)
        scope[.px] = pointer.map { x - $0.x } ?? 999
        scope[.py] = pointer.map { y - $0.y } ?? 999
        scope[.d] = hypot(scope[.px], scope[.py])
        scope[.k] = activity
        scope[.v] = sound

        var value = pattern.expression.evaluate(scope)
        if let previous {
            // 沿对角线从左上到右下逐格换过去
            let eased = morphed(Double(column + row), at: date, live: live)
            value = previous.expression.evaluate(scope) * (1 - eased) + value * eased
        } else if rise == nil {
            // 由原点向外长出来；涨的图案从底边升起，见下
            let reach = PatternGrid.reach(width: w, height: h, bottom: grid.bottom)
            let delay = reach > 0 ? scope[.r] / reach * PatternMotion.growSpread : 0
            let elapsed = live ? date.timeIntervalSince(changed) : .infinity
            value *= easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
        }
        value *= 1 + PatternMotion.soundSwell * sound
        if let rise {
            let reach = lift * (rise + sound * (h - rise))
            let half = max((w - 1) / 2, 1), offset = Double(column) - half
            let edge = reach * (1 - PatternMotion.riseArch * offset * offset / (half * half))
            value *= smoothstep((edge - h + 0.5 + Double(row)) / max(edge - h * PatternMotion.riseFloor, 1))
        }
        if let leaving, live, rise == nil {
            value *= 1 - easeOutCubic(date.timeIntervalSince(leaving) / PatternMotion.leaveDuration)
        }
        if !quiet.isEmpty {
            let square = DotMetrics.square(column: column + columns.lowerBound, row: row + rows.lowerBound)
            var factor = 1.0
            for quiet in quiet {
                let distance = Double(DotMetrics.distance(between: square, and: quiet.rect) / DotMetrics.pitch)
                factor = min(factor, quiet.floor + (1 - quiet.floor) * smoothstep(distance / PatternMotion.quietReach))
            }
            value *= factor
        }
        return value
    }

    /// 换图案时，列号加行号（相对左上角，可以在两格之间）为 diagonal 的地方形变到几成。
    private func morphed(_ diagonal: Double, at date: Date, live: Bool) -> Double {
        let elapsed = live ? date.timeIntervalSince(changed) : .infinity
        let span = Double(columns.count + rows.count - 2)
        let delay = span > 0 ? diagonal / span * PatternMotion.morphSpread : 0
        return easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
    }
}

/// 在一块区域上铺点阵签名：自己只占位，图案交给所在窗口的舞台。指针划过和打字由使用方报给舞台。
/// 给出 area 时铺在那里（如整个窗口，连同标题栏和控制区后面），否则铺满自己占的位置。
struct DotPatternArea: View {
    let pattern: DotPattern?
    /// 收弱的范围；坐标与 area 相同：窗口坐标，在会移动的卡片里是卡片坐标。
    var quiet: [PatternQuiet] = []
    var area: CGRect?
    /// 随声音从底边往上涨，见 PatternSlot.rise。
    var rise: CGFloat?
    let slot: String
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @State private var frame: CGRect?

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: DotCarrier.coordinateSpace(carrier))
            } action: {
                frame = $0
                refresh()
            }
            .onChange(of: pattern) { refresh() }
            .onChange(of: quiet) { refresh() }
            .onChange(of: area) { refresh() }
            .onChange(of: rise) { refresh() }
            .onDisappear { stage?.showPattern(nil, in: .zero, slot: slot) }
            .preference(key: DotSlots.self, value: [slot])
            .allowsHitTesting(false)
    }

    private func refresh() {
        guard let area = area ?? frame else { return }
        stage?.showPattern(pattern, in: area, quiet: quiet, rise: rise, slot: slot, carrier: carrier)
    }
}
