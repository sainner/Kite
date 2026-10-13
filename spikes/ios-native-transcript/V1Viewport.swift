import SwiftUI
import UIKit

/// V1：关了滚动的 UITextView（TextKit 2）放进外层 UIScrollView、只露出 400 pt 时，它自己排版排多少；改宽以后又排多少。
/// 对照：同一段字整段 ensureLayout、开着滚动的 UITextView 自己当滚动视图、「视口窗」（文本视图只取露出来那截，bounds 跟着偏移），
/// 以及共用的 TextKitMeasuring.measure(lineWidth:from:through:) 只排一截。
struct ViewportSpikeHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ViewportSpike { ViewportSpike() }
    func updateUIViewController(_ controller: ViewportSpike, context: Context) {}
}

/// 遵循 App 的共用量高协议（app/Kite/UI/TextKitMeasuring.swift 直接编进来），fit 按 iOS 写：改视图宽，容器跟着。
class SpikeTextView: UITextView, TextKitMeasuring {
    private(set) var layouts = 0

    override func layoutSubviews() {
        layouts += 1
        super.layoutSubviews()
    }

    /// 容器的高也要放开：关了滚动的 UITextView 把容器高定成视图的高（实测 frame 高 100 时整段只排到 109 pt）。
    func fit(lineWidth: CGFloat) {
        let total = lineWidth + textContainerInset.left + textContainerInset.right
        if frame.width != total { frame.size.width = total }
        let size = CGSize(width: lineWidth, height: .greatestFiniteMagnitude)
        if textContainer.size != size { textContainer.size = size }
    }
}

final class ViewportSpike: UIViewController {
    private let report = Report.shared
    private var ran = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !ran else { return }
        ran = true
        Task { await run() }
    }

    static func text(characters: Int) -> NSAttributedString {
        let sentences = [
            "原生列表只量可见区附近的行，远处的按量过的高占位，空闲时再补。",
            "This keeps the drag at sixty frames per second while the column width changes on iPad.",
            "拖缝时长正文只排露出来的那一截，其余按估的高占位，停下以后整段排准。",
            "看着的内容按顶上那一行按住，补量让上面的行变高变矮时不跳。",
            "A long English sentence that wraps across several lines so that line breaking actually matters here.",
            "中文避头尾在临界宽度下会让个别行折得不一样，所以停下后按精确的重量。",
        ]
        let body = UIFont.preferredFont(forTextStyle: .body)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 10
        let result = NSMutableAttributedString()
        var index = 0
        while result.length < characters {
            let count = 2 + index % 5
            let paragraph = (0..<count).map { sentences[($0 + index) % sentences.count] }.joined() + "\n"
            result.append(NSAttributedString(string: paragraph, attributes: [.font: body, .paragraphStyle: style, .foregroundColor: UIColor.label]))
            index += 1
        }
        return result
    }

    private func makeTextView(_ text: NSAttributedString, scrolls: Bool = false) -> SpikeTextView {
        let view = SpikeTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = scrolls
        view.scrollsToTop = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = text
        return view
    }

    /// 已排好的段落数 / 总段数，以及排好的那些在排版坐标里的上下沿。
    private func laid(_ view: UITextView) -> String {
        guard let layout = view.textLayoutManager else { return "无 TextKit 2" }
        var laid = 0, total = 0
        var top = CGFloat.infinity, bottom = -CGFloat.infinity
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            total += 1
            if fragment.state == .layoutAvailable {
                laid += 1
                top = min(top, fragment.layoutFragmentFrame.minY)
                bottom = max(bottom, fragment.layoutFragmentFrame.maxY)
            }
            return true
        }
        return laid == 0 ? "排好 0/\(total) 段" : "排好 \(laid)/\(total) 段（y \(Int(top))…\(Int(bottom))）"
    }

    private func viewport(_ view: UITextView) -> String {
        guard let controller = view.textLayoutManager?.textViewportLayoutController else { return "-" }
        let bounds = controller.viewportBounds
        return "视口 y \(Int(bounds.minY))…\(Int(bounds.maxY))（高 \(Int(bounds.height))）"
    }

    private func clippedTextView(_ text: NSAttributedString, scrolls: Bool, outer: UIScrollView) -> ClippedTextView {
        let view = ClippedTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = scrolls
        view.panGestureRecognizer.isEnabled = false
        view.scrollsToTop = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.clip = { [weak outer, weak view] in
            guard let outer, let view else { return .null }
            return outer.convert(outer.bounds, to: view).insetBy(dx: 0, dy: -100).intersection(view.bounds)
        }
        view.attributedText = text
        return view
    }

    private func ms(_ start: CFTimeInterval) -> String {
        String(format: "%.1f ms", (CACurrentMediaTime() - start) * 1000)
    }

    /// y 处（排版坐标）那段起头的字在全文里是第几个：排好的位置是真的还是估的，和整段排准的参照比。
    private func offset(at y: CGFloat, in view: SpikeTextView) -> Int? {
        guard let layout = view.textLayoutManager, let fragment = view.laidFragment(at: y) else { return nil }
        return layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
    }

    private func run() async {
        let width: CGFloat = 600
        let narrow: CGFloat = 560
        let text = Self.text(characters: 75_000)
        report.line("V1 \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)，正文 \(text.length) 字，正文字体 \(UIFont.preferredFont(forTextStyle: .body).pointSize) pt")

        // 参照：整段排准
        let reference = makeTextView(text)
        reference.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        var start = CACurrentMediaTime()
        let fullHeight = reference.measure(lineWidth: width)
        report.line("参照：宽 \(Int(width)) 整段 ensureLayout \(ms(start))，高 \(Int(fullHeight))，\(laid(reference))")
        start = CACurrentMediaTime()
        let narrowHeight = reference.measure(lineWidth: narrow)
        report.line("参照：改到 \(Int(narrow)) 整段 ensureLayout \(ms(start))，高 \(Int(narrowHeight))")
        start = CACurrentMediaTime()
        _ = reference.measure(lineWidth: width)
        report.line("参照：改回 \(Int(width)) 整段 \(ms(start))")
        let middle = (fullHeight * 0.5).rounded()

        // A：关了滚动，整段高的 frame，放进外层滚动视图，只露 400 pt，可见区停在正文中间
        let scroll = UIScrollView(frame: CGRect(x: 20, y: 120, width: width, height: 400))
        scroll.contentSize = CGSize(width: width, height: fullHeight)
        scroll.contentOffset.y = middle
        view.addSubview(scroll)
        start = CACurrentMediaTime()
        let a = makeTextView(text)
        report.line("A 建文本视图、设字 \(ms(start))：\(laid(a))，容器 \(a.textContainer.size)")
        start = CACurrentMediaTime()
        a.frame = CGRect(x: 0, y: 0, width: width, height: fullHeight)
        report.line("A 设整段高的 frame \(ms(start))：\(laid(a))，容器 \(a.textContainer.size)")
        start = CACurrentMediaTime()
        scroll.addSubview(a)
        scroll.layoutIfNeeded()
        a.layoutIfNeeded()
        report.line("A 首次露出（关滚动、露 400 pt）layoutIfNeeded \(ms(start))，layoutSubviews \(a.layouts) 次，\(laid(a))，\(viewport(a))")
        await spin(0.4)
        report.line("A 画完一帧后：\(laid(a))，\(viewport(a))")
        start = CACurrentMediaTime()
        a.frame.size.width = narrow
        report.line("A 改宽到 \(Int(narrow))：只设 frame \(ms(start))，\(laid(a))")
        start = CACurrentMediaTime()
        a.layoutIfNeeded()
        report.line("A 改宽后 layoutIfNeeded \(ms(start))，\(laid(a))，\(viewport(a))")
        await spin(0.4)
        report.line("A 改宽画完一帧后：\(laid(a))，\(viewport(a))")
        // 滚一下：视口跟不跟着可见区
        scroll.contentOffset.y = middle + 2000
        start = CACurrentMediaTime()
        scroll.layoutIfNeeded()
        a.layoutIfNeeded()
        report.line("A 外层滚动 2000 pt 后 layoutIfNeeded \(ms(start))，\(laid(a))，\(viewport(a))")
        scroll.removeFromSuperview()

        // A2：同 A，但 frame 只给到估的高（文本视图自己不会改高），看视口是不是跟 frame 走
        let scroll2 = UIScrollView(frame: CGRect(x: 20, y: 120, width: width, height: 400))
        scroll2.contentSize = CGSize(width: width, height: fullHeight)
        scroll2.contentOffset.y = 0
        view.addSubview(scroll2)
        let a2 = makeTextView(text)
        a2.frame = CGRect(x: 0, y: 0, width: width, height: fullHeight)
        scroll2.addSubview(a2)
        start = CACurrentMediaTime()
        scroll2.layoutIfNeeded()
        a2.layoutIfNeeded()
        report.line("A2 首次露出在文首（只露顶上 400 pt）layoutIfNeeded \(ms(start))，\(laid(a2))，\(viewport(a2))")
        scroll2.removeFromSuperview()

        // C：对照，开着滚动的 UITextView 自己当滚动视图，高 400，停在中间
        let c = makeTextView(text, scrolls: true)
        c.frame = CGRect(x: 20, y: 120, width: width, height: 400)
        view.addSubview(c)
        start = CACurrentMediaTime()
        c.layoutIfNeeded()
        c.contentOffset.y = middle
        c.layoutIfNeeded()
        report.line("C 对照（开着滚动、自己滚到中间）layoutIfNeeded \(ms(start))，\(laid(c))，\(viewport(c))")
        start = CACurrentMediaTime()
        c.frame.size.width = narrow
        c.layoutIfNeeded()
        report.line("C 改宽 layoutIfNeeded \(ms(start))，\(laid(c))，\(viewport(c))")
        c.removeFromSuperview()

        // B：视口窗。关着滚动，frame 只取露出来那截上下各加 100 pt，bounds 的原点跟着偏到那截在正文里的位置
        let margin: CGFloat = 100
        let window = CGRect(x: 0, y: middle - margin, width: width, height: 400 + margin * 2)
        let holder = UIView(frame: CGRect(x: 20, y: 120, width: width, height: 400))
        holder.clipsToBounds = true
        view.addSubview(holder)
        let b = makeTextView(text)
        b.frame = CGRect(x: 0, y: -margin, width: width, height: window.height)
        holder.addSubview(b)
        b.contentOffset = CGPoint(x: 0, y: window.minY)
        start = CACurrentMediaTime()
        b.layoutIfNeeded()
        report.line("B 视口窗首次露出 layoutIfNeeded \(ms(start))，contentOffset \(Int(b.contentOffset.y))，contentSize 高 \(Int(b.contentSize.height))，\(laid(b))，\(viewport(b))")
        await spin(0.3)
        report.line("B 画完一帧后：contentOffset \(Int(b.contentOffset.y))，\(laid(b))，\(viewport(b))")
        // 露出来的那截起头的字是不是整段排准时同一处的字
        if let shown = offset(at: middle, in: b), let truth = offset(at: middle, in: reference) {
            report.line("B 露出那截（排版 y=\(Int(middle))）起头的字：视口窗 \(shown)，整段排准 \(truth)，\(shown == truth ? "一致" : "不一致（上面没排的段落按估的高占位）")")
        }
        start = CACurrentMediaTime()
        b.frame.size.width = narrow
        b.layoutIfNeeded()
        report.line("B 改宽 layoutIfNeeded \(ms(start))，contentOffset \(Int(b.contentOffset.y))，\(laid(b))，\(viewport(b))")
        holder.removeFromSuperview()

        // E：同 A，但文本视图覆写 TextKit 视口控制器问它要的视口（viewportBoundsForTextViewportLayoutController:），
        // 只给外层滚动视图露出来的那截上下各加 100 pt，相当于 Mac 覆写 visibleRect
        let scroll3 = UIScrollView(frame: CGRect(x: 20, y: 120, width: width, height: 400))
        scroll3.contentSize = CGSize(width: width, height: fullHeight)
        scroll3.contentOffset.y = middle
        view.addSubview(scroll3)
        start = CACurrentMediaTime()
        let e = ClippedTextView(usingTextLayoutManager: true)
        e.isEditable = false
        e.isSelectable = false
        e.isScrollEnabled = false
        e.scrollsToTop = false
        e.backgroundColor = .clear
        e.textContainerInset = .zero
        e.textContainer.lineFragmentPadding = 0
        e.clip = { [weak scroll3, weak e] in
            guard let scroll3, let e else { return .null }
            return scroll3.convert(scroll3.bounds, to: e).insetBy(dx: 0, dy: -100).intersection(e.bounds)
        }
        e.attributedText = text
        report.line("E 建文本视图、设字 \(ms(start))：\(laid(e))，视口代理 \(String(describing: e.textLayoutManager?.textViewportLayoutController.delegate.map { type(of: $0) }))")
        start = CACurrentMediaTime()
        e.frame = CGRect(x: 0, y: 0, width: width, height: fullHeight)
        report.line("E 设整段高的 frame \(ms(start))：\(laid(e))")
        start = CACurrentMediaTime()
        scroll3.addSubview(e)
        scroll3.layoutIfNeeded()
        e.layoutIfNeeded()
        report.line("E 首次露出 layoutIfNeeded \(ms(start))，问视口 \(e.asked) 次，\(laid(e))，\(viewport(e))")
        await spin(0.4)
        report.line("E 画完一帧后：\(laid(e))，\(viewport(e))")
        start = CACurrentMediaTime()
        e.frame.size.width = narrow
        report.line("E 改宽：只设 frame \(ms(start))，\(laid(e))")
        start = CACurrentMediaTime()
        e.layoutIfNeeded()
        report.line("E 改宽后 layoutIfNeeded \(ms(start))，\(laid(e))，\(viewport(e))")
        await spin(0.4)
        report.line("E 改宽画完一帧后：\(laid(e))，\(viewport(e))")
        scroll3.contentOffset.y = middle + 2000
        e.setNeedsLayout()
        start = CACurrentMediaTime()
        e.layoutIfNeeded()
        report.line("E 外层滚动 2000 pt、请文本视图重排 \(ms(start))，\(laid(e))，\(viewport(e))")
        scroll3.removeFromSuperview()

        // F：开着滚动、关掉它自己的拖动手势，frame 给整段高放进外层滚动视图，视口同 E 裁到外层露出来的那截
        let scroll4 = UIScrollView(frame: CGRect(x: 20, y: 120, width: width, height: 400))
        scroll4.contentSize = CGSize(width: width, height: fullHeight)
        scroll4.contentOffset.y = middle
        view.addSubview(scroll4)
        let f = clippedTextView(text, scrolls: true, outer: scroll4)
        start = CACurrentMediaTime()
        f.frame = CGRect(x: 0, y: 0, width: width, height: fullHeight)
        report.line("F 开着滚动：设整段高的 frame \(ms(start))：\(laid(f))，contentSize 高 \(Int(f.contentSize.height))")
        start = CACurrentMediaTime()
        scroll4.addSubview(f)
        scroll4.layoutIfNeeded()
        f.layoutIfNeeded()
        report.line("F 首次露出 layoutIfNeeded \(ms(start))，\(laid(f))，\(viewport(f))")
        await spin(0.4)
        report.line("F 画完一帧后：\(laid(f))，\(viewport(f))，contentOffset \(Int(f.contentOffset.y))")
        start = CACurrentMediaTime()
        f.frame.size.width = narrow
        report.line("F 改宽：只设 frame \(ms(start))，\(laid(f))")
        start = CACurrentMediaTime()
        f.layoutIfNeeded()
        report.line("F 改宽后 layoutIfNeeded \(ms(start))，\(laid(f))，\(viewport(f))，contentOffset \(Int(f.contentOffset.y))")
        await spin(0.4)
        report.line("F 改宽画完一帧后：\(laid(f))，\(viewport(f))")
        if let shown = offset(at: middle, in: f), let truth = offset(at: middle, in: reference) {
            report.line("F 露出那截（排版 y=\(Int(middle))）起头的字：\(shown)，宽 600 整段排准时 \(truth)（改宽后本来就该不同，只看有没有排）")
        }
        start = CACurrentMediaTime()
        f.frame.size.height = fullHeight + 1849
        report.line("F 只改 frame 高 \(ms(start))，\(laid(f))")
        scroll4.removeFromSuperview()

        // G：关着滚动，容器不跟着视图宽，只改容器宽、不动 frame：设 frame 的开销是不是从容器尺寸变来的
        let scroll5 = UIScrollView(frame: CGRect(x: 20, y: 120, width: width, height: 400))
        scroll5.contentSize = CGSize(width: width, height: fullHeight)
        scroll5.contentOffset.y = middle
        view.addSubview(scroll5)
        let g = clippedTextView(text, scrolls: false, outer: scroll5)
        g.textContainer.widthTracksTextView = false
        g.textContainer.heightTracksTextView = false
        g.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        start = CACurrentMediaTime()
        g.frame = CGRect(x: 0, y: 0, width: width, height: fullHeight)
        report.line("G 关滚动、容器不跟视图：设整段高的 frame \(ms(start))：\(laid(g))，容器 \(g.textContainer.size)")
        start = CACurrentMediaTime()
        scroll5.addSubview(g)
        scroll5.layoutIfNeeded()
        g.layoutIfNeeded()
        report.line("G 首次露出 layoutIfNeeded \(ms(start))，\(laid(g))，\(viewport(g))")
        start = CACurrentMediaTime()
        g.textContainer.size = CGSize(width: narrow, height: .greatestFiniteMagnitude)
        report.line("G 改宽：只改容器宽 \(ms(start))，\(laid(g))")
        start = CACurrentMediaTime()
        g.layoutIfNeeded()
        report.line("G 改宽后 layoutIfNeeded \(ms(start))，\(laid(g))，\(viewport(g))")
        start = CACurrentMediaTime()
        g.frame.size.width = narrow
        report.line("G 再把 frame 宽跟上 \(ms(start))，\(laid(g))")
        start = CACurrentMediaTime()
        g.frame.size.height = fullHeight + 1849
        report.line("G 只改 frame 高 \(ms(start))，\(laid(g))，容器 \(g.textContainer.size)")
        scroll5.removeFromSuperview()

        // H：开着滚动（拖动手势关掉）、容器不跟视图宽，frame 宽固定成最宽的内容列，拖缝只改容器宽、frame 只改高
        let columnMax: CGFloat = 720
        let scroll6 = UIScrollView(frame: CGRect(x: 20, y: 120, width: columnMax, height: 400))
        scroll6.contentSize = CGSize(width: columnMax, height: fullHeight)
        scroll6.contentOffset.y = middle
        view.addSubview(scroll6)
        let h = clippedTextView(text, scrolls: true, outer: scroll6)
        h.textContainer.widthTracksTextView = false
        h.textContainer.heightTracksTextView = false
        h.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        start = CACurrentMediaTime()
        let measured = h.measure(lineWidth: width)
        report.line("H 先按容器宽 \(Int(width)) 量高 \(ms(start))：高 \(Int(measured))，\(laid(h))，容器 \(h.textContainer.size)")
        start = CACurrentMediaTime()
        h.frame = CGRect(x: 0, y: 0, width: columnMax, height: measured)
        report.line("H 开着滚动、frame 宽固定 \(Int(columnMax))：再设 frame \(ms(start))：\(laid(h))，容器 \(h.textContainer.size)")
        start = CACurrentMediaTime()
        scroll6.addSubview(h)
        scroll6.layoutIfNeeded()
        h.layoutIfNeeded()
        report.line("H 首次露出 layoutIfNeeded \(ms(start))，\(laid(h))，\(viewport(h))")
        await spin(0.3)
        var total: CFTimeInterval = 0
        var widths: [CGFloat] = []
        for step in 1...20 {
            let lineWidth = (width - 6 * CGFloat(step)).rounded()
            widths.append(lineWidth)
            start = CACurrentMediaTime()
            h.textContainer.size = CGSize(width: lineWidth, height: .greatestFiniteMagnitude)
            h.layoutIfNeeded()
            total += CACurrentMediaTime() - start
        }
        report.line("H 连续 20 步只改容器宽（\(Int(widths.first ?? 0))→\(Int(widths.last ?? 0))）每步平均 \(String(format: "%.1f ms", total / 20 * 1000))，\(laid(h))，\(viewport(h))，contentSize 高 \(Int(h.contentSize.height))，contentOffset \(Int(h.contentOffset.y))，容器 \(h.textContainer.size)")
        start = CACurrentMediaTime()
        h.frame.size.height = fullHeight + 1849
        h.layoutIfNeeded()
        report.line("H 只改 frame 高 \(ms(start))，\(laid(h))，contentOffset \(Int(h.contentOffset.y))")
        scroll6.contentOffset.y = middle + 2000
        start = CACurrentMediaTime()
        h.textLayoutManager?.textViewportLayoutController.layoutViewport()
        report.line("H 外层滚动 2000 pt、请视口重排 \(ms(start))，\(laid(h))，\(viewport(h))")
        await spin(0.3)
        let image = UIGraphicsImageRenderer(bounds: scroll6.bounds).image { _ in scroll6.drawHierarchy(in: scroll6.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("v1-h.png"))
        scroll6.removeFromSuperview()

        // D：共用的只排一截（拖缝时列表量高用）：整段排准以后改宽，从中间一段起排 1400 pt
        let d = makeTextView(text)
        d.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        _ = d.measure(lineWidth: width)
        if let layout = d.textLayoutManager, let fragment = d.laidFragment(at: middle) {
            start = CACurrentMediaTime()
            let laidBand = d.measure(lineWidth: narrow, from: fragment.rangeInElement.location, through: 1400)
            report.line("D 共用 measure(lineWidth:from:through:) 改宽后只排 1400 pt：\(ms(start))，这截 y \(Int(laidBand?.top ?? -1))…\(Int(laidBand?.bottom ?? -1))，\(laid(d))")
            _ = layout
        }
        report.finish("v1")
    }
}

/// 视口只给 clip 那截：TextKit 视口控制器向文本视图要视口时，按外层可见区裁。iOS 27 起 UITextView 公开了这个代理方法
/// （viewportBounds(for:)，头文件注明要调 super），相当于 Mac 覆写 visibleRect。
final class ClippedTextView: SpikeTextView {
    var clip: (() -> CGRect)?
    private(set) var asked = 0

    @available(iOS 27.0, *)
    override func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let full = super.viewportBounds(for: textViewportLayoutController)
        asked += 1
        guard let clip = clip?(), !clip.isNull else { return full }
        return full.intersection(clip)
    }
}
