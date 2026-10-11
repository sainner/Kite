import AppKit
import SwiftUI

// 字体与间距对齐生产 token，颜色用于像素识别；Text、Capsule、尺寸提案与定位全部来自生产组件。
enum Theme {
    static let secondary = Font.subheadline
    static let card = Color(red: 0, green: 1, blue: 0)
}

enum Metrics {
    static let gap: CGFloat = 12
}

private enum LabelFailure: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "停靠提示原生验证失败"
    }
}

@Observable @MainActor
private final class LabelState {
    var text = "重新打开"
    var icon = CGRect(x: 380, y: 132, width: 36, height: 36)
    var presented = true
    var revision = 0
}

@MainActor
private final class LabelFrames {
    var onFrame: ((Int) -> Void)?
}

private struct LabelFrameProbe: NSViewRepresentable {
    let date: Date
    let revision: Int
    let frames: LabelFrames

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { frames.onFrame?(revision) }
}

private struct LabelFixture: View {
    let state: LabelState
    let frames: LabelFrames
    static let contentBounds = CGRect(x: 0, y: 0, width: 420, height: 300)
    static let margin: CGFloat = 12
    static let windowBounds = CGRect(x: 0, y: 0, width: 444, height: 324)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Rectangle().fill(Color(red: 0, green: 0, blue: 1))
                .frame(width: state.icon.width, height: state.icon.height)
                .position(x: state.icon.midX, y: state.icon.midY)
            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
                LabelFrameProbe(date: context.date, revision: state.revision, frames: frames)
                    .frame(width: 1, height: 1)
            }
            .allowsHitTesting(false)
        }
        .frame(width: Self.contentBounds.width, height: Self.contentBounds.height)
        .dockHoverSource(state.presented ? DockHoverTip(text: state.text, frame: state.icon) : nil)
        .mask { Rectangle() }
        .padding(Self.margin)
        .dockHoverHost()
        .transaction { $0.disablesAnimations = true }
        .foregroundStyle(Color(red: 1, green: 0, blue: 0))
        .background(.black)
    }
}

private struct ColorPixels: CustomStringConvertible {
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
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

private struct LabelPixels: CustomStringConvertible {
    var text = ColorPixels()
    var capsule = ColorPixels()
    var icon = ColorPixels()
    var description: String { "文字 \(text)；胶囊 \(capsule)；图标 \(icon)" }
}

@MainActor
private final class LabelDeadline: NSObject {
    var expire: (() -> Void)?
    @objc func finish(_ timer: Timer) { expire?() }
}

@MainActor
private final class LabelHost {
    let state = LabelState()
    let frames = LabelFrames()
    let host: NSHostingView<LabelFixture>
    let window: NSWindow

    init() {
        host = NSHostingView(rootView: LabelFixture(state: state, frames: frames))
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: LabelFixture.windowBounds.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderFront(nil)
    }

    func show(text: String, icon: CGRect, presented: Bool = true) async throws -> LabelPixels {
        state.text = text
        state.icon = icon
        state.presented = presented
        state.revision += 1
        let expected = state.revision
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let deadline = LabelDeadline()
            let timer = Timer(timeInterval: 3, target: deadline, selector: #selector(LabelDeadline.finish),
                              userInfo: nil, repeats: false)
            var completed = false
            var renderedFrames = 0
            let finish: (Bool) -> Void = { [frames] rendered in
                guard !completed else { return }
                completed = true
                timer.invalidate()
                deadline.expire = nil
                frames.onFrame = nil
                if rendered { continuation.resume() }
                else { continuation.resume(throwing: LabelFailure.failed("没有收到新提示内容的呈现帧")) }
            }
            deadline.expire = { finish(false) }
            frames.onFrame = { revision in
                if revision == expected {
                    renderedFrames += 1
                    if renderedFrames >= 2 { DispatchQueue.main.async { finish(true) } }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        return try pixels()
    }

    private func pixels() throws -> LabelPixels {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw LabelFailure.failed("无法建立提示的原生像素缓存")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw LabelFailure.failed("提示像素缓存没有 CGImage") }
        let width = Int(LabelFixture.windowBounds.width), height = Int(LabelFixture.windowBounds.height)
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
        guard rendered else { throw LabelFailure.failed("无法读取提示的原生 RGBA 像素") }
        var result = LabelPixels()
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                if r > 35 && r > g && r > b * 2 { result.text.include(x: x, y: y) }
                if g > 35 && g > r * 2 && g > b * 2 { result.capsule.include(x: x, y: y) }
                if b > 35 && b > r * 2 && b > g * 2 { result.icon.include(x: x, y: y) }
            }
        }
        return result
    }
}

@MainActor @main
private struct DockHoverLabelContract {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await bottomSmallIconKeepsCenteredTipOutsideContentMask()
                print("停靠提示的一个原生场景验证通过")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    // 真实回归：最底部 16×16 图标的 hover tip 胶囊下半截被工作区底边裁掉；只给 Text fixedSize 未修好。
    // source 位于内容矩形 mask 内，host 位于 mask 外并保留 12 点窗口留白，运行生产 anchorPreference 坐标换算。
    // 同一组件的中间 36 点图标提供自然尺寸参照；底边小图标的提示必须居中并完整画进留白，不能上移避让。
    // 夹具关闭动画，只验证最终布局和跨 mask 像素，不把 hover 的淡入或位置动画时序作为本场景约束。
    private static func bottomSmallIconKeepsCenteredTipOutsideContentMask() async throws {
        let harness = LabelHost()
        defer { harness.window.close() }
        let middle = CGRect(x: 380, y: 132, width: 36, height: 36)
        let smallMiddle = CGRect(x: 380, y: 142, width: 16, height: 16)
        let bottom = CGRect(x: 380, y: 284, width: 16, height: 16)
        var shortTextHeight: CGFloat?
        for title in ["重新打开", "这是一个很长的中文窗口标题，用于确认提示保持单行省略并且不会被工作区的底部裁掉"] {
            let reference = try await harness.show(text: title, icon: middle)
            try leftAndCentered(reference, icon: middle)
            guard let referenceText = reference.text.rect, let referenceCapsule = reference.capsule.rect else {
                throw LabelFailure.failed("中间 36 点图标旁的自然提示没有呈现；\(reference)")
            }
            if let shortTextHeight {
                guard referenceText.height <= shortTextHeight + 2 else {
                    throw LabelFailure.failed("长中文标题应保持单行；短标题字高 \(shortTextHeight)，长标题 \(reference)")
                }
            } else { shortTextHeight = referenceText.height }
            print("36 点图标自然参照：\(reference)")
            for icon in [smallMiddle, bottom] {
                let actual = try await harness.show(text: title, icon: icon)
                try leftAndCentered(actual, icon: icon)
                guard let text = actual.text.rect, let capsule = actual.capsule.rect,
                      abs(text.width - referenceText.width) <= 2, abs(text.height - referenceText.height) <= 2,
                      abs(capsule.width - referenceCapsule.width) <= 2, abs(capsule.height - referenceCapsule.height) <= 2,
                      Double(actual.text.count) >= Double(reference.text.count) * 0.90,
                      Double(actual.capsule.count) >= Double(reference.capsule.count) * 0.95 else {
                    throw LabelFailure.failed("16 点图标 \(icon) 的提示应保留自然文字与完整胶囊；参照 \(reference)；实际 \(actual)")
                }
                if icon == bottom {
                    guard capsule.maxY > LabelFixture.margin + LabelFixture.contentBounds.maxY + 2 else {
                        throw LabelFailure.failed("底边提示应越过内容矩形 mask，绘入窗口底部留白；\(actual)")
                    }
                }
                print("16 点图标 \(icon) 的完整提示：\(actual)")
            }
        }
        let hidden = try await harness.show(text: "重新打开", icon: bottom, presented: false)
        guard hidden.text.count == 0, hidden.capsule.count == 0, hidden.icon.rect != nil else {
            throw LabelFailure.failed("source 变为 nil 后应只保留图标，移除遮罩外的文字与胶囊；\(hidden)")
        }
        print("通过：source 变为 nil 后，遮罩外的提示消失而图标保留")
    }

    private static func leftAndCentered(_ pixels: LabelPixels, icon: CGRect) throws {
        let expectedIcon = icon.offsetBy(dx: LabelFixture.margin, dy: LabelFixture.margin)
        guard let text = pixels.text.rect, let capsule = pixels.capsule.rect, let renderedIcon = pixels.icon.rect,
              abs(renderedIcon.minX - expectedIcon.minX) <= 1, abs(renderedIcon.minY - expectedIcon.minY) <= 1,
              abs(renderedIcon.width - icon.width) <= 1, abs(renderedIcon.height - icon.height) <= 1,
              LabelFixture.windowBounds.contains(capsule), capsule.maxX < renderedIcon.minX,
              abs(capsule.midY - renderedIcon.midY) <= 1,
              capsule.insetBy(dx: -1, dy: -1).contains(text),
              text.minY > capsule.minY, text.maxY < capsule.maxY else {
            throw LabelFailure.failed("提示应在图标左侧并与图标垂直居中，文字和胶囊完整位于实际宿主窗口内；预期图标 \(expectedIcon)；\(pixels)")
        }
    }
}
