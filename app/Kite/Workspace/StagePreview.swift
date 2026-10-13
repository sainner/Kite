import SwiftUI

extension View {
    /// Debug build 带 --stage-preview（或 --ring-preview）启动时主窗口空着，宽屏台面（或状态圆环、停靠栏脉冲）的新旧对照另开一个窗口，
    /// 见 StagePreview、RingPreview。
    @ViewBuilder func stagePreview() -> some View {
        #if DEBUG && os(macOS)
        if StagePreview.enabled || RingPreview.enabled { Color.clear } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG && os(macOS)
import AppKit
import os

private let log = Logger(subsystem: "kite.stage-preview", category: "capture")

/// 宽屏台面的新旧对照：左边 SwiftUI 版（SwiftUITilesLayer），右边原生版（StageHost），各用一个造出来的工作区，数据和排布一样，
/// 一次一种状态，两边同时改排布模型。不连工作机、不发请求。
/// 带 --capture-port <端口> 时依次摆好每种状态，等动画走完抓自己窗口的图和两格的位置 POST 到本机这个端口，抓完退出；
/// 深色外观加 -KiteAppearance dark 启动。
struct StagePreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--stage-preview") }
    static var capturePort: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--capture-port"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    /// 两格的大小：台面含停靠栏。宽是点阵模块（12）的整数倍、两格隔 24：两格落在窗口点阵的同一相位上，静息点逐像素对得上。
    static let cell = CGSize(width: 684, height: 564)

    static func openWindow(model: AppModel) {
        if RingPreview.enabled {
            DispatchQueue.main.async { RingPreview.openWindow(model: model) }
            return
        }
        DispatchQueue.main.async {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 2 * cell.width + 72, height: cell.height + 110),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            switch UserDefaults.standard.string(forKey: "KiteAppearance") {
            case "dark": window.appearance = NSAppearance(named: .darkAqua)
            case "light": window.appearance = NSAppearance(named: .aqua)
            default: break
            }
            window.contentView = NSHostingView(rootView: StagePreview().environment(model).toastHost())
            window.center()
            // -stageHover swiftui|native：把窗口挪到指针底下，让指针停在那一边右上那张卡片上，比悬停露出的窗口按钮
            if let side = UserDefaults.standard.string(forKey: "stageHover") {
                let point = CGPoint(x: (side == "native" ? 2 * 24 + cell.width : 24) + cell.width - 160, y: 96 + 200)
                let mouse = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(x: mouse.x - point.x, y: mouse.y + point.y - window.frame.height))
            }
            window.orderFrontRegardless()
            shown = window
        }
    }

    private static var shown: NSWindow?

    @Environment(AppModel.self) private var model
    @State private var scenes = [StagePreviewScene(side: "swiftui"), StagePreviewScene(side: "native")]
    @State private var frames = StagePreviewFrames()
    @State private var index = 0
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("台面对照 · \(StagePreviewStep.all[index].title)").font(Theme.title)
                Text("左 SwiftUI 版，右原生版").font(Theme.secondary).foregroundStyle(.secondary)
                Spacer()
                Button("下一步") { advance() }.disabled(index == StagePreviewStep.all.count - 1)
            }
            HStack(alignment: .top, spacing: 24) {
                ForEach(scenes.indices, id: \.self) { side in
                    StagePreviewCell(scene: scenes[side], native: side == 1, frames: frames)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear {
            guard !started else { return }
            started = true
            if let port = Self.capturePort {
                let frames = frames
                Task { @MainActor in await capture(port: port, frames: frames) }
            }
        }
    }

    private func advance() {
        guard index + 1 < StagePreviewStep.all.count else { return }
        index += 1
        for scene in scenes { StagePreviewStep.all[index].apply(scene) }
    }

    private func capture(port: Int, frames: StagePreviewFrames) async {
        let appearance = UserDefaults.standard.string(forKey: "KiteAppearance") ?? "light"
        try? await Task.sleep(for: .seconds(3))
        for step in StagePreviewStep.all.indices {
            if step > 0 { advance() }
            Self.shown?.makeFirstResponder(nil)
            let name = "stage-\(appearance)-\(String(format: "%02d", step))-\(StagePreviewStep.all[step].id)"
            // 动画途中按固定的时刻各抓一张，两边同一次更新里开始，看飞行中的外框、正文、头像、叠放
            let start = Date.now
            for (index, delay) in StagePreviewStep.all[step].flight.enumerated() {
                try? await Task.sleep(until: .now + .seconds(max(0, delay - Date.now.timeIntervalSince(start))))
                await shoot("\(name)-f\(index)", port: port, frames: frames)
            }
            try? await Task.sleep(for: .milliseconds(1500))
            await shoot(name, port: port, frames: frames)
        }
        await StagePreviewCapture.post("stage-\(appearance)-done.txt", Data(), port: port)
        NSApp.terminate(nil)
    }

    private func shoot(_ name: String, port: Int, frames: StagePreviewFrames) async {
        guard let window = Self.shown, let image = StagePreviewCapture.image(of: window) else {
            log.error("抓不到窗口")
            return
        }
        await StagePreviewCapture.post("\(name).png", image, port: port)
        let layout: [String: Any] = ["scale": window.backingScaleFactor,
                                     "cells": frames.cells.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }]
        if let data = try? JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys]) {
            await StagePreviewCapture.post("\(name).json", data, port: port)
        }
    }
}

@Observable private final class StagePreviewFrames {
    @ObservationIgnored var cells: [String: CGRect] = [:]
}

private struct StagePreviewCell: View {
    let scene: StagePreviewScene
    let native: Bool
    let frames: StagePreviewFrames

    var body: some View {
        Group {
            if native { StageHost(group: .workspace(scene.area)) } else { SwiftUITilesLayer(group: .workspace(scene.area)) }
        }
        .environment(scene.area)
        .environment(scene.area.layout)
        // 侧栏收起时左上角的窗口带侧栏入口
        .environment(\.openSidebar, {})
        .frame(width: StagePreview.cell.width, height: StagePreview.cell.height)
        .appDotBackground()
        .dockHoverHost()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.cells[native ? "native" : "swiftui"] = $0 }
    }
}

/// 一边的工作区：两个代理窗口（一个带着没有窗口的子代理）、文件和终端两个工具窗口、三个没有窗口的后台代理。
/// 排布从默认的左一右二起：代理 A | 文件 / 代理 B，终端缩在停靠栏。
private final class StagePreviewScene {
    let area: WorkArea
    let agentA: Pane
    let files: Pane
    let agentB: Pane
    let family: String
    let miniFamily: String

    init(side: String) {
        let machine = RemoteMachine(id: "stage-preview", name: "预览", createdAt: 0)
        let workspace = "stage-preview.\(side)"
        // 上次预览留下的排布不算，每次从默认排布起
        UserDefaults.standard.removeObject(forKey: "KiteWindowLayout.\(machine.id).\(workspace)")
        var b = DockPreviewBuilder(machine: machine, workspace: workspace, roles: [])
        b.title = "台面对照"
        let a = b.agent("重构停靠栏", role: 0, window: .stage)
        let files = b.tool("文件", .previewFiles, window: .stage)
        let parent = b.agent("写测试", role: 1, window: .stage)
        b.agent("子代理", role: 2, parent: parent.id)
        b.tool("终端", .previewTerminal, window: .docked)
        let background = (0..<3).map { b.agent("后台 \($0 + 1)", role: $0) }
        // 小头像里的家族：从停靠栏底下往上展开，上面缩着的卡片露在外面、被压暗
        b.agent("后台子代理", role: 3, parent: background[0].id)
        let scene = b.build()
        area = scene.area
        // 两个代理窗口是会话，A 有一段够长的对话：滚到底时开头压在标题栏后面，看滚动软边
        for (instance, records) in [(a, Self.records), (parent, [Record]())] {
            let thread = WorkThread(workspace: "/", project: "预览")
            thread.adopt(instance: instance.id)
            thread.title = instance.title
            thread.transcript = Transcript(root: "/", records: records)
            area.threads.append(thread)
        }
        agentA = b.pane(of: a)!
        self.files = b.pane(of: files)!
        agentB = b.pane(of: parent)!
        family = DockEntry.familyID(parent.id)
        miniFamily = DockEntry.familyID(background[0].id)
    }
}

extension StagePreviewScene {
    static let records: [Record] = (1...4).flatMap { round in
        [Record(block: .human(Message(id: "preview-\(round)", text: "第 \(round) 轮：帮我看看停靠栏的格子为什么在缩小时跳一下"))),
         Record(block: .text("""
            先看排布：缩小时卡片的终点是停靠栏里那一格，**格子的位置**在同一次更新里算好。跳一下多半是两套时钟错开了一帧，\
            卡片按显示链接取样，停靠栏按 SwiftUI 的动画走。

            ```swift
            let frame = plan.dockFrame(of: pane, area: area)
            motion.move(to: target, kind: .settle)
            ```

            可以先在第 \(round) 个窗口上量一下帧间隔，再决定改哪边。
            """))]
    }
}

/// 一步：改两边的排布模型。
private struct StagePreviewStep {
    let id: String
    let title: String
    /// 动画途中在哪几个时刻（秒）各抓一张。
    var flight: [Double] = []
    let apply: (StagePreviewScene) -> Void

    private static var bounds: CGRect { CGRect(origin: .zero, size: StagePreview.cell) }

    static let all: [StagePreviewStep] = [
        StagePreviewStep(id: "one-and-two", title: "左一右二") { _ in },
        StagePreviewStep(id: "side-by-side", title: "左右两窗（缩小一窗）", flight: [0.06, 0.12, 0.2]) { $0.area.layout.minimize($0.agentB) },
        StagePreviewStep(id: "one", title: "一窗占满") { $0.area.layout.expand($0.agentA) },
        StagePreviewStep(id: "empty", title: "空台面") { $0.area.layout.minimize($0.agentA) },
        StagePreviewStep(id: "restore", title: "从停靠栏恢复两窗", flight: [0.06, 0.12, 0.2]) { scene in
            scene.area.layout.restore(scene.agentA, in: bounds)
            scene.area.layout.restore(scene.files, in: bounds)
        },
        StagePreviewStep(id: "drag", title: "拖动预览（放到右边）") { scene in
            let regions = scene.area.layout.regions(in: bounds)
            scene.area.layout.drag(scene.agentA, to: CGPoint(x: regions.canvas.maxX - 10, y: regions.canvas.midY), in: bounds)
        },
        StagePreviewStep(id: "drag-dock", title: "拖动预览（放进停靠栏）") { scene in
            let regions = scene.area.layout.regions(in: bounds)
            scene.area.layout.drag(scene.agentA, to: CGPoint(x: regions.dock.midX, y: regions.dock.minY + 140), in: bounds)
        },
        StagePreviewStep(id: "dropped", title: "放下") { scene in scene.area.layout.cancelDrag() },
        StagePreviewStep(id: "family", title: "停靠栏展开家族格", flight: [0.06, 0.12, 0.2]) { scene in scene.area.toggleDock(scene.family, depth: 0) },
        StagePreviewStep(id: "collapsed", title: "收起") { scene in scene.area.collapseDock() },
        StagePreviewStep(id: "mini-family", title: "停靠栏展开小头像家族（上面的卡片压暗）") { scene in
            scene.area.toggleDock(scene.miniFamily, depth: 0)
        },
    ]
}

/// 状态圆环、停靠栏脉冲的新旧对照：左边 SwiftUI 版逐帧画的那一帧（ContextRingFrame、DockPulseFrame），右边图层版停在同一处
/// （ContextRingLayers、DockPulseLayers 的 frozen），各阶段、各进度一格。加 --capture-port 时抓一张图和两格的位置 POST 回去。
struct RingPreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ring-preview") }
    private static var shown: NSWindow?
    @State private var frames = StagePreviewFrames()

    static func openWindow(model: AppModel) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        if UserDefaults.standard.string(forKey: "KiteAppearance") == "dark" { window.appearance = NSAppearance(named: .darkAqua) }
        window.contentView = NSHostingView(rootView: RingPreview().environment(model))
        window.center()
        window.orderFrontRegardless()
        shown = window
    }

    private static let rings: [(phase: String, fraction: Double?)] = [("running", 0.4), ("running", nil), ("stopping", 0.7), ("finishing", nil), ("idle", 0.2)]
    private static let progresses: [Double] = [0, 0.15, 0.4, 0.75]

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            grid(native: false)
            grid(native: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
        .task {
            guard let port = StagePreview.capturePort else { return }
            try? await Task.sleep(for: .seconds(2))
            guard let window = Self.shown, let image = StagePreviewCapture.image(of: window) else { return }
            let appearance = UserDefaults.standard.string(forKey: "KiteAppearance") ?? "light"
            await StagePreviewCapture.post("ring-\(appearance).png", image, port: port)
            let layout: [String: Any] = ["scale": window.backingScaleFactor,
                                         "cells": frames.cells.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }]
            if let data = try? JSONSerialization.data(withJSONObject: layout) {
                await StagePreviewCapture.post("ring-\(appearance).json", data, port: port)
            }
            await StagePreviewCapture.post("ring-\(appearance)-done.txt", Data(), port: port)
            NSApp.terminate(nil)
        }
    }

    private func grid(native: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Self.rings.indices, id: \.self) { row in
                let ring = Self.rings[row]
                HStack(spacing: 18) {
                    ForEach(Self.progresses, id: \.self) { progress in
                        Group {
                            if native {
                                ContextRingLayers(phase: ring.phase, fraction: ring.fraction, lineWidth: 3, still: ring.phase == "idle", frozen: progress)
                            } else {
                                ContextRingFrame(phase: ring.phase, fraction: ring.fraction, lineWidth: 3, progress: progress, still: ring.phase == "idle")
                            }
                        }
                        .padding(1.5)
                        .frame(width: 27, height: 27)
                        .frame(width: 60, height: 60)
                    }
                }
            }
            // 标题栏里的样子：有提示时虚化、变淡，叠提示图标
            HStack(spacing: 18) {
                ForEach([PaneNotice?.none, PaneNotice.failure("工作机连不上")], id: \.?.text) { notice in
                    Group {
                        if native {
                            ContextRingLayers(phase: "running", fraction: 0.4, lineWidth: 3, still: false, frozen: 0.15)
                        } else {
                            ContextRingFrame(phase: "running", fraction: 0.4, lineWidth: 3, progress: 0.15, still: false)
                        }
                    }
                    .paneHeaderRing(lineWidth: 3, status: "运行中")
                    .environment(\.paneNotice, notice)
                    .frame(width: 60, height: 60)
                }
            }
            HStack(spacing: 18) {
                ForEach(Self.progresses, id: \.self) { progress in
                    let margin = Metrics.dragBubble * DockPulse.reach
                    Group {
                        if native {
                            DockPulseLayers(color: .accentColor, period: 2.4, margin: margin, still: false, frozen: progress)
                        } else {
                            DockPulseFrame(color: .accentColor, margin: margin, progress: progress)
                        }
                    }
                    .padding(-margin)
                    .frame(width: 36, height: 36)
                    .frame(width: 60, height: 60)
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.cells[native ? "native" : "swiftui"] = $0 }
    }
}

private enum StagePreviewCapture {
    typealias CreateWindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// 自己窗口的图，经窗口服务器合成（含玻璃），不需要录屏权限。
    static func image(of window: NSWindow) -> Data? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateWindowImage.self)
        guard let image = create(.null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
                                 CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue)?
            .takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func post(_ name: String, _ data: Data, port: Int) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(name)")!)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.upload(for: request, from: data)
    }
}
#endif
