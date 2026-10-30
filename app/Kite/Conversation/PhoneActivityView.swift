#if os(iOS)
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// 工具行的动效：等待中内容透明度按等待呼吸起伏，工具组在做事时像素扫掠。
/// 要带动效的字和图标放进 content。
/// - 呼吸是 Core Animation 的关键帧动画，按绝对时间对齐，几行一起起伏，和 SwiftUI 里的 waitingBreath 共用一个时钟。
/// - 扫掠时 content 画进一张贴图，盖在上面的 CAMetalLayer 按屏幕刷新率逐帧画（着色器 kiteSweepFragment，和 Mac 的
///   ToolActivityView 同一套算法，见 PixelSweep）：每帧只编一次绘制，字和尺寸变了才重画贴图。拖缝、吸附中尺寸一直在变，先不扫、只显示字，停下再接着扫。
/// - 扫掠中换字（change）是一次过渡，同 Mac：新字等下一遍扫掠开始时才换上，这一遍里扫掠头的前面是新字、后面还是旧字的贴图，
///   扫过去就换好了；不在扫时（没在做事、看不见、过渡中、减弱动态效果）当场换。平时只扫到 sweepWidth 为止。
/// - 减弱动态效果时不动；所在窗口不在屏上（PanePresence）时停。这一行被列表藏起、所在的层透明、滚出窗口或窗口在过渡中时
///   不画，看不见时显示链接降到低频，只等着看得见，不把屏幕拖在高刷新率上。
final class PhoneActivityView: UIView {
    enum Mode: Equatable { case none, breathing, sweeping }

    let content = UIView()
    private let metal = CAMetalLayer()
    private var link: CADisplayLink?
    /// 显示链接降到了低频（看不见时）。
    private var idling = false
    private var texture: MTLTexture?
    /// 等下一遍扫掠开始时换上的字（只留最新的一次）。
    private var pending: (() -> Void)?
    /// 这一遍扫掠在换字：换之前的字画成的贴图和它的大小（点）。
    private var outgoing: (texture: MTLTexture, size: CGSize)?
    /// 正在扫的是第几遍（参考时刻起每 2 秒一遍），换了一遍就把等着的字换上。
    private var pass: Int?
    /// 平时扫掠只扫到这么宽（如汇总的字，不扫后面的步数和箭头），nil 是整个内容；换字的那一遍扫过整个内容。
    var sweepWidth: CGFloat?
    private var mode: Mode = .none
    private var presence: PanePresence?
    private let tracking = ModelTracking()

    /// 贴图比字的范围四边多出的点，同 SwiftUI 的 maxSampleOffset。
    private static let inset: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        content.isUserInteractionEnabled = false
        addSubview(content)
        metal.isOpaque = false
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isHidden = true
        layer.addSublayer(metal)
        // 浅色深色、屏幕倍数变了，字的颜色、像素跟着变，贴图重画
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance + [UITraitDisplayScale.self]) {
            (self: Self, _: UITraitCollection) in self.texture = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 换上这一次的动效和窗口在不在屏上的盒子。字变了由调用方 contentChanged。
    func show(_ mode: Mode, presence: PanePresence?) {
        if self.presence !== presence {
            self.presence = presence
            tracking.cancel()
        }
        self.mode = UIAccessibility.isReduceMotionEnabled ? .none : mode
        apply()
    }

    /// content 里的字、颜色变了：扫掠的贴图重画。
    func contentChanged() {
        texture = nil
    }

    /// 换字：apply 改里面的字（和外面跟着变的排版，要当场排好），扫掠中等下一遍扫过去时换上，否则当场换。
    func change(_ apply: @escaping () -> Void) {
        guard link != nil, !metal.isHidden else {
            settle()
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

    override func layoutSubviews() {
        super.layoutSubviews()
        if content.frame != bounds {
            content.frame = bounds
            texture = nil
        }
        // 换字途中画布由 tick 按新旧两样里宽的那个摆
        guard outgoing == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        // 窗口进出屏幕时停、接着动
        let shown = tracking.track { presence?.onScreen ?? true } changed: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        let onScreen = window != nil && shown
        let breathing = mode == .breathing && onScreen
        if breathing, content.layer.animation(forKey: "breath") == nil {
            content.layer.add(Self.breath(), forKey: "breath")
        } else if !breathing {
            content.layer.removeAnimation(forKey: "breath")
        }
        let sweeping = mode == .sweeping && onScreen && Self.renderer != nil
        if sweeping, link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            idling = true
            idle(false)
        } else if !sweeping, let link {
            link.invalidate()
            self.link = nil
            showSweep(false)
        }
        if !sweeping { settle() }
    }

    /// 等待呼吸：透明度 0.45 到 1 正弦起伏，2.8 秒一圈（WaitingBreath），按绝对时间对齐到当前的相位。
    private static func breath() -> CAAnimation {
        let period = WaitingBreath.period
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let steps = 56
        animation.values = (0...steps).map { index in
            0.45 + 0.55 * (sin(Double(index) / Double(steps) * .pi * 2) + 1) / 2
        }
        animation.calculationMode = .linear
        animation.duration = period
        animation.repeatCount = .infinity
        animation.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func showSweep(_ shown: Bool) {
        guard metal.isHidden == shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.isHidden = !shown
        content.layer.opacity = shown ? 0 : 1
        CATransaction.commit()
    }

    /// 看不见时显示链接降到低频，看得见了回到屏幕刷新率。
    private func idle(_ idle: Bool) {
        guard idle != idling, let link else { return }
        idling = idle
        let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = idle ? CAFrameRateRange(minimum: 4, maximum: 10, preferred: 10)
            : CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let visible = isVisibleInWindow
        idle(!visible)
        // 看不见、窗口在过渡中，或拖缝、吸附中尺寸一直在变：先只显示字，不每帧重画贴图
        guard visible, !WindowLayout.anyTransitioning, !WindowLayout.anyResizing, let renderer = Self.renderer else {
            settle()
            showSweep(false)
            return
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        // 两秒一轮：前 88% 用系统的 easeInOut 推过去，余下停在文字外面；换了一轮就把等着的字换上，这一轮从旧字扫成新字
        let time = Date().timeIntervalSinceReferenceDate
        let current = Int((time / 2).rounded(.down))
        if pass != current {
            pass = current
            beginPass(renderer.device, scale: scale)
        }
        let progress = min(time.truncatingRemainder(dividingBy: 2) / 2 / 0.88, 1)
        if progress >= 1 { outgoing = nil }
        let travel = Float(UnitCurve.easeInOut.value(at: progress))
        if texture == nil { texture = renderTexture(renderer.device, scale: scale) }
        guard let texture else { return }
        // 换字途中画布盖住新旧两样里宽的那个，扫过整个内容；平时只扫到 sweepWidth
        let canvas = CGSize(width: max(bounds.width, outgoing?.size.width ?? 0), height: max(bounds.height, outgoing?.size.height ?? 0))
        let span = outgoing == nil ? min(sweepWidth ?? bounds.width, bounds.width) : canvas.width
        let size = CGSize(width: (canvas.width * scale).rounded(.up), height: (canvas.height * scale).rounded(.up))
        if metal.drawableSize != size || metal.bounds.size != canvas {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metal.frame = CGRect(origin: .zero, size: canvas)
            CATransaction.commit()
            metal.device = renderer.device
            metal.contentsScale = scale
            metal.drawableSize = size
        }
        guard let drawable = metal.nextDrawable() else { return }
        let old = outgoing?.texture ?? texture
        renderer.draw(texture, outgoing: old, into: drawable, uniforms: KiteSweepUniforms(
            bounds: SIMD4(0, 0, Float(span), Float(bounds.height)), travel: travel, scale: Float(scale),
            inset: Float(Self.inset), wiping: outgoing == nil ? 0 : 1, textureSize: SIMD2(Float(texture.width), Float(texture.height)),
            outgoingSize: SIMD2(Float(old.width), Float(old.height))))
        showSweep(true)
    }

    /// 新的一轮：有等着的字就先把现在的画下来当旧字，再换上新字、当场排好。
    private func beginPass(_ device: MTLDevice, scale: CGFloat) {
        outgoing = nil
        guard let pending else { return }
        self.pending = nil
        let size = bounds.size
        let old = texture ?? renderTexture(device, scale: scale)
        pending()
        texture = nil
        if let old { outgoing = (old, size) }
    }

    /// 把 content 连同四边的余量画进贴图（预乘透明度的 BGRA）。
    private func renderTexture(_ device: MTLDevice, scale: CGFloat) -> MTLTexture? {
        let inset = Self.inset
        let width = Int(((bounds.width + inset * 2) * scale).rounded(.up))
        let height = Int(((bounds.height + inset * 2) * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: inset, y: inset)
        // 扫掠时 content 是透明的（字由贴图画），画贴图时先放回来
        let opacity = content.layer.opacity
        content.layer.opacity = 1
        traitCollection.performAsCurrent { content.layer.render(in: context) }
        content.layer.opacity = opacity
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        return texture
    }

    /// 着色器和命令队列只建一份；建不出来（没有 Metal）就不扫。
    @MainActor private static let renderer = KiteSweepRenderer()
}

extension UIView {
    /// 真的看得见：在窗口里、有大小，自己和上层都没藏起、没透明，并且和窗口的范围有交集。对话列表藏起滚远的行只设
    /// isHidden（不移出窗口），紧凑布局预热的窗口在屏外，逐帧、逐秒的更新靠它跳过。
    var isVisibleInWindow: Bool {
        guard let window, bounds.width > 0, bounds.height > 0 else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return false }
            view = current.superview
        }
        return convert(bounds, to: window).intersects(window.bounds)
    }
}

/// 着色器 kiteSweepFragment 的参数，和 KitePixels.metal 里的结构一样排。
struct KiteSweepUniforms {
    var bounds: SIMD4<Float>
    var travel: Float
    var scale: Float
    var inset: Float
    /// 换字的那一遍（1）：扫掠头后面取旧内容的贴图。
    var wiping: Float
    var textureSize: SIMD2<Float>
    var outgoingSize: SIMD2<Float>
}

@MainActor final class KiteSweepRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "kiteSweepVertex"), let fragment = library.makeFunction(name: "kiteSweepFragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// outgoing 是换字时旧内容的贴图，不换字时给 texture 本身。
    func draw(_ texture: MTLTexture, outgoing: MTLTexture, into drawable: CAMetalDrawable, uniforms: KiteSweepUniforms) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<KiteSweepUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(outgoing, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
#endif
