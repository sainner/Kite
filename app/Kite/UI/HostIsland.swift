#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 原生外壳里的一块 SwiftUI（停靠栏、空画板、点阵、头像、窗口按钮、标题栏、窗口正文……）：UIHostingController 的视图包一层，
/// 尺寸由原生给，不另算安全区。进窗口时把控制器挂到最近的视图控制器下面（菜单、弹窗、键盘快捷键要它在控制器层级里），离开时摘掉。
/// 只在 hitRegion（本视图坐标）里接点按，其余的点落到下面；不给 hitRegion 时整块照常。Mac 的对应是各个 NSHostingView 子类。
final class HostIsland: UIView {
    let controller: IslandController
    /// 接点按的范围，本视图坐标；返回 nil 时整块不接。
    var hitRegion: (() -> CGRect?)?
    /// 接点按的范围按圆角算（输入区的玻璃）。
    var hitRadius: CGFloat = 0

    var rootView: AnyView {
        get { controller.rootView }
        set { controller.rootView = newValue }
    }

    /// 托管视图报理想大小变了（sizing 里有 preferredContentSize 时）。
    var sizeChanged: (() -> Void)? {
        get { controller.sizeChanged }
        set { controller.sizeChanged = newValue }
    }

    init(sizing: UIHostingControllerSizingOptions = []) {
        controller = IslandController(rootView: AnyView(EmptyView()))
        controller.sizingOptions = sizing
        controller.safeAreaRegions = []
        super.init(frame: .zero)
        controller.view.backgroundColor = .clear
        addSubview(controller.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 托管视图的理想大小（sizing 里有 intrinsicContentSize 时由 SwiftUI 维护）。
    var idealSize: CGSize { controller.view.intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        if controller.view.frame != bounds { controller.view.frame = bounds }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            guard controller.parent == nil, let parent = nearestController else { return }
            parent.addChild(controller)
            controller.didMove(toParent: parent)
        } else if controller.parent != nil {
            controller.willMove(toParent: nil)
            controller.removeFromParent()
        }
    }

    private var nearestController: UIViewController? {
        var responder: UIResponder? = superview
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hitRegion {
            guard let region = hitRegion() else { return nil }
            let shape = hitRadius > 0 ? UIBezierPath(roundedRect: region, cornerRadius: hitRadius) : UIBezierPath(rect: region)
            guard shape.contains(point) else { return nil }
        }
        let hit = super.hitTest(point, with: event)
        // 托管视图里没有东西接的空白不挡下面
        return hit === self ? nil : hit
    }
}

/// 岛的控制器：理想大小变了告诉外面。
final class IslandController: UIHostingController<AnyView> {
    var sizeChanged: (() -> Void)?

    override var preferredContentSize: CGSize {
        didSet { if preferredContentSize != oldValue { sizeChanged?() } }
    }
}

/// 只负责显示、点按和读屏都穿过去的一层（头像随外框平移的那一层）。
final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// 按下挪过 threshold 才算开始的拖动，同 SwiftUI 的 DragGesture(minimumDistance:)（UIPanGestureRecognizer 的起步距离改不了）。
/// 位置都按窗口坐标报（同 DragGesture 的 .global）；速度按最近 0.1 秒挪的算（点每秒）。
final class ThresholdDrag: UIGestureRecognizer {
    var threshold: CGFloat = Metrics.dragThreshold
    private(set) var start: CGPoint?
    private(set) var location: CGPoint = .zero
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    /// 相对按下处挪了多少。
    var translation: CGSize {
        guard let start else { return .zero }
        return CGSize(width: location.x - start.x, height: location.y - start.y)
    }

    var velocity: CGSize {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.001 else { return .zero }
        let dt = last.time - first.time
        return CGSize(width: (last.point.x - first.point.x) / dt, height: (last.point.y - first.point.y) / dt)
    }

    /// 松手后照这个速度滑下去大概停在哪（同 UIScrollView 正常减速的投影），相对按下处。
    var predictedTranslation: CGSize {
        let rate = UIScrollView.DecelerationRate.normal.rawValue
        let factor = rate / (1 - rate) / 1000
        return CGSize(width: translation.width + velocity.width * factor, height: translation.height + velocity.height * factor)
    }

    private func sample(_ touch: UITouch) {
        let now = touch.timestamp
        samples.append((now, touch.location(in: nil)))
        samples.removeAll { now - $0.time > 0.1 }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, state == .possible, start == nil, let touch = touches.first else {
            if state == .possible { state = .failed }
            return
        }
        start = touch.location(in: nil)
        location = start ?? .zero
        samples = []
        sample(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let start else { return }
        location = touch.location(in: nil)
        sample(touch)
        if state == .possible {
            if hypot(location.x - start.x, location.y - start.y) >= threshold { state = .began }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        // 松手前停住的，速度按停住算
        if let touch = touches.first, start != nil { sample(touch) }
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        start = nil
        samples = []
    }
}

/// 图层模糊：iOS 的图层没有公开的模糊滤镜，用系统自己（SwiftUI 的 blur 也是）用的 CAFilter；取不到时只做透明度。
enum LayerBlur {
    static func filter(name: String) -> NSObject? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        guard type.responds(to: make), let filter = type.perform(make, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        filter.setValue(name, forKey: "name")
        filter.setValue(0, forKey: "inputRadius")
        return filter
    }
}
#endif
