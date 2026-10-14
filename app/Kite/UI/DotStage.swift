import SwiftUI

/// 点阵舞台：一个 App 窗口只有一套点阵，像一块显示屏，每个模块是一个像素。组件只占位，把图案（mask）交给所在窗口的舞台；
/// App 背景和窗口卡片上的 DotCanvas 都只是这块屏的取景框，画的是同一份状态里落在自己范围内的那部分。
/// 坐标统一用窗口坐标（SwiftUI 的 .global）：原点是窗口左上角，每个模块（步距 p）的中心一颗点；窗口卡片的边缘不一定落在模块线上。
///
/// 静息网点是屏的底色：宽屏有开启点阵的窗口时由窗口画，没有时由 App 背景画；
/// 窄屏 App 背景一直画，开启点阵的窗口也画，连成一块屏。
/// 各取景框格位一致，卡片移动时格位不跟着挪；摆在卡片上的图形跟着卡片走，见 DotCarrier。
/// 图案按摆上去的先后叠加，后摆上的按覆盖度盖在上面；波和轨迹最后按取大叠上去。
/// 事件（如发送消息的波）只在一段时间里抬高经过的格子，结束后格子退回静息的点。
/// 每个图形占一个位置（slot），格子一直长着，换图形时逐格形变过去；组件消失时用 remove 直接撤掉。
/// 图案落在两格之间（随滚动或卡片位移）时不取整，由相邻格按位置插值显示。
/// 图形的各层可以有自己的小动画（浮动、闪烁、脉冲、帧序列）：格子始终在格位上，浮动时动的是各格从图形内容里分到的形变量
/// （亚格重采样，同 Pigeon 的格阵）。换图形时先停下，形变完再动起来。
@MainActor @Observable
final class DotStage {
    private var waves: [DotWave] = []
    private var slots: [String: FigureSlot] = [:]
    /// 新 slot 的叠放次序，越大越靠上。
    @ObservationIgnored private var nextOrder = 0
    /// 指针或手指在空白画板上划过时点亮的格子，键是格位，值是点亮的时刻。
    @ObservationIgnored private var sparks: [DotCell: Date] = [:]
    /// 有不限窗口的波、形变或轨迹在走时为 true，所有取景框都要刷新。
    private var ticking = false
    /// 只画在某个窗口里的波还在走的窗口（DotScope）：只带动那个窗口的取景框，App 背景和别的窗口不跟着逐帧刷新。
    private var wavingScopes: Set<ObjectIdentifier> = []
    /// 按弹簧走的波，每个窗口（不限窗口的是 nil）推过几道：每推一道加一，取景框按 springAnimation 逐帧插值（见 springProgress），
    /// 减去起步时的值就是波这一帧走了多少。
    private var springs: [ObjectIdentifier?: Double] = [:]
    /// 最近一道按弹簧走的波的弹簧。取景框自己按它插值，不靠外面传进来的动画：原生卡片的点阵层托管在自己的视图里，接不到外面事务里的动画。
    private(set) var springAnimation: Animation?
    /// 铺满一块区域的图案（点阵签名），见 DotPattern。
    private var patterns: [String: PatternSlot] = [:]
    @ObservationIgnored private var patternRequests: [String: PatternRequest] = [:]
    @ObservationIgnored private var patternInputs: [String: PatternInput] = [:]
    /// 各图案上一帧用的 PatternGrid，位置、大小和压字范围不变就接着用。
    @ObservationIgnored private var patternGrids: [String: PatternGrid] = [:]
    /// 取景框（rect，窗口坐标）是否要逐帧刷新，静息时不耗电：有不限窗口的事件走时都刷新，限在窗口里的波只刷新那个窗口（scope）；
    /// 呼吸、在动的图形和图案只带动与它相交、画它们的取景框（carrier、scope 对得上，见 field）；不画图案的取景框不受图案带动。
    func animating(in rect: CGRect, carrier: DotCarrier? = nil, patterns drawsPatterns: Bool = true, scope: DotScope? = nil) -> Bool {
        if ticking || scope.map({ wavingScopes.contains(ObjectIdentifier($0)) }) == true { return true }
        // 浮动至多偏出一格
        let near = rect.insetBy(dx: -DotMetrics.pitch, dy: -DotMetrics.pitch)
        let window = scope.map(ObjectIdentifier.init)
        return slots.contains { key, slot in
            slot.carrier === carrier && slot.drawn(in: window) && (slot.breathing || slot.figure?.figure.moves == true) && figureFrame(key)?.intersects(near) == true
        } || drawsPatterns && patterns.values.contains {
            $0.carrier === carrier && ($0.carrier?.rest.apply($0.area) ?? $0.area).intersects(near)
        }
    }

    /// 有摆在这张卡片上的图形或图案。
    func carries(_ carrier: DotCarrier) -> Bool {
        slots.values.contains { $0.carrier === carrier && ($0.figure != nil || $0.previous != nil) }
            || patterns.values.contains { $0.carrier === carrier }
    }
    /// slot 上正拼着的图形。
    func shownFigure(_ slot: String = FigureSlot.main) -> DotFigure? { slots[slot]?.figure?.figure }
    /// slot 上的图形在窗口坐标中占的范围。
    func figureFrame(_ slot: String = FigureSlot.main) -> CGRect? {
        guard let shown = slots[slot] else { return nil }
        return (shown.carrier?.carry(shown) ?? shown).figure?.frame
    }
    @ObservationIgnored private var activeUntil = Date.distantPast
    @ObservationIgnored private var settle: Task<Void, Never>?
    /// 各 slot 最近一次要摆的图形；被所在内容的离场收起时留着，回到场上再摆回去。
    @ObservationIgnored private var requests: [String: Request] = [:]
    /// 收起了各 slot 的离场层，见 DotsPresence。
    @ObservationIgnored private var hiders: [String: Set<String>] = [:]

    private struct PatternRequest {
        var pattern: DotPattern
        var area: CGRect
        var quiet: [PatternQuiet]
        var rise: CGFloat?
        var carrier: DotCarrier?
    }

    /// 在 slot 上把 pattern 铺满 area（窗口坐标；给出 carrier 时是卡片坐标），nil 让图案收回。
    /// 从无到有时由中心向外长出来，换图案时沿对角线逐格形变；quiet 是文字压在上面的范围，图案在那里收弱；rise 见 PatternSlot.rise。
    func showPattern(_ pattern: DotPattern?, in area: CGRect, quiet: [PatternQuiet] = [], rise: CGFloat? = nil, slot: String,
                     carrier: DotCarrier? = nil) {
        patternRequests[slot] = pattern.map { PatternRequest(pattern: $0, area: area, quiet: quiet, rise: rise, carrier: carrier) }
        placePattern(slot)
    }

    /// 指针在图案上的位置（窗口坐标），离开时给 nil。
    func patternPointer(_ point: CGPoint?, slot: String) {
        patternInputs[slot, default: PatternInput()].pointer = point
    }

    /// 图案随 level 的响度起伏（表达式里的 v）；nil 时 v 回到 0。
    func patternSound(_ level: AudioLevel?, slot: String) {
        patternInputs[slot, default: PatternInput()].sound = level
    }

    /// 打了一下字：图案的活跃度加一截，随后慢慢落回去。
    func patternKeystroke(slot: String) {
        var input = patternInputs[slot] ?? PatternInput()
        input.activity = min(1, input.level(at: .now) + PatternMotion.activityStep)
        input.activityAt = .now
        patternInputs[slot] = input
    }

    private func placePattern(_ slot: String) {
        let request = hiders[slot] == nil ? patternRequests[slot] : nil
        let now = Date.now
        guard var current = patterns[slot] else {
            guard let request else { return }
            patterns[slot] = PatternSlot(pattern: request.pattern, changed: now, start: now,
                                         area: request.area, quiet: request.quiet, rise: request.rise, carrier: request.carrier)
            return
        }
        if let request {
            var changed = current.area != request.area || current.quiet != request.quiet || current.rise != request.rise
                || current.carrier !== request.carrier
            if current.leaving != nil {
                // 收回途中又摆回来：重新长出来
                current.previous = nil
                current.changed = now
                current.leaving = nil
                changed = true
            } else if current.pattern != request.pattern {
                current.previous = current.pattern
                current.changed = now
                changed = true
            }
            guard changed else { return }
            current.pattern = request.pattern
            current.area = request.area
            current.quiet = request.quiet
            current.rise = request.rise
            current.carrier = request.carrier
            patterns[slot] = current
        } else if current.leaving == nil {
            current.leaving = now
            patterns[slot] = current
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(PatternMotion.leaveDuration + 0.05))
                guard let self, self.patterns[slot]?.leaving == now else { return }
                self.patterns[slot] = nil
                self.patternGrids[slot] = nil
            }
        }
    }

    /// carrier 上的图案；指针按 follow（见 field）换算到卡片停着时的位置。
    private func resolvedPatterns(at date: Date, live: Bool, carrier: DotCarrier?, follow: DotCarrier.Mapping?) -> [ResolvedPattern] {
        patterns.compactMap { key, slot in
            guard slot.carrier === carrier else { return nil }
            let mapping = slot.carrier?.rest
            let area = mapping?.apply(slot.area) ?? slot.area
            let pitch = DotMetrics.pitch
            let cells = DotMetrics.cells(within: area)
            guard !cells.columns.isEmpty, !cells.rows.isEmpty else { return nil }
            let columns = cells.columns.lowerBound, lastColumn = cells.columns.upperBound - 1
            let rows = cells.rows.lowerBound, lastRow = cells.rows.upperBound - 1
            let input = patternInputs[key] ?? PatternInput()
            let bottom = slot.rise != nil
            let center = (x: Double(columns) + Double((lastColumn - columns + 1) / 2),
                          y: Double(rows + PatternGrid.originRow(height: lastRow - rows + 1, bottom: bottom)))
            let pointer = input.pointer.map { follow?.apply($0) ?? $0 }
                .map { (x: Double($0.x / pitch) - 0.5 - center.x, y: Double($0.y / pitch) - 0.5 - center.y) }
            // 形变走完就不再算旧图案
            let previous = live && date.timeIntervalSince(slot.changed) < PatternMotion.settled ? slot.previous : nil
            let quiet = slot.quiet.map { $0.mapped(by: mapping) }
            return ResolvedPattern(pattern: slot.pattern, previous: previous, changed: slot.changed, leaving: slot.leaving,
                                   start: slot.start, columns: columns...lastColumn, rows: rows...lastRow,
                                   quiet: quiet, pointer: pointer,
                                   activity: live ? input.level(at: date) : 0, sound: live ? input.sound?.level(at: date) ?? 0 : 0,
                                   rise: slot.rise.map { Double($0 * (mapping?.scale ?? 1) / pitch) },
                                   grid: grid(key, columns: columns...lastColumn, rows: rows...lastRow, quiet: quiet, bottom: bottom))
        }
    }

    private func grid(_ slot: String, columns: ClosedRange<Int>, rows: ClosedRange<Int>, quiet: [PatternQuiet], bottom: Bool) -> PatternGrid {
        if let grid = patternGrids[slot], grid.matches(columns: columns, rows: rows, quiet: quiet, bottom: bottom) { return grid }
        let grid = PatternGrid(columns: columns, rows: rows, quiet: quiet, bottom: bottom)
        patternGrids[slot] = grid
        return grid
    }

    private struct Request {
        var figure: DotFigure
        var area: CGRect
        var placement: PlacedFigure.Placement
        var clip: CGRect?
        var breathing: Bool
        var carrier: DotCarrier?
        var scope: DotScope?
    }

    /// 从 origin（窗口坐标）向四周推开一道波；不给 form 时取方格终态。pace 小于 1 时整道波放慢，用于不赶时间的场景。
    /// 给出 scope 时波只画在那个窗口里，App 背景和别的窗口不画，见 DotScope。
    /// 按弹簧走的波，弹簧交给 SwiftUI 的动画跑，和同一次更新里起步的动画同一帧起步：自己按时钟走的话，
    /// iPhone 上发送那一次排版要近百毫秒，第一帧就跳过一大截（2026-10-11 实测）。
    func emitWave(from origin: CGRect, form: DotForm? = nil, pace: Double = 1, parameters: DotWave.Parameters = .init(),
                  in scope: DotScope? = nil) {
        var wave = DotWave(origin: origin, start: .now, form: form ?? .square, pace: pace, parameters: parameters,
                           scope: scope.map(ObjectIdentifier.init))
        if let spring = parameters.spring {
            let base = springs[wave.scope] ?? 0
            wave.springBase = base
            springs[wave.scope] = base + 1
            let animation = Animation.spring(spring).speed(pace)
            if springAnimation != animation { springAnimation = animation }
        }
        waves.append(wave)
        if let scope = wave.scope { wavingScopes.insert(scope) }
        keepAnimating(for: wave.duration, everywhere: wave.scope == nil)
    }

    /// 在 slot 上按 placement 把 figure 摆进 area（窗口坐标），nil 让图形退回静息的点。换成另一个图形时逐格形变过去；
    /// 只是区域变了（窗口改大小、内容滚动）就直接挪过去。breathing 时图形按等待呼吸起伏。
    /// clip 是图案可见的范围（同 area 的坐标），出了范围的格子不显示，像窗口裁掉滚出去的内容。
    /// 摆在会移动的卡片上时给出 carrier，area 与 clip 用卡片坐标（DotCarrier.space）：卡片走着的时候图形随它在点阵上滑过去。
    /// 摆在自己画点阵的窗口里时给出 scope，图形只由这个窗口的取景框画，见 FigureSlot.scope。
    func show(_ figure: DotFigure?, in area: CGRect, placement: PlacedFigure.Placement = .center,
              clip: CGRect? = nil, breathing: Bool = false, slot: String = FigureSlot.main, carrier: DotCarrier? = nil,
              scope: DotScope? = nil) {
        requests[slot] = figure.map {
            Request(figure: $0, area: area, placement: placement, clip: clip, breathing: breathing, carrier: carrier, scope: scope)
        }
        place(slot)
    }

    /// owner 所在的内容离场（hidden）或回到场上时，收起或摆回 slots 上的图形。见 DotsPresence。
    func setHidden(_ slots: Set<String>, by owner: String, _ hidden: Bool) {
        for slot in slots {
            let was = hiders[slot] != nil
            if hidden {
                hiders[slot, default: []].insert(owner)
            } else {
                hiders[slot]?.remove(owner)
                if hiders[slot]?.isEmpty == true { hiders[slot] = nil }
            }
            if was != (hiders[slot] != nil) {
                place(slot)
                placePattern(slot)
            }
        }
    }

    /// owner 随所在内容一起移除：只去掉它的登记，不把收起的图形摆回去，图形由各自的组件消失时撤掉。
    func release(_ slots: Set<String>, by owner: String) {
        for slot in slots {
            hiders[slot]?.remove(owner)
            if hiders[slot]?.isEmpty == true { hiders[slot] = nil }
        }
    }

    private func place(_ slot: String) {
        let request = hiders[slot] == nil ? requests[slot] : nil
        let figure = request?.figure, area = request?.area ?? .zero, placement = request?.placement ?? .center
        let clip = request?.clip, breathing = request?.breathing ?? false
        // 收回途中照样跟着原来的卡片：卡片正在走（比如在拉开的侧边栏里切页面）时，换成按停着的位置画会从窗口里跳到屏幕中间
        let carrier = request?.carrier ?? slots[slot]?.carrier
        // 收回途中也照样只由原来的窗口画
        let scope = request.map { $0.scope.map(ObjectIdentifier.init) } ?? slots[slot]?.scope
        guard figure != nil || slots[slot] != nil else { return }
        var current = slots[slot] ?? FigureSlot(order: nextOrder)
        if slots[slot] == nil { nextOrder += 1 }
        current.carrier = carrier
        current.scope = scope
        let placed = figure.map { figure in
            carrier.map { PlacedFigure(figure, in: $0.rest.apply(area), placement: placement, area: area,
                                       clip: clip.map($0.rest.apply), localClip: clip) }
                ?? PlacedFigure(figure, in: area, placement: placement, clip: clip)
        }
        current.breathing = breathing && placed != nil
        if placed == current.figure {
            if slots[slot]?.breathing != current.breathing || slots[slot]?.carrier !== carrier || slots[slot]?.scope != scope {
                slots[slot] = current
            }
            return
        }
        if let placed, placed.figure == current.figure?.figure {
            // 换摆放方式（滚动开始或停下）时整格与亚格位置差不到一格，从原来的位置滑过去，不跳。
            if let old = current.figure, old.placement != placed.placement {
                let residual = current.settleResidual(at: .now)
                let x = Double(old.column) + old.shiftX + residual.x - Double(placed.column) - placed.shiftX
                let y = Double(old.row) + old.shiftY + residual.y - Double(placed.row) - placed.shiftY
                if abs(x) > 0.001 || abs(y) > 0.001 {
                    current.settle = (x, y)
                    current.settleStart = .now
                    keepAnimating(for: FigureSlot.settleDuration)
                }
            }
            current.figure = placed
            current.previous = nil
            slots[slot] = current
            return
        }
        current.previous = current.figure
        current.figure = placed
        current.start = .now
        slots[slot] = current
        keepAnimating(for: DotFigure.transition)
    }

    /// 在 point（窗口坐标）附近留下轨迹，越远越淡，随后慢慢退回静息的点。
    func trace(at point: CGPoint) {
        let (column, row) = DotMetrics.cell(at: point)
        let now = Date.now
        sparks = sparks.filter { now.timeIntervalSince($0.value) < DotSpark.duration }
        sparks[DotCell(column: column, row: row)] = now
        for dr in -DotSpark.radius...DotSpark.radius {
            for dc in -DotSpark.radius...DotSpark.radius {
                let distance = hypot(Double(dc), Double(dr))
                guard distance > 0, distance <= Double(DotSpark.radius) else { continue }
                let age = DotSpark.halo * distance
                let cell = DotCell(column: column + dc, row: row + dr)
                if sparks[cell].map({ now.timeIntervalSince($0) > age }) ?? true {
                    sparks[cell] = now - age
                }
            }
        }
        keepAnimating(for: DotSpark.duration)
    }

    /// 取景框所在窗口的波和不限窗口的波各自的弹簧进度。取景框把它当成可动画的值，按 springAnimation 逐帧插值后交回 field。
    func springProgress(in scope: DotScope?) -> AnimatablePair<Double, Double> {
        AnimatablePair(springs[scope.map(ObjectIdentifier.init)] ?? 0, springs[.none] ?? 0)
    }

    /// date 时刻的取值快照，供一帧绘制使用。live 为 false（静息或减少动态效果）时不呼吸；
    /// patterns 为 false 时不含图案，逐格求值的图案只由画它的取景框算。scope 是取景框所在的窗口，只含不限窗口的波和图形，以及这个窗口的。
    /// springs 是取景框这一帧插值到的弹簧进度，见 springProgress。
    /// carrier 是取景框画的那张卡片：只含摆在它上面的图形和图案，nil 时只含不在卡片上的。
    /// follow 是卡片正在走时，屏幕上的一点对应卡片停着时的哪里，摆在卡片上的图形和图案按它取样，跟着卡片走。
    func field(at date: Date, rest: DotColor, live: Bool, patterns drawsPatterns: Bool = true, scope: DotScope? = nil,
               springs: AnimatablePair<Double, Double>, carrier: DotCarrier? = nil, follow: DotCarrier.Mapping? = nil) -> DotField {
        let scope = scope.map(ObjectIdentifier.init)
        let waves = waves.compactMap { wave -> DotWave? in
            guard wave.isActive(at: date), wave.scope == nil || wave.scope == scope else { return nil }
            guard let base = wave.springBase else { return wave }
            var wave = wave
            wave.travelled = (wave.scope == nil ? springs.second : springs.first) - base
            return wave
        }
        return DotField(waves: waves,
                        palette: DotColor.palette, rest: rest,
                        slots: slots.values.compactMap { slot -> FigureSlot? in
                            guard slot.carrier === carrier, slot.drawn(in: scope) else { return nil }
                            return (slot.carrier?.carry(slot) ?? slot).settled(at: date, live: live)
                        }
                        .sorted { $0.order < $1.order },
                        breath: live ? WaitingBreath.opacity(at: date) : 1, moving: live,
                        sparks: live ? sparks : [:],
                        patterns: drawsPatterns ? resolvedPatterns(at: date, live: live, carrier: carrier, follow: follow) : [],
                        follow: follow)
    }

    /// everywhere 为 false 时只是限在窗口里的波，取景框按 wavingScopes 刷新，这里只负责到时收尾。
    private func keepAnimating(for duration: TimeInterval, everywhere: Bool = true) {
        activeUntil = max(activeUntil, .now + duration)
        if everywhere { ticking = true }
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, (self?.activeUntil.timeIntervalSinceNow ?? 0)) + 0.05))
            guard let self, !Task.isCancelled else { return }
            waves.removeAll { !$0.isActive(at: .now) }
            sparks = sparks.filter { Date.now.timeIntervalSince($0.value) < DotSpark.duration }
            for key in slots.keys { slots[key]?.previous = nil }
            slots = slots.filter { $0.value.figure != nil }
            requests = requests.filter { slots[$0.key] != nil || hiders[$0.key] != nil }
            ticking = false
            wavingScopes = []
        }
    }
}

/// 一张会移动的卡片（窄屏的窗口）。卡片里的内容按卡片自己的坐标（space）排，rest 是卡片停着时卡片坐标到窗口坐标的换算。
/// 摆在卡片上的图形和图案按 rest 落到点阵的格位上，停着时不插值、不发虚；卡片走着时由卡片的点阵层逐帧给出 follow，
/// 把屏幕上的每一格换算回卡片停着时的位置取样，图形随卡片平移、缩放，落在两格之间由相邻格插值（同浮动）。
/// 静息网点不跟着卡片动。
@MainActor @Observable
final class DotCarrier {
    /// 卡片内容的坐标空间。
    nonisolated static let space = "dot.carrier"

    /// 摆到点阵上的坐标：在会移动的卡片里（carrier 不为 nil）用卡片坐标，否则用窗口坐标。
    nonisolated static func coordinateSpace(_ carrier: DotCarrier?) -> CoordinateSpace { carrier == nil ? .global : .named(space) }

    /// 一个坐标到另一个坐标：p × scale + origin。
    nonisolated struct Mapping: Hashable, Sendable {
        var origin = CGPoint.zero
        var scale: CGFloat = 1

        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
        }

        func apply(_ rect: CGRect) -> CGRect {
            CGRect(origin: apply(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
        }

        var inverted: Mapping {
            Mapping(origin: CGPoint(x: -origin.x / scale, y: -origin.y / scale), scale: 1 / scale)
        }

        /// 先换算 other，再换算自己。
        func after(_ other: Mapping) -> Mapping {
            Mapping(origin: apply(other.origin), scale: scale * other.scale)
        }

        var transform: CGAffineTransform {
            CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(origin.x)
            hasher.combine(origin.y)
            hasher.combine(scale)
        }
    }

    /// 卡片停着时卡片坐标到窗口坐标的换算。
    var rest = Mapping()

    /// slot 上的图形（area 是卡片坐标）按卡片停着的位置摆到点阵上，图形本身不缩放。
    func carry(_ slot: FigureSlot) -> FigureSlot {
        func carried(_ placed: PlacedFigure) -> PlacedFigure {
            guard let area = placed.area else { return placed }
            return PlacedFigure(placed.figure, in: rest.apply(area), placement: placed.placement, area: area,
                                clip: placed.localClip.map(rest.apply), localClip: placed.localClip)
        }
        var slot = slot
        slot.figure = slot.figure.map(carried)
        slot.previous = slot.previous.map(carried)
        return slot
    }
}
