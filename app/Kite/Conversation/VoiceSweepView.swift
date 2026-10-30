import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 语音整理时盖在上面扫掠的输入框（两端的 ComposerField）给出的几样：现在的字、某个位置所在的行、画成的图、灰的那段、挂遮罩的图层。
/// 位置和图都按输入框看得见的那一块算（iOS 的输入框是滚动视图，扣掉滚动的偏移），和盖在上面的 VoiceSweepView 坐标一致。
@MainActor protocol VoiceSweepField: AnyObject {
    var voiceString: String { get }
    /// 第 offset 个 UTF-16 单元前面那个位置：x 是这个位置，y、高是它所在的那一行；在行尾时算上一行的末尾。
    func caret(at offset: Int) -> CGRect?
    /// 现在显示的字画成的图，不画插入点和选区、不带扫掠挖的洞。
    func sweepImage() -> CGImage?
    var voiceGray: NSRange? { get }
    var sweepMaskLayer: CALayer? { get }
}

/// 语音整理时输入框里的像素扫掠，同工具行（算法见 PixelSweep）：扫掠的头在 VoiceTextStyle.head，
/// 头的前面是整理后的字，后面是还没扫到的灰字，扫过去的地方就换成了整理后的字。
/// 头由 ThreadControlsModel 按固定速度一个字一个字往前推，这里逐帧追上（时间常数 0.05 秒），进场时从这一行左边滑进来；
/// 整理完（或没成、被人改了字）头接着走过字尾离开。换行时跳到新的一行。
/// 盖在输入框上面、和它一样大，不接点击；输入框用遮罩挖掉扫到的那一截，这一截画成算好的图。开了「减弱动态效果」不画，只有灰字。
/// Mac、iPhone、iPad 共用，各自的输入区（MacControlsBar、PhoneControlsBar 里的 ControlsBarView）把它摆在输入框上。
final class VoiceSweepView: PlatformView {
    private weak var field: (PlatformView & VoiceSweepField)?
    private let effect = CALayer()
    private let hole = CAShapeLayer()
    private let ticker = FrameTicker()
    /// 整理到哪了；nil 时扫掠在收尾，走过字尾离开。
    private var head: Int?
    /// 输入框画成的图，字、灰的那段或大小变了重画。
    private var source: (key: SourceKey, sweep: PixelSweep)?
    /// 扫掠头现在在哪一行（行的范围）、x。
    private var front: (line: CGRect, x: CGFloat)?
    private var last: CFTimeInterval?
    /// 开始收尾的时刻，收尾最多走这么久。
    private var finishing: CFTimeInterval?

    /// 扫掠两侧各多宽。
    private static let halfWidth: CGFloat = 32
    private static let finishLimit: CFTimeInterval = 0.6

    private struct SourceKey: Equatable {
        var text: String
        var gray: NSRange?
        var size: CGSize
    }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var showing: Bool { window?.occlusionState.contains(.visible) == true }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    #else
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    private var showing: Bool { isVisibleInWindow }
    private var scale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
    #endif

    init(field: PlatformView & VoiceSweepField) {
        self.field = field
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        layer?.addSublayer(effect)
        #else
        isUserInteractionEnabled = false
        layer.addSublayer(effect)
        #endif
        effect.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        effect.isHidden = true
        hole.fillRule = .evenOdd
        hole.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 输入框的语音样式变了（见 ThreadControlsModel.voiceStyle）。整理中跟着 head 走；整理完了、正在扫的走过字尾离开。
    func update(_ style: VoiceTextStyle?) {
        if let next = style?.head {
            head = next
            finishing = nil
            guard !reduceMotion, !ticker.running else { return }
            last = nil
            ticker.start(in: self) { [weak self] time in self?.advance(at: time) ?? false }
        } else if ticker.running, front != nil {
            head = nil
        } else {
            stop()
        }
    }

    private func advance(at time: CFTimeInterval) -> Bool {
        guard let field, showing, !WindowLayout.anyTransitioning else {
            stop()
            return false
        }
        let length = (field.voiceString as NSString).length
        guard let caret = field.caret(at: min(head ?? length, length)) else {
            stop()
            return false
        }
        // 收尾时头的去处在字尾后面一个扫掠宽，到了就收起
        var target = caret.minX
        if head == nil {
            if finishing == nil { finishing = time }
            target += Self.halfWidth
        }
        let dt = last.map { min(max(time - $0, 0), 0.05) } ?? 0
        last = time
        if let front, abs(front.line.minY - caret.minY) < 1 {
            self.front = (caret, front.x + (target - front.x) * (1 - exp(-dt / 0.05)))
        } else {
            front = (caret, self.front == nil ? caret.minX - Self.halfWidth : head == nil ? target : caret.minX)
        }
        if let finishing, let front, front.x >= target - 1 || time - finishing > Self.finishLimit {
            stop()
            return false
        }
        show(field)
        return true
    }

    /// 摆出眼下这一刻：扫到的那一截换成算好的图，输入框挖掉这一截。
    private func show(_ field: PlatformView & VoiceSweepField) {
        guard let front else { return }
        let size = field.bounds.size
        let key = SourceKey(text: field.voiceString, gray: field.voiceGray, size: size)
        if source?.key != key {
            let scale = scale
            source = field.sweepImage().flatMap { image in
                PixelSweep(image: image, size: size, scale: scale, cell: PixelSweep.cell(lineHeight: front.line.height))
            }.map { (key, $0) }
        }
        guard let sweep = source?.sweep, let target = field.sweepMaskLayer,
              let band = sweep.band(front: front.x, halfWidth: Self.halfWidth, rows: front.line.minY..<front.line.maxY) else { return hide() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.frame = band.frame
        effect.contents = band.image
        effect.contentsScale = sweep.scale
        effect.isHidden = false
        // 遮罩挂在输入框的图层上、按它的 bounds 摆（iOS 滚动时原点是滚动偏移），路径按看得见的那一块
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        path.addRect(band.frame)
        hole.frame = field.bounds
        hole.path = path
        if target.mask !== hole { target.mask = hole }
        CATransaction.commit()
    }

    private func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.isHidden = true
        if let target = field?.sweepMaskLayer, target.mask === hole { target.mask = nil }
        CATransaction.commit()
    }

    private func stop() {
        ticker.stop()
        head = nil
        front = nil
        finishing = nil
        source = nil
        hide()
    }
}
