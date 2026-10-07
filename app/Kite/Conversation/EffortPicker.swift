import SwiftUI

/// 选 effort。平时只显示当前档位；触屏按下它、指针移上去，刻度线（见 EffortTicks）展开在档位名前面，档位名让到右边。
/// 触屏一按下档位名就展开，刻度线挪到当前档位落在手指下面，左边放不下就贴着左边。没拖就松手，留着展开，再点一下档位名收起；
/// 按下以后横着拖是在调档位，手指在哪一格就是哪一格，松手就是松手处那一档，收起。按下时手指所在的那一格要等手指离开它才算：
/// 刻度线贴着左边时手指下面不是当前档位，按下去、手抖一下不会就换。展开以后点一下刻度直接选那一档、收起，从刻度上拖也一样调。
/// 竖着拖留给拉 action 栏，刻度线收起。指针移上去在原地展开，不跟着指针挪，移开就收起；在上面点、拖和触屏一样调档位。
struct EffortPicker: View {
    @Binding var effort: Effort
    var allowed: [Effort] = Effort.allCases
    var commit: () -> Void = {}
    var cancel: () -> Void = {}
    /// 按下时展开的，松手后留着还是收起见 onEnded。
    @State private var open = false
    /// Mac 上鼠标在上面。
    @State private var hovering = false
    /// 刻度线的左边在哪，从这个控件的左边算。
    @State private var origin: CGFloat = 0
    @State private var touch: Touch?
    /// 手指按着。松手、被系统打断都会自己变回 false；打断时不调 onEnded，靠它收尾。
    @GestureState private var down = false

    /// 这一次按下。
    private struct Touch: Equatable {
        /// 起手那一格：按在刻度上是按着的那一档，按在档位名上是展开后手指下面那一档。
        /// 手指离开过它就是 nil，之后手指在哪一格就是哪一格。
        var start: Effort?
        /// 按在刻度上：没离开起手那一格就松手，是点了那一档。
        let onTicks: Bool
        /// 这次按下时才展开的：没离开起手那一格就松手，留着展开。
        let opened: Bool
        /// 挪开以后定下：横着拖是在调档位，竖着拖留给拉 action 栏。还没挪开是 nil。
        var sliding: Bool?
        /// 横着拖时手指到过的最右一根刻度。
        var farthest: Int?

        /// 没离开起手那一格就松手，算点。
        var tapped: Bool { start != nil && sliding != false }
    }

    /// 手指按着在调档位：按下还没挪开，或者在横着拖。
    private var adjusting: Bool {
        if let touch { touch.sliding != false } else { false }
    }

    private var showsTicks: Bool { open || hovering || adjusting }

    var body: some View {
        HStack(spacing: 0) {
            EffortTicks(effort: effort, origin: origin, shown: showsTicks, adjusting: adjusting, reached: touch?.farthest)
            Text(effort.name)
                .font(Theme.secondary)
                .foregroundStyle(showsTicks ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: Metrics.paneButton)
        }
        .contentShape(Rectangle())
        .gesture(press)
        .onChange(of: down) { _, down in
            // 松手时 onEnded 已经收过尾；被系统打断时不调它，在这里收
            if !down, touch != nil {
                withAnimation(.snappy) {
                    touch = nil
                    open = false
                }
                cancel()
            }
        }
        .onHover { hovering in
            withAnimation(.snappy) { self.hovering = hovering }
        }
        .sensoryFeedback(.selection, trigger: effort)
    }

    /// 按、点、拖都在这一个手势里，位置都从这个控件的左边算：展开时档位名会让到右边，按它自己的坐标算不准。
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($down) { _, down, _ in down = true }
            .onChanged { value in
                guard var touch else {
                    begin(at: value.startLocation.x)
                    return
                }
                let x = value.location.x
                if touch.sliding == nil {
                    let moved = value.translation
                    guard hypot(moved.width, moved.height) >= Metrics.dragThreshold else { return }
                    touch.sliding = DrawerPull.isHorizontal(moved)
                    if touch.sliding == false {
                        withAnimation(.snappy) {
                            self.touch = touch
                            open = false
                        }
                        return
                    }
                }
                guard touch.sliding == true else { return }
                let level = level(at: x)
                if level != touch.start { touch.start = nil }
                let tick = EffortTicks.tick(at: x - origin)
                touch.farthest = max(tick, touch.farthest ?? tick)
                if touch != self.touch { self.touch = touch }
                if touch.start == nil, level != effort { effort = level }
            }
            .onEnded { _ in
                guard let touch else { return }
                withAnimation(.snappy) {
                    self.touch = nil
                    if touch.tapped, touch.onTicks, let start = touch.start { effort = start }
                    // 点档位名展开的留着；点了刻度、点档位名收起、拖完了都收起
                    if !(touch.tapped && touch.opened) { open = false }
                }
                commit()
            }
    }

    /// 按下：记下起手那一格。收着的话马上展开，刻度线挪到当前档位的主刻度落在手指下面，左边放不下就贴着左边。
    private func begin(at x: CGFloat) {
        let opened = !showsTicks
        // 展开以前算：展开以后手指下面就是刻度了
        let onTicks = !opened && (0...EffortTicks.width).contains(x - origin)
        withAnimation(.snappy) {
            if opened {
                origin = max(x - EffortTicks.center(of: effort), 0)
                open = true
            }
            touch = Touch(start: level(at: x), onTicks: onTicks, opened: opened)
        }
    }

    /// x 处（从这个控件的左边算）是哪一档。
    private func level(at x: CGFloat) -> Effort {
        let level = EffortTicks.level(at: x - origin)
        return allowed.min(by: { abs($0.rawValue - level.rawValue) < abs($1.rawValue - level.rawValue) }) ?? effort
    }
}

/// effort 的刻度线：一档一根主刻度，中间是装饰刻度，粗细、高度一样，垂直居中；主刻度淡主题色，装饰刻度灰色，当前档位主题色、稍宽。
/// 一档占 effortTick 宽，每一档的格子以它的主刻度为中心。手指按着的时候当前档位附近的刻度略微拉长，越近越长。
/// 展开、收起都是一道先快后慢扫过去的线：展开时档位名往右让开，扫过哪根刻度，哪根就淡显出来，是个小圆点，再长到正常高度；
/// 收起时从右往左扫，扫到的刻度缩回圆点、淡出，档位名跟在它后面回到左边，不会压着还没收掉的刻度。
/// 半路掉头，每根刻度、档位名从当时的样子接着变。展开时手指往右拖得比扫的线快，直接快进到手指处那根刻度刚淡显出来，再接着播完：
/// 手指拖到哪，哪里的刻度就已经在了。收着时也在，不占宽度、看不见。
private struct EffortTicks: View {
    let effort: Effort
    /// 刻度线的左边在哪，从这个控件的左边算。
    let origin: CGFloat
    /// 展开着。
    let shown: Bool
    /// 手指按着在调档位。
    let adjusting: Bool
    /// 手指横着拖到过的最右一根刻度；没在拖是 nil。
    let reached: Int?
    @State private var sweep = Sweep()
    /// 在播，要一帧帧画。
    @State private var playing = false

    /// 相邻两根主刻度之间几根装饰刻度。
    private static let minors = 2
    private static let perLevel = minors + 1
    /// 一共几根刻度。
    private static let count = (Effort.allCases.count - 1) * perLevel + 1
    /// 相邻两根刻度的间距。
    private static let step = Metrics.effortTick / CGFloat(perLevel)
    /// 刻度线两头各留的半格，每一档的格子正好以它的主刻度为中心。
    private static let inset = (Metrics.effortTick - step) / 2
    /// 刻度线多宽。
    static let width = Metrics.effortTick * CGFloat(Effort.allCases.count)

    /// 扫的线从一头走到另一头、档位名让开或回来用多久。
    private static let slide = 0.3
    /// 展开时一根刻度被扫到以后：淡显用多久，多久开始长高、长多久。
    private static let fadeIn = 0.1
    private static let growDelay = 0.05
    private static let grow = 0.25
    /// 收起时一根刻度被扫到以后：缩回圆点用多久，多久开始淡出、淡出用多久。
    private static let shrink = 0.1
    private static let fadeOutDelay = 0.05
    private static let fadeOut = 0.07
    /// 收起时一根刻度被扫到以后多久没了，档位名在扫的线后面落这么久。
    private static let vanish = fadeOutDelay + fadeOut
    /// 一段播完要多久：展开时最后一根刻度被扫到以后长完；收起时档位名落在扫的线后面，回到左边。
    private static let unfoldDuration = slide + growDelay + grow
    private static let foldDuration = slide + vanish
    private static let easeOut = UnitCurve.easeOutCubic

    /// 第 index 根刻度的中心，从刻度线左边算。
    private static func center(_ index: Int) -> CGFloat {
        inset + step * (CGFloat(index) + 0.5)
    }

    /// 某一档的主刻度的中心，从刻度线左边算。
    static func center(of level: Effort) -> CGFloat {
        center(level.rawValue * perLevel)
    }

    /// 刻度线上 x 处（从刻度线左边算）是第几根刻度的格子，两头之外算第一根、最后一根。
    static func tick(at x: CGFloat) -> Int {
        min(max(Int(((x - inset) / step).rounded(.down)), 0), count - 1)
    }

    /// 刻度线上 x 处（从刻度线左边算）是哪一档，两头之外算最低、最高档。
    static func level(at x: CGFloat) -> Effort {
        let index = Int((x / Metrics.effortTick).rounded(.down))
        return Effort.allCases[min(max(index, 0), Effort.allCases.count - 1)]
    }

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            strip(look(at: context.date))
        }
        // 刻度线会伸出自己占的宽度；点、拖都由外面整个控件接
        .allowsHitTesting(false)
        .onChange(of: shown) {
            let now = Date.now
            sweep = Sweep(unfolding: shown, start: now, from: look(at: now))
        }
        .onChange(of: reached) {
            guard let reached, sweep.unfolding else { return }
            // 手指处那根刻度刚淡显出来的时候
            let target = Self.reach((origin + Self.center(reached)) / fullWidth, in: Self.slide) + Self.fadeIn
            let now = Date.now
            if target > sweep.time(at: now) { sweep.skip += target - sweep.time(at: now) }
        }
        // 播完就停下，不再一帧帧画；多等一点，最后一帧落在播完以后
        .task(id: sweep) {
            playing = sweep.end > .now
            guard playing, (try? await Task.sleep(for: .seconds(sweep.end.timeIntervalSinceNow + 0.05))) != nil else { return }
            playing = false
        }
    }

    /// 刻度线连同左边空出来的那段，展开时一共多宽。
    private var fullWidth: CGFloat {
        origin + Self.width
    }

    /// now 这一刻的样子。
    private func look(at now: Date) -> Look {
        let t = sweep.time(at: now)
        var look = sweep.from
        if sweep.unfolding {
            // 扫的线跟档位名一起往右，先快后慢；比开始时的样子只增不减
            look.slide = max(look.slide, Self.eased(t / Self.slide))
            for i in 0..<Self.count {
                let own = t - Self.reach((origin + Self.center(i)) / fullWidth, in: Self.slide)
                look.fade[i] = max(look.fade[i], Self.eased(own / Self.fadeIn))
                look.grow[i] = max(look.grow[i], Self.eased((own - Self.growDelay) / Self.grow))
            }
        } else {
            // 扫的线从右往左，先快后慢；档位名落在它后面 vanish 秒，扫到的刻度那时刚好没了。从开始时的样子按比例收
            look.slide *= 1 - Self.eased((t - Self.vanish) / Self.slide)
            for i in 0..<Self.count {
                let own = t - Self.reach(1 - (origin + Self.center(i)) / fullWidth, in: Self.slide)
                look.grow[i] *= 1 - Self.eased(own / Self.shrink)
                look.fade[i] *= 1 - Self.eased((own - Self.fadeOutDelay) / Self.fadeOut)
            }
        }
        return look
    }

    private func strip(_ look: Look) -> some View {
        let current = effort.rawValue * Self.perLevel
        return HStack(spacing: 0) {
            ForEach(0..<Self.count, id: \.self) { index in
                // 按着的时候离当前档位两档以内的略微拉长，越近越长，照余弦平滑过渡
                let distance = CGFloat(abs(index - current)) * Self.step / (Metrics.effortTick * 2)
                let near = distance < 1 ? (1 + cos(.pi * distance)) / 2 : 0
                let width: CGFloat = index == current ? 3 : 1.5
                let height = 14 + (adjusting ? 5 * near : 0)
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint)
                          : index % Self.perLevel == 0 ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.tertiary))
                    // 没长时高度等于宽度，是个小圆点
                    .frame(width: width, height: width + (height - width) * look.grow[index])
                    .opacity(look.fade[index])
                    .frame(width: Self.step, height: 32)
            }
        }
        .padding(.horizontal, Self.inset)
        .animation(.snappy(duration: 0.2), value: effort)
        .animation(.snappy(duration: 0.2), value: adjusting)
        .padding(.leading, origin)
        // 占的宽度跟着档位名让开、回来；刻度线靠左画，多出来的伸到右边
        .frame(width: fullWidth * look.slide, alignment: .leading)
    }

    /// x 截到 0 到 1 之间，按 easeOut 走了几成。
    private static func eased(_ x: Double) -> Double {
        easeOut.value(at: min(max(x, 0), 1))
    }

    /// 按 easeOut 走 duration 秒，走到 fraction 处是第几秒。
    private static func reach(_ fraction: Double, in duration: Double) -> Double {
        duration * easeOut.inverse.value(at: min(max(fraction, 0), 1))
    }

    /// 某一刻的样子，都在 0 到 1 之间：每根刻度淡显了几成、长高了几成，档位名让开了几成。
    private struct Look: Equatable {
        var fade = Array(repeating: 0.0, count: EffortTicks.count)
        var grow = Array(repeating: 0.0, count: EffortTicks.count)
        var slide = 0.0
    }

    /// 这一段在展开还是收起，从哪一刻、什么样子开始。
    private struct Sweep: Equatable {
        var unfolding = false
        var start = Date.distantPast
        var from = Look()
        /// 展开时被手指快进了多少秒。
        var skip = 0.0

        /// 这一段播到第几秒。
        func time(at now: Date) -> Double {
            now.timeIntervalSince(start) + skip
        }

        /// 播完的那一刻。
        var end: Date {
            start + (unfolding ? EffortTicks.unfoldDuration : EffortTicks.foldDuration) - skip
        }
    }
}
