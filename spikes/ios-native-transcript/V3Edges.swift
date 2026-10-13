import SwiftUI
import UIKit

/// V3：UIKit 的滚动视图放进现有 SwiftUI 窗口（标题栏、控制区都是 safeAreaBar）时：
/// 1. 标题栏底下的滚动软边：对照现在的 SwiftUI ScrollView，看 UIScrollView 设 topEdgeEffect.style = .soft、
///    再用 UIScrollEdgeElementContainerInteraction 登记顶上那一截，出来的软边一不一样（截屏由 build.sh 用 simctl 拍）。
/// 2. 底下让出的高带着动画变（控制区长高，和键盘升起一样是 SwiftUI 带动画的事务把新安全区交下来）时，
///    表示视图用 context.animate 改 contentInset 和滚动位置，贴底的内容和控制区是不是同一条曲线：逐帧记最后一行底边和控制区顶边的距离。
///    再由程序聚焦输入框试一次真键盘（模拟器接着硬件键盘时软键盘不出来，照实记下）。
struct EdgeSpike: View {
    /// 0：SwiftUI ScrollView；1：UIKit，只设软边样式；2：UIKit，再登记顶上那一截。
    @State private var variant = 0
    /// 控制区长高 300 pt（代替键盘）。
    @State private var lifted = false
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var position = ScrollPosition(y: 0)

    static let rows = 60
    static let rowHeight: CGFloat = 28

    var body: some View {
        Group {
            if variant == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<Self.rows, id: \.self) { index in
                            Text(Self.line(index)).frame(height: Self.rowHeight, alignment: .leading)
                                .overlay(alignment: .bottom) { if index == Self.rows - 1 { RowMarker().frame(height: 1) } }
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
            } else {
                GeometryReader { proxy in
                    UIKitList(insets: proxy.safeAreaInsets, registers: variant == 2)
                        .ignoresSafeArea()
                }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack {
                Image(systemName: "sidebar.left").font(.title2)
                Text("标题栏").font(.headline)
                Spacer()
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                BarMarker()
                    .frame(height: 1)
                TextField("输入", text: $draft)
                    .focused($focused)
                    .padding(12)
                    .background(Color.gray.opacity(0.15), in: Capsule())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                if lifted { Color.clear.frame(height: 300) }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .task { await run() }
    }

    static func line(_ index: Int) -> String {
        "第 \(index) 行：原生列表的软边要和 SwiftUI 的一样 Edge effect"
    }

    private func shoot(_ name: String) async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        try? "".write(to: directory.appendingPathComponent("shoot-\(name)"), atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("shot-\(name)").path) { return }
            await spin(0.1)
        }
        Report.shared.line("截屏 \(name) 没等到")
    }

    private func run() async {
        let report = Report.shared
        report.line("V3 \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)")
        // 软边：三种写法各拍一张，内容滚到标题栏底下
        for (index, name) in [(0, "swiftui"), (1, "uikit-style"), (2, "uikit-registered")] {
            variant = index
            await spin(0.5)
            position.scrollTo(y: 300)
            UIKitListBox.shared.view?.scroll(toContentY: 300)
            await spin(1.0)
            await shoot(name)
            report.line("截屏 v3-\(name).png：\(index == 0 ? "SwiftUI ScrollView" : index == 1 ? "UIScrollView，topEdgeEffect.style = .soft" : "再加 UIScrollEdgeElementContainerInteraction 登记顶上那截")")
        }
        // 对照：SwiftUI ScrollView 贴底（defaultScrollAnchor(.bottom, for: .sizeChanges)），同样让控制区长高
        variant = 0
        await spin(0.5)
        position.scrollTo(edge: .bottom)
        await spin(0.8)
        let baseline = GapSampler(swiftUI: true)
        baseline.start()
        withAnimation(.smooth(duration: 0.4)) { lifted = true }
        await spin(0.8)
        report.line("对照 SwiftUI ScrollView 贴底、控制区带动画长高 300 pt：" + baseline.stop())
        withAnimation(.smooth(duration: 0.4)) { lifted = false }
        await spin(0.8)
        // 贴底、控制区带动画长高 300 pt：逐帧记最后一行底边离控制区顶边多远
        variant = 2
        await spin(0.5)
        UIKitListBox.shared.view?.scrollToBottom()
        await spin(0.5)
        let sampler = GapSampler()
        _ = UIKitListBox.shared.takeUpdates()
        sampler.start()
        withAnimation(.smooth(duration: 0.4)) { lifted = true }
        await spin(0.8)
        report.line("控制区带动画长高 300 pt（smooth 0.4 秒），context.animate 改 contentInset 和滚动位置：\(UIKitListBox.shared.takeUpdates())，" + sampler.stop())
        sampler.start()
        withAnimation(.smooth(duration: 0.4)) { lifted = false }
        await spin(0.8)
        report.line("  收回：\(UIKitListBox.shared.takeUpdates())，" + sampler.stop())
        // 真键盘：第一次弹出模拟器要加载键盘、卡一阵，先弹一次热身，再量第二次
        focused = true
        await spin(2.0)
        focused = false
        await spin(1.2)
        UIKitListBox.shared.view?.scrollToBottom()
        await spin(0.3)
        _ = UIKitListBox.shared.takeUpdates()
        sampler.start()
        focused = true
        await spin(1.2)
        report.line("程序聚焦输入框（第二次）：\(UIKitListBox.shared.takeUpdates())，底下让出 \(Int(UIKitListBox.shared.view?.scroll.contentInset.bottom ?? -1)) pt，" + sampler.stop())
        await shoot("keyboard")
        sampler.start()
        focused = false
        await spin(1.0)
        report.line("  收起键盘：\(UIKitListBox.shared.takeUpdates())，" + sampler.stop())
        report.finish("v3")
    }
}

/// 逐帧记最后一行底边（呈现层）和控制区顶边（呈现层）之间的距离：贴底时两者同一条曲线，距离不变。
@MainActor final class GapSampler: NSObject {
    private var link: CADisplayLink?
    private var gaps: [CGFloat] = []
    private var bars: [CGFloat] = []
    private let swiftUI: Bool

    init(swiftUI: Bool = false) {
        self.swiftUI = swiftUI
    }

    func start() {
        gaps = []
        bars = []
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let row: UIView? = swiftUI ? UIKitListBox.shared.rowMarker : UIKitListBox.shared.view?.lastRow
        guard let row, let marker = UIKitListBox.shared.marker, let window = row.window,
              let windowLayer = window.layer.presentation(),
              let last = row.layer.presentation(), let bar = marker.layer.presentation() else { return }
        let bottom = last.convert(last.bounds, to: windowLayer).maxY
        let top = bar.convert(bar.bounds, to: windowLayer).minY
        gaps.append(top - bottom)
        bars.append(top)
    }

    func stop() -> String {
        link?.invalidate()
        link = nil
        guard let first = gaps.first, let low = gaps.min(), let high = gaps.max() else { return "没取到帧" }
        let moving = gaps.count
        // 逐帧：控制区顶边挪了多少 / 距离，只列在动的那几帧
        let start = bars.first ?? 0
        let series = zip(bars, gaps).filter { abs($0.0 - start) > 0.5 || abs($0.1 - first) > 0.5 }
            .prefix(40).map { String(format: "%.0f/%.1f", $0.0 - start, $0.1) }.joined(separator: " ")
        return "\(moving) 帧，距离起 \(String(format: "%.1f", first))、最小 \(String(format: "%.1f", low))、最大 \(String(format: "%.1f", high))、终 \(String(format: "%.1f", gaps.last ?? 0)) pt；逐帧（控制区挪动/距离）\(series)"
    }
}

@MainActor final class UIKitListBox {
    static let shared = UIKitListBox()
    weak var view: UIKitListView?
    weak var marker: UIView?
    weak var rowMarker: UIView?
    /// updateUIView 每次调时事务里带不带动画。
    var updates: [String] = []

    func takeUpdates() -> String {
        defer { updates = [] }
        return "updateUIView \(updates.count) 次（\(Dictionary(grouping: updates, by: { $0 }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: "、"))）"
    }
}

/// SwiftUI 对照里最后一行底边的记号。
struct RowMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        UIKitListBox.shared.rowMarker = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// 控制区顶边的记号。
struct BarMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        UIKitListBox.shared.marker = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// 以后 PhoneTranscriptView 的样子：铺满窗口，标题栏、控制区让出的高作为 insets 传进来；顶上一截透明的口袋登记成滚动软边的元素。
final class UIKitListView: UIView {
    let scroll = UIScrollView()
    let pocket = UIView()
    private(set) var lastRow = UILabel()
    private var registered = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = true
        scroll.topEdgeEffect.style = .soft
        scroll.bottomEdgeEffect.isHidden = true
        addSubview(scroll)
        pocket.isUserInteractionEnabled = false
        addSubview(pocket)
        let font = UIFont.preferredFont(forTextStyle: .body)
        for index in 0..<EdgeSpike.rows {
            let label = UILabel()
            label.font = font
            label.text = EdgeSpike.line(index)
            label.frame = CGRect(x: 20, y: CGFloat(index) * EdgeSpike.rowHeight, width: 600, height: EdgeSpike.rowHeight)
            scroll.addSubview(label)
            lastRow = label
        }
        scroll.contentSize = CGSize(width: 10, height: CGFloat(EdgeSpike.rows) * EdgeSpike.rowHeight)
    }

    required init?(coder: NSCoder) { fatalError() }

    func register(_ registers: Bool) {
        guard registers != registered else { return }
        registered = registers
        if registers {
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.scrollView = scroll
            interaction.edge = .top
            pocket.addInteraction(interaction)
        } else {
            pocket.interactions.removeAll()
        }
    }

    var following = true

    /// 让出的高变了：贴底的跟着底边走。
    func apply(_ insets: EdgeInsets) {
        let new = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
        guard scroll.contentInset != new else { return }
        scroll.contentInset = new
        scroll.verticalScrollIndicatorInsets = new
        pocket.frame = CGRect(x: 0, y: 0, width: bounds.width, height: insets.top)
        if following { scrollToBottom() }
    }

    func scrollToBottom() {
        following = true
        scroll.contentOffset.y = max(scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height, -scroll.contentInset.top)
    }

    func scroll(toContentY y: CGFloat) {
        following = false
        scroll.contentOffset.y = y - scroll.contentInset.top
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        pocket.frame = CGRect(x: 0, y: 0, width: bounds.width, height: scroll.contentInset.top)
    }
}

struct UIKitList: UIViewRepresentable {
    let insets: EdgeInsets
    let registers: Bool

    func makeUIView(context: Context) -> UIKitListView {
        let view = UIKitListView()
        UIKitListBox.shared.view = view
        return view
    }

    func updateUIView(_ view: UIKitListView, context: Context) {
        UIKitListBox.shared.view = view
        UIKitListBox.shared.updates.append(context.transaction.animation == nil ? "无动画" : "带动画")
        view.register(registers)
        // 安全区跟着带动画的事务（键盘、控制区长高）一起交下来：在同一条曲线里改 contentInset 和滚动位置
        if context.transaction.animation != nil {
            context.animate {
                view.apply(insets)
                view.layoutIfNeeded()
            }
        } else {
            view.apply(insets)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIKitListView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
