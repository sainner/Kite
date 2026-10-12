import SwiftUI

/// 窗口点阵上的一格。
nonisolated struct DotCell: Hashable, Sendable {
    let column: Int
    let row: Int
}

/// 画板上划过留下的轨迹：一下长到 peak，再缓缓收回静息的点。
nonisolated enum DotSpark {
    static let duration: TimeInterval = 1.4
    static let radius = 2
    /// 每离中心一格，多衰减这么久，边缘的格子就更小。
    static let halo: TimeInterval = 0.5
    static let peak = 0.7
    /// 轨迹的颜色在正中的不透明度，同默认的波。
    static let opacity = DotWave.Parameters().opacity

    static func shape(since start: Date, at date: Date) -> Double {
        let t = date.timeIntervalSince(start) / duration
        guard t >= 0, t < 1 else { return 0 }
        return peak * pow(1 - t, 2)
    }
}

/// 一道波：波前从起点区域的边缘向外推，经过的格子长成 form、从点色混到波的颜色，离开后退回点。
nonisolated struct DotWave: Sendable {
    let origin: CGRect
    let start: Date
    let form: DotForm
    /// 时间倍率，1 是约定的速度。
    var pace = 1.0
    let parameters: Parameters
    /// 只画在这个窗口里（DotScope），nil 时各个取景框都画。
    let scope: ObjectIdentifier?
    /// 按弹簧走的波起步时舞台里的弹簧进度，见 DotStage.emitWave。
    var springBase: Double?
    /// 按弹簧走的波这一帧走了多少（到 reach 为 1），由取景框按插值到的弹簧进度给出，见 DotStage.field。
    var travelled: Double?

    /// 波的参数，默认值给初始配置完成一步、扫到码、连接成功时的慢波（再按 pace 放慢）；发送消息的波见 ThreadControls。
    struct Parameters: Equatable, Sendable {
        /// 每秒推进多少点。
        var speed = 420.0
        /// 波前按这个弹簧从起点走向 reach，和同一次更新里用同一弹簧的动画一起走（见 DotStage.emitWave）；给出时不看 speed。
        var spring: Spring?
        /// 波前的半宽（点），三个模块。
        var width = 36.0
        /// 走到 reach 时的半宽，一路从 width 匀着变过去；nil 是不变。
        var widthEnd: Double?
        /// 波前走到这么远（点）为止，十个模块。
        var reach = 120.0
        /// 弓形的波：波前是一段圆弧，圆心在起点区域顶边中点往下这么远（点），中间先走、两边落后；
        /// nil 时波前与起点区域的边缘平行。
        var bow: Double?
        /// 走到 reach 的几成处开始变弱；0 是一出发就渐弱。
        var fadeStart = 0.0
        /// 走到 reach 的几成处淡尽。
        var fadeEnd = 1.0
        /// 波前正中那一格长到多大（shape）。
        var peak = 1.0
        /// 波的颜色在波前正中的不透明度，压低后波不那么抢眼。
        var opacity = 0.4
    }

    var duration: TimeInterval {
        (parameters.spring?.settlingDuration ?? parameters.reach / max(parameters.speed, 1)) / max(pace, 0.01)
    }

    func isActive(at date: Date) -> Bool {
        let elapsed = date.timeIntervalSince(start)
        return elapsed >= 0 && elapsed < duration
    }

    /// date 时刻波前离起点多远（点）、半宽多少、正中那一格多大；不在走或已经淡尽时为 nil。
    func front(at date: Date) -> (distance: Double, width: Double, amplitude: Double)? {
        let time = date.timeIntervalSince(start) * pace
        let travelled = parameters.spring == nil ? time * parameters.speed / max(parameters.reach, 1) : self.travelled ?? 0
        let width = parameters.width + ((parameters.widthEnd ?? parameters.width) - parameters.width) * travelled
        guard time >= 0, travelled < min(parameters.fadeEnd, 1), width > 0 else { return nil }
        let fade = 1 - smoothstep((travelled - parameters.fadeStart) / max(parameters.fadeEnd - parameters.fadeStart, 0.001))
        return (parameters.reach * travelled, width, fade * parameters.peak)
    }

    /// 格子离起点多远（点）：到起点区域的距离；弓形的波是格心到起点圆弧的距离，在弧里面为负。
    func distance(to square: CGRect) -> Double {
        guard let bow = parameters.bow else { return Double(DotMetrics.distance(between: square, and: origin)) }
        return hypot(square.midX - origin.midX, square.midY - origin.minY - bow) - bow
    }

    func shape(at square: CGRect, date: Date) -> Double {
        guard let front = front(at: date) else { return 0 }
        let x = abs(distance(to: square) - front.distance) / front.width
        guard x < 1 else { return 0 }
        return (1 - smoothstep(x)) * front.amplitude
    }
}

/// 一帧的取值：静息的点，加上背景上的图形和经过的波。
nonisolated struct DotField: Sendable {
    let waves: [DotWave]
    let palette: [DotColor]
    let rest: DotColor
    let slots: [FigureSlot]
    /// 呼吸着的图形此刻的不透明度系数。
    let breath: Double

    /// 图形在动（不是静息、没开减少动态效果）。
    let moving: Bool
    let sparks: [DotCell: Date]
    let patterns: [ResolvedPattern]
    /// 所在卡片正在走：屏幕上的一点对应卡片停着时的哪里。图形和图案按停着的位置摆，每格把格心换算过去取样，
    /// 跟着卡片走；波、轨迹和静息的点不跟着走。见 DotCarrier。
    let follow: DotCarrier.Mapping?

    func dot(column: Int, row: Int, at date: Date) -> Dot {
        dot(column: column, row: row, at: date, figures: figureFrames(at: date))
    }

    private func dot(column: Int, row: Int, at date: Date, figures: [FigureFrame]) -> Dot {
        // 先按叠放次序把各图案合成到静息的点上，再叠波和轨迹
        var dot = Dot(.square, shape: 0, color: rest)
        let center = DotMetrics.center(column: column, row: row)
        let point = follow?.apply(center) ?? center
        // 图案铺在最底下，图形叠在它上面
        for pattern in patterns {
            if let value = pattern.dot(at: point, at: date, live: moving, rest: rest) { dot = value }
        }
        for figure in figures {
            if let cell = figureCell(figure, at: point) {
                dot = DotBlend.normal.composite(cell, over: dot)
            }
        }
        let square = DotMetrics.square(column: column, row: row)
        var shape = 0.0
        var form = DotForm.square
        var opacity = 0.0
        for wave in waves {
            let value = wave.shape(at: square, date: date)
            if value > shape {
                shape = value
                form = wave.form
                opacity = wave.parameters.opacity
            }
        }
        if !sparks.isEmpty, let start = sparks[DotCell(column: column, row: row)] {
            let spark = DotSpark.shape(since: start, at: date)
            if spark > shape {
                shape = spark
                opacity = DotSpark.opacity
            }
        }
        var target = DotColor.palette(column: column, row: row, in: palette)
        target.alpha *= opacity
        // 波只占图案之外剩余的幅度，交接处不因大小刚好反超而跳色；满格图案保留原色。
        let lit = DotBlend.lighten.composite(DotSample(shape: shape, color: target, coverage: 1), over: dot)
        return shape > dot.shape ? Dot(form, shape: lit.shape, color: lit.color) : dot
    }

    /// 一个图形位置这一帧的样子，各格共用：新旧图形各自按此刻的幅度摆好。
    private struct FigureFrame {
        let slot: FigureSlot
        let elapsed: TimeInterval
        let to: PosedFigure?
        let from: PosedFigure?
    }

    /// 旧图形一开始形变就在 0.3 秒内停下回正，新图形形变完后 0.8 秒内动起来。
    private func figureFrames(at date: Date) -> [FigureFrame] {
        slots.map { slot in
            let elapsed = date.timeIntervalSince(slot.start)
            return FigureFrame(slot: slot, elapsed: elapsed,
                               to: slot.figure?.posed(at: date, amplitude: moving ? smoothstep((elapsed - DotFigure.transition) / 0.8) : 0),
                               from: slot.previous?.posed(at: date, amplitude: moving ? 1 - smoothstep(elapsed / 0.3) : 0))
        }
    }

    /// 图形在 point（一格的格心，见 dot）的取值；形变中从旧图形（或静息的点）缓出到新图形（或静息的点）。
    private func figureCell(_ frame: FigureFrame, at point: CGPoint) -> DotSample? {
        let slot = frame.slot, figure = slot.figure, previousFigure = slot.previous
        let elapsed = frame.elapsed
        let to = frame.to?.sample(at: point, rest: rest)
        let from = frame.from?.sample(at: point, rest: rest)
        guard to != nil || from != nil else { return nil }
        var eased = 1.0
        if let previousFigure, let figure {
            let first = min(previousFigure.column + previousFigure.row, figure.column + figure.row)
            let last = max(previousFigure.column + previousFigure.figure.columns + previousFigure.row + previousFigure.figure.rows,
                           figure.column + figure.figure.columns + figure.row + figure.figure.rows) - 2
            // point 所在格的列号加行号，跟着卡片走时可以在两格之间
            let diagonal = Double((point.x + point.y) / DotMetrics.pitch) - 1
            let delay = last > first ? (diagonal - Double(first)) / Double(last - first) * DotFigure.stagger : 0
            eased = easeOutCubic((elapsed - delay) / DotMetrics.morphDuration)
        } else if previousFigure != nil || figure != nil {
            // 从无到有或整体收回：所有格子一起形变。
            eased = easeOutCubic(elapsed / DotMetrics.morphDuration)
        }
        var target = to?.color ?? rest
        if to != nil, slot.breathing { target.alpha *= breath }
        // 旧图案按 1 − eased、新图案按 eased 计入覆盖度，颜色按各自覆盖的份量混合
        let fromWeight = (from?.coverage ?? 0) * (1 - eased), toWeight = (to?.coverage ?? 0) * eased
        let coverage = fromWeight + toWeight
        guard coverage > 0 else { return nil }
        let shape = (from?.shape ?? 0) * (1 - eased) + (to?.shape ?? 0) * eased
        let color = (from?.color ?? rest).mixed(with: target, by: toWeight / coverage)
        return DotSample(shape: shape, color: color, coverage: coverage)
    }

    /// 这一帧交给着色器（DotField.metal）的样子。图形与轨迹覆盖到的格子在这里按 dot 算好，放进按格位散列的表；
    /// 图案（点阵签名）铺满整块区域，格子多，可见的部分整批求值后按行列直接排给着色器；其余格子只有经过的波和静息的点，由着色器逐像素算。
    /// origin 是画布左上角的窗口坐标，scale 是画布坐标到窗口坐标的缩放，pixel 是一像素合多少窗口点，bounds 是画布在窗口里的范围。
    /// drawsRest 为 false 时不画静息的点，只留图形、图案、波和轨迹。hidden 是画布被遮掉的范围（窗口坐标），那里不用算。
    func shader(origin: CGPoint, scale: CGFloat, pixel: CGFloat, bounds: CGRect, at date: Date, drawsRest: Bool = true,
                hidden: [CGRect] = []) -> Shader {
        var waveFloats = waves.flatMap { wave -> [Float] in
            guard let front = wave.front(at: date) else { return [] }
            return [wave.origin.minX, wave.origin.minY, wave.origin.width, wave.origin.height, front.distance, wave.form.index,
                    front.width, front.amplitude, wave.parameters.opacity, wave.parameters.bow ?? -1]
                .map { Float($0) }
        }
        if waveFloats.isEmpty { waveFloats = [0] }
        let colors = palette.isEmpty ? DotColor.palette : palette
        let visible = DotMetrics.cells(covering: bounds)
        let hiddenCells = hidden.map(DotMetrics.cells(within:))
        var patternFloats: [Float] = [], patternValues: [Float] = []
        for pattern in patterns {
            pattern.appendShaderData(to: &patternFloats, values: &patternValues, columns: visible.columns, rows: visible.rows,
                                     hidden: hiddenCells, follow: follow, at: date, live: moving)
        }
        // 着色器的数组参数不能为空，空的给一个占位；占位比一条记录短，着色器按长度跳过。
        let hiddenFloats = hidden.flatMap { [Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)] }
        return ShaderLibrary.dotField(
            .float4(origin.x, origin.y, scale, pixel), rest.shaderValue, .float(drawsRest ? 1 : 0),
            .floatArray(cellTable(at: date, in: visible, hidden: hiddenCells)), .floatArray(waveFloats),
            .floatArray(colors.flatMap { [Float($0.red), Float($0.green), Float($0.blue), Float($0.alpha)] }),
            .floatArray(DotForm.shaderProfiles),
            .floatArray(patternFloats.isEmpty ? [0] : patternFloats), .floatArray(patternValues.isEmpty ? [0] : patternValues),
            .floatArray(hiddenFloats.isEmpty ? [0] : hiddenFloats))
    }

    /// 格表每格的数：列、行、终态序号（-1 是空位）、shape、不预乘的 sRGB 与透明度。
    static let cellStride = 8

    /// 开放寻址的格表，容量是 2 的幂且至少空一半，着色器按 slot 取位、顺次往后找。
    /// 只收落在画布范围（visible）里、图形分得到内容的格子（浮动、落在两格之间、跟着卡片走时连同相邻的格子，见 PosedFigure.forEachReachedCell）和轨迹，
    /// 算出来是静息的点就不收。这些格子按 dot 连同底下的图案一起算好，着色器查到就不再算图案；图案的其余格子由着色器算。
    /// 着色器每个像素只查自己那一格，范围外的格子不用算；整格落在 hidden 里的像素全被遮掉，也不用算。
    private func cellTable(at date: Date, in visible: (columns: ClosedRange<Int>, rows: ClosedRange<Int>),
                           hidden hiddenCells: [(columns: Range<Int>, rows: Range<Int>)]) -> [Float] {
        let visibleColumns = visible.columns, visibleRows = visible.rows
        let figures = figureFrames(at: date)
        // 各图形可能占到的范围（浮动、随卡片挪动至多偏出一格），在这些范围合起来的方框里按格记下要算的格子，不重复
        let posedFigures = figures.flatMap { [$0.to, $0.from] }.compactMap(\.self)
        let reaches = posedFigures.compactMap { posed -> (posed: PosedFigure, columns: ClosedRange<Int>, rows: ClosedRange<Int>)? in
            var (columns, rows) = posed.placed.reach
            if let follow {
                // 屏幕上换算回去落在这片格子里的格子
                (columns, rows) = DotMetrics.cells(covering: follow.inverted.apply(DotMetrics.rect(columns: columns, rows: rows)))
            }
            guard rows.overlaps(visibleRows), columns.overlaps(visibleColumns) else { return nil }
            return (posed: posed, columns: columns.clamped(to: visibleColumns), rows: rows.clamped(to: visibleRows))
        }
        let boxColumns = (reaches.map(\.columns.lowerBound).min() ?? 0)..<(reaches.map(\.columns.upperBound).max() ?? -1) + 1
        let boxRows = (reaches.map(\.rows.lowerBound).min() ?? 0)..<(reaches.map(\.rows.upperBound).max() ?? -1) + 1
        var cells: [DotCell] = []
        var marked = [Bool](repeating: false, count: boxColumns.count * boxRows.count)
        func mark(_ column: Int, _ row: Int) {
            guard boxColumns.contains(column), boxRows.contains(row) else { return }
            let index = (row - boxRows.lowerBound) * boxColumns.count + column - boxColumns.lowerBound
            guard !marked[index] else { return }
            marked[index] = true
            cells.append(DotCell(column: column, row: row))
        }
        for reach in reaches { reach.posed.forEachReachedCell(through: follow, mark) }
        for cell in sparks.keys where visibleColumns.contains(cell.column) && visibleRows.contains(cell.row) {
            if boxColumns.contains(cell.column), boxRows.contains(cell.row) { mark(cell.column, cell.row) } else { cells.append(cell) }
        }
        var dots: [(DotCell, Dot)] = []
        for cell in cells {
            if !hiddenCells.isEmpty, hiddenCells.contains(where: { $0.columns.contains(cell.column) && $0.rows.contains(cell.row) }) { continue }
            let dot = dot(column: cell.column, row: cell.row, at: date, figures: figures)
            if dot.shape > 1.0 / 512 || dot.color != rest { dots.append((cell, dot)) }
        }
        var capacity = 2
        while capacity < dots.count * 2 { capacity *= 2 }
        let stride = Self.cellStride
        var table = [Float](repeating: 0, count: capacity * stride)
        for slot in 0..<capacity { table[slot * stride + 2] = -1 }
        let mask = UInt32(capacity - 1)
        for (cell, dot) in dots {
            var slot = Int(Self.slot(column: cell.column, row: cell.row) & mask)
            while table[slot * stride + 2] >= 0 { slot = (slot + 1) & Int(mask) }
            let base = slot * stride
            table[base] = Float(cell.column)
            table[base + 1] = Float(cell.row)
            table[base + 2] = Float(dot.form.index)
            table[base + 3] = Float(dot.shape)
            table[base + 4] = Float(dot.color.red)
            table[base + 5] = Float(dot.color.green)
            table[base + 6] = Float(dot.color.blue)
            table[base + 7] = Float(dot.color.alpha)
        }
        return table
    }

    /// 格位的散列，与 DotField.metal 的 cellHash 一致。
    static func slot(column: Int, row: Int) -> UInt32 {
        let h = (UInt32(truncatingIfNeeded: column) &* 73_856_093) ^ (UInt32(truncatingIfNeeded: row) &* 19_349_663)
        return h ^ (h >> 16)
    }
}

/// 点阵共用的缓动，输入先截到 0...1。
nonisolated func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// 形变、长出与收回用的缓出。
nonisolated func easeOutCubic(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return 1 - pow(1 - t, 3)
}
