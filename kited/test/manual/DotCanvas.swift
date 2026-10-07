import AppKit
import SwiftUI

private enum DotCanvasError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        if case .failed(let message) = self { return message }
        return "点阵原生验证失败"
    }
}

private struct DotCanvasFixture: View {
    let stage: DotStage

    var body: some View {
        ZStack {
            Color.white
            DotCanvas().environment(\.dotStage, stage)
        }
        .environment(\.colorScheme, .light)
    }
}

private struct PixelCoverage: CustomStringConvertible {
    let counts: [Int]
    let areas: [Int]

    // 分区检查避免把局部残留的点误认成铺满；不绑定点的精确坐标或抗锯齿结果。
    var filled: Bool { zip(counts, areas).allSatisfy { Double($0.0) > Double($0.1) * 0.01 } }
    var description: String { "深色像素=\(counts.reduce(0, +))，16 区=\(counts)" }
}

@MainActor @main
private struct DotCanvasContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let checks: [(String, () throws -> Void)] = [
                ("点阵静息首次出现、尺寸改变与重建后仍显示", restingDotsSurviveMountResizeAndRebuild),
                ("浮动异色格交接连续，外沿回到静息色", floatingColorsStayContinuous),
                ("闪烁层与底层连续交接，小形状保留自身颜色", blinkingOverlayKeepsColorIndependentOfShape),
                ("彩色帧与空白帧连续交换颜色和透明度", blankFramesReturnToRestColor),
            ]
            var failures = [String]()
            for (name, check) in checks {
                do {
                    try check()
                    print("通过：\(name)")
                } catch {
                    failures.append("\(name)：\(error)")
                }
            }
            if !failures.isEmpty { throw DotCanvasError.failed(failures.joined(separator: "\n")) }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    // 真实回归：浮动重采样在异色相邻格权重交接时突然换色，外沿消失时也会跳回静息色。
    // 经真实 DotField 取最终绘制颜色，固定时刻跨完整周期，不约束运动曲线或混色空间。
    private static func floatingColorsStayContinuous() throws {
        let red = DotColor(hex: 0xE54B4B)
        let blue = DotColor(hex: 0x2878D0)
        let figure = DotFigure(["R", "B"], colors: ["R": red, "B": blue],
                               motion: .float(Double(DotMetrics.pitch), period: 4))
        let (field, placed) = field(figure)
        let middle = cycle(field, column: placed.column, row: placed.row + 1, duration: 4)
        try requireContinuous(middle, "相邻异色格")
        try require(middle.contains { colorDistance($0.color, red) < 0.02 }
                    && middle.contains { colorDistance($0.color, blue) < 0.02 },
                    "浮动周期应经过两格原色")
        try require(middle.contains { $0.shape > 0.95 && colorDistance($0.color, red) > 0.15
                    && colorDistance($0.color, blue) > 0.15 }, "两格交接应出现中间色")

        let edge = cycle(field, column: placed.column, row: placed.row - 1, duration: 4)
        try requireContinuous(edge, "浮动外沿")
        try require(edge.contains { $0.shape > 0.8 } && edge.contains { $0.shape == 0 },
                    "外沿应经历出现与回到静息点")
        try requireRestingBoundary(edge, "浮动外沿")
    }

    // 真实回归：闪烁层淡入后立刻抢走底层颜色；按 shape 统一染色又会使静止的小格褪色。
    private static func blinkingOverlayKeepsColorIndependentOfShape() throws {
        let blue = DotColor(hex: 0x2878D0)
        let yellow = DotColor(hex: 0xEFBF35)
        let base = DotFigure(["B"], colors: ["B": blue])
        let overlay = DotFigure(["Y"], colors: ["Y": yellow], motion: .blink(period: 4))
        let (field, placed) = field(base.adding(overlay, column: 0, row: 0))
        let dots = cycle(field, column: placed.column, row: placed.row, duration: 4)
        try requireContinuous(dots, "闪烁层交接")
        try require(dots.allSatisfy { $0.shape > 0.95 }, "闪烁层消失时底层形状应保持完整")
        try require(dots.contains { colorDistance($0.color, blue) < 0.02 }
                    && dots.contains { colorDistance($0.color, yellow) < 0.02 },
                    "闪烁周期应分别显示底层和顶层原色")
        try require(dots.contains { colorDistance($0.color, blue) > 0.15
                    && colorDistance($0.color, yellow) > 0.15 }, "闪烁层交接应出现中间色")

        let small = DotFigure(["Y"], colors: ["Y": yellow], shapes: ["Y": 0.15])
        let (smallField, smallPlaced) = Self.field(small, moving: false)
        let dot = smallField.dot(column: smallPlaced.column, row: smallPlaced.row,
                                 at: Date(timeIntervalSinceReferenceDate: 0))
        try require(abs(dot.shape - 0.15) < 0.001 && colorDistance(dot.color, yellow) < 0.002,
                    "静止小格应保留独立于形状的原色，实际 shape=\(dot.shape)，\(rgba(dot.color))")
    }

    // 真实回归：帧序列彩色格缩至空白前仍保留原色，跨空白边界时颜色和透明度突然跳变。
    private static func blankFramesReturnToRestColor() throws {
        let color = DotColor(hex: 0xEFBF35, alpha: 0.8)
        let figure = DotFigure(frames: [["Y"], [" "]], colors: ["Y": color], hold: 1, transition: 1)
        let (field, placed) = field(figure)
        let dots = cycle(field, column: placed.column, row: placed.row, duration: 4)
        try requireContinuous(dots, "彩色与空白帧")
        try require(dots.contains { $0.shape > 0.99 && colorDistance($0.color, color) < 0.002 },
                    "彩色帧应保留原色和透明度")
        try require(dots.contains { $0.shape == 0 && colorDistance($0.color, restColor) < 0.002 },
                    "空白帧应回到静息点颜色和透明度")
        try require(dots.contains { $0.color.alpha > restColor.alpha + 0.1 && $0.color.alpha < color.alpha - 0.1 },
                    "空白交接应有中间透明度")
        try requireRestingBoundary(dots, "彩色与空白帧")
    }

    private static let restColor = DotColor(hex: 0x1E3350, alpha: 0.12)

    private static func field(_ figure: DotFigure, moving: Bool = true) -> (DotField, PlacedFigure) {
        let placed = PlacedFigure(figure, in: CGRect(x: 120, y: 120, width: 120, height: 120), placement: .leading)
        return (DotField(waves: [], wave: .init(), palette: [DotColor(hex: 0x2878D0)], rest: restColor,
                         slots: [FigureSlot(figure: placed)], breath: 1, moving: moving, sparks: [:]), placed)
    }

    private static func cycle(_ field: DotField, column: Int, row: Int, duration: TimeInterval) -> [Dot] {
        (0...2000).map { step in
            field.dot(column: column, row: row,
                      at: Date(timeIntervalSinceReferenceDate: duration * Double(step) / 2000))
        }
    }

    private static func colorDistance(_ a: DotColor, _ b: DotColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue), abs(a.alpha - b.alpha))
    }

    private static func requireContinuous(_ dots: [Dot], _ label: String) throws {
        let jumps = zip(dots, dots.dropFirst()).map { colorDistance($0.color, $1.color) }
        let largest = jumps.max() ?? 0
        try require(largest < 0.04, "\(label) 相邻 2 毫秒的最大 RGBA 跳变为 \(largest)，应小于 0.04")
    }

    private static func requireRestingBoundary(_ dots: [Dot], _ label: String) throws {
        let resting = dots.filter { $0.shape == 0 }
        try require(!resting.isEmpty && resting.allSatisfy { colorDistance($0.color, restColor) < 0.002 },
                    "\(label) 静息端点应保留静息颜色与透明度")
        // 形状和颜色可以使用不同曲线，只约束实际空白边界两侧的颜色连续性。
        let neighbors = zip(dots, dots.dropFirst()).compactMap { left, right -> Dot? in
            if left.shape == 0 && right.shape > 0 { return right }
            if right.shape == 0 && left.shape > 0 { return left }
            return nil
        }
        try require(!neighbors.isEmpty, "\(label) 应跨过静息点与图案的交接边界")
        let furthest = neighbors.map { colorDistance($0.color, restColor) }.max() ?? 0
        try require(furthest < 0.04, "\(label) 距空白边界 2 毫秒内与静息色的最大 RGBA 差为 \(furthest)，应小于 0.04")
    }

    private static func rgba(_ color: DotColor) -> String {
        "RGBA=(\(color.red), \(color.green), \(color.blue), \(color.alpha))"
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw DotCanvasError.failed(message) }
    }

    // 真实回归：暂停的 TimelineView 在首次出现或同 stage 重建后只剩空白，resize/动画才唤醒。
    // 必须捕获真实 Canvas 像素；bounds 正确和 animating=false 都不能单独证明点阵已经显示。
    private static func restingDotsSurviveMountResizeAndRebuild() throws {
        // 独立 swiftc 程序没有 App 的颜色资源，显式提供静息颜色并在结束时恢复。
        let tuning = DotTuning.shared
        let original = tuning.values
        tuning.values.restLight = DotColor(red: 0, green: 0, blue: 0)
        tuning.values.restDark = DotColor(red: 0, green: 0, blue: 0)
        defer { tuning.values = original }

        let stage = DotStage()
        let host = NSHostingView(rootView: DotCanvasFixture(stage: stage))
        let initial = CGSize(width: 480, height: 360)
        let expanded = CGSize(width: 720, height: 480)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: initial),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        try requireRestingPixels("首次出现", host: host, stage: stage, size: initial)
        window.setContentSize(expanded)
        try requireRestingPixels("尺寸改变", host: host, stage: stage, size: expanded)

        // 先确认正常显示，再重建真实宿主；全程不发波纹或启动动画来救活画布。
        let rebuilt = NSHostingView(rootView: DotCanvasFixture(stage: stage))
        window.contentView = rebuilt
        try requireRestingPixels("同 stage 重建", host: rebuilt, stage: stage, size: expanded)
    }

    private static func requireRestingPixels(_ label: String, host: NSView, stage: DotStage,
                                            size: CGSize) throws {
        let deadline = Date().addingTimeInterval(3)
        var last: PixelCoverage?
        repeat {
            host.layoutSubtreeIfNeeded()
            guard !stage.animating else {
                throw DotCanvasError.failed("\(label) 意外启动了动画")
            }
            if host.bounds.size == size && stage.bounds.size == size {
                let pixels = try coverage(host)
                last = pixels
                if pixels.filled {
                    print("\(label)：\(Int(size.width))×\(Int(size.height))，animating=false，\(pixels)")
                    return
                }
            }
            // 运行实际布局和显示事件，按像素状态结束，不用 sleep 猜首帧时间。
            RunLoop.main.run(mode: .default, before: deadline)
        } while Date() < deadline
        throw DotCanvasError.failed("\(label) 静息点阵未铺满：bounds=\(stage.bounds)，\(String(describing: last))")
    }

    private static func coverage(_ host: NSView) throws -> PixelCoverage {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw DotCanvasError.failed("无法捕获原生宿主的像素")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let inset = Int(12 * CGFloat(bitmap.pixelsWide) / host.bounds.width)
        let width = bitmap.pixelsWide - inset * 2
        let height = bitmap.pixelsHigh - inset * 2
        var counts = [Int](repeating: 0, count: 16)
        var areas = counts
        for y in inset..<(bitmap.pixelsHigh - inset) {
            for x in inset..<(bitmap.pixelsWide - inset) {
                let region = (y - inset) * 4 / height * 4 + (x - inset) * 4 / width
                areas[region] += 1
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent < 0.5 && color.greenComponent < 0.5 && color.blueComponent < 0.5 {
                    counts[region] += 1
                }
            }
        }
        return PixelCoverage(counts: counts, areas: areas)
    }
}
