import CoreGraphics
import Foundation

/// 像素扫掠：扫过的那一截笔画变成彩色方块，离开后恢复（算法同 KitePixels.metal 里 iOS 用的着色器）。
/// 内容画成一张图交进来，每一格方块的颜色一起算好（只取决于原图）；每一帧只按扫到的位置算那一截。
/// 扫掠也是换内容的过渡：头的前面（左边）取新内容，后面取旧内容，扫过去的地方就换好了。
/// 工具行（ToolActivityView）按时间扫过一遍换字；语音整理时的输入框（VoiceSweepView）里头跟着整理出的字走。
nonisolated struct PixelSweep {
    /// 内容画成的图。
    let image: CGImage
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let size: CGSize
    let scale: CGFloat
    let cell: CGFloat
    let columns: Int
    /// 每一格的方块：效果色乘上这一格的覆盖率（预乘透明度），按行排。
    let blocks: [SIMD4<Float>]

    /// 方块的边长：按一行字的高取。
    static func cell(lineHeight: CGFloat) -> CGFloat { min(max(lineHeight * 0.2, 2.5), 4.0) }

    /// 扫掠的半宽：按扫过的宽取。
    static func halfWidth(span: CGFloat) -> CGFloat { min(max(span * 0.2, 24), 64) }

    /// image 是内容画成的图（预乘透明度的 RGBA 都行），size 是它在点上的大小。算好每一格的方块：格子中心周围 3×3 取样求平均（同着色器），
    /// 覆盖率放大 1.65 倍，颜色按格子散列取。
    init?(image: CGImage, size: CGSize, scale: CGFloat, cell: CGFloat) {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.image = image
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
        self.pixels = pixels
        self.width = width
        self.height = height
        self.size = size
        self.scale = scale
        self.cell = cell
        self.columns = columns
        self.blocks = blocks
    }

    /// 头在 front（点）、两侧各 halfWidth 的那一截，在 rows（点，纵向范围；nil 是整张高）里的样子：强度在头上最大、往两侧平滑落到 0，
    /// 按强度把原图和方块混合，同着色器。front 左边取 before 的内容（换内容时的新内容，和自己同高、同倍率），右边取自己的；
    /// before 为 nil 时都取自己的。limit 是扫掠画到哪为止（点），nil 时画到内容尽头。返回这一截的范围（点）和图；扫掠不在内容上时给 nil。
    func band(front: CGFloat, halfWidth: CGFloat, rows: Range<CGFloat>? = nil, before: PixelSweep? = nil,
              limit: CGFloat? = nil) -> (frame: CGRect, image: CGImage)? {
        let span = min(max(size.width, before?.size.width ?? 0), limit ?? .greatestFiniteMagnitude)
        let lower = max(Int(((front - halfWidth) * scale).rounded(.down)), 0)
        let upper = min(Int(((front + halfWidth) * scale).rounded(.up)), Int((span * scale).rounded(.up)))
        let top = rows.map { max(Int(($0.lowerBound * scale).rounded(.down)), 0) } ?? 0
        let bottom = rows.map { min(Int(($0.upperBound * scale).rounded(.up)), height) } ?? height
        guard lower < upper, top < bottom else { return nil }
        let bandWidth = upper - lower, bandHeight = bottom - top
        var pixels = [UInt8](repeating: 0, count: bandWidth * bandHeight * 4)
        for column in lower..<upper {
            let x = (CGFloat(column) + 0.5) / scale
            let source = x < front ? before ?? self : self
            let t = min(max(abs(x - front) / halfWidth, 0), 1)
            let intensity = Float(1 - t * t * (3 - 2 * t))
            let gridX = Int((x / source.cell).rounded(.down))
            for row in top..<bottom {
                let to = ((row - top) * bandWidth + column - lower) * 4
                guard column < source.width, row < source.height else { continue }
                let from = (row * source.width + column) * 4
                guard intensity >= 0.001 else {
                    for channel in 0..<4 { pixels[to + channel] = source.pixels[from + channel] }
                    continue
                }
                let gridY = Int(((CGFloat(row) + 0.5) / scale / source.cell).rounded(.down))
                let block = source.blocks[gridY * source.columns + gridX]
                for channel in 0..<4 {
                    let original = Float(source.pixels[from + channel]) / 255
                    let mixed = original + (block[channel] - original) * intensity
                    pixels[to + channel] = UInt8(min(max(mixed * 255, 0), 255).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: bandWidth, height: bandHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bandWidth * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let frame = CGRect(x: CGFloat(lower) / scale, y: CGFloat(top) / scale, width: CGFloat(bandWidth) / scale, height: CGFloat(bandHeight) / scale)
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
