#if os(iOS)
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// 工具在跑时的动效，照 ToolRowActivity：等待中（queued）内容透明度按等待呼吸起伏，执行中（running）像素扫掠。
/// 要带动效的字和图标放进 content。
/// - 呼吸是 Core Animation 的关键帧动画，按绝对时间对齐，几行一起起伏，同 SwiftUI 版共用一个时钟。
/// - 扫掠时 content 画进一张贴图，盖在上面的 CAMetalLayer 按屏幕刷新率逐帧画（着色器 kiteSweepFragment，和 SwiftUI 版的 kitePixels
///   同一套算法）：每帧只编一次绘制，字和尺寸变了才重画贴图。拖缝、吸附中尺寸一直在变，先不扫、只显示字，停下再接着扫。
/// - 减弱动态效果时不动；所在窗口不在屏上（PanePresence）时停。
final class PhoneActivityView: UIView {
    let content = UIView()
    private let metal = CAMetalLayer()
    private var link: CADisplayLink?
    private var texture: MTLTexture?
    private var state: Call.State?
    private var presence: PanePresence?
    private var watchingPresence = false

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 换上这一次的状态和窗口在不在屏上的盒子。字变了由调用方 contentChanged。
    func show(_ state: Call.State?, presence: PanePresence?) {
        if self.presence !== presence {
            self.presence = presence
            watchingPresence = false
        }
        self.state = UIAccessibility.isReduceMotionEnabled ? nil : state
        apply()
    }

    /// content 里的字、颜色变了：扫掠的贴图重画。
    func contentChanged() {
        texture = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if content.frame != bounds {
            content.frame = bounds
            texture = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        texture = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private var onScreen: Bool { window != nil && presence?.onScreen != false }

    private func apply() {
        watchPresence()
        let breathing = state == .queued && onScreen
        if breathing, content.layer.animation(forKey: "breath") == nil {
            content.layer.add(Self.breath(), forKey: "breath")
        } else if !breathing {
            content.layer.removeAnimation(forKey: "breath")
        }
        let sweeping = state == .running && onScreen && Self.renderer != nil
        if sweeping, link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !sweeping, let link {
            link.invalidate()
            self.link = nil
            showSweep(false)
        }
    }

    /// 窗口进出屏幕时停、接着动。盒子建好就不再换，只看它的 onScreen。
    private func watchPresence() {
        guard let presence, !watchingPresence else { return }
        watchingPresence = true
        withObservationTracking { _ = presence.onScreen } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchingPresence = false
                self?.apply()
            }
        }
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

    @objc private func tick(_ link: CADisplayLink) {
        // 拖缝、吸附中尺寸一直在变：先只显示字，不每帧重画贴图
        guard !WindowLayout.anyResizing, bounds.width > 0, bounds.height > 0, let renderer = Self.renderer else {
            showSweep(false)
            return
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        if texture == nil { texture = renderTexture(renderer.device, scale: scale) }
        guard let texture else { return }
        let size = CGSize(width: (bounds.width * scale).rounded(.up), height: (bounds.height * scale).rounded(.up))
        if metal.drawableSize != size {
            metal.device = renderer.device
            metal.contentsScale = scale
            metal.drawableSize = size
        }
        // 两秒一轮：前 88% 用系统的 easeInOut 推过去，余下停在文字外面，同 ToolRowActivity
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
        let travel = Float(UnitCurve.easeInOut.value(at: min(phase / 0.88, 1)))
        guard let drawable = metal.nextDrawable() else { return }
        renderer.draw(texture, into: drawable, uniforms: KiteSweepUniforms(
            bounds: SIMD4(0, 0, Float(bounds.width), Float(bounds.height)), travel: travel, scale: Float(scale),
            inset: Float(Self.inset), padding: 0, textureSize: SIMD2(Float(texture.width), Float(texture.height))))
        showSweep(true)
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

/// 着色器 kiteSweepFragment 的参数，和 KitePixels.metal 里的结构一样排。
struct KiteSweepUniforms {
    var bounds: SIMD4<Float>
    var travel: Float
    var scale: Float
    var inset: Float
    var padding: Float
    var textureSize: SIMD2<Float>
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

    func draw(_ texture: MTLTexture, into drawable: CAMetalDrawable, uniforms: KiteSweepUniforms) {
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
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
#endif
