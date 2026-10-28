import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 流式时新放出来的字从透明淡到原样：给文本视图的层套一层蒙版，正在淡入的每一段字在蒙版上各占一块，逐帧改这几块的透明度，
/// 其余地方全显示；都淡完就拿掉蒙版。只动合成，不重排、不重画：TextKit 2 画好的段落改了显示颜色不会重画
/// （docs/research/2026-10-23-代码编辑器上色验证.md），改字色又要重排那一段。
/// 嵌在字里的卡片（代码块、表格）跟着它那个字一起淡入；段落开头那一行连同左边的引用竖线、列表符号一起淡入。
@MainActor final class StreamFade {
    /// 一段字淡入要多久。
    static let duration: CFTimeInterval = 0.28

    weak var view: PlatformTextView?
    private var fades: [(range: NSRange, start: CFTimeInterval)] = []
    private var ticker: FrameTicker?
    private var mask: CALayer?
    /// 不在淡入的地方：一大块减去正在淡入的字。
    private let settled = CAShapeLayer()
    /// 正在淡入的字，一段一块。
    private var pieces: [CAShapeLayer] = []

    /// range 这段字刚放出来，从透明开始淡入。当场套好蒙版：新字露出来的第一帧就是透明的。
    func add(_ range: NSRange) {
        guard range.length > 0, let view else { return }
        let now = CACurrentMediaTime()
        fades.append((range, now))
        // 新字刚放进去，排好才量得出它在哪
        if let layout = view.textLayoutManager, let textRange = layout.textRange(for: range) {
            layout.ensureLayout(for: textRange)
        }
        guard step(now) else { return }
        if ticker == nil {
            let ticker = FrameTicker()
            self.ticker = ticker
            ticker.start(in: view) { [weak self] time in self?.tick(time) ?? false }
        }
    }

    /// 字变短了（整段换了）：超出的淡入不再管。
    func clamp(to length: Int) {
        fades = fades.compactMap { fade in
            let end = min(NSMaxRange(fade.range), length)
            return end > fade.range.location ? (NSRange(location: fade.range.location, length: end - fade.range.location), fade.start) : nil
        }
    }

    /// 都显示出来，拿掉蒙版。
    func stop() {
        fades = []
        ticker?.stop()
        ticker = nil
        removeMask()
    }

    private func tick(_ time: CFTimeInterval) -> Bool {
        if step(time) { return true }
        ticker = nil
        return false
    }

    /// 按 now 时的进度摆一遍蒙版，还有在淡入的返回 true。字的位置每帧重新量：新的一行把前面的字挤下去、行宽变了，蒙版都跟着。
    private func step(_ now: CFTimeInterval) -> Bool {
        fades.removeAll { now - $0.start >= Self.duration }
        guard !fades.isEmpty, let view, let layer = Self.layer(of: view), let layout = view.textLayoutManager else {
            fades = []
            removeMask()
            return false
        }
        let storage: NSTextStorage? = view.textStorage
        let string = (storage?.string ?? "") as NSString
        let all = CGMutablePath()
        var shapes: [(path: CGPath, opacity: Float)] = []
        for fade in fades {
            let path = CGMutablePath()
            for rect in rects(of: fade.range, in: view, layout: layout, string: string) { path.addRect(convert(rect, in: view)) }
            all.addPath(path)
            let progress = min(max((now - fade.start) / Self.duration, 0), 1)
            shapes.append((path, Float(1 - (1 - progress) * (1 - progress))))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = self.mask ?? makeMask()
        if layer.mask !== mask { layer.mask = mask }
        // 蒙版的原点对齐层的坐标原点，下面的路径直接用层里的坐标
        mask.frame = CGRect(origin: .zero, size: layer.bounds.size)
        let whole = CGPath(rect: layer.bounds.insetBy(dx: -4000, dy: -4000), transform: nil)
        settled.path = whole.subtracting(all)
        while pieces.count < shapes.count {
            let piece = CAShapeLayer()
            piece.fillColor = CGColor(gray: 0, alpha: 1)
            mask.addSublayer(piece)
            pieces.append(piece)
        }
        while pieces.count > shapes.count { pieces.removeLast().removeFromSuperlayer() }
        for (piece, shape) in zip(pieces, shapes) {
            piece.path = shape.path
            piece.opacity = shape.opacity
        }
        CATransaction.commit()
        return true
    }

    private func makeMask() -> CALayer {
        let mask = CALayer()
        settled.fillColor = CGColor(gray: 0, alpha: 1)
        mask.addSublayer(settled)
        self.mask = mask
        return mask
    }

    private func removeMask() {
        guard let mask else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let view, let layer = Self.layer(of: view), layer.mask === mask { layer.mask = nil }
        CATransaction.commit()
        pieces.forEach { $0.removeFromSuperlayer() }
        pieces = []
        self.mask = nil
    }

    /// 这段字占的地方（视图坐标），一行一块，高是整行的高（盖住行内代码的底色）。新起的一行往左伸到头，
    /// 引用的竖线、列表的符号跟着这一行淡入。
    private func rects(of range: NSRange, in view: PlatformTextView, layout: NSTextLayoutManager, string: NSString) -> [CGRect] {
        guard let textRange = layout.textRange(for: range) else { return [] }
        let origin = view.textContainerOrigin
        var rects: [CGRect] = []
        layout.enumerateTextSegments(in: textRange, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        let startsLine = range.location == 0 || range.location <= string.length && string.character(at: range.location - 1) == 0x0A
        for index in rects.indices where index == 0 ? startsLine : rects[index].minY > rects[index - 1].minY + 0.5 {
            rects[index] = CGRect(x: -4000, y: rects[index].minY, width: rects[index].maxX + 4000, height: rects[index].height)
        }
        return rects
    }

    /// 视图坐标换到层里：Mac 的文本视图是翻转的，层按 convertToLayer 换；iOS 两边一样。
    private func convert(_ rect: CGRect, in view: PlatformTextView) -> CGRect {
        #if canImport(UIKit)
        rect
        #else
        view.convertToLayer(rect)
        #endif
    }

    /// 文本视图的层：iOS 上总有，Mac 上是可选的。
    private static func layer(of view: PlatformTextView) -> CALayer? { view.layer }
}
