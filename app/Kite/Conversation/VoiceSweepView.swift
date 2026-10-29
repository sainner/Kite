#if os(macOS)
import AppKit

/// 语音整理时输入框里的像素扫掠，同工具行（算法见 PixelSweep）：扫掠的头在 VoiceTextStyle.head，
/// 头的前面是整理后的字，后面是还没扫到的灰字，扫过去的地方就换成了整理后的字。
/// 头由 ThreadControlsModel 按固定速度一个字一个字往前推，这里逐帧追上（时间常数 0.05 秒），进场时从这一行左边滑进来；
/// 整理完（或没成、被人改了字）头接着走过字尾离开。换行时跳到新的一行。
/// 盖在输入框上面、和它一样大，不接点击；输入框用遮罩挖掉扫到的那一截，这一截画成算好的图。开了「减弱动态效果」不画，只有灰字。
final class VoiceSweepView: NSView {
    private weak var field: ComposerField?
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

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(field: ComposerField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(effect)
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
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !ticker.running else { return }
            last = nil
            ticker.start(in: self) { [weak self] time in self?.advance(at: time) ?? false }
        } else if ticker.running, front != nil {
            head = nil
        } else {
            stop()
        }
    }

    private func advance(at time: CFTimeInterval) -> Bool {
        guard let field, window?.occlusionState.contains(.visible) == true, !WindowLayout.anyTransitioning else {
            stop()
            return false
        }
        let length = (field.text as NSString).length
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
    private func show(_ field: ComposerField) {
        guard let front else { return }
        let key = SourceKey(text: field.text, gray: field.voiceGray, size: field.bounds.size)
        if source?.key != key {
            let scale = window?.backingScaleFactor ?? 2
            source = field.sweepImage().flatMap { image in
                PixelSweep(image: image, size: field.bounds.size, scale: scale, cell: PixelSweep.cell(lineHeight: front.line.height))
            }.map { (key, $0) }
        }
        guard let sweep = source?.sweep,
              let band = sweep.band(front: front.x, halfWidth: Self.halfWidth, rows: front.line.minY..<front.line.maxY) else { return hide() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.frame = band.frame
        effect.contents = band.image
        effect.contentsScale = sweep.scale
        effect.isHidden = false
        let path = CGMutablePath()
        path.addRect(field.bounds)
        path.addRect(band.frame)
        hole.frame = field.bounds
        hole.path = path
        if field.layer == nil { field.wantsLayer = true }
        if field.layer?.mask !== hole { field.layer?.mask = hole }
        CATransaction.commit()
    }

    private func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effect.isHidden = true
        if field?.layer?.mask === hole { field?.layer?.mask = nil }
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
#endif
