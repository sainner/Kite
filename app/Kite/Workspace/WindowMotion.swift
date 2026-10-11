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
}

nonisolated enum WindowMotionKind {
    case immediate, settle, preview, tracking

    var duration: TimeInterval {
        switch self {
        case .immediate: 0
        case .settle: 0.3
        case .preview, .tracking: 0.2
        }
    }
}

/// 只在目标改变时更新。TimelineView 负责取帧，窗口内容不订阅逐帧状态。
/// 中途反向从当时的呈现状态继续；拖动中的指针移动平移整条轨迹，不反复重启缩小动画。
@MainActor @Observable
final class WindowMotion {
    private(set) var target: WindowPose
    private(set) var moving = false
    var interacting = false
    @ObservationIgnored private var source: WindowPose
    @ObservationIgnored private var started = Date.distantPast
    @ObservationIgnored private var duration: TimeInterval = 0
    @ObservationIgnored private var kind = WindowMotionKind.immediate
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(_ pose: WindowPose) { target = pose; source = pose }

    func presentation(at date: Date) -> WindowPose {
        guard duration > 0 else { return target }
        let fraction = min(max(date.timeIntervalSince(started) / duration, 0), 1)
        let progress = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0),
                                       endControlPoint: UnitPoint(x: 0, y: 1)).value(at: fraction)
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
        started = date
        duration = kind.duration
        self.kind = kind
        completion?.cancel()
        generation += 1
        let current = generation
        moving = duration > 0
        guard moving else { source = next; return }
        completion = Task { [weak self, duration] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, generation == current else { return }
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
    let contentSize: CGSize
    let viewport: CGSize
    let iconSize: CGFloat
    let color: Color
    let minimizedColor: Color?
    let content: Content
    let icon: Icon
    let background: AnyView
    let headerHeight: CGFloat?
    let onHover: (Bool) -> Void
    let header: Header

    init(motion: WindowMotion, contentSize: CGSize, viewport: CGSize, iconSize: CGFloat, color: Color, minimizedColor: Color? = nil, background: AnyView = AnyView(EmptyView()),
         headerHeight: CGFloat? = nil, onHover: @escaping (Bool) -> Void = { _ in },
         @ViewBuilder content: () -> Content, @ViewBuilder icon: () -> Icon, @ViewBuilder header: () -> Header = { EmptyView() }) {
        self.motion = motion
        self.contentSize = contentSize
        self.viewport = viewport
        self.iconSize = iconSize
        self.color = color
        self.minimizedColor = minimizedColor
        self.background = background
        self.headerHeight = headerHeight
        self.onHover = onHover
        self.content = content()
        self.icon = icon()
        self.header = header()
    }

    var body: some View {
        let destination = motion.target.contentOrigin(size: contentSize)
        TimelineView(.animation(paused: !motion.moving)) { clock in
            let pose = motion.presentation(at: clock.date)
            let outline = WindowOutline(frame: pose.frame, radius: pose.radius)
            ZStack(alignment: .topLeading) {
                outline.fill(color).opacity(min(pose.contentOpacity + pose.iconOpacity, 1))
                if let minimizedColor { outline.fill(minimizedColor).opacity(pose.iconOpacity) }
                background
                    .opacity(pose.contentOpacity)
                    .allowsHitTesting(false)
                content
                    // 外层去掉了事务里的动画（外框按每帧取样）；内容自己的动画照常，如发送时对话滑动、气泡浮起，
                    // 只是窗口改尺寸那一次不带，内容一次排到位
                    .transaction(value: contentSize) { $0.animation = nil }
                    .transaction { $0.animation = $0.windowContentAnimation }
                    .frame(width: contentSize.width, height: contentSize.height)
                    .modifier(WindowTranslation(point: destination))
                    .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                    .modifier(WindowContentTransform(pose: pose, destination: destination, contentSize: contentSize).ignoredByLayout())
                    // 蒙版保留 Mac 标题栏滚动软边的登记，不能对整段正文使用 opacity。
                    .mask { Rectangle().opacity(pose.contentOpacity) }
                icon
                    .frame(width: iconSize, height: iconSize)
                    .position(x: pose.frame.midX, y: pose.frame.midY)
                    .opacity(pose.iconOpacity)
                    .allowsHitTesting(false)
                header
                    .frame(width: pose.frame.width, height: headerHeight ?? pose.frame.height)
                    .position(x: pose.frame.midX, y: pose.frame.minY + (headerHeight ?? pose.frame.height) / 2)
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            // onHover 按排版框登记区域；裁切全舞台的轮廓不能隔开相邻窗口的悬停。
            .modifier(WindowTranslation(point: CGPoint(x: -pose.frame.minX, y: -pose.frame.minY)))
            .frame(width: pose.frame.width, height: pose.frame.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: pose.radius))
            .contentShape(RoundedRectangle(cornerRadius: pose.radius))
            .onHover(perform: onHover)
            .position(x: pose.frame.midX, y: pose.frame.midY)
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .transaction { $0.windowContentAnimation = $0.animation; $0.animation = nil }
        }
        .environment(\.windowMotion, motion)
        .environment(\.windowContentSize, contentSize)
    }
}

extension Transaction {
    /// WindowSurface 外层去掉动画前的动画，交还给窗口里的内容。
    @Entry var windowContentAnimation: Animation?
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
}

/// 标题两侧只读同一时钟，不自己加动画；正文尺寸变了也不会产生另一段补位时序。
struct WindowHeaderAnchor: ViewModifier {
    let edge: HorizontalEdge
    var clipsTitle = false
    @Environment(\.windowMotion) private var motion
    @Environment(\.windowContentSize) private var contentSize

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: motion?.moving != true)) { clock in
            let pose = motion?.presentation(at: clock.date)
            let visible = pose.map { CGSize(width: $0.frame.width / $0.scale, height: $0.frame.height / $0.scale) } ?? contentSize
            let x = (contentSize.width - visible.width) / 2 * (edge == .leading ? 1 : -1)
            let y = contentSize.height - visible.height
            content
                // 标题仍按终点宽度排版，但运动中只露出两侧控件之间的部分。
                .mask(alignment: .leading) {
                    Rectangle().padding(.trailing, clipsTitle ? max(0, contentSize.width - visible.width) : 0)
                }
                .modifier(WindowTranslation(point: CGPoint(x: x, y: y)))
        }
    }
}

extension Animation {
    static let windowSettle = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.3)
    static let windowPreview = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.2)
}
