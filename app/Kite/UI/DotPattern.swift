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
    var carrier: DotCarrier?
}

/// 图案的交互输入：指针所在（窗口坐标）、打字的活跃度与声音的响度。逐帧读取，不引起视图更新。
struct PatternInput {
    var pointer: CGPoint?
    var activity = 0.0
    var activityAt = Date.distantPast
    /// 表达式里的 v（0～1），留给语音输入或系统播放的声音；音源接入前恒为 0。
    var sound = 0.0

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
    static let leaveDuration: TimeInterval = 0.45
    /// 长出来或形变完所需的最长时间，过后不再算旧图案。
    static let settled: TimeInterval = 1.3
    static let activityStep = 0.22
    static let activityDecay = 0.5
    /// 压字的范围里留多少，离开范围多远（格）回到原样。
    static let quietFloor = 0.12
    static let quietReach = 3.0
}

/// 一块图案只随位置、大小和压字范围变的逐格量，按行排满整块：表达式里只与格位有关的变量，以及压字处收弱的系数。
/// 舞台按图案记下，这些不变就一直沿用，每帧只算随时间和输入变的部分。
nonisolated struct PatternGrid: Sendable {
    let columns: ClosedRange<Int>
    let rows: ClosedRange<Int>
    let quiet: [PatternQuiet]
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

    init(columns: ClosedRange<Int>, rows: ClosedRange<Int>, quiet: [PatternQuiet]) {
        self.columns = columns
        self.rows = rows
        self.quiet = quiet
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
        let x = vDSP.add(-(w / 2).rounded(.down), column), y = vDSP.add(-(h / 2).rounded(.down), row)
        self.column = column
        self.row = row
        self.x = x
        self.y = y
        i = vDSP.add(column, vDSP.multiply(w, row))
        r = vDSP.hypot(x, y)
        a = vForce.atan2(x: x, y: y)
        quietFactors = quiet.isEmpty ? [] : Self.factors(quiet, columns: columns, rows: rows)
    }

    func matches(columns: ClosedRange<Int>, rows: ClosedRange<Int>, quiet: [PatternQuiet]) -> Bool {
        self.columns == columns && self.rows == rows && self.quiet == quiet
    }

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
    let grid: PatternGrid

    /// 交给着色器（DotField.metal）的一块图案：可见范围里每格的取值（带正负，已乘上长出、形变、收回和收弱）整批算好，
    /// 按行追加到 values；表头按 patternStride 排，颜色由着色器按取值混。算法与下面逐格的 dot 相同。
    /// hidden 是整格被遮掉的格子：可见的几列全被遮掉的行不算，其余的行按连续的几段各追加一条。
    func appendShaderData(to header: inout [Float], values: inout [Float], columns visibleColumns: ClosedRange<Int>,
                          rows visibleRows: ClosedRange<Int>, hidden: [(columns: Range<Int>, rows: Range<Int>)], at date: Date, live: Bool) {
        guard let pattern, columns.overlaps(visibleColumns), rows.overlaps(visibleRows) else { return }
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
        } else if elapsed < PatternMotion.growSpread + DotMetrics.morphDuration {
            // 由中心向外长出来；全部长完后系数都是 1，不用再乘
            let reach = hypot(w / 2, h / 2)
            value = vDSP.multiply(value, eased(reach > 0 ? vDSP.multiply(PatternMotion.growSpread / reach, grid.r[range]) : zeros()))
        }
        if let leaving, live {
            value = vDSP.multiply(1 - easeOutCubic(date.timeIntervalSince(leaving) / PatternMotion.leaveDuration), value)
        }
        if !grid.quietFactors.isEmpty {
            value = vDSP.multiply(value, grid.quietFactors[range])
        }

        func color(_ color: DotColor) -> [Float] { [Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha)] }
        let earlier = previous ?? pattern
        header += [Float(shownColumns.lowerBound), Float(shownColumns.upperBound), Float(shownRows.lowerBound), Float(shownRows.upperBound),
                   Float(values.count), Float(columns.lowerBound), Float(rows.lowerBound), Float(w + h - 2),
                   Float(min(elapsed, 1e9)), previous == nil ? 0 : 1, Float(pattern.form.index), Float(earlier.form.index)]
        header += color(pattern.positive) + color(pattern.negative) + color(earlier.positive) + color(earlier.negative)
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

    func dot(column: Int, row: Int, at date: Date, live: Bool, rest: DotColor) -> Dot? {
        guard columns.contains(column), rows.contains(row) else { return nil }
        let w = Double(columns.count), h = Double(rows.count)
        let x = Double(column - columns.lowerBound) - (w / 2).rounded(.down)
        let y = Double(row - rows.lowerBound) - (h / 2).rounded(.down)
        var scope = DotExpression.Scope()
        scope[.t] = live ? date.timeIntervalSince(start) : 0
        scope[.x] = x
        scope[.y] = y
        scope[.w] = w
        scope[.h] = h
        scope[.i] = Double(row - rows.lowerBound) * w + Double(column - columns.lowerBound)
        scope[.r] = hypot(x, y)
        scope[.a] = atan2(y, x)
        scope[.px] = pointer.map { x - $0.x } ?? 999
        scope[.py] = pointer.map { y - $0.y } ?? 999
        scope[.d] = hypot(scope[.px], scope[.py])
        scope[.k] = activity
        scope[.v] = sound

        let elapsed = live ? date.timeIntervalSince(changed) : .infinity
        var value = 0.0
        var colors = pattern
        if let pattern {
            value = pattern.expression.evaluate(scope)
            if let previous {
                // 沿对角线从左上到右下逐格换过去
                let span = Double(columns.count + rows.count - 2)
                let delay = span > 0 ? Double(column - columns.lowerBound + row - rows.lowerBound) / span * PatternMotion.morphSpread : 0
                let eased = easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
                value = previous.expression.evaluate(scope) * (1 - eased) + value * eased
                if eased < 0.5 { colors = previous }
            } else {
                // 由中心向外长出来
                let reach = hypot(w / 2, h / 2)
                let delay = reach > 0 ? scope[.r] / reach * PatternMotion.growSpread : 0
                value *= easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
            }
        }
        if let leaving, live {
            value *= 1 - easeOutCubic(date.timeIntervalSince(leaving) / PatternMotion.leaveDuration)
        }
        if !quiet.isEmpty {
            let square = DotMetrics.square(column: column, row: row)
            var factor = 1.0
            for quiet in quiet {
                let distance = Double(DotMetrics.distance(between: square, and: quiet.rect) / DotMetrics.pitch)
                factor = min(factor, quiet.floor + (1 - quiet.floor) * smoothstep(distance / PatternMotion.quietReach))
            }
            value *= factor
        }
        let shape = abs(value)
        guard shape > 1.0 / 512, let colors else { return nil }
        let color = rest.mixed(with: value >= 0 ? colors.positive : colors.negative, by: min(1, shape * 1.6))
        return Dot(colors.form, shape: shape, color: color)
    }
}

/// 在一块区域上铺点阵签名：自己只占位，图案交给所在窗口的舞台。指针划过和打字由使用方报给舞台。
/// 给出 area 时铺在那里（如整个窗口，连同标题栏和控制区后面），否则铺满自己占的位置。
struct DotPatternArea: View {
    let pattern: DotPattern?
    /// 收弱的范围；坐标与 area 相同：窗口坐标，在会移动的卡片里是卡片坐标。
    var quiet: [PatternQuiet] = []
    var area: CGRect?
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
            .onDisappear { stage?.showPattern(nil, in: .zero, slot: slot) }
            .preference(key: DotSlots.self, value: [slot])
            .allowsHitTesting(false)
    }

    private func refresh() {
        guard let area = area ?? frame else { return }
        stage?.showPattern(pattern, in: area, quiet: quiet, slot: slot, carrier: carrier)
    }
}
