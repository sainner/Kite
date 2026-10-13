import SwiftUI
import UIKit

/// V2：SwiftUI 只在渲染时做的几何效果（照紧凑布局的 WindowShell、iPad 卡片的 WindowMotion 舞台、横滑那一行的写法）套在
/// UIViewRepresentable 上时，UIKit 视图的 frame、bounds、transform 每帧怎么变，layoutSubviews、updateUIView 被调几次。
/// 开合、飞行都由程序改状态驱动（同 DrawerMotion.settle、WindowMotion 的取样），不合成触摸。
struct GeometrySpike: View {
    @State private var scenario = 0
    /// 抽屉：0 铺满，1 拉开（窗口缩小让开）。
    @State private var openness: CGFloat = 0
    /// 卡片：飞行开始的时刻，nil 停着。
    @State private var flight: Date?
    /// 横滑：窗口这一行平移了多少。
    @State private var swipe: CGFloat = 0
    private let box = ProbeBox.shared

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Group {
                switch scenario {
                case 1: drawer(size: size)
                case 2: card(size: size)
                case 3: swiped(size: size)
                default: Color.clear
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .task { await run() }
    }

    private func content(size: CGSize) -> some View {
        Probe(box: box)
            .frame(width: size.width, height: size.height)
    }

    /// 紧凑布局开合：内容定尺寸，开合的缩放、平移只在渲染时做（Animatable 的 GeometryEffect，ignoredByLayout），
    /// 外壳的排版框逐帧按进度排（ShellFrame），按圆角裁。
    private func drawer(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            content(size: size)
                .modifier(DrawerTransform(openness: openness, size: size).ignoredByLayout())
        }
        .modifier(DrawerShell(openness: openness, size: size))
    }

    /// iPad 卡片飞行：TimelineView 逐帧取样外框，内容按终点尺寸排一次，飞行中整块缩放（ignoredByLayout），外框逐帧排、按圆角裁，内容按透明度遮罩。
    private func card(size: CGSize) -> some View {
        let content = CGSize(width: size.width * 0.6, height: size.height * 0.7)
        return TimelineView(.animation(paused: flight == nil)) { clock in
            let progress = flight.map { min(max(clock.date.timeIntervalSince($0) / 0.5, 0), 1) } ?? 0
            let eased = 1 - pow(1 - progress, 3)
            let scale = 1 - 0.6 * eased
            let frame = CGRect(x: 40 + 200 * eased, y: 80 + 150 * eased, width: content.width * scale, height: content.height * scale)
            ZStack(alignment: .topLeading) {
                self.content(size: content)
                    .frame(width: content.width, height: content.height)
                    .modifier(CardScale(scale: scale).ignoredByLayout())
                    .mask { Rectangle().opacity(1 - 0.5 * eased) }
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12 + 20 * eased))
            .offset(x: frame.minX, y: frame.minY)
        }
    }

    /// 紧凑布局控制区横滑：整行窗口在渲染时平移（ignoredByLayout），窗口都建着。
    private func swiped(size: CGSize) -> some View {
        content(size: size)
            .modifier(Translation(x: swipe).ignoredByLayout())
    }

    private func run() async {
        let report = Report.shared
        report.line("V2 \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)")
        for (index, name) in [(1, "抽屉开合（Animatable GeometryEffect + 逐帧排的外壳框 + 圆角裁）"),
                              (2, "卡片飞行（TimelineView 取样，外框逐帧排 + 内容缩放 + 透明度遮罩 + 圆角裁）"),
                              (3, "横滑（平移 GeometryEffect）")] {
            scenario = index
            await spin(0.6)
            box.reset()
            box.sampling = true
            switch index {
            case 1: withAnimation(.smooth(duration: 0.5)) { openness = 1 }
            case 2: flight = .now
            default: withAnimation(.smooth(duration: 0.5)) { swipe = -300 }
            }
            await spin(0.8)
            box.sampling = false
            report.line("\(name)：")
            report.line(box.summary())
            box.reset()
            box.sampling = true
            switch index {
            case 1: withAnimation(.smooth(duration: 0.5)) { openness = 0 }
            case 2: flight = nil
            default: withAnimation(.smooth(duration: 0.5)) { swipe = 0 }
            }
            await spin(0.8)
            box.sampling = false
            report.line("  收回：" + box.summary())
        }
        report.finish("v2")
    }
}

private struct DrawerTransform: GeometryEffect {
    var openness: CGFloat
    let size: CGSize

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let scale = 1 - 0.15 * openness
        return ProjectionTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: 280 * openness, ty: self.size.height * 0.075 * openness))
    }
}

private struct DrawerShell: ViewModifier, Animatable {
    var openness: CGFloat
    let size: CGSize

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: size.width + 280 * openness, height: size.height, alignment: .topLeading)
            .background { Color.gray.opacity(0.2) }
            .clipShape(RoundedRectangle(cornerRadius: 40 * openness))
    }
}

private struct CardScale: GeometryEffect {
    let scale: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct Translation: GeometryEffect {
    var x: CGFloat
    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// 探针视图记下的：每次 layoutSubviews 时的 bounds，逐帧的 frame、transform、在窗口里的位置，updateUIView 的次数。
@MainActor final class ProbeBox {
    static let shared = ProbeBox()
    weak var view: ProbeView?
    var sampling = false {
        didSet {
            if sampling { start() } else { link?.invalidate(); link = nil }
        }
    }
    private(set) var layouts = 0
    private(set) var updates = 0
    private(set) var frames = 0
    private var sizes: Set<String> = []
    private var viewFrames: Set<String> = []
    private var transforms: Set<String> = []
    private var windowRects: Set<String> = []
    private var presentationRects: Set<String> = []
    private var link: CADisplayLink?

    func reset() {
        layouts = 0
        updates = 0
        frames = 0
        sizes = []
        viewFrames = []
        transforms = []
        windowRects = []
        presentationRects = []
    }

    func laidOut(_ size: CGSize) {
        guard sampling else { return }
        layouts += 1
        sizes.insert("\(Int(size.width))×\(Int(size.height))")
    }

    func updated() {
        if sampling { updates += 1 }
    }

    private func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard let view, let window = view.window else { return }
        frames += 1
        viewFrames.insert(Self.text(view.frame))
        transforms.insert("\(view.transform) layer \(CATransform3DIsIdentity(view.layer.transform) ? "单位" : "非单位")")
        windowRects.insert(Self.text(view.convert(view.bounds, to: window)))
        if let presentation = view.layer.presentation(), let windowLayer = window.layer.presentation() {
            presentationRects.insert(Self.text(presentation.convert(presentation.bounds, to: windowLayer)))
        }
    }

    private static func text(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }

    func summary() -> String {
        "  \(frames) 帧里：layoutSubviews \(layouts) 次（尺寸 \(sizes.sorted().joined(separator: "、"))），updateUIView \(updates) 次；"
            + "视图 frame \(viewFrames.count) 种 \(viewFrames.sorted().prefix(3).joined(separator: " "))；transform \(transforms.count) 种 \(transforms.sorted().first ?? "")；"
            + "按 UIView 换算到窗口 \(windowRects.count) 种；按呈现层换算到窗口 \(presentationRects.count) 种 \(presentationRects.sorted().prefix(2).joined(separator: " "))"
    }
}

/// 代表以后的 PhoneTranscriptView：一个铺满的 UIScrollView，排版时按 bounds 摆。
final class ProbeView: UIView {
    let scroll = UIScrollView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(scroll)
        scroll.contentSize = CGSize(width: 10, height: 4000)
        backgroundColor = .systemTeal.withAlphaComponent(0.3)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ProbeBox.shared.laidOut(bounds.size)
        scroll.frame = bounds
    }
}

struct Probe: UIViewRepresentable {
    let box: ProbeBox

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        box.view = view
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        box.view = view
        box.updated()
    }

    /// 尺寸由外面给，不走 Auto Layout 量（设计稿 §4.1）。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ProbeView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
