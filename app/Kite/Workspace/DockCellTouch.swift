#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// iPad 台面上从停靠栏拖出一格（有视图的实例、家族格的父代理、展开的家族格里的子代理）：同 Mac 的 DockPaneDrag 走排布的拖动模型，
/// 卡片缩成停靠形状跟着手指或指针，放到台面上就放上台面，放回停靠栏上空就是缩小（WindowLayout.drag、drop，坐标由 PhoneStageView 换算）。
///
/// 起拖交给系统拖放（UIDragInteraction），同标题栏的拖动（PhoneCardView 的 CardHeaderView）只借它的长按、跟踪和与长按菜单的配合，
/// 拖着的东西看不见，卡片自己跟着走；松手由排布按最后的落点放（系统那边没有放的地方，一律当取消）。
/// - 手指和笔：长按到时格子浮起、弹出长按菜单（格子上 SwiftUI 的 contextMenu），不动就留着菜单，动了菜单收起、转成拖动；
///   没长按就滑动的不起拖，交给停靠栏的滚动。
/// - 指针（触控板、鼠标）：按住挪过一段就起拖，不等长按（iOS 上指针拖动默认如此，见 allowsPointerDragBeforeLiftDelay），同 Mac 按距离起拖。
/// 拿起来时系统让别的手势都失败：按钮不再点开，停靠栏不再滚动。
///
/// 菜单和拖动挂在同一个视图上，由系统协调（同标题栏）。格子上 SwiftUI 的长按菜单不在格子自己的视图上：iOS 27.1 的 SwiftUI 里是
/// ContextMenuBridge，一个托管视图一个交互、按按下的位置找格子，所以拖动也挂在停靠栏那个岛的托管视图上；
/// 拖动只知道按在哪，拖哪一格要另外认，见 DockCellTouch。
final class DockTouchDrag: NSObject, UIDragInteractionDelegate {
    /// 各停靠栏岛上装着的，岛没了跟着去掉。
    private static let installed = NSMapTable<HostIsland, DockTouchDrag>.weakToStrongObjects()

    /// 台面建好停靠栏的岛时装上，一个岛一份。
    static func install(on island: HostIsland, stage: PhoneStageView) {
        guard installed.object(forKey: island) == nil else { return }
        installed.setObject(DockTouchDrag(island: island, stage: stage), forKey: island)
    }

    /// view 所在的停靠栏岛上装着的那份。
    fileprivate static func serving(_ view: UIView) -> DockTouchDrag? {
        var current: UIView? = view
        while let candidate = current {
            if let island = candidate as? HostIsland, let drag = installed.object(forKey: island) { return drag }
            current = candidate.superview
        }
        return nil
    }

    private weak var host: UIView?
    private weak var stage: PhoneStageView?
    private let down = DockTouchDown()
    /// 最近一次按在能拖的格子上：哪一格、哪次按下。
    private var press: (pane: Pane, down: TouchDown)?
    /// 交出了拖动的项、等系统开始拖。
    private var lifted: Pane?
    /// 正在拖的那一格。
    private var dragging: Pane?

    private init(island: HostIsland, stage: PhoneStageView) {
        host = island.controller.view
        self.stage = stage
        super.init()
        // 每次按下都记，挂在岛上：托管视图上只放和长按菜单配对的拖动
        island.addGestureRecognizer(down)
        let lift = UIDragInteraction(delegate: self)
        lift.isEnabled = true
        if #available(iOS 27.0, *) { lift.allowsPointerDragBeforeLiftDelay = true }
        island.controller.view.addInteraction(lift)
    }

    fileprivate func pressed(_ pane: Pane, at touch: TouchDown) {
        press = (pane, touch)
    }

    // MARK: 起拖

    /// 只在这一次按下落在能拖的格子上时交出一项；按在加号、布局文件夹、压暗的格子这些地方的，格子那边没记下这次按下，不起拖，长按菜单照常。
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        guard dragging == nil, let press, let last = down.last, press.down.same(as: last), stage?.group.layout.drag == nil else { return [] }
        lifted = press.pane
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.previewProvider = { UIDragPreview(view: Self.invisible(), parameters: Self.invisibleParameters()) }
        return [item]
    }

    /// 浮起来的是长按菜单的那份；拖动本身看不见，卡片自己跟着走。
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                         session: any UIDragSession) -> UITargetedDragPreview? {
        guard let host else { return nil }
        return UITargetedDragPreview(view: Self.invisible(), parameters: Self.invisibleParameters(),
                                     target: UIDragPreviewTarget(container: host, center: session.location(in: host)))
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem,
                         withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? { nil }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        guard let pane = lifted, let host else { return }
        lifted = nil
        dragging = pane
        // 手指拿起来轻触一下（iPad 没有触感马达，只有支持触感的笔会震），同标题栏；指针不震
        if down.last?.pointer != true {
            UIImpactFeedbackGenerator(style: .light, view: host).impactOccurred(at: session.location(in: host))
        }
        stage?.drag(pane, to: windowLocation(session))
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: any UIDragSession) {
        guard let pane = dragging else { return }
        stage?.drag(pane, to: windowLocation(session))
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, willEndWith operation: UIDropOperation) {
        guard dragging != nil else { return }
        dragging = nil
        stage?.drop()
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
        guard dragging != nil else { return }
        dragging = nil
        stage?.cancelDrag()
    }

    /// 手指或指针在窗口里的位置，台面按它换算（见 PhoneStageView.drag）。
    private func windowLocation(_ session: any UIDragSession) -> CGPoint {
        guard let host else { return .zero }
        return host.convert(session.location(in: host), to: nil)
    }

    private static func invisible() -> UIView { UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1)) }

    private static func invisibleParameters() -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.shadowPath = UIBezierPath()
        return parameters
    }
}

/// 停靠栏里能拖出去的一格认领按下：DockPaneDrag 在 iOS 上挂它，pane 为 nil（不能拖，或不在宽屏台面上，紧凑布局没有台面）时什么都不挂。
/// 格子在滚动、堆叠、展开，画在哪由 SwiftUI 排，这里不另算一份位置：挂在格子上的识别器由 SwiftUI 按命中交给按下
/// （压在上面的格子、压暗或收着不接点按的都按 SwiftUI 算），它记下这次按下落在哪一格，托管视图上的拖动起拖时据此认格子。
struct DockCellTouch: ViewModifier {
    let pane: Pane?

    func body(content: Content) -> some View {
        if let pane {
            content.gesture(DockCellPress(pane: pane))
        } else {
            content
        }
    }
}

private struct DockCellPress: UIGestureRecognizerRepresentable {
    let pane: Pane

    func makeUIGestureRecognizer(context: Context) -> DockCellPressRecognizer {
        DockCellPressRecognizer(pane: pane)
    }

    func updateUIGestureRecognizer(_ recognizer: DockCellPressRecognizer, context: Context) {
        recognizer.pane = pane
    }
}

/// 只看不认：按下时记给所在停靠栏的 DockTouchDrag 就放弃，不挡按钮、滚动和长按菜单。
private final class DockCellPressRecognizer: UIGestureRecognizer {
    var pane: Pane

    init(pane: Pane) {
        self.pane = pane
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        allowedTouchTypes = TouchDown.allTypes
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view, let drag = DockTouchDrag.serving(view) {
            drag.pressed(pane, at: TouchDown(touch))
        }
        state = .failed
    }
}

/// 停靠栏岛上每次按下都记一笔（只看不认）：格子记下的按下是不是最近这一次，按在别处以后不拿旧的那格起拖。
private final class DockTouchDown: UIGestureRecognizer {
    private(set) var last: TouchDown?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        allowedTouchTypes = TouchDown.allTypes
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { last = TouchDown(touch) }
        state = .failed
    }
}

/// 一次按下：什么时候、窗口里哪一点、是不是指针。
private struct TouchDown {
    static let allTypes = [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { $0.rawValue as NSNumber }

    let time: TimeInterval
    let point: CGPoint
    let pointer: Bool

    init(_ touch: UITouch) {
        time = touch.timestamp
        point = touch.location(in: nil)
        pointer = touch.type == .indirectPointer
    }

    /// 两个识别器各自记的是不是同一次按下：同一次分发里读到的时刻和位置一样，留一点余量；
    /// 另一次按下不会在这么短的时间里落在这么近的地方，真有（连点两下）也是同一格。
    func same(as other: TouchDown) -> Bool {
        abs(time - other.time) < 0.1 && hypot(point.x - other.point.x, point.y - other.point.y) < 10
    }
}
#endif
