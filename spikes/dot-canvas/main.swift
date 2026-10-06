import AppKit
import SwiftUI

// 验证单画布方案：卡片底面改由窗口最底层那张画布来画时，布局动画进行中画布能不能跟上 SwiftUI 实际摆出的卡片。
//
// 同一张底层画布用两种来源画卡片位置：
// - A（红框）：卡片用 onGeometryChange 报的窗口坐标，等于现在 DotStage.register 的做法。
// - B（绿底）：直接由模型算出窗口坐标，作为画布视图的 animatableData 传进去，跟着同一个动画事务插值。
// 卡片本身是透明的，只描一圈蓝边，就是 SwiftUI 实际摆出的位置。
// 另在卡片里放一个 NSView 探针，逐帧读它在窗口里的位置，作为第三份参照。
//
// swiftc -parse-as-library -O main.swift -o dot-canvas && ./dot-canvas --auto <日志路径>

let windowSize = CGSize(width: 960, height: 600)
let margin: CGFloat = 12
let seam: CGFloat = 12
let slots = 3

@MainActor @Observable
final class Model {
    var ratio: CGFloat = 0.3
    var sidebar: CGFloat = 120
    var third = false
    var scenario = "静止"
    /// A：卡片报上来的位置。
    var reported: [Int: CGRect] = [:]

    /// 由模型算出各卡片在窗口坐标里的位置；不在排布里的卡片给 nil。
    func frames(third: Bool? = nil) -> [CGRect?] {
        let third = third ?? self.third
        let origin = CGPoint(x: margin + sidebar + seam, y: margin)
        let width = windowSize.width - origin.x - margin, height = windowSize.height - 2 * margin
        let left = ((width - seam) * ratio).rounded()
        let a = CGRect(x: origin.x, y: origin.y, width: left, height: height)
        let rightX = origin.x + left + seam, rightWidth = width - left - seam
        if !third {
            return [a, CGRect(x: rightX, y: origin.y, width: rightWidth, height: height), nil]
        }
        let top = ((height - seam) / 2).rounded()
        return [a, CGRect(x: rightX, y: origin.y, width: rightWidth, height: top),
                CGRect(x: rightX, y: origin.y + top + seam, width: rightWidth, height: height - top - seam)]
    }
}

/// 固定槽位的矩形组，每槽 x、y、宽、高、不透明度五个数，可在动画里插值。
struct Slots: VectorArithmetic {
    var values: [Double]

    static var zero: Slots { Slots(values: Array(repeating: 0, count: slots * 5)) }

    static func + (a: Slots, b: Slots) -> Slots { Slots(values: zip(a.values, b.values).map(+)) }
    static func - (a: Slots, b: Slots) -> Slots { Slots(values: zip(a.values, b.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    /// 不在排布里的槽位按插入过渡的起点给：原位缩到 0.92、完全透明。
    init(_ frames: [CGRect?], hiddenAt fallback: [CGRect]) {
        values = []
        for (index, frame) in frames.enumerated() {
            let rect = frame ?? fallback[index].insetBy(dx: fallback[index].width * 0.04, dy: fallback[index].height * 0.04)
            values += [rect.minX, rect.minY, rect.width, rect.height, frame == nil ? 0 : 1].map(Double.init)
        }
    }

    init(values: [Double]) { self.values = values }

    func rect(_ index: Int) -> (CGRect, Double) {
        let v = Array(values[index * 5 ..< index * 5 + 5])
        return (CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), v[4])
    }
}

/// 探针：卡片里的一个 NSView，逐帧读它在窗口里的位置。
final class ProbeView: NSView {
    static var all: [Int: ProbeView] = [:]
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var windowFrame: CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let rect = convert(bounds, to: content)
        return content.isFlipped ? rect : CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct Probe: NSViewRepresentable {
    let index: Int
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        ProbeView.all[index] = view
        return view
    }
    func updateNSView(_ view: ProbeView, context: Context) { ProbeView.all[index] = view }
}

final class Recorder {
    static var lines: [String] = ["t,scenario,slot,ax,ay,aw,ah,bx,by,bw,bh,bo,px,py,pw,ph"]
    static var start = Date()
    static var late: [String] = ["t,scenario,slot,bx,by,bw,bh,px,py,pw,ph"]
}

/// 底层画布：B 作为 animatableData，A 从模型读。
struct Surface: View, Animatable {
    var slotsData: Slots
    let model: Model
    let record: Bool

    var animatableData: Slots {
        get { slotsData }
        set { slotsData = newValue }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                // 点阵，验证坐标同位用
                var dots = Path()
                for column in 0 ..< Int(windowSize.width / 12) {
                    for row in 0 ..< Int(windowSize.height / 12) {
                        dots.addEllipse(in: CGRect(x: CGFloat(column) * 12 + 5, y: CGFloat(row) * 12 + 5, width: 2, height: 2))
                    }
                }
                context.fill(dots, with: .color(.gray.opacity(0.35)))
                let t = timeline.date.timeIntervalSince(Recorder.start)
                for index in 0 ..< slots {
                    let (b, opacity) = slotsData.rect(index)
                    context.fill(Path(roundedRect: b, cornerRadius: 12), with: .color(.green.opacity(0.35 * opacity)))
                    let a = model.reported[index]
                    if let a {
                        context.stroke(Path(roundedRect: a.insetBy(dx: 3, dy: 3), cornerRadius: 10), with: .color(.red), lineWidth: 2)
                    }
                    guard record else { continue }
                    let p = ProbeView.all[index]?.windowFrame
                    let fields = [a, b, p].flatMap { rect -> [String] in
                        guard let rect else { return ["", "", "", ""] }
                        return [rect.minX, rect.minY, rect.width, rect.height].map { String(format: "%.2f", $0) }
                    }
                    let row = [String(format: "%.4f", t), model.scenario, "\(index)"] + fields[0 ..< 4]
                        + fields[4 ..< 8] + [String(format: "%.3f", opacity)] + fields[8 ..< 12]
                    Recorder.lines.append(row.joined(separator: ","))
                    // 同一帧提交之后再读一次探针，区分「探针读早了」与「画布领先」
                    let label = model.scenario, bText = fields[4 ..< 8].joined(separator: ",")
                    DispatchQueue.main.async {
                        let late = ProbeView.all[index]?.windowFrame
                        let lateText = late.map { [$0.minX, $0.minY, $0.width, $0.height].map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? ",,,"
                        Recorder.late.append([String(format: "%.4f", t), label, "\(index)", bText, lateText].joined(separator: ","))
                    }
                }
            }
        }
    }
}

struct Card: View {
    let index: Int
    let model: Model

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.blue, lineWidth: 2)
            .background(Probe(index: index))
            .overlay(alignment: .topLeading) {
                Text("卡片 \(index)").font(.caption).padding(8)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.reported[index] = $0 }
            .onDisappear { model.reported[index] = nil }
    }
}

struct Root: View {
    let model: Model
    let auto: String?

    var body: some View {
        let frames = model.frames()
        let full = model.frames(third: true).map { $0! }
        ZStack(alignment: .topLeading) {
            Surface(slotsData: Slots(frames, hiddenAt: full), model: model, record: auto != nil)
            // 与 Kite 相同的摆法：侧栏在左，内容区里卡片按排布用 frame + position 摆放
            HStack(spacing: 0) {
                Color.clear.frame(width: model.sidebar)
                Color.clear.frame(width: seam)
                GeometryReader { geo in
                    let origin = geo.frame(in: .global).origin
                    ZStack(alignment: .topLeading) {
                        ForEach(0 ..< slots, id: \.self) { index in
                            if let rect = frames[index] {
                                Card(index: index, model: model)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX - origin.x, y: rect.midY - origin.y)
                                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                            }
                        }
                    }
                }
            }
            .padding(margin)
            if auto == nil { controls }
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .ignoresSafeArea()
        .task { if let auto { await run(log: auto) } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("分栏（线性 2 秒）") { model.scenario = "分栏线性"; withAnimation(.linear(duration: 2)) { model.ratio = model.ratio < 0.5 ? 0.7 : 0.3 } }
            Button("分栏（snappy）") { model.scenario = "分栏snappy"; withAnimation(.snappy) { model.ratio = model.ratio < 0.5 ? 0.7 : 0.3 } }
            Button("开关第三张（线性 2 秒）") { model.scenario = "开关线性"; withAnimation(.linear(duration: 2)) { model.third.toggle() } }
            Button("侧栏（线性 2 秒）") { model.scenario = "侧栏线性"; withAnimation(.linear(duration: 2)) { model.sidebar = model.sidebar < 200 ? 300 : 120 } }
        }
        .buttonStyle(.bordered)
        .padding(.leading, margin + 8)
        .padding(.top, 40)
        .frame(width: model.sidebar + margin, alignment: .leading)
    }

    private func step(_ name: String, _ animation: Animation, wait: Double, _ change: @escaping () -> Void) async {
        model.scenario = name
        withAnimation(animation, change)
        try? await Task.sleep(for: .seconds(wait))
        model.scenario = "静止"
        try? await Task.sleep(for: .seconds(0.4))
    }

    private func run(log: String) async {
        try? await Task.sleep(for: .seconds(1))
        Recorder.start = .now
        Recorder.lines.append("# window \(NSApp.windows.first?.windowNumber ?? 0)")
        try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "\(NSApp.windows.first?.windowNumber ?? 0)".write(toFile: log + ".window", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(0.5))
        await step("分栏线性", .linear(duration: 2), wait: 2.2) { model.ratio = 0.7 }
        await step("开关线性", .linear(duration: 2), wait: 2.2) { model.third = true }
        await step("侧栏线性", .linear(duration: 2), wait: 2.2) { model.sidebar = 300 }
        await step("分栏snappy", .snappy, wait: 1.0) { model.ratio = 0.3 }
        await step("关闭snappy", .snappy, wait: 1.0) { model.third = false }
        try? Recorder.lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        try? Recorder.late.joined(separator: "\n").write(toFile: log + ".late", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

@main
struct DotCanvasSpike: App {
    @State private var model = Model()
    private let auto: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--auto"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }()

    var body: some Scene {
        Window("单画布实验", id: "spike") {
            Root(model: model, auto: auto)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
