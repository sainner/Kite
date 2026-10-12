import AppKit
import SwiftUI

private enum MotionFailure: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "窗口动画原生验证失败"
    }
}

@MainActor
private final class MotionRecorder {
    var buttons = [String: NSButton]()
    var clicks = [String]()
    var onFrame: (() -> Void)?
}

private struct FrameProbe: NSViewRepresentable {
    let date: Date
    let recorder: MotionRecorder

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.onFrame?()
    }
}

private final class ColorButton: NSButton {
    var marker = NSColor.red

    override func draw(_ dirtyRect: NSRect) {
        marker.setFill()
        bounds.fill()
    }
}

private struct HeaderButton: NSViewRepresentable {
    let id: String
    let recorder: MotionRecorder

    final class Coordinator: NSObject {
        let id: String
        let recorder: MotionRecorder

        init(id: String, recorder: MotionRecorder) {
            self.id = id
            self.recorder = recorder
        }

        @objc func click() { recorder.clicks.append(id) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(id: id, recorder: recorder) }

    func makeNSView(context: Context) -> NSButton {
        let button = ColorButton(title: id, target: context.coordinator, action: #selector(Coordinator.click))
        button.isBordered = false
        button.marker = id == "leading" || id == "first" ? .red : .cyan
        recorder.buttons[id] = button
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {}
}

private struct MotionFixture: View {
    let motion: WindowMotion
    let contentSize: CGSize
    let recorder: MotionRecorder
    static let viewport = CGSize(width: 1000, height: 800)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            WindowSurface(motion: motion, target: motion.target, contentSize: contentSize, viewport: Self.viewport,
                          iconSize: 40, color: Color(red: 0, green: 1, blue: 0)) {
                ZStack {
                    HeaderButton(id: "leading", recorder: recorder)
                        .frame(width: 84, height: 28)
                        .modifier(WindowHeaderAnchor(edge: .leading))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    HeaderButton(id: "trailing", recorder: recorder)
                        .frame(width: 84, height: 28)
                        .modifier(WindowHeaderAnchor(edge: .trailing))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .padding(20)
                .frame(width: contentSize.width, height: contentSize.height)
            } icon: {
                Rectangle().fill(Color(red: 1, green: 0, blue: 1))
            }
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
                FrameProbe(date: context.date, recorder: recorder)
                    .frame(width: 1, height: 1)
            }
            .allowsHitTesting(false)
        }
        .frame(width: Self.viewport.width, height: Self.viewport.height)
    }
}

private struct StackedMotionFixture: View {
    let first: WindowMotion
    let second: WindowMotion
    let recorder: MotionRecorder

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            surface(first, id: "first")
            surface(second, id: "second")
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
                FrameProbe(date: context.date, recorder: recorder).frame(width: 1, height: 1)
            }
            .allowsHitTesting(false)
        }
        .frame(width: MotionFixture.viewport.width, height: MotionFixture.viewport.height)
    }

    private func surface(_ motion: WindowMotion, id: String) -> some View {
        WindowSurface(motion: motion, target: motion.target, contentSize: CGSize(width: 600, height: 300),
                      viewport: MotionFixture.viewport, iconSize: 40, color: Color(red: 0, green: 1, blue: 0),
                      headerHeight: 64) {
            Color.clear
        } icon: {
            EmptyView()
        } header: {
            HeaderButton(id: id, recorder: recorder)
                .frame(width: 84, height: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 20)
                .padding(.top, 18)
        }
    }
}

private struct PixelBounds: CustomStringConvertible {
    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min
    var count = 0

    mutating func include(x: Int, y: Int) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
        count += 1
    }

    var rect: CGRect? {
        count == 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    var description: String { "\(String(describing: rect))，\(count) 像素" }
}

private struct MotionPixels: CustomStringConvertible {
    var card = PixelBounds()
    var icon = PixelBounds()
    var leading = PixelBounds()
    var trailing = PixelBounds()

    var description: String { "卡框 \(card)；头像 \(icon)；左标题 \(leading)；右标题 \(trailing)" }
}

@MainActor
private final class MotionDeadline: NSObject {
    var onTimeout: (() -> Void)?
    @objc func finish(_ timer: Timer) { onTimeout?() }
}

@MainActor
private final class MotionHost {
    let motion: WindowMotion
    let recorder = MotionRecorder()
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(pose: WindowPose, contentSize: CGSize, neighbor: WindowMotion? = nil) {
        motion = WindowMotion(pose)
        let root: AnyView
        if let neighbor {
            root = AnyView(StackedMotionFixture(first: motion, second: neighbor, recorder: recorder))
        } else {
            root = AnyView(MotionFixture(motion: motion, contentSize: contentSize, recorder: recorder))
        }
        host = NSHostingView(rootView: root)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: MotionFixture.viewport),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderFront(nil)
    }

    func nextFrame() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let expiration = MotionDeadline()
            let timeout = Timer(timeInterval: 3, target: expiration, selector: #selector(MotionDeadline.finish),
                                userInfo: nil, repeats: false)
            var completed = false
            let finish: (Bool) -> Void = { [recorder] success in
                guard !completed else { return }
                completed = true
                timeout.invalidate()
                expiration.onTimeout = nil
                recorder.onFrame = nil
                if success { continuation.resume() }
                else { continuation.resume(throwing: MotionFailure.failed("没有收到 SwiftUI 帧回调")) }
            }
            expiration.onTimeout = { finish(false) }
            recorder.onFrame = { DispatchQueue.main.async { finish(true) } }
            RunLoop.main.add(timeout, forMode: .common)
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    func pixels() throws -> MotionPixels {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw MotionFailure.failed("无法建立原生像素缓存")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw MotionFailure.failed("原生像素缓存没有 CGImage") }
        let width = Int(MotionFixture.viewport.width), height = Int(MotionFixture.viewport.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw MotionFailure.failed("无法读取原生 RGBA 像素") }
        var result = MotionPixels()
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                if g > 35 && r * 2 < g && b * 2 < g { result.card.include(x: x, y: y) }
                if r > 15 && b > 15 && abs(r - b) < 20 { result.icon.include(x: x, y: y) }
                if r > 35 && g * 2 < r && b * 2 < r { result.leading.include(x: x, y: y) }
                if g > 35 && b > 35 && r * 2 < min(g, b) { result.trailing.include(x: x, y: y) }
            }
        }
        return result
    }

    func settled() async throws -> MotionPixels {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            guard Date() < deadline else { throw MotionFailure.failed("窗口动画没有进入静止状态") }
            try await nextFrame()
        } while motion.moving
        try await nextFrame()
        return try pixels()
    }

    func click(_ id: String, pixels: MotionPixels) throws {
        let marker = id == "leading" || id == "first" ? pixels.leading : pixels.trailing
        guard let rect = marker.rect, let button = recorder.buttons[id] else {
            throw MotionFailure.failed("\(id) 标题按钮没有实际显示；\(pixels)")
        }
        let displayed = CGPoint(x: rect.midX, y: rect.midY)
        let local = CGPoint(x: displayed.x, y: host.isFlipped ? displayed.y : host.bounds.height - displayed.y)
        let point = host.convert(local, to: host.superview)
        let hit = host.hitTest(point)
        guard let hit, hit === button || hit.isDescendant(of: button) else {
            throw MotionFailure.failed("\(id) 按钮的实际显示中心 \(displayed) 无法从宿主命中，实际命中 \(String(describing: hit))；原生布局 \(button.convert(button.bounds, to: host))；\(pixels)")
        }
        let count = recorder.clicks.count
        button.performClick(nil)
        guard recorder.clicks.count == count + 1, recorder.clicks.last == id else {
            throw MotionFailure.failed("已命中的 \(id) 原生按钮没有响应动作")
        }
    }
}

@MainActor @main
private struct WindowMotionContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await iconAndCardTravelTogetherAcrossInterruptedMotion()
                try await immediateResizeKeepsHeadersVisibleAndHittable()
                try await stackedHeadersKeepTheirPixelsAndHitsAfterSwapping()
                print("窗口动画的三个原生场景验证通过")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    // 真实回归：最小化时头像先跳到终点，卡片随后才到；从停靠格展开的中途卡片被终点框裁掉。
    // 生产 SwiftUI 的几何效果、裁切和图层合成必须实际渲染；仅断言 WindowPose 数学不能挡住回归。
    private static func iconAndCardTravelTogetherAcrossInterruptedMotion() async throws {
        let expanded = WindowPose(frame: CGRect(x: 100, y: 100, width: 600, height: 420))
        let docked = WindowPose(frame: CGRect(x: 800, y: 650, width: 80, height: 80),
                                scale: 0.25, radius: 20, contentOpacity: 0, iconOpacity: 1)
        let harness = MotionHost(pose: expanded, contentSize: expanded.frame.size)
        defer { harness.window.close() }
        let initial = try await harness.settled()
        try frameEquals(initial.card.rect, expanded.frame, label: "初始展开卡片", pixels: initial)

        harness.motion.move(to: docked, kind: .settle)
        let shrinking = try await intermediate(harness, between: expanded.frame, and: docked.frame)
        try aligned(shrinking, label: "最小化中途")
        let compact = try await harness.settled()
        try frameEquals(compact.card.rect, docked.frame, label: "最小化终点", pixels: compact)

        harness.motion.move(to: expanded, kind: .settle)
        let growing = try await intermediate(harness, between: docked.frame, and: expanded.frame)
        try aligned(growing, label: "展开中途")
        guard let card = growing.card.rect, card.maxX > expanded.frame.maxX + 15,
              card.maxY > expanded.frame.maxY + 15 else {
            throw MotionFailure.failed("展开中途卡框应完整保留在终点框之外；\(growing)")
        }

        // 首次真实中间帧出现就改变终点，期间不等动画收尾。
        let relocated = WindowPose(frame: CGRect(x: 60, y: 630, width: 80, height: 80),
                                  scale: 0.25, radius: 20, contentOpacity: 0, iconOpacity: 1)
        harness.motion.move(to: relocated, kind: .preview)
        let reversing = try await intermediate(harness, between: card, and: relocated.frame)
        try aligned(reversing, label: "中途反向并移动终点")
        let moved = try await harness.settled()
        try frameEquals(moved.card.rect, relocated.frame, label: "改变后的停靠终点", pixels: moved)
        harness.motion.move(to: expanded, kind: .settle)
        let restored = try await harness.settled()
        try frameEquals(restored.card.rect, expanded.frame, label: "反向后恢复展开", pixels: restored)
        try harness.click("leading", pixels: restored)
        try harness.click("trailing", pixels: restored)

        // 真实回归：拖起的缩小完成后，继续移动指针又启动追赶动画，使卡框和头像落在旧位置。
        // 等缩小阶段结束后连续改变终点，每次只等下一个呈现帧，不能再等 moving 结束掩盖跟手延迟。
        harness.motion.move(to: docked, kind: .tracking)
        let lifted = try await harness.settled()
        try frameEquals(lifted.card.rect, docked.frame, label: "拖起缩小终点", pixels: lifted)
        for origin in [CGPoint(x: 690, y: 610), CGPoint(x: 590, y: 560), CGPoint(x: 470, y: 660)] {
            var following = docked
            following.frame.origin = origin
            harness.motion.move(to: following, kind: .tracking)
            try await harness.nextFrame()
            let pixels = try harness.pixels()
            try frameEquals(pixels.card.rect, following.frame, label: "持续 tracking 首帧 \(origin)", pixels: pixels)
            try aligned(pixels, label: "持续 tracking 首帧 \(origin)")
        }
        print("通过：收放与中途反向的头像和卡框共位，框外像素不被终点裁切，恢复后按钮可命中，拖起后连续 tracking 首帧立即跟手")
    }

    // 真实回归：连续 resize 中标题补位使用另一段动画，导致标题偏离卡框、被裁切或显示与命中脱节。
    // 每次尺寸更新后的首个实际帧同时检查两端标题像素和 NSHostingView 到 NSButton 的原生命中。
    private static func immediateResizeKeepsHeadersVisibleAndHittable() async throws {
        let frame = CGRect(x: 120, y: 100, width: 600, height: 420)
        let harness = MotionHost(pose: WindowPose(frame: frame), contentSize: frame.size)
        defer { harness.window.close() }
        _ = try await harness.settled()
        for width: CGFloat in [360, 740, 440, 600] {
            let next = CGRect(x: 120, y: 100, width: width, height: 420)
            harness.motion.move(to: WindowPose(frame: next), kind: .immediate)
            try await harness.nextFrame()
            let pixels = try harness.pixels()
            try frameEquals(pixels.card.rect, next, label: "即时 resize \(width)", pixels: pixels)
            guard let leading = pixels.leading.rect, let trailing = pixels.trailing.rect,
                  abs(leading.minX - (next.minX + 20)) <= 2,
                  abs(trailing.maxX - (next.maxX - 20)) <= 2,
                  abs(leading.width - 84) <= 2, abs(trailing.width - 84) <= 2,
                  abs(leading.height - 28) <= 2, abs(trailing.height - 28) <= 2,
                  abs(leading.minY - (next.minY + 20)) <= 2,
                  abs(trailing.minY - (next.minY + 20)) <= 2 else {
                throw MotionFailure.failed("即时 resize \(width) 的首帧标题应贴合当前卡框，完整显示且没有独立延迟；\(pixels)")
            }
            do {
                try harness.click("leading", pixels: pixels)
                try harness.click("trailing", pixels: pixels)
            } catch {
                let failure = error
                let stable = try await harness.settled()
                do {
                    try harness.click("leading", pixels: stable)
                    try harness.click("trailing", pixels: stable)
                    print("诊断：动画 moving=false 后再过一帧，两个按钮恢复命中")
                } catch {
                    print("诊断：动画 moving=false 后再过一帧仍不能命中：\(error)")
                }
                throw failure
            }
        }
        print("通过：四次即时 resize 的首帧标题贴边完整显示，左右原生按钮均在实际像素位置命中")
    }

    private static func intermediate(_ harness: MotionHost, between start: CGRect, and end: CGRect) async throws -> MotionPixels {
        let deadline = Date().addingTimeInterval(3)
        var last = MotionPixels()
        while Date() < deadline {
            try await harness.nextFrame()
            last = try harness.pixels()
            if let card = last.card.rect, last.icon.rect != nil,
               abs(card.midX - start.midX) + abs(card.midY - start.midY) > 20,
               abs(card.midX - end.midX) + abs(card.midY - end.midY) > 20 {
                print("实际中间帧：\(last)")
                return last
            }
            if !harness.motion.moving { break }
        }
        throw MotionFailure.failed("没有捕捉到头像与卡片同时可见的真实中间帧；\(last)")
    }

    // 真实回归：同列上下两个窗口的控制区固定在一个窗口，移入另一窗口时归属没有正确切换。
    // 两个全 viewport 的 SwiftUI surface 叠放后，标题可见坐标与命中必须仍属于各自卡框。
    // 离屏 NSWindow 内派发鼠标事件连普通 SwiftUI .onHover 对照也无法触发，故此场景不宣称验证悬停回调。
    private static func stackedHeadersKeepTheirPixelsAndHitsAfterSwapping() async throws {
        let upper = WindowPose(frame: CGRect(x: 180, y: 60, width: 600, height: 300))
        let lower = WindowPose(frame: CGRect(x: 180, y: 420, width: 600, height: 300))
        let neighbor = WindowMotion(lower)
        let harness = MotionHost(pose: upper, contentSize: upper.frame.size, neighbor: neighbor)
        defer { harness.window.close() }
        _ = try await harness.settled()

        for swapped in [false, true] {
            let first = swapped ? lower : upper
            let second = swapped ? upper : lower
            harness.motion.move(to: first, kind: .immediate)
            neighbor.move(to: second, kind: .immediate)
            try await harness.nextFrame()
            let pixels = try harness.pixels()
            try frameEquals(pixels.leading.rect,
                            CGRect(x: first.frame.minX + 20, y: first.frame.minY + 18, width: 84, height: 28),
                            label: "窗口 first 的标题按钮", pixels: pixels)
            try frameEquals(pixels.trailing.rect,
                            CGRect(x: second.frame.minX + 20, y: second.frame.minY + 18, width: 84, height: 28),
                            label: "窗口 second 的标题按钮", pixels: pixels)
            try harness.click("first", pixels: pixels)
            try harness.click("second", pixels: pixels)
        }
        print("通过：上下窗口的标题像素与原生按钮命中各归其窗，交换上下位置后仍成立；悬停回调未验证")
    }

    private static func aligned(_ pixels: MotionPixels, label: String) throws {
        guard let card = pixels.card.rect, let icon = pixels.icon.rect,
              abs(card.midX - icon.midX) <= 3, abs(card.midY - icon.midY) <= 3 else {
            throw MotionFailure.failed("\(label) 的头像和卡框应处在同一呈现中心；\(pixels)")
        }
    }

    private static func frameEquals(_ actual: CGRect?, _ expected: CGRect, label: String, pixels: MotionPixels) throws {
        guard let actual, abs(actual.minX - expected.minX) <= 2, abs(actual.minY - expected.minY) <= 2,
              abs(actual.width - expected.width) <= 2, abs(actual.height - expected.height) <= 2 else {
            throw MotionFailure.failed("\(label) 应显示完整卡框 \(expected)；\(pixels)")
        }
    }
}
