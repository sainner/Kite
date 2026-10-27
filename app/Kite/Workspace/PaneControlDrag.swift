#if os(iOS)
import SwiftUI
import UIKit

/// 共用控制区的拖动由原生宿主接，SwiftUI 只交出范围、焦点与保留区域。
/// 真机上返回全灰的上下文工具栏后，UIKit 仍收到触摸，但 SwiftUI 的识别器在按下时已经失败；
/// 手势挂在 HostIsland 上，避免横滑、上拉依赖里面按钮和玻璃的手势注册。
struct PaneControlDrag: UIViewRepresentable {
    let swipe: PaneSwipeActions?
    let pull: DrawerPull?
    let reservations: [CGRect]
    let nativeReservation: (@MainActor (CGPoint) -> Bool)?

    func makeUIView(context: Context) -> PaneControlDragView { PaneControlDragView() }

    func updateUIView(_ view: PaneControlDragView, context: Context) { view.update(self) }

    static func dismantleUIView(_ view: PaneControlDragView, coordinator: ()) { view.leave() }
}

final class PaneControlDragView: UIView, UIGestureRecognizerDelegate {
    private let drag = ThresholdDrag()
    private weak var island: HostIsland?
    private var configuration: PaneControlDrag?
    /// 一次拖动始终交给起手时的窗口；环境重报不能把半次手势交到另一个窗口。
    private enum Action {
        case swipe(PaneSwipeActions)
        case pull(DrawerPull)
    }
    private var action: Action?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        drag.delegate = self
        drag.addTarget(self, action: #selector(dragged(_:)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ configuration: PaneControlDrag) {
        self.configuration = configuration
        switch action {
        case .swipe where configuration.swipe == nil, .pull where configuration.pull == nil:
            cancel()
            drag.isEnabled = false
        default:
            break
        }
        drag.isEnabled = configuration.swipe != nil || configuration.pull != nil
    }

    /// 识别器挂在所在的岛上，归谁由岛定（见 HostIsland.controlsDragOwner）。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { leave(); return }
        var ancestor = superview
        while let view = ancestor {
            if let island = view as? HostIsland {
                if self.island !== island { leave() }
                self.island = island
                island.enterControlsDrag(self)
                return
            }
            ancestor = view.superview
        }
        leave()
    }

    func leave() {
        island?.leaveControlsDrag(self)
        island = nil
    }

    func attach(to island: HostIsland) {
        island.addGestureRecognizer(drag)
    }

    func release(from island: HostIsland) {
        cancel()
        island.removeGestureRecognizer(drag)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 识别器挂在整块岛上，但起手范围只含这条控制区，不接正文或标题栏。
        island?.controlsDragOwner === self && window != nil && bounds.contains(touch.location(in: self))
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let configuration, let start = drag.start else { return false }
        if DrawerPull.isHorizontal(drag.translation) {
            guard let swipe = configuration.swipe,
                  !configuration.reservations.contains(where: { $0.contains(start) }),
                  configuration.nativeReservation?(start) != true else { return false }
            action = .swipe(swipe)
        } else {
            guard let pull = configuration.pull else { return false }
            action = .pull(pull)
        }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func dragged(_ recognizer: ThresholdDrag) {
        switch recognizer.state {
        case .began, .changed:
            switch action {
            case .swipe(let swipe): swipe.track(recognizer.translation.width)
            case .pull(let pull): pull.changed(recognizer.translation, recognizer.velocity)
            case nil: break
            }
        case .ended:
            let finished = action
            action = nil
            switch finished {
            case .swipe(let swipe): swipe.end(recognizer.translation.width, recognizer.predictedTranslation.width)
            case .pull(let pull): pull.ended(recognizer.velocity)
            case nil: break
            }
        case .cancelled, .failed:
            cancel()
        default:
            break
        }
    }

    private func cancel() {
        let cancelled = action
        action = nil
        switch cancelled {
        case .swipe(let swipe): swipe.cancel()
        case .pull(let pull): pull.ended(.zero)
        case nil: break
        }
    }
}
#endif
