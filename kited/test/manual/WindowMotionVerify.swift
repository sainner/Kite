import AppKit
import SwiftUI

// 本合同的标题是原生按钮，不发送 PaneHeader 的状态、操作宽度或交互区域偏好。
// 只补齐空值承载类型，实际的标题宿主和跟随逻辑编译自 WindowHeaderAnchored.swift。
nonisolated struct PaneHeaderStatusText: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {}
}

nonisolated struct PaneHeaderActionsWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {}
}

nonisolated struct PaneHeaderInteractiveRects: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {}
}

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
    var texts = [String: NSTextView]()
    var textCreations = [String: Int]()
    var bodySize = CGSize.zero
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
    var onClick: (() -> Void)? = nil

    final class Coordinator: NSObject {
        let id: String
        let recorder: MotionRecorder
        var onClick: (() -> Void)?

        init(id: String, recorder: MotionRecorder, onClick: (() -> Void)?) {
            self.id = id
            self.recorder = recorder
            self.onClick = onClick
        }

        @objc func click() {
            recorder.clicks.append(id)
            onClick?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(id: id, recorder: recorder, onClick: onClick) }

    func makeNSView(context: Context) -> NSButton {
        let button = ColorButton(title: id, target: context.coordinator, action: #selector(Coordinator.click))
        button.isBordered = false
        button.marker = id == "leading" || id == "first" ? .red : .cyan
        recorder.buttons[id] = button
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.onClick = onClick }
}

/// 尺寸完全由标题内部的 State 决定；外层夹具不能直接读写它来促成重测。
private struct SelfSizingHeader: View {
    let recorder: MotionRecorder
    @State private var expanded = false

    var body: some View {
        HeaderButton(id: "leading", recorder: recorder, onClick: { expanded.toggle() })
            .frame(width: expanded ? 172 : 84, height: expanded ? 60 : 28)
    }
}

private struct IntrinsicHeaderFixture: View {
    let motion: WindowMotion
    let contentSize: MotionFixtureSize
    let recorder: MotionRecorder

    var body: some View {
        let size = contentSize.value
        ZStack(alignment: .topLeading) {
            Color.black
            WindowSurface(motion: motion, target: motion.target, contentSize: size,
                          viewport: MotionFixture.viewport, iconSize: 40, color: Color(red: 0, green: 1, blue: 0)) {
                HStack(alignment: .bottom, spacing: 12) {
                    SelfSizingHeader(recorder: recorder).windowHeaderAnchor(.leading)
                    // 这个兄弟视图在锚定宿主外：它的坐标同时证实外层收到了标题的新宽和新高。
                    HeaderButton(id: "trailing", recorder: recorder).frame(width: 84, height: 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
                .frame(width: size.width, height: size.height)
            } icon: {
                EmptyView()
            }
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
                FrameProbe(date: context.date, recorder: recorder).frame(width: 1, height: 1)
            }
            .allowsHitTesting(false)
        }
        .frame(width: MotionFixture.viewport.width, height: MotionFixture.viewport.height)
    }
}

@Observable @MainActor
private final class MotionFixtureSize {
    var value: CGSize
    init(_ value: CGSize) { self.value = value }
}

private struct MotionFixture: View {
    let motion: WindowMotion
    let contentSize: MotionFixtureSize
    let recorder: MotionRecorder
    static let viewport = CGSize(width: 1000, height: 800)

    var body: some View {
        let contentSize = self.contentSize.value
        ZStack(alignment: .topLeading) {
            Color.black
            WindowSurface(motion: motion, target: motion.target, contentSize: contentSize, viewport: Self.viewport,
                          iconSize: 40, color: Color(red: 0, green: 1, blue: 0)) {
                ZStack {
                    HeaderButton(id: "leading", recorder: recorder)
                        .frame(width: 84, height: 28)
                        .windowHeaderAnchor(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    HeaderButton(id: "trailing", recorder: recorder)
                        .frame(width: 84, height: 28)
                        .windowHeaderAnchor(.trailing)
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

@Observable @MainActor
private final class MotionBodyState {
    var size = CGSize(width: 600, height: 520)
    var message = "初始正文"
    var contextRevision = 1
    var scheme = ColorScheme.light
}

private extension EnvironmentValues {
    @Entry var motionBodyContextRevision = 0
}

// 原生正文 adapter 只承担 TextKit 2 的换行和选区；不包含 WindowSurface 的宿主或尺寸更新逻辑。
private struct MotionBodyText: NSViewRepresentable {
    let id: String
    let text: String
    let recorder: MotionRecorder

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.font = .systemFont(ofSize: 15)
        recorder.texts[id] = view
        recorder.textCreations[id, default: 0] += 1
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text { view.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let offered = proposal.width ?? 360
        let width = offered.isFinite ? max(1, offered) : 2000
        guard let manager = nsView.textLayoutManager, let content = manager.textContentManager else { return nil }
        nsView.textContainer?.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: content.documentRange)
        var height: CGFloat = 0
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            height = max(height, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return CGSize(width: width, height: ceil(height))
    }
}

private struct MotionBodyContent: View {
    let message: String
    let recorder: MotionRecorder
    @Environment(\.motionBodyContextRevision) private var contextRevision
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MotionBodyText(id: "selection", text: String(repeating: "可选择的原生正文包含中文与 English words，改宽时会重新换行。", count: 4),
                           recorder: recorder)
            MotionBodyText(id: "semantic", text: "\(message)；环境版本 \(contextRevision)；\(scheme == .dark ? "深色" : "浅色")",
                           recorder: recorder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _, value in
            recorder.bodySize = value
        }
    }
}

private struct MotionBodyFixture: View {
    let motion: WindowMotion
    let state: MotionBodyState
    let recorder: MotionRecorder

    var body: some View {
        let size = state.size
        // 传普通值，正文不直接观察 state；否则会绕开待验证的宿主内容交接。
        let message = state.message
        ZStack(alignment: .topLeading) {
            Color.black
            WindowSurface(motion: motion, target: motion.target, contentSize: size, viewport: MotionFixture.viewport,
                          iconSize: 40, color: Color(red: 0, green: 1, blue: 0)) {
                MotionBodyContent(message: message, recorder: recorder)
            } icon: {
                EmptyView()
            }
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
                FrameProbe(date: context.date, recorder: recorder).frame(width: 1, height: 1)
            }
            .allowsHitTesting(false)
        }
        .frame(width: MotionFixture.viewport.width, height: MotionFixture.viewport.height)
        .environment(\.motionBodyContextRevision, state.contextRevision)
        .environment(\.colorScheme, state.scheme)
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
    let contentSize: MotionFixtureSize
    let recorder = MotionRecorder()
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(pose: WindowPose, contentSize: CGSize, neighbor: WindowMotion? = nil, bodyState: MotionBodyState? = nil,
         intrinsicHeader: Bool = false) {
        motion = WindowMotion(pose)
        self.contentSize = MotionFixtureSize(contentSize)
        let root: AnyView
        if intrinsicHeader {
            root = AnyView(IntrinsicHeaderFixture(motion: motion, contentSize: self.contentSize, recorder: recorder))
        } else if let bodyState {
            root = AnyView(MotionBodyFixture(motion: motion, state: bodyState, recorder: recorder))
        } else if let neighbor {
            root = AnyView(StackedMotionFixture(first: motion, second: neighbor, recorder: recorder))
        } else {
            root = AnyView(MotionFixture(motion: motion, contentSize: self.contentSize, recorder: recorder))
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
            let scenarios: [(String, () async throws -> Void)] = [
                ("收放与反向", iconAndCardTravelTogetherAcrossInterruptedMotion),
                ("即时改宽标题", immediateResizeKeepsHeadersVisibleAndHittable),
                ("双窗口标题", stackedHeadersKeepTheirPixelsAndHitsAfterSwapping),
                ("正文与环境交接", continuousResizeKeepsBodyEnvironmentIdentityAndSelectionCurrent),
                ("标题内部尺寸变化", headerLocalStateResizesOuterLayoutAndKeepsButtonIdentity),
            ]
            var failures = [String]()
            // 场景各自创建并关闭窗口；一个已有失败不应遮住另一个独立场景的回归证据。
            for (name, run) in scenarios {
                do { try await run() }
                catch { failures.append("\(name)：\(error)") }
            }
            if failures.isEmpty {
                print("窗口动画的五个原生场景验证通过")
                exit(0)
            }
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
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
            // 正常拖缝时，生产 CardSlot 的正文尺寸与 target.frame 来自同一个 rect，必须同步输入。
            // 收放/中途反向场景仍固定正文尺寸，不使用这里的 resize 更新。
            harness.contentSize.value = next.size
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

    // 标题自己的 State 改变理想尺寸后，嵌套 NSHostingView 必须让外层 SwiftUI 重测。
    // AppKit 固有尺寸失效能否穿过 representable 边界、是否重建已有按钮，必须运行真实宿主才能确认。
    private static func headerLocalStateResizesOuterLayoutAndKeepsButtonIdentity() async throws {
        var frame = CGRect(x: 120, y: 100, width: 600, height: 420)
        let harness = MotionHost(pose: WindowPose(frame: frame), contentSize: frame.size, intrinsicHeader: true)
        defer { harness.window.close() }
        let initial = try await harness.settled()
        guard let leading = harness.recorder.buttons["leading"], let trailing = harness.recorder.buttons["trailing"] else {
            throw MotionFailure.failed("内部尺寸场景未建立两个原生按钮")
        }

        func verify(_ label: String, titleSize: CGSize, pixels: MotionPixels) throws {
            guard harness.recorder.buttons["leading"] === leading, harness.recorder.buttons["trailing"] === trailing,
                  leading.window === harness.window, trailing.window === harness.window else {
                throw MotionFailure.failed("\(label)：标题或兄弟按钮被重建，或离开原窗口")
            }
            try frameEquals(pixels.card.rect, frame, label: "\(label) 卡片", pixels: pixels)
            try frameEquals(pixels.leading.rect,
                            CGRect(x: frame.minX + 20, y: frame.minY + 20, width: titleSize.width, height: titleSize.height),
                            label: "\(label) 内部状态标题", pixels: pixels)
            try frameEquals(pixels.trailing.rect,
                            CGRect(x: frame.minX + 20 + titleSize.width + 12,
                                   y: frame.minY + 20 + titleSize.height - 28, width: 84, height: 28),
                            label: "\(label) 按外层测量排列的兄弟按钮", pixels: pixels)
            try harness.click("trailing", pixels: pixels)
        }

        let small = CGSize(width: 84, height: 28)
        let large = CGSize(width: 172, height: 60)
        try verify("初始", titleSize: small, pixels: initial)
        // 只触发标题内部 State；不改父层输入、rootView 或尺寸，不在夹具里主动使固有尺寸失效。
        try harness.click("leading", pixels: initial)
        try await harness.nextFrame()
        try verify("内部展开后的首帧", titleSize: large, pixels: harness.pixels())

        for width: CGFloat in [360, 740, 440, 600] {
            frame.size.width = width
            harness.contentSize.value = frame.size
            harness.motion.move(to: WindowPose(frame: frame), kind: .immediate)
            try await harness.nextFrame()
            try verify("改宽 \(width)", titleSize: large, pixels: harness.pixels())
        }
        let returned = try harness.pixels()
        try harness.click("leading", pixels: returned)
        try await harness.nextFrame()
        try verify("往返改宽后内部收起的首帧", titleSize: small, pixels: harness.pixels())
        print("通过：标题仅改内部 State 即向外传播宽高，兄弟按钮同步重排；往返改宽保留展开状态、原生按钮身份与实际像素命中")
    }

    // 稳定宿主不能冻结父层传入的正文或整份环境，也不能靠重建原生子树刷新内容。
    // SwiftUI 内容值、环境、嵌套 NSHostingView 尺寸与 AppKit 选区的交接必须在真实运行时验证。
    private static func continuousResizeKeepsBodyEnvironmentIdentityAndSelectionCurrent() async throws {
        let state = MotionBodyState()
        let origin = CGPoint(x: 120, y: 100)
        let harness = MotionHost(pose: WindowPose(frame: CGRect(origin: origin, size: state.size)),
                                 contentSize: state.size, bodyState: state)
        defer { harness.window.close() }
        _ = try await harness.settled()
        guard let selected = harness.recorder.texts["selection"],
              let semantic = harness.recorder.texts["semantic"] else {
            throw MotionFailure.failed("正文合同未建立两个原生文本视图")
        }
        let originals = ["selection": selected, "semantic": semantic]
        let selection = NSRange(location: 8, length: 17)
        selected.setSelectedRange(selection)

        func verify(_ label: String) throws {
            let expectedText = "\(state.message)；环境版本 \(state.contextRevision)；\(state.scheme == .dark ? "深色" : "浅色")"
            guard semantic.string == expectedText else {
                throw MotionFailure.failed("\(label)：正文或外层环境没有在首帧更新；期望「\(expectedText)」，实际「\(semantic.string)」")
            }
            guard abs(harness.recorder.bodySize.width - state.size.width) <= 1,
                  abs(harness.recorder.bodySize.height - state.size.height) <= 1 else {
                throw MotionFailure.failed("\(label)：正文首帧尺寸落后；期望 \(state.size)，实际 \(harness.recorder.bodySize)")
            }
            for (id, view) in originals {
                guard harness.recorder.texts[id] === view, harness.recorder.textCreations[id] == 1,
                      view.window === harness.window else {
                    throw MotionFailure.failed("\(label)：原生正文 \(id) 被重建或离开原窗口")
                }
                guard abs(view.bounds.width - (state.size.width - 24)) <= 1, view.bounds.height > 0 else {
                    throw MotionFailure.failed("\(label)：原生正文 \(id) 首帧没有按当前容器宽度排版；期望宽 \(state.size.width - 24)，实际 \(view.bounds)")
                }
            }
            guard selected.selectedRange() == selection else {
                throw MotionFailure.failed("\(label)：改宽或内容交接丢失已有原生选区，实际 \(selected.selectedRange())")
            }
        }

        try verify("初始正文")
        // 只有宿主的尺寸输入变化，正文值和环境保持不变；不能借内容更新补上落后的 proposal。
        state.size.width = 480
        harness.motion.move(to: WindowPose(frame: CGRect(origin: origin, size: state.size)), kind: .immediate)
        try await harness.nextFrame()
        try verify("仅改宽，正文与环境不变")

        for (index, width) in [CGFloat(360), 540, 300, 660, 420, 600].enumerated() {
            state.size.width = width
            state.message = "第 \(index + 1) 次正文更新"
            state.contextRevision += 1
            state.scheme = index.isMultiple(of: 2) ? .dark : .light
            harness.motion.move(to: WindowPose(frame: CGRect(origin: origin, size: state.size)), kind: .immediate)
            try await harness.nextFrame()
            try verify("连续改宽 \(width)")

            if index == 2 {
                // 同尺寸更新也必须生效，不能依赖下一次 resize 顺带刷新环境或正文。
                state.contextRevision += 100
                state.scheme = .light
                try await harness.nextFrame()
                try verify("尺寸不变，仅外层环境变化")
                state.message = "尺寸不变时到达的新正文"
                try await harness.nextFrame()
                try verify("尺寸不变，仅正文变化")
            }
        }
        print("通过：连续改宽与同尺寸内容/环境变化在首帧生效，正文实际宽度同步，两个原生文本对象和已有选区保留")
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
