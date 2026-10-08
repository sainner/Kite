import AppKit
import SwiftUI

private enum SizingFailure: Error, CustomStringConvertible {
    case failed(String)

    nonisolated var description: String {
        if case .failed(let message) = self { return message }
        return "弹窗原生尺寸验证失败"
    }
}

@Observable @MainActor
private final class SizingState {
    var presented = false
    var rows = 1
    var revision = 0

    func show(rows: Int) {
        self.rows = rows
        revision += 1
    }
}

@MainActor
private final class SizingRecorder {
    weak var sheet: NSWindow?
    var changedWindow = false
    var revision = -1
    var stableFrames = 0
    var height: CGFloat = 0
    var bodyHeight: CGFloat = 0
    var onFrame: (() -> Void)?

    func record(_ view: NSView, revision: Int) {
        guard let window = view.window, window.sheetParent != nil else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        if let sheet, sheet !== window { changedWindow = true }
        sheet = window
        let current = window.contentRect(forFrameRect: window.frame).height
        stableFrames = self.revision == revision && abs(height - current) < 0.5 ? stableFrames + 1 : 0
        self.revision = revision
        height = current
        onFrame?()
    }
}

@MainActor
private final class SizingDeadline: NSObject {
    var onTimeout: (() -> Void)?
    @objc func finish(_ timer: Timer) { onTimeout?() }
}

private struct SizingProbe: NSViewRepresentable {
    let revision: Int
    let frame: Date
    let recorder: SizingRecorder

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { recorder.record(view, revision: revision) }
    }
}

private struct SheetFixture: View {
    @Bindable var state: SizingState
    let recorder: SizingRecorder

    var body: some View {
        Text("弹窗尺寸验证宿主")
            .frame(width: 800, height: 720)
            .sheet(isPresented: $state.presented) {
                CardSheet(title: "登录订阅账号", subtitle: "尺寸回归夹具", close: { state.presented = false }) {
                    VStack(spacing: 8) {
                        ForEach(0..<state.rows, id: \.self) { row in
                            Text("授权信息 \(row + 1)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { recorder.bodyHeight = $0 }
                } actions: {
                    Button("等待授权完成") {}
                        .buttonStyle(.glassProminent)
                }
                .background {
                    TimelineView(.animation) { context in
                        SizingProbe(revision: state.revision, frame: context.date, recorder: recorder)
                    }
                }
            }
    }
}

@MainActor @main
private struct CardSheetSizingContract: App {
    @State private var state = SizingState()
    private let recorder = SizingRecorder()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }

    var body: some Scene {
        Window("弹窗原生尺寸验证", id: "card-sheet-sizing") {
            SheetFixture(state: state, recorder: recorder)
                .task {
                    do {
                        guard let parent = NSApplication.shared.windows.first(where: { $0.sheetParent == nil }) else {
                            throw SizingFailure.failed("SwiftUI scene 没有创建宿主窗口")
                        }
                        parent.alphaValue = 0
                        parent.ignoresMouseEvents = true
                        try await Self.sameSheetGrowsAndShrinksWithContent(state: state, recorder: recorder, parent: parent)
                        exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("\(error)\n".utf8))
                        exit(1)
                    }
                }
        }
        .defaultSize(width: 800, height: 720)
        .windowResizability(.contentSize)
    }

    // 真实回归：订阅登录从启动中进入授权阶段后，真实 .sheet 仍停留在初始矮高度。
    // SwiftUI 的尺寸提案与 AppKit sheet 的尺寸缓存联动必须实际呈现才能确认。
    // 由真实 SwiftUI.App scene 管理同一 sheet，依次显示短、长、短内容。
    // 测试窗口透明且不接收鼠标，只读取窗口尺寸，不截图或操作用户 App。
    private static func sameSheetGrowsAndShrinksWithContent(state: SizingState, recorder: SizingRecorder,
                                                         parent: NSWindow) async throws {
        defer {
            if let sheet = parent.attachedSheet { parent.endSheet(sheet); sheet.close() }
            parent.close()
        }

        state.presented = true
        guard await wait(recorder: recorder, until: {
            parent.attachedSheet != nil && recorder.revision == 0 && recorder.stableFrames >= 8
        }) else { throw SizingFailure.failed("初始 sheet 未完成原生布局；当前高度 \(recorder.height)") }
        guard let sheet = parent.attachedSheet else { throw SizingFailure.failed("真实 sheet 未挂到宿主窗口") }
        let short = recorder.height
        print("初始短内容高度：\(short)；内容布局高度：\(recorder.bodyHeight)")

        state.show(rows: 12)
        let grew = await wait(recorder: recorder, until: {
            recorder.revision == state.revision && recorder.stableFrames >= 8 && recorder.height > short + 100
        })
        let long = recorder.height
        print("同一弹窗长内容高度：\(long)；增加：\(long - short)；内容布局高度：\(recorder.bodyHeight)；阶段：\(recorder.revision)")
        print("长内容原生约束：最小 \(sheet.contentMinSize)；最大 \(sheet.contentMaxSize)；宿主理想尺寸 \(String(describing: sheet.contentView?.fittingSize))")

        state.show(rows: 1)
        let shrank = await wait(recorder: recorder, until: {
            recorder.revision == state.revision && recorder.stableFrames >= 8 && abs(recorder.height - short) <= 2
        })
        let finalShort = recorder.height
        print("同一弹窗恢复短内容高度：\(finalShort)；缩短：\(long - finalShort)")

        guard !recorder.changedWindow, parent.attachedSheet === sheet, recorder.sheet === sheet else {
            throw SizingFailure.failed("内容变化期间替换或关闭了 sheet，不能证明同一次呈现的自适应")
        }
        guard grew, long > short + 100 else {
            throw SizingFailure.failed("长内容应使同一 sheet 长高至少 100 点，实际 \(short) → \(long) → \(finalShort)")
        }
        guard shrank, long > finalShort + 100, abs(finalShort - short) <= 2 else {
            throw SizingFailure.failed("内容恢复后 sheet 应回到初始高度（允许 2 点误差），实际 \(short) → \(long) → \(finalShort)")
        }

        guard let screen = sheet.screen ?? parent.screen else {
            throw SizingFailure.failed("真实 sheet 没有所属屏幕，不能确认超长内容边界")
        }
        let visible = screen.visibleFrame
        state.show(rows: 100)
        let reachedLimit = await wait(recorder: recorder, until: {
            recorder.revision == state.revision && recorder.stableFrames >= 8 &&
                recorder.bodyHeight > visible.height && recorder.height >= long - 2
        })
        let boundedFrame = sheet.frame
        print("超长内容窗口 frame：\(boundedFrame)；屏幕可用 frame：\(visible)；内容布局高度：\(recorder.bodyHeight)")

        state.show(rows: 1)
        let recovered = await wait(recorder: recorder, until: {
            recorder.revision == state.revision && recorder.stableFrames >= 8 && abs(recorder.height - short) <= 2
        })
        print("超长内容恢复短内容高度：\(recorder.height)；内容布局高度：\(recorder.bodyHeight)；阶段：\(recorder.revision)")
        print("恢复后的原生约束：最小 \(sheet.contentMinSize)；最大 \(sheet.contentMaxSize)；宿主理想尺寸 \(String(describing: sheet.contentView?.fittingSize))")
        guard reachedLimit, boundedFrame.minY >= visible.minY - 2, boundedFrame.maxY <= visible.maxY + 2 else {
            throw SizingFailure.failed("超长内容应将窗口限制在屏幕内，实际窗口 \(boundedFrame)，屏幕可用范围 \(visible)")
        }
        guard recovered, !recorder.changedWindow, parent.attachedSheet === sheet, recorder.sheet === sheet else {
            throw SizingFailure.failed("超长内容恢复后应保持同一 sheet 并回到 \(short) 点，实际 \(recorder.height) 点")
        }
        print("通过：同一次真实 CardSheet 随内容长高、按屏幕限高并恢复短高度")
    }

    // 等 SwiftUI 原生动画帧更新尺寸；计时器仅用于有界超时，不用于延迟状态切换。
    private static func wait(recorder: SizingRecorder, until predicate: @escaping () -> Bool) async -> Bool {
        if predicate() { return true }
        return await withCheckedContinuation { continuation in
            let expiration = SizingDeadline()
            let timeout = Timer(fireAt: Date().addingTimeInterval(3), interval: 0, target: expiration,
                                selector: #selector(SizingDeadline.finish(_:)), userInfo: nil, repeats: false)
            let finish: (Bool) -> Void = { result in
                timeout.invalidate()
                expiration.onTimeout = nil
                recorder.onFrame = nil
                continuation.resume(returning: result)
            }
            expiration.onTimeout = { finish(false) }
            recorder.onFrame = { if predicate() { finish(true) } }
            RunLoop.main.add(timeout, forMode: .common)
        }
    }
}
