#if os(macOS)
import AppKit
import SwiftUI

/// 工具行里正在做的事的动效：等待时整块透明度呼吸（WaitingBreath 的节奏），工具组在做事时像素扫掠
/// （扫过时笔画变成彩色方块，离开后恢复；算法同 KitePixels.metal 里 iOS 用的着色器）。里面的字、图标照常放在 content 里，链接照常能点。
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
    /// 原来的内容挖掉扫到的那一截。
    private let hole = CAShapeLayer()
    var mode: Mode = .none {
        didSet { if mode != oldValue { update() } }
    }
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
    /// 内容画成的图，见 Source。
    private var source: Source?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(content)
        layer?.addSublayer(effect)
        effect.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        effect.isHidden = true
        hole.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 里面的字、图标变了：扫掠中要重画那张图。
    func contentChanged() {
        source = nil
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
        if !sweeping { hideBand() }
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
    private func advance() {
        guard bounds.width > 0, bounds.height > 0, let window, window.occlusionState.contains(.visible), !visibleRect.isEmpty,
              !WindowLayout.anyTransitioning else { return hideBand() }
        // 先在 Double 里收敛到一周期：2 秒一周，前 88% 走完，余下停在终点（扫掠已离开字）
        let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
        show(travel: CGFloat(UnitCurve.easeInOut.value(at: min(phase / 0.88, 1))))
    }

    /// 收起扫到的那一截，内容照常画。
    private func hideBand() {
        guard !effect.isHidden || content.layer?.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.isHidden = true
        content.layer?.mask = nil
        CATransaction.commit()
    }

    /// 摆出 travel 那一刻：扫到的那一截换成算好的图，原来的内容挖掉这一截。
    private func show(travel: CGFloat) {
        if source == nil || source?.size != bounds.size { source = capture() }
        guard let source, let content = content.layer, let band = render(travel: travel) else { return hideBand() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.frame = band.frame
        effect.contents = band.image
        effect.contentsScale = source.scale
        effect.isHidden = false
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: band.frame.minX, height: bounds.height))
        path.addRect(CGRect(x: band.frame.maxX, y: 0, width: max(bounds.width - band.frame.maxX, 0), height: bounds.height))
        hole.path = path
        if content.mask !== hole { content.mask = hole }
        CATransaction.commit()
    }

    /// 内容画成的图，连同每一格方块的颜色（只取决于原图，画图时一起算好，每一帧只按扫到多少混合）。
    private struct Source {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var size: CGSize
        var scale: CGFloat
        var cell: CGFloat
        var columns: Int
        /// 每一格的方块：效果色乘上这一格的覆盖率（预乘透明度），按行排。
        var blocks: [SIMD4<Float>]
    }

    /// 把内容画成一张图，算好每一格的方块：格子中心周围 3×3 取样求平均（同着色器），覆盖率放大 1.65 倍，颜色按格子散列取。
    private func capture() -> Source? {
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        // 画出来的图带着遮罩：扫掠中换字、变宽时重画，扫到的那一截会被挖空、记进图里，之后扫过那里就缺字。先摘下，画完挂回去，同一次提交里看不出来
        let mask = content.layer?.mask
        content.layer?.mask = nil
        content.cacheDisplay(in: content.bounds, to: rep)
        content.layer?.mask = mask
        guard let image = rep.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let cell = min(max(size.height * 0.2, 2.5), 4.0)
        let columns = Int((size.width / cell).rounded(.up)) + 1, rows = Int((size.height / cell).rounded(.up)) + 1
        /// 按点的坐标取原图（双线性），预乘的 RGBA，0～1。
        func sample(_ x: CGFloat, _ y: CGFloat) -> SIMD4<Float> {
            let px = x * scale - 0.5, py = y * scale - 0.5
            let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
            let fx = Float(px - CGFloat(x0)), fy = Float(py - CGFloat(y0))
            func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
                guard x >= 0, y >= 0, x < width, y < height else { return .zero }
                let index = (y * width + x) * 4
                return SIMD4(Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2]), Float(pixels[index + 3])) / 255
            }
            let top = pixel(x0, y0) * (1 - fx) + pixel(x0 + 1, y0) * fx
            let bottom = pixel(x0, y0 + 1) * (1 - fx) + pixel(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
        var blocks = [SIMD4<Float>](repeating: .zero, count: columns * rows)
        for gridY in 0..<rows {
            for gridX in 0..<columns {
                let center = CGPoint(x: (CGFloat(gridX) + 0.5) * cell, y: (CGFloat(gridY) + 0.5) * cell)
                var coverage: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 { coverage += sample(center.x + CGFloat(dx) * cell / 3, center.y + CGFloat(dy) * cell / 3).w / 9 }
                }
                let color = Self.palette[min(Int(Self.noise(Float(gridX), Float(gridY)) * 5), 4)]
                let alpha = min(coverage * 1.65, 1)
                blocks[gridY * columns + gridX] = SIMD4(color.x * alpha, color.y * alpha, color.z * alpha, alpha)
            }
        }
        return Source(pixels: pixels, width: width, height: height, size: size, scale: scale, cell: cell, columns: columns, blocks: blocks)
    }

    /// 这一帧扫到的那一截（点的坐标）和它的样子：按扫掠的强度把原图和方块混合，同着色器。扫掠不在字上时给 nil。
    private func render(travel: CGFloat) -> (frame: CGRect, image: CGImage)? {
        guard let source else { return nil }
        let size = source.size, scale = source.scale, cell = source.cell
        let baseHalfWidth = min(max(size.width * 0.2, 24), 64)
        let maxHalfWidth = baseHalfWidth * 1.35
        let halfWidth = baseHalfWidth * 0.45 + (maxHalfWidth - baseHalfWidth * 0.45) * travel
        let front = -baseHalfWidth + (size.width + maxHalfWidth + baseHalfWidth) * travel
        let lower = max(Int(((front - halfWidth) * scale).rounded(.down)), 0)
        let upper = min(Int(((front + halfWidth) * scale).rounded(.up)), source.width)
        guard lower < upper else { return nil }
        let width = upper - lower
        var pixels = [UInt8](repeating: 0, count: width * source.height * 4)
        for column in lower..<upper {
            let x = (CGFloat(column) + 0.5) / scale
            let t = min(max(abs(x - front) / halfWidth, 0), 1)
            let intensity = Float(1 - t * t * (3 - 2 * t))
            let gridX = Int((x / cell).rounded(.down))
            for row in 0..<source.height {
                let from = (row * source.width + column) * 4
                let to = (row * width + column - lower) * 4
                guard intensity >= 0.001 else {
                    for channel in 0..<4 { pixels[to + channel] = source.pixels[from + channel] }
                    continue
                }
                let gridY = Int(((CGFloat(row) + 0.5) / scale / cell).rounded(.down))
                let block = source.blocks[gridY * source.columns + gridX]
                for channel in 0..<4 {
                    let original = Float(source.pixels[from + channel]) / 255
                    let mixed = original + (block[channel] - original) * intensity
                    pixels[to + channel] = UInt8(min(max(mixed * 255, 0), 255).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: source.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let frame = CGRect(x: CGFloat(lower) / scale, y: 0, width: CGFloat(width) / scale, height: CGFloat(source.height) / scale)
        return (frame, image)
    }

    /// 效果色，与 DotColor.palette 同一组（见 docs/视觉风格.md），同着色器。
    private static let palette: [SIMD3<Float>] = [
        SIMD3(127, 168, 214) / 255, // #7FA8D6 Morning Breeze
        SIMD3(168, 198, 231) / 255, // #A8C6E7 Dewy Blue
        SIMD3(255, 224, 138) / 255, // #FFE08A Sunwashed
        SIMD3(245, 201, 92) / 255,  // #F5C95C Sunwashed 深一档
        SIMD3(91, 136, 194) / 255,  // #5B88C2 主题色
    ]

    /// 同一格始终取同一色，同着色器的 fract(sin(dot(grid, (127.1, 311.7))) * 43758.5453)。
    private static func noise(_ x: Float, _ y: Float) -> Float {
        let value = sin(x * 127.1 + y * 311.7) * 43758.5453
        return value - value.rounded(.down)
    }
}
#endif
