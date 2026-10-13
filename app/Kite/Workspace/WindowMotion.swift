import SwiftUI

/// 窗口的一帧。轮廓、正文和头像共用这份状态，不能各自从目标值启动动画。
nonisolated struct WindowPose: Equatable {
    var frame: CGRect
    var scale: CGFloat = 1
    var radius: CGFloat = 16
    var contentOpacity: Double = 1
    var iconOpacity: Double = 0

    func interpolated(to other: Self, progress: Double) -> Self {
        let p = CGFloat(progress)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return Self(frame: CGRect(x: mix(frame.minX, other.frame.minX), y: mix(frame.minY, other.frame.minY),
                                  width: mix(frame.width, other.frame.width), height: mix(frame.height, other.frame.height)),
                    scale: mix(scale, other.scale), radius: mix(radius, other.radius),
                    contentOpacity: contentOpacity + (other.contentOpacity - contentOpacity) * progress,
                    iconOpacity: iconOpacity + (other.iconOpacity - iconOpacity) * progress)
    }

    /// 正文横向居中、底边固定，尺寸只在目标改变时重排一次。
    func contentOrigin(size: CGSize) -> CGPoint {
        CGPoint(x: frame.midX - size.width * scale / 2, y: frame.maxY - size.height * scale)
    }

    /// 标题两侧贴着这一帧的外框：相对正文排版位置，左侧右移、右侧左移 dx，两侧都下移 dy。
    func headerShift(contentSize: CGSize) -> CGVector {
        CGVector(dx: (contentSize.width - frame.width / scale) / 2, dy: contentSize.height - frame.height / scale)
    }
}

nonisolated enum WindowMotionKind {
    case immediate, settle, preview, tracking

    /// 逐帧取样与 SwiftUI 排布动画共用曲线和时长，窗口与停靠栏保持同步。
    static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0),
                                       endControlPoint: UnitPoint(x: 0, y: 1))

    var duration: TimeInterval {
        switch self {
        case .immediate: 0
        case .settle: 0.3
        case .preview, .tracking: 0.2
        }
    }

    /// SwiftUI 排布动画，与逐帧取样同曲线同时长。
    var animation: Animation { .timingCurve(Self.curve, duration: duration) }
}

/// 只在目标改变时更新。TimelineView 负责取帧，窗口内容不订阅逐帧状态。
/// 中途反向从当时的呈现状态继续；拖动中的指针移动平移整条轨迹，不反复重启缩小动画。
@MainActor @Observable
final class WindowMotion {
    private(set) var target: WindowPose
    private(set) var moving = false
    var interacting = false
    @ObservationIgnored private var source: WindowPose
    /// 从这次改变排好、交上去之后起算；之前取样都停在起点，见 move。
    @ObservationIgnored private var started: Date?
    @ObservationIgnored private var duration: TimeInterval = 0
    private var kind = WindowMotionKind.immediate
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// 这一段开始计时的那一刻（见 move），Mac 原生台面在这时把整段交给 Core Animation。
    @ObservationIgnored var onStart: ((WindowMotion) -> Void)?

    init(_ pose: WindowPose) { target = pose; source = pose }

    /// 排布动画进行中（缩小、恢复、让位、放下后归位），不含跟手拖动。
    var settling: Bool { moving && kind != .tracking }

    /// 跟手拖动：指针一动整条轨迹跟着平移，不能整段预先交出去。
    var tracking: Bool { kind == .tracking }

    /// 正在走的这一段从哪一刻起、走多久；还没开始计时或停着时为 nil。
    var flight: (start: Date, duration: TimeInterval)? {
        guard moving, duration > 0, let started else { return nil }
        return (started, duration)
    }

    /// 排布动画在停靠形状和台面形状之间变：缩小进停靠栏、从停靠栏恢复、拖动松手后展开。
    var changingForm: Bool { settling && source.iconOpacity != target.iconOpacity }

    func presentation(at date: Date) -> WindowPose {
        guard duration > 0 else { return target }
        guard let started else { return source }
        let fraction = min(max(date.timeIntervalSince(started) / duration, 0), 1)
        let progress = WindowMotionKind.curve.value(at: fraction)
        return source.interpolated(to: target, progress: progress)
    }

    func move(to next: WindowPose, kind: WindowMotionKind, at date: Date = .now) {
        guard next != target || (kind == .immediate && moving) else { return }
        if kind == .tracking, self.kind == .tracking,
           next.frame.size == target.frame.size, next.scale == target.scale {
            let dx = next.frame.minX - target.frame.minX, dy = next.frame.minY - target.frame.minY
            source.frame = source.frame.offsetBy(dx: dx, dy: dy)
            if !moving { source = next }
            target = next
            return
        }
        source = presentation(at: date)
        target = next
        duration = kind.duration
        if self.kind != kind { self.kind = kind }
        completion?.cancel()
        generation += 1
        let current = generation
        // 没变不写：拖缝时每步都交新终点，读 moving 的几层不跟着每步更新
        if moving != (duration > 0) { moving = duration > 0 }
        guard moving else { source = next; started = date; return }
        // 改变排布的那次更新要重排几个窗口，几十毫秒后才画出第一帧（2026-10-11 Mac 三窗口实测 60～70 毫秒）。
        // 从动作时刻起算的话，第一帧已走过曲线的一半，窗口一出来就跳一大截；所以第一帧停在起点，等这次更新交上去再计时
        started = nil
        completion = Task { [weak self] in
            await Task.yield()
            guard let self, generation == current else { return }
            let start = Date.now
            started = start
            onStart?(self)
            do { try await Task.sleep(until: .now + .seconds(duration)) } catch { return }
            guard generation == current else { return }
            source = target
            self.duration = 0
            moving = false
            completion = nil
        }
    }
}

extension EnvironmentValues {
    @Entry var windowMotion: WindowMotion?
    @Entry var windowContentSize = CGSize.zero
}

/// 稳定的舞台：排版框始终覆盖内容区，所有裁切都发生在同一坐标系，飞行途中不经过终点的小框。
struct WindowSurface<Content: View, Icon: View, Header: View>: View {
    let motion: WindowMotion
    /// 这次排布给的终点，和交给 motion 的是同一个，见 body。
    let target: WindowPose
    let contentSize: CGSize
    let viewport: CGSize
    let iconSize: CGFloat
    let color: Color
    let minimizedColor: Color?
    /// 头像的描边，画在外框上，随头像淡入：飞过同色的窗口时也看得出轮廓，落进停靠栏外框就是头像那一圈。
    let ring: (color: Color, width: CGFloat)?
    let content: Content
    let icon: Icon
    let background: AnyView
    /// 点阵层另外要收起的时候（如拖缝调整大小）。窗口自己在动时总是收起，停下后淡入，见 WindowLayout.transitioning。
    let backgroundHidden: Bool
    let headerHeight: CGFloat?
    let onHover: (Bool) -> Void
    let header: Header
    #if os(macOS)
    @State private var hosted = HostedContentLink()
    /// 舞台左上角在窗口里的位置，正文的托管视图按它对齐窗口原点，见 HostedContentContainer。
    @State private var stageOrigin = CGPoint.zero
    #endif

    init(motion: WindowMotion, target: WindowPose, contentSize: CGSize, viewport: CGSize, iconSize: CGFloat, color: Color, minimizedColor: Color? = nil,
         ring: (color: Color, width: CGFloat)? = nil, background: AnyView = AnyView(EmptyView()), backgroundHidden: Bool = false,
         headerHeight: CGFloat? = nil, onHover: @escaping (Bool) -> Void = { _ in },
         @ViewBuilder content: () -> Content, @ViewBuilder icon: () -> Icon, @ViewBuilder header: () -> Header = { EmptyView() }) {
        self.motion = motion
        self.target = target
        self.contentSize = contentSize
        self.viewport = viewport
        self.iconSize = iconSize
        self.color = color
        self.minimizedColor = minimizedColor
        self.ring = ring
        self.background = background
        self.backgroundHidden = backgroundHidden
        self.headerHeight = headerHeight
        self.onHover = onHover
        self.content = content()
        self.icon = icon()
        self.header = header()
    }

    /// 终点用排布给的 target，不读 motion 的：排布一变，卡片随即把新终点交给 motion，读 motion 的话窗口和正文要跟着再算一轮。
    /// 动画开始、结束（moving 翻转）也只更新读它的几层（WindowClock、WindowDots），窗口本身和正文不跟着重算。
    var body: some View {
        let destination = target.contentOrigin(size: contentSize)
        // 底色、点阵和舞台各自按同一时钟取样。点阵本来就按视口坐标画，不放进下面会移动的舞台，只用轮廓遮住；
        // 窗口移动时它的内容不变，不能跟着逐帧重画（见 WindowBackdrop）
        ZStack(alignment: .topLeading) {
            WindowClock(motion: motion) { pose in
                let outline = WindowOutline(frame: pose.frame, radius: pose.radius)
                ZStack {
                    outline.fill(color).opacity(min(pose.contentOpacity + pose.iconOpacity, 1))
                    if let minimizedColor { outline.fill(minimizedColor).opacity(pose.iconOpacity) }
                }
            }
            WindowDots(motion: motion, content: background, hidden: backgroundHidden)
            #if os(macOS)
            hostedContent(destination: destination)
            #endif
            WindowClock(motion: motion) { pose in
                ZStack(alignment: .topLeading) {
                    stage(pose: pose, destination: destination)
                    if let ring { outlineRing(ring, pose: pose) }
                    #if os(macOS)
                    // 正文的缩放、平移和外框按同一次取样，同一帧交上去；动画开始、结束时接不接输入也从这里交
                    HostedContentDriver(link: hosted,
                                        placement: hostedPlacement(destination: destination), onHover: onHover,
                                        frame: hostedFrame(pose, destination: destination, area: hostedArea(destination)))
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                    #endif
                }
            }
            #if os(macOS)
            headerLayer
            #endif
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        #if os(macOS)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { stageOrigin = $0 }
        #endif
        .transaction { $0.windowContentAnimation = $0.animation; $0.animation = nil }
        .environment(\.windowMotion, motion)
        // 标题两侧按正文尺寸贴外框（见 WindowHeaderAnchor）。Mac 上两侧的挪动在图层上算（见 hostedFrame），不放进环境：
        // 放了的话正文尺寸一变就是一次环境变化，窗口正文里每个文本视图都要跟着更新
        #if !os(macOS)
        .environment(\.windowContentSize, contentSize)
        #endif
    }

    /// 描边压在舞台外面，不经过舞台的圆角裁切，外缘与外框贴合。
    private func outlineRing(_ ring: (color: Color, width: CGFloat), pose: WindowPose) -> some View {
        let inset = ring.width / 2
        return WindowOutline(frame: pose.frame.insetBy(dx: inset, dy: inset), radius: max(pose.radius - inset, 0))
            .stroke(ring.color, lineWidth: ring.width)
            .opacity(pose.iconOpacity)
            .allowsHitTesting(false)
    }

    #if os(macOS)
    /// Mac 的正文托管在自己的视图里，按停着的样子排在 destination，飞行中的缩放、平移只改外层图层（见 HostedContent）。
    /// 停着、看得见时由正文自己接悬停；收成停靠形状、飞行中舞台接（见 stage）。
    private func hostedContent(destination: CGPoint) -> some View {
        let area = hostedArea(destination)
        return HostedContent(link: hosted, motion: motion, content: content)
            .frame(width: area.width, height: area.height)
            .modifier(WindowTranslation(point: area.origin))
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    private func hostedPlacement(destination: CGPoint) -> HostedPlacementValue {
        let area = hostedArea(destination)
        // 托管视图的原点对齐窗口原点（见 HostedContentContainer），正文也保留窗口坐标。
        return HostedPlacementValue(origin: CGPoint(x: stageOrigin.x + area.minX, y: stageOrigin.y + area.minY),
                                    contentSize: contentSize,
                                    offset: CGPoint(x: stageOrigin.x + destination.x, y: stageOrigin.y + destination.y),
                                    extent: CGSize(width: max(stageOrigin.x + area.maxX, 0), height: max(stageOrigin.y + area.maxY, 0)))
    }

    /// Mac 的标题栏一层（拖动区和窗口按钮）按停着的外框摆，不跟时钟走。飞行中它看不见（按钮淡出、拖动区透明）也不接输入；
    /// 跟着外框逐帧变大小的话，拖动区这个 AppKit 视图每帧改尺寸，连带焦点、可见范围、跟踪区域和光标逐帧重算（2026-10-12 Mac 实测）。
    /// 拖起时缩小那一段拖动区直接到终点，拖动照常由按下时的视图接。
    private var headerLayer: some View {
        let frame = target.frame
        return header
            .frame(width: frame.width, height: headerHeight ?? frame.height)
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: target.radius))
            .position(x: frame.midX, y: frame.midY)
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    /// 托管视图的范围：正文的排版框加上停着时的外框。标题两侧按外框贴边（见 WindowHeaderAnchor），外框比正文宽时按钮在正文外面，
    /// 托管视图要盖住它们才接得到点击。
    private func hostedArea(_ destination: CGPoint) -> CGRect {
        CGRect(origin: destination, size: contentSize).union(target.frame)
    }

    /// 正文这一帧的摆放，都在托管视图（area）的坐标里：排在 destination、原尺寸的正文按 scale 缩放、左上角落在 contentOrigin，
    /// 按外框裁切、按 contentOpacity 淡出。标题两侧要挪多少、标题右边截掉多少，见 WindowHeaderAnchored。
    private func hostedFrame(_ pose: WindowPose, destination: CGPoint, area: CGRect) -> HostedContentFrame {
        HostedContentFrame(pose: pose, target: target, destination: destination, area: area, contentSize: contentSize)
    }
    #endif

    /// 正文、头像和标题栏的舞台：排版框始终覆盖内容区，按当前外框裁切。Mac 的正文和标题栏不在这里，见 hostedContent、headerLayer。
    private func stage(pose: WindowPose, destination: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            #if !os(macOS)
            content
                // 外层去掉了事务里的动画（外框按每帧取样）；内容自己的动画照常，如发送时对话滑动、气泡浮起。
                // 窗口改尺寸和排布变化带来的改动不带动画，内容一次排到位：原位恢复时尺寸不变，标题栏跟着窗口状态改的排版若带上恢复的动画，
                // 按钮组外层的平台容器会从窄插值到宽，按钮组被从右往左裁开（2026-10-11 Mac 实测，鼠标停在停靠栏不动时，图层树里裁它的是 _NSGraphicsView）
                .transaction(value: contentSize) { $0.animation = nil }
                .transaction { $0.animation = $0.windowLayoutChange ? nil : $0.windowContentAnimation }
                .frame(width: contentSize.width, height: contentSize.height)
                .modifier(WindowTranslation(point: destination))
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .modifier(WindowContentTransform(pose: pose, destination: destination, contentSize: contentSize).ignoredByLayout())
                // 蒙版保留 Mac 标题栏滚动软边的登记，不能对整段正文使用 opacity。
                .mask { Rectangle().opacity(pose.contentOpacity) }
            #endif
            icon
                .frame(width: iconSize, height: iconSize)
                .position(x: pose.frame.midX, y: pose.frame.midY)
                .opacity(pose.iconOpacity)
                .allowsHitTesting(false)
            #if !os(macOS)
            header
                .frame(width: pose.frame.width, height: headerHeight ?? pose.frame.height)
                .position(x: pose.frame.midX, y: pose.frame.minY + (headerHeight ?? pose.frame.height) / 2)
            #endif
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        // onHover 按排版框登记区域；裁切全舞台的轮廓不能隔开相邻窗口的悬停。
        .modifier(WindowTranslation(point: CGPoint(x: -pose.frame.minX, y: -pose.frame.minY)))
        .frame(width: pose.frame.width, height: pose.frame.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: pose.radius))
        #if os(macOS)
        // 正文在舞台下面另一个视图里。舞台整块可命中会挡住点正文，只在收成停靠形状停着时垫一层接悬停；
        // 飞行中悬停本来不用（见 PaneCard），不让它逐帧随外框重算
        .background {
            RoundedRectangle(cornerRadius: pose.radius).fill(.clear)
                .contentShape(RoundedRectangle(cornerRadius: pose.radius))
                .onHover(perform: onHover)
                .allowsHitTesting(!motion.moving && target.contentOpacity == 0)
        }
        #else
        .contentShape(RoundedRectangle(cornerRadius: pose.radius))
        .onHover(perform: onHover)
        #endif
        .position(x: pose.frame.midX, y: pose.frame.midY)
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }
}

/// 按 motion 逐帧取样，只在动画进行中走。动画开始、结束只更新这一层，外面的窗口不跟着重算。
struct WindowClock<Content: View>: View {
    let motion: WindowMotion
    var paused = false
    @ViewBuilder let content: (WindowPose) -> Content

    var body: some View {
        TimelineView(.animation(paused: paused || !motion.moving)) { clock in
            content(motion.presentation(at: clock.date))
        }
    }
}

/// 点阵层按外框遮住。点阵不参与过渡：窗口在动就收起，停下后淡入；收起时遮罩也不逐帧取样。
private struct WindowDots: View {
    let motion: WindowMotion
    let content: AnyView
    let hidden: Bool

    var body: some View {
        let hidden = hidden || motion.moving
        WindowBackdrop(content: content, hidden: hidden)
            .mask {
                WindowClock(motion: motion, paused: hidden) { pose in
                    WindowOutline(frame: pose.frame, radius: pose.radius).fill().opacity(pose.contentOpacity)
                }
            }
            #if !os(macOS)
            // Mac 上由 WindowBackdrop 自己在图层上淡入
            .opacity(hidden ? 0 : 1)
            .animation(hidden ? nil : .easeOut(duration: 0.25), value: hidden)
            #endif
            .allowsHitTesting(false)
    }
}

/// 窗口的点阵层。Mac 上托管在自己的视图里：窗口移动时只改外面的遮罩，里面整窗大小的点阵着色器不跟着卡片逐帧重画
/// （2026-10-11 Mac 实测，三个窗口并排缩小、恢复时，每帧多画三遍整窗点阵，掉到约 30 帧；挪进单独的视图后这部分开销消失）。
/// 环境整份转交，点阵照常读舞台、卡片和配色。
#if os(macOS)
private struct WindowBackdrop: NSViewRepresentable {
    let content: AnyView
    let hidden: Bool

    func makeNSView(context: Context) -> BackdropHost {
        let host = BackdropHost(rootView: rooted(in: context))
        host.sizingOptions = []
        host.alphaValue = hidden ? 0 : 1
        return host
    }

    func updateNSView(_ host: BackdropHost, context: Context) {
        host.rootView = rooted(in: context)
        // 点阵不参与过渡：一开始就收起，停下后淡入。淡入交给图层动画，主线程不逐帧插值（2026-10-12 Mac 实测，SwiftUI 插值每次多约 35 毫秒）；
        // 不经过 animator()：它由 AppKit 的动画管理器驱动，收起时在首帧后面多一次整窗排版（2026-10-12 Mac 实测约 7 毫秒）
        let alpha: CGFloat = hidden ? 0 : 1
        guard host.alphaValue != alpha else { return }
        host.alphaValue = alpha
        // 收起要当场收：淡入还在走的话图层动画会盖过新的透明度，点阵照样淡出来（2026-10-13 用户看到松手时点阵闪一下）
        if hidden { host.layer?.removeAnimation(forKey: "fade") }
        guard !hidden, let layer = host.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }

    private func rooted(in context: Context) -> AnyView {
        AnyView(content.environment(\.self, context.environment))
    }
}

/// 只负责显示，点击和读屏都穿过去。
final class BackdropHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// 正文一帧的摆放，见 WindowSurface.hostedFrame。
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

/// 正文里跟着外框挪动的标题一侧，见 WindowHeaderAnchored。
@MainActor protocol WindowHeaderFollower: AnyObject {
    /// shift 是相对排版位置要挪的量（左侧按原样、右侧横向取反），titleCut 是标题右边截掉的宽度。
    func follow(shift: CGVector, titleCut: CGFloat)
    /// 整段交给 Core Animation：每一帧的挪动量和截掉的宽度，按时间均匀取，停在最后一帧。
    func follow(_ frames: [(shift: CGVector, titleCut: CGFloat)], duration: TimeInterval)
    /// 交给 Core Animation 的那一段走完了：按最后一帧摆好，收掉为它留着的东西。
    func settleFlight()
}

/// 窗口正文的托管视图、正文里标题两侧与逐帧驱动之间的联系。
@MainActor final class HostedContentLink {
    weak var container: HostedContentContainer?
    private(set) var frame = HostedContentFrame()
    let placement = HostedPlacement()
    var onHover: (Bool) -> Void = { _ in }
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

    /// 整段交给 Core Animation：frames 是按时间均匀取的每一帧，飞行中一直看得见，停在最后一帧（Mac 原生台面，见 CardView）。
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
}

/// Mac 的窗口正文托管在自己的视图里，按停着的样子排一次；缩小、恢复途中只改外层图层的 sublayerTransform。
/// 正文若和舞台一起由 SwiftUI 几何效果缩放，SwiftUI 会把变换落到里面每个 AppKit 视图上（setFrameTransform、滚动区的 setBoundsOrigin），
/// 对话的滚动区和每个文本视图逐帧重排可见范围、按新比例重画字形（2026-10-12 Mac 实测：缩小、恢复后 0.5 秒里主线程忙 360～410 毫秒，
/// 一半以上花在这上面；离屏对照每帧 8～12 毫秒，只改外层图层后 1～4 毫秒）。
/// 外层图层的变换 AppKit 和 SwiftUI 都不知道：飞行中按停着时的位置命中，所以只在停着、看得见时接点击；
/// 收成停靠形状停着时整块隐藏，原尺寸摆着的文本视图不接光标和点击。环境整份转交，同 WindowBackdrop。
private struct HostedContent<Content: View>: NSViewRepresentable {
    let link: HostedContentLink
    let motion: WindowMotion
    let content: Content

    func makeNSView(context: Context) -> HostedContentContainer {
        let container = HostedContentContainer(rootView: rooted(in: context))
        container.motion = motion
        container.origin = link.placement.value.origin
        link.container = container
        container.apply(link.frame)
        return container
    }

    /// 尺寸由外面的 frame 定。不给的话 SwiftUI 按 Auto Layout 量 fittingSize，每次排版都把整段正文的 AppKit 视图树
    /// 塞进临时约束引擎求解（2026-10-12 Mac 实测，一分钟操作里累计 1.5 秒）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostedContentContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ container: HostedContentContainer, context: Context) {
        container.host.rootView = rooted(in: context)
    }

    private func rooted(in context: Context) -> AnyView {
        AnyView(HostedPlaced(content: content, link: link).environment(\.self, context.environment))
    }
}

/// 正文尺寸和窗口坐标单独送进托管树；拖缝只更新这里，语义内容与外部环境仍由 HostedContent 正常转交。
@Observable final class HostedPlacement {
    var value = HostedPlacementValue()
}

struct HostedPlacementValue: Equatable {
    var origin = CGPoint.zero
    var contentSize = CGSize.zero
    var offset = CGPoint.zero
    var extent = CGSize.zero
}

struct HostedPlaced<Content: View>: View {
    let content: Content
    let link: HostedContentLink

    var body: some View {
        let placement = link.placement.value
        content
            .onHover { link.onHover($0) }
            .environment(\.windowHeaderAnchors, link)
            .frame(width: placement.contentSize.width, height: placement.contentSize.height)
            .offset(x: placement.offset.x, y: placement.offset.y)
            .frame(width: placement.extent.width, height: placement.extent.height, alignment: .topLeading)
    }
}

/// 外框裁切和淡出是这一层图层上的遮罩：SwiftUI 的 mask 加在 AppKit 视图上时，每帧按整个窗口区域的大小重画遮罩
/// （2026-10-12 Mac 实测，缩小、恢复各多 30～50 毫秒主线程）。缩放、平移放在里面一层：sublayerTransform 连遮罩一起变换。
/// 托管视图从窗口原点铺到这一层的右下角，里面的坐标就是窗口坐标：嵌套的托管视图按自己的原点报标题栏给滚动软边，
/// 软边却按窗口坐标比对，原点不在窗口左上角时对不上，软边当作上面没有浮着的元素，不再模糊（2026-10-12 Mac 实测，
/// 一列两个窗口时下面那个没有软边）；正文里按 .global 取位置的也一起对上。
final class HostedContentContainer: NSView {
    let host: HostedContentView
    weak var motion: WindowMotion?
    var origin = CGPoint.zero {
        didSet { if origin != oldValue { needsLayout = true } }
    }
    /// 原生的正文（Mac 原生台面上的会话窗口外框，见 ThreadWindowView）：有它时托管视图只留一点、不跟着改尺寸，
    /// 正文按 nativeFrame（这一层的坐标）摆，缩放、裁切照样在外面这一层。
    var native: NSView? {
        didSet {
            guard native !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let native { mover.addSubview(native) }
            needsLayout = true
        }
    }
    var nativeFrame = CGRect.zero {
        didSet { if nativeFrame != oldValue { needsLayout = true } }
    }
    private let mover = FlippedView()
    private let clip = CAShapeLayer()
    private var frameState = HostedContentFrame()

    init(rootView: AnyView) {
        host = HostedContentView(rootView: rootView)
        // 尺寸由外面给，正文只按停着的大小排；不另算安全区，和放在卡片里时一样
        host.sizingOptions = []
        host.safeAreaRegions = []
        super.init(frame: .zero)
        wantsLayer = true
        mover.wantsLayer = true
        mover.addSubview(host)
        addSubview(mover)
        layer?.mask = clip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        mover.frame = bounds
        if let native {
            if host.frame != .zero { host.frame = .zero }
            if native.frame != nativeFrame { native.frame = nativeFrame }
        } else {
            host.frame = CGRect(x: -origin.x, y: -origin.y,
                                width: max(origin.x + bounds.width, 0), height: max(origin.y + bounds.height, 0))
        }
        // 排版只补摆模型值，不收进行中交给 Core Animation 的那一段
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(frameState)
        CATransaction.commit()
    }

    /// 停着、看得见时才接点击。命中时当场看动画状态：动作那一刻 SwiftUI 就按新排版重算悬停，等逐帧驱动交过来已经晚了，
    /// 会把整段正文的视图树遍历一遍（2026-10-12 Mac 实测，首帧约 3 毫秒）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let motion, !motion.moving, motion.target.contentOpacity > 0 else { return nil }
        return super.hitTest(point)
    }

    /// 交给 Core Animation 的那一段还在走，正文一直显示着（见 animate）。
    private var flying = false

    /// 摆到这一帧：交给 Core Animation 的那一段（有的话）收掉。
    func apply(_ state: HostedContentFrame) {
        flying = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mover.layer?.removeAnimation(forKey: "flight")
        clip.removeAnimation(forKey: "flight-path")
        clip.removeAnimation(forKey: "flight-opacity")
        place(state)
        CATransaction.commit()
    }

    /// 只摆模型值，不碰进行中的动画。
    private func place(_ state: HostedContentFrame) {
        frameState = state
        let shown = state.shown || flying
        if isHidden == shown { isHidden = !shown }
        guard let layer else { return }
        mover.layer?.sublayerTransform = CATransform3DMakeAffineTransform(state.transform)
        clip.frame = layer.bounds
        clip.path = clipPath(state, in: layer)
        clip.opacity = Float(state.opacity)
    }

    /// 遮罩的路径按图层自己的坐标：图层没翻转时原点在左下，视图坐标（左上为原点）要上下翻过来。
    private func clipPath(_ state: HostedContentFrame, in layer: CALayer) -> CGPath {
        var rect = state.clip
        if !layer.contentsAreFlipped() { rect.origin.y = layer.bounds.height - rect.maxY }
        return WindowOutline.path(in: rect, radius: state.radius)
    }

    /// 整段交给 Core Animation：变换、遮罩的路径和透明度按 frames 逐帧走，飞行中一直看得见，模型值停在最后一帧。
    func animate(_ frames: [HostedContentFrame], duration: TimeInterval) {
        guard let last = frames.last, let layer, let moverLayer = mover.layer else { return }
        apply(last)
        flying = frames.contains(where: \.shown)
        place(last)
        moverLayer.add(StageKeyframes.make("sublayerTransform", frames.map { NSValue(caTransform3D: CATransform3DMakeAffineTransform($0.transform)) },
                                           duration: duration), forKey: "flight")
        clip.add(StageKeyframes.make("path", frames.map { clipPath($0, in: layer) }, duration: duration), forKey: "flight-path")
        clip.add(StageKeyframes.make("opacity", frames.map { Float($0.opacity) }, duration: duration), forKey: "flight-opacity")
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 窗口背景照常能拖窗口，正文里按下不拖，和正文放在卡片里时一样。
final class HostedContentView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 放在舞台的时钟里，每帧把正文的摆放交给托管视图。
private struct HostedContentDriver: NSViewRepresentable {
    let link: HostedContentLink
    let placement: HostedPlacementValue
    let onHover: (Bool) -> Void
    let frame: HostedContentFrame

    func makeNSView(context: Context) -> NSView { DriverView() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }

    func updateNSView(_ view: NSView, context: Context) {
        link.onHover = onHover
        if link.placement.value != placement { link.placement.value = placement }
        link.container?.origin = placement.origin
        guard link.frame != frame else { return }
        link.apply(frame)
    }

    private final class DriverView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

#else
private struct WindowBackdrop: View {
    let content: AnyView
    let hidden: Bool

    var body: some View { content }
}
#endif

extension Transaction {
    /// WindowSurface 外层去掉动画前的动画，交还给窗口里的内容。
    @Entry var windowContentAnimation: Animation?
    /// 窗口排布的变化（缩小、恢复、展开、排列、拖放）。它带的动画只给外框和停靠栏，不交给窗口内容。
    @Entry var windowLayoutChange = false
}

/// 不可插值的排版位置。动画由 WindowMotion 统一采样，SwiftUI 不再额外补一次位移。
struct WindowTranslation: GeometryEffect {
    let point: CGPoint
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: point.x, y: point.y))
    }
}

private struct WindowContentTransform: GeometryEffect {
    let pose: WindowPose
    let destination: CGPoint
    let contentSize: CGSize
    func effectValue(size: CGSize) -> ProjectionTransform {
        let origin = pose.contentOrigin(size: contentSize)
        return ProjectionTransform(CGAffineTransform(a: pose.scale, b: 0, c: 0, d: pose.scale,
                                                     tx: origin.x - destination.x * pose.scale,
                                                     ty: origin.y - destination.y * pose.scale))
    }
}

nonisolated struct WindowOutline: Shape {
    let frame: CGRect
    let radius: CGFloat
    func path(in _: CGRect) -> Path { RoundedRectangle(cornerRadius: radius).path(in: frame) }

    /// 同样的圆角矩形（圆角按 RoundedRectangle 的 .circular，半径不超过短边的一半），给图层用。
    /// 每次都是四段直线加四段三次曲线，半径为零也一样：Core Animation 按控制点逐个插值路径，前后段数不同就不连贯。
    static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        // 四分之一圆的三次曲线近似
        let k = r * 0.552_284_749_8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                      control1: CGPoint(x: rect.maxX - r + k, y: rect.minY), control2: CGPoint(x: rect.maxX, y: rect.minY + r - k))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.maxY - r + k), control2: CGPoint(x: rect.maxX - r + k, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                      control1: CGPoint(x: rect.minX + r - k, y: rect.maxY), control2: CGPoint(x: rect.minX, y: rect.maxY - r + k))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + r - k), control2: CGPoint(x: rect.minX + r - k, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// 按时间均匀取的关键帧，线性插值（取得够密，曲线由取样给出）。
enum StageKeyframes {
    static func make(_ keyPath: String, _ values: [Any], duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }
}

/// 标题两侧只读同一时钟，不自己加动画；正文尺寸变了也不会产生另一段补位时序。
/// 锚定只平移，不加遮罩：遮罩会让按钮组套上一层按自身大小裁切的容器，按下时放大的交互玻璃被切掉边（2026-10-11 Mac 实测）。
struct WindowHeaderAnchor: ViewModifier {
    let edge: HorizontalEdge
    @Environment(\.windowMotion) private var motion
    @Environment(\.windowContentSize) private var contentSize

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: motion?.moving != true)) { clock in
            let shift = motion?.presentation(at: clock.date).headerShift(contentSize: contentSize) ?? .zero
            content.modifier(WindowTranslation(point: CGPoint(x: edge == .leading ? shift.dx : -shift.dx, y: shift.dy)))
        }
    }
}

/// 标题仍按终点宽度排版，运动中只露出两侧控件之间的部分；读同一时钟，与 WindowHeaderAnchor 同步。
/// 只遮标题，不遮它前面的侧栏按钮，理由同 WindowHeaderAnchor：标题在一组的最右，遮罩按右边截掉的量不变。
/// Mac 上标题在自己这一侧的托管视图里，遮罩在那一层图层上，这里只报标题的左边，见 WindowHeaderAnchored。
struct WindowHeaderTitleMask: ViewModifier {
    @Environment(\.windowMotion) private var motion
    @Environment(\.windowContentSize) private var contentSize
    #if os(macOS)
    @Environment(\.windowHeaderTitleEdge) private var edge
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        if let edge {
            content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("pane-header")).minX } action: { edge.minX = $0 }
        } else {
            masked(content)
        }
        #else
        masked(content)
        #endif
    }

    private func masked(_ content: Content) -> some View {
        TimelineView(.animation(paused: motion?.moving != true)) { clock in
            let pose = motion?.presentation(at: clock.date)
            let visible = pose.map { $0.frame.width / $0.scale } ?? contentSize.width
            content.mask(alignment: .leading) {
                Rectangle().padding(.trailing, max(0, contentSize.width - visible))
            }
        }
    }
}

#if os(macOS)
/// 标题左边在它那一侧里的位置：截得再多也不截到标题前面的按钮，见 WindowHeaderTitleMask。
@MainActor final class WindowHeaderTitleEdge {
    var minX: CGFloat = 0 {
        didSet { if minX != oldValue { changed?() } }
    }
    var changed: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var windowHeaderTitleEdge: WindowHeaderTitleEdge?
}
#endif
