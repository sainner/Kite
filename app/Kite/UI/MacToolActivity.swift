#if os(macOS)
import AppKit
import SwiftUI

/// 工具行里正在做的事的动效：等待时整块透明度呼吸（WaitingBreath 的节奏），工具组在做事时像素扫掠
/// （扫过时笔画变成彩色方块，离开后恢复；算法在 PixelSweep，同 KitePixels.metal 里 iOS 用的着色器）。里面的字、图标照常放在 content 里，链接照常能点。
/// 扫掠中换字（change）是一次过渡：新字等下一遍扫掠开始时才换上，这一遍里扫掠头的前面是新字、后面还是旧字的图，扫过去就换好了；
/// 不在扫时（没在做事、窗口不在屏上、过渡中、减弱动态效果）当场换。
/// 扫掠每秒最多 60 帧（现版 30 帧）：内容画成一张图记下来、每一格方块的颜色一起算好（字、宽度、外观变了才重画，
/// 拖缝改宽时只有被截短的字才要重画）；每一帧只算扫到的那一截，放进一个只有这一截宽的图层，原来的内容用遮罩挖掉这一截，其余照常画。
/// 窗口不在屏上（PanePresence）、在过渡中（含拖缝）、被挡住、这一行滚出可见区时不算，只显示字，停下再接着扫。呼吸交给 Core Animation，按参考时刻对齐，
/// 和别处的呼吸同一拍。开了「减弱动态效果」都不动。
final class ToolActivityView: NSView {
    enum Mode: Equatable { case none, breathing, sweeping }

    /// 放字、图标的那一层。
    let content = FlippedLayerView()
    /// 扫到的那一截。
    private let effect = CALayer()
    /// 原来的内容挖掉扫到的那一截；换字时只留扫掠头前面的新字。
    private let hole = CAShapeLayer()
    /// 换字途中扫掠头后面的旧字（画好的图，只露出后面那段）。
    private let outgoingLayer = CALayer()
    var mode: Mode = .none {
        didSet { if mode != oldValue { update() } }
    }
    /// 平时扫掠只扫到这么宽（如汇总的字，不扫后面的步数和箭头），nil 是整个内容；换字的那一遍扫过整个内容，后面几样也随扫掠换过去。
    var sweepWidth: CGFloat?
    /// 所在窗口在不在屏上，不在屏上停（同 PaneTimeline）。
    var presence: PanePresence? {
        didSet {
            guard presence !== oldValue else { return }
            tracking.cancel()
            update()
        }
    }
    private let tracking = ModelTracking()
    private var link: CADisplayLink?
    /// 内容画成的图，见 PixelSweep。
    private var source: PixelSweep?
    /// 等下一遍扫掠开始时换上的字（只留最新的一次）。
    private var pending: (() -> Void)?
    /// 这一遍扫掠在换字：换之前的字画成的图。
    private var outgoing: PixelSweep?
    /// 正在扫的是第几遍（参考时刻起每 2 秒一遍），换了一遍就把等着的字换上。
    private var pass: Int?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(content)
        layer?.addSublayer(outgoingLayer)
        layer?.addSublayer(effect)
        for layer in [effect, outgoingLayer] {
            layer.actions = ["contents": NSNull(), "contentsRect": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer.isHidden = true
        }
        hole.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 里面的字、图标变了：扫掠中要重画那张图。
    func contentChanged() {
        source = nil
    }

    /// 换字：apply 改里面的字（和外面跟着变的排版），扫掠中等下一遍扫过去时换上，否则当场换。
    func change(_ apply: @escaping () -> Void) {
        guard link != nil else {
            apply()
            contentChanged()
            return
        }
        pending = apply
    }

    /// 等着的字当场换上，换字的过渡不再画。
    private func settle() {
        outgoing = nil
        guard let pending else { return }
        self.pending = nil
        pending()
        contentChanged()
    }

    override func layout() {
        super.layout()
        let resized = content.frame != bounds
        if resized {
            content.frame = bounds
            source = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hole.frame = content.bounds
        CATransaction.commit()
        // 扫到的那一截和遮罩还是按原来的宽摆的：截短的长行跟着窗口变宽时，多出来的尾巴落在遮罩外面被挖掉，这一帧就按新的宽重摆
        if resized, link != nil, !effect.isHidden { advance() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        source = nil
        outgoing = nil
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func update() {
        let onScreen = tracking.track { presence?.onScreen ?? true } changed: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.update() }
        }
        let sweeping = mode == .sweeping && window != nil && !reduceMotion && onScreen
        if sweeping, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !sweeping, let link {
            link.invalidate()
            self.link = nil
        }
        if !sweeping {
            settle()
            hideBand()
        }
        if mode != .sweeping { source = nil }
        let breathing = mode == .breathing && window != nil && !reduceMotion
        if breathing, layer?.animation(forKey: "breath") == nil {
            layer?.add(Self.breath(), forKey: "breath")
        } else if !breathing {
            layer?.removeAnimation(forKey: "breath")
        }
    }

    /// 等待呼吸：透明度在 0.45 与 1 之间按正弦起伏，2.8 秒一周，按参考时刻对齐（同 WaitingBreath.opacity）。
    private static func breath() -> CAKeyframeAnimation {
        let period = WaitingBreath.period
        let steps = 56
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = (0...steps).map { step in
            0.45 + 0.55 * (sin(Double(step) / Double(steps) * .pi * 2) + 1) / 2
        }
        animation.duration = period
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        // 从这一周开头算起，和 WaitingBreath 同一拍
        let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        animation.beginTime = CACurrentMediaTime() - phase
        animation.isRemovedOnCompletion = false
        return animation
    }

    @objc private func tick(_ link: CADisplayLink) { advance() }

    /// 摆出眼下这一刻。屏幕外（窗口被挡住、行滚出可见区）、窗口在过渡中不算，只显示字：停住的那一截对不上过渡中变了宽的字。
    /// 换了一遍扫掠时把等着的字换上，这一遍从旧字扫成新字；走完这一遍的路程换字就完了。
    private func advance() {
        guard bounds.width > 0, bounds.height > 0, let window, window.occlusionState.contains(.visible), !visibleRect.isEmpty,
              !WindowLayout.anyTransitioning else {
            settle()
            return hideBand()
        }
        // 先在 Double 里收敛到一周期：2 秒一周，前 88% 走完，余下停在终点（扫掠已离开字）
        let time = Date.timeIntervalSinceReferenceDate
        let current = Int((time / 2).rounded(.down))
        if pass != current {
            pass = current
            beginPass()
        }
        let progress = min(time.truncatingRemainder(dividingBy: 2) / 2 / 0.88, 1)
        if progress >= 1 { outgoing = nil }
        show(travel: CGFloat(UnitCurve.easeInOut.value(at: progress)))
    }

    /// 新的一遍：有等着的字就先把现在的画下来当旧字，再换上新字。
    private func beginPass() {
        outgoing = nil
        guard let pending else { return }
        self.pending = nil
        let old = source ?? capture()
        pending()
        superview?.layoutSubtreeIfNeeded()
        source = nil
        outgoing = old
    }

    /// 收起扫到的那一截，内容照常画。
    private func hideBand() {
        guard !effect.isHidden || !outgoingLayer.isHidden || content.layer?.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.isHidden = true
        outgoingLayer.isHidden = true
        content.layer?.mask = nil
        CATransaction.commit()
    }

    /// 摆出 travel 那一刻：扫到的那一截换成算好的图，原来的内容挖掉这一截；换字时扫掠头后面露出旧字的图，新字只留前面。
    private func show(travel: CGFloat) {
        if source == nil || source?.size != bounds.size { source = capture() }
        guard let source, let content = content.layer else { return hideBand() }
        let span = outgoing.map { max(source.size.width, $0.size.width) } ?? min(sweepWidth ?? source.size.width, source.size.width)
        let baseHalfWidth = PixelSweep.halfWidth(span: span)
        let maxHalfWidth = baseHalfWidth * 1.35
        let halfWidth = baseHalfWidth * 0.45 + (maxHalfWidth - baseHalfWidth * 0.45) * travel
        let front = -baseHalfWidth + (span + maxHalfWidth + baseHalfWidth) * travel
        let band = outgoing.map { $0.band(front: front, halfWidth: halfWidth, before: source) }
            ?? source.band(front: front, halfWidth: halfWidth, limit: span)
        guard band != nil || outgoing != nil else { return hideBand() }
        // 换字途中扫掠还没进来：整行还是旧字
        let left = band?.frame.minX ?? (front < 0 ? 0 : span), right = band?.frame.maxX ?? left
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let band {
            effect.frame = band.frame
            effect.contents = band.image
            effect.contentsScale = source.scale
        }
        effect.isHidden = band == nil
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: left, height: bounds.height))
        if outgoing == nil { path.addRect(CGRect(x: right, y: 0, width: max(bounds.width - right, 0), height: bounds.height)) }
        hole.path = path
        if content.mask !== hole { content.mask = hole }
        if let outgoing, right < outgoing.size.width {
            let width = outgoing.size.width
            outgoingLayer.frame = CGRect(x: right, y: 0, width: width - right, height: outgoing.size.height)
            outgoingLayer.contents = outgoing.image
            outgoingLayer.contentsScale = outgoing.scale
            outgoingLayer.contentsRect = CGRect(x: right / width, y: 0, width: 1 - right / width, height: 1)
            outgoingLayer.isHidden = false
        } else {
            outgoingLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// 把内容画成一张图，交给 PixelSweep 算好方块。
    private func capture() -> PixelSweep? {
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.width > 0, bounds.height > 0, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        // 画出来的图带着遮罩：扫掠中换字、变宽时重画，扫到的那一截会被挖空、记进图里，之后扫过那里就缺字。先摘下，画完挂回去，同一次提交里看不出来
        let mask = content.layer?.mask
        content.layer?.mask = nil
        content.cacheDisplay(in: content.bounds, to: rep)
        content.layer?.mask = mask
        guard let image = rep.cgImage else { return nil }
        return PixelSweep(image: image, size: bounds.size, scale: scale, cell: PixelSweep.cell(lineHeight: bounds.height))
    }
}
#endif
