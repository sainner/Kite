import SwiftUI

/// 原生台面（Mac 的 StageView、iPad 的 PhoneStageView）上，窗口正文按停着的样子排一次，飞行中只改外层图层的变换和遮罩。
/// 这里是两端共用的部分：一帧的摆放、正文所在的容器（HostedContentSurface，各端一个原生视图）、标题两侧的跟随、正文托管树的摆放。

/// 正文一帧的摆放，在托管视图（area）的坐标里：排在 destination、原尺寸的正文按 scale 缩放、左上角落在 contentOrigin，
/// 按外框裁切、按 contentOpacity 淡出。标题两侧要挪多少、标题右边截掉多少，见 WindowHeaderAnchored。
struct HostedContentFrame: Equatable {
    init() {}

    /// 正文这一帧的摆放，都在托管视图（area）的坐标里：排在 destination、原尺寸的正文按 scale 缩放、左上角落在 contentOrigin，
    /// 按外框裁切、按 contentOpacity 淡出；标题两侧挪多少、标题右边截掉多少，见 WindowHeaderAnchored。
    init(pose: WindowPose, target: WindowPose, destination: CGPoint, area: CGRect, contentSize: CGSize) {
        let origin = pose.contentOrigin(size: contentSize)
        transform = CGAffineTransform(a: pose.scale, b: 0, c: 0, d: pose.scale,
                                      tx: origin.x - area.minX - pose.scale * (destination.x - area.minX),
                                      ty: origin.y - area.minY - pose.scale * (destination.y - area.minY))
        let shift = pose.headerShift(contentSize: contentSize)
        clip = pose.frame.offsetBy(dx: -area.minX, dy: -area.minY)
        radius = pose.radius
        opacity = pose.contentOpacity
        headerShift = shift
        titleCut = max(0, 2 * shift.dx)
        // 按这一帧看不看得见：排布刚改的那次更新里 motion 还没开始走，只按终点和 moving 算的话，缩小时整块正文先藏起来、
        // 开始走时再露出来，正文的视图树来回走两遍（2026-10-12 Mac 实测，首帧多 2～3 毫秒）
        shown = target.contentOpacity > 0 || pose.contentOpacity > 0
    }

    var transform = CGAffineTransform.identity
    var clip = CGRect.zero
    var radius: CGFloat = 0
    var opacity: Double = 1
    /// 标题两侧相对排版位置要挪的量，左侧按原样、右侧横向取反。标题栏看得见、停着时外框和正文一样大，不用挪。
    var headerShift = CGVector.zero
    /// 标题右边截掉的宽度。
    var titleCut: CGFloat = 0
    /// 收成停靠形状停着时整块隐藏。
    var shown = true
}

/// 正文所在的原生容器：Mac 是 HostedContentContainer，iPad 是 PhoneContentContainer。
@MainActor protocol HostedContentSurface: AnyObject {
    /// 摆到这一帧：交给 Core Animation 的那一段（有的话）收掉。
    func apply(_ frame: HostedContentFrame)
    /// 整段交给 Core Animation：frames 按时间均匀取，飞行中一直看得见，模型值停在最后一帧。
    func animate(_ frames: [HostedContentFrame], duration: TimeInterval)
}

/// 正文里跟着外框挪动的标题一侧，见 WindowHeaderAnchored。
@MainActor protocol WindowHeaderFollower: AnyObject {
    /// shift 是相对排版位置要挪的量（左侧按原样、右侧横向取反），titleCut 是标题右边截掉的宽度。
    func follow(shift: CGVector, titleCut: CGFloat)
    /// 整段交给 Core Animation：每一帧的挪动量和截掉的宽度，按时间均匀取，停在最后一帧。
    func follow(_ frames: [(shift: CGVector, titleCut: CGFloat)], duration: TimeInterval)
    /// 交给 Core Animation 的那一段走完了：按最后一帧摆好，收掉为它留着的东西。
    func settleFlight()
}

/// 窗口正文的容器、正文里标题两侧与逐帧驱动之间的联系。
@MainActor final class HostedContentLink {
    weak var container: (any HostedContentSurface)?
    private(set) var frame = HostedContentFrame()
    let placement = HostedPlacement()
    private let followers = NSHashTable<AnyObject>.weakObjects()

    /// 加进来时先按当前这一帧摆好。
    func add(_ follower: WindowHeaderFollower) {
        followers.add(follower)
        follower.follow(shift: frame.headerShift, titleCut: frame.titleCut)
    }

    func remove(_ follower: WindowHeaderFollower) { followers.remove(follower) }

    func apply(_ frame: HostedContentFrame) {
        self.frame = frame
        container?.apply(frame)
        for case let follower as WindowHeaderFollower in followers.allObjects {
            follower.follow(shift: frame.headerShift, titleCut: frame.titleCut)
        }
    }

    /// 交给 Core Animation 的那一段走完：按最后一帧再交一次，飞行中一直显示着的正文这时该藏的藏起来。
    func settle() {
        container?.apply(frame)
        for case let follower as WindowHeaderFollower in followers.allObjects { follower.settleFlight() }
    }

    /// 整段交给 Core Animation：frames 是按时间均匀取的每一帧，飞行中一直看得见，停在最后一帧（原生台面，见 CardView）。
    func animate(_ frames: [HostedContentFrame], duration: TimeInterval) {
        guard let last = frames.last else { return }
        frame = last
        container?.animate(frames, duration: duration)
        for case let follower as WindowHeaderFollower in followers.allObjects {
            follower.follow(frames.map { ($0.headerShift, $0.titleCut) }, duration: duration)
        }
    }
}

extension EnvironmentValues {
    /// 正文里的标题两侧按它接逐帧的挪动，见 WindowHeaderAnchored。
    @Entry var windowHeaderAnchors: HostedContentLink?
    @Entry var windowHeaderTitleEdge: WindowHeaderTitleEdge?
}

/// 标题左边在它那一侧里的位置：截得再多也不截到标题前面的按钮，见 WindowHeaderTitleMask。
@MainActor final class WindowHeaderTitleEdge {
    var minX: CGFloat = 0 {
        didSet { if minX != oldValue { changed?() } }
    }
    var changed: (() -> Void)?
}

/// 正文尺寸和窗口坐标单独送进托管树；拖缝只更新这里，语义内容与外部环境仍正常转交。
@Observable final class HostedPlacement {
    var value = HostedPlacementValue()
}

struct HostedPlacementValue: Equatable {
    var origin = CGPoint.zero
    var contentSize = CGSize.zero
    var offset = CGPoint.zero
    var extent = CGSize.zero
}

/// 正文托管树：从窗口原点铺起，正文按 offset 摆在它停着的位置，里面按 .global 取位置的和窗口坐标对得上。
struct HostedPlaced<Content: View>: View {
    let content: Content
    let link: HostedContentLink

    var body: some View {
        let placement = link.placement.value
        content
            .environment(\.windowHeaderAnchors, link)
            .frame(width: placement.contentSize.width, height: placement.contentSize.height)
            .offset(x: placement.offset.x, y: placement.offset.y)
            .frame(width: placement.extent.width, height: placement.extent.height, alignment: .topLeading)
    }
}
