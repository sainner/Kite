import SwiftUI

extension View {
    /// Debug build 带 --composer-preview 启动时主窗口空着，会话输入区的新旧对照另开一个窗口，见 ComposerPreview。
    @ViewBuilder func composerPreview() -> some View {
        #if DEBUG && os(macOS)
        if ComposerPreview.enabled { Color.clear } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG && os(macOS)
import AppKit
import os

private let log = Logger(subsystem: "kite.composer-preview", category: "capture")

/// 会话输入区的新旧对照：同一个会话、同样的卡片底，左边 SwiftUI 版（PaneControlsBar 套 ThreadControls），右边 Mac 宽屏的原生版
/// （MacControlsBar），一次一种状态，左右切换。不建工作区、不发请求，按钮不做事。
/// 带 --capture-port <端口> 时依次摆好每种状态，抓自己窗口的图（不需要录屏权限）和两格的位置 POST 到本机这个端口，抓完退出；
/// 深色外观加 -KiteAppearance dark 启动。
struct ComposerPreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--composer-preview") }
    static var capturePort: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--capture-port"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    /// 对照放在自己开的 AppKit 窗口里：脚本启动时 SwiftUI 的主窗口有时不开（没有可恢复的状态，点停靠栏重开也不开，原因没查清）。
    /// 主窗口开出来时是空的，见 composerPreview。外观按 -KiteAppearance。
    static func openWindow(model: AppModel) {
        DispatchQueue.main.async {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.identifier = NSUserInterfaceItemIdentifier(windowID)
            window.isReleasedWhenClosed = false
            switch UserDefaults.standard.string(forKey: "KiteAppearance") {
            case "dark": window.appearance = NSAppearance(named: .darkAqua)
            case "light": window.appearance = NSAppearance(named: .aqua)
            default: break
            }
            window.contentView = NSHostingView(rootView: ComposerPreview().environment(model))
            window.center()
            window.orderFrontRegardless()
            shown = window
        }
    }

    private static let windowID = "composer-preview"
    private static var shown: NSWindow?

    @Environment(AppModel.self) private var model
    @State private var scene = ComposerPreviewScene()
    @State private var frames = ComposerPreviewFrames()
    @State private var index = 0
    @State private var started = false

    var body: some View {
        let state = ComposerPreviewState.all[index]
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("输入区对照 · \(state.title)").font(Theme.title)
                Text("左 SwiftUI 版，右原生版").font(Theme.secondary).foregroundStyle(.secondary)
                Spacer()
                Button("上一种") { show(index - 1) }.disabled(index == 0)
                Button("下一种") { show(index + 1) }.disabled(index == ComposerPreviewState.all.count - 1)
            }
            HStack(alignment: .top, spacing: 24) {
                ComposerPreviewCell(native: false, width: state.width, frames: frames)
                ComposerPreviewCell(native: true, width: state.width, frames: frames)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .environment(scene.thread)
        .environment(scene.area)
        .onAppear {
            show(0)
            guard !started, let port = Self.capturePort else { return }
            started = true
            let frames = frames
            Task { @MainActor in await capture(port: port, frames: frames) }
        }
    }

    private func show(_ index: Int) {
        let index = min(max(index, 0), ComposerPreviewState.all.count - 1)
        self.index = index
        ComposerPreviewState.all[index].apply(scene.thread, voice: model.voice)
    }

    private func capture(port: Int, frames: ComposerPreviewFrames) async {
        let dark = Self.shown?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance = (UserDefaults.standard.string(forKey: "KiteAppearance") ?? (dark ? "dark" : "light"))
            + (ControlsBarVariant.noGlass ? "-noglass" : "")
            + (ProcessInfo.processInfo.arguments.contains("--composer-inactive") ? "-inactive" : "")
        try? await Task.sleep(for: .seconds(2))
        for (index, state) in ComposerPreviewState.all.enumerated() {
            show(index)
            // 不让哪个输入框有焦点：现版启动时第一个输入框会拿到焦点，画出插入点
            Self.shown?.makeFirstResponder(nil)
            // --composer-inactive：比 App 不在前台、窗口不是主窗口时的样子
            if ProcessInfo.processInfo.arguments.contains("--composer-inactive") { NSApp.deactivate() }
            try? await Task.sleep(for: .milliseconds(800))
            guard let window = Self.shown, let image = ComposerPreviewCapture.image(of: window) else {
                log.error("抓不到窗口 \(NSApp.windows.count)")
                continue
            }
            let name = "\(appearance)-\(String(format: "%02d", index))-\(state.id)"
            await ComposerPreviewCapture.post("\(name).png", image, port: port)
            let layout: [String: Any] = [
                "scale": window.backingScaleFactor,
                "cells": frames.cells.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
                "fields": ComposerPreviewCapture.fieldReport(in: window),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys]) {
                await ComposerPreviewCapture.post("\(name).json", data, port: port)
            }
        }
        await ComposerPreviewCapture.post("\(appearance)-done.txt", Data(), port: port)
        NSApp.terminate(nil)
    }
}

/// 两格在窗口里的位置（SwiftUI 的 .global，左上角起）。
@Observable private final class ComposerPreviewFrames {
    @ObservationIgnored var cells: [String: CGRect] = [:]
}

private struct ComposerPreviewCell: View {
    let native: Bool
    let width: CGFloat
    let frames: ComposerPreviewFrames
    @FocusState private var typing: Bool
    @Environment(WorkThread.self) private var thread
    @Environment(WorkArea.self) private var area

    var body: some View {
        let disabled = area.creatingWindow != nil || thread.configuringTemplate
        // 同 PaneWindow：内容铺满，底栏用 safeAreaBar 压在下面；卡片底和字垫在整格后面，玻璃后面也有字
        Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if native {
                MacControlsBar(typing: $typing, send: Self.send, voiceOwner: ComposerPreviewScene.voiceOwner)
                    .disabled(disabled)
            } else {
                PaneControlsBar(controls: ThreadControls(typing: $typing, send: Self.send, voiceOwner: ComposerPreviewScene.voiceOwner)
                    .disabled(disabled)
                    .frame(maxWidth: Metrics.transcriptWidth), typing: typing)
            }
        }
        .frame(width: width, height: 320)
        .background(alignment: .bottomLeading) {
            ZStack(alignment: .bottomLeading) {
                Theme.card
                // 不画玻璃时只比内容，后面不垫字
                if !ControlsBarVariant.noGlass { backdrop }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.cells[native ? "native" : "swiftui"] = $0 }
    }

    /// 玻璃后面垫几行字，看模糊和折射对不对得上。
    private var backdrop: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<14, id: \.self) { line in
                Text(line % 3 == 0 ? "玻璃后面的一行字，用来看模糊和折射 The quick brown fox \(line)" : "第 \(line) 行 · 对话从输入区后面滚过去")
                    .font(line % 2 == 0 ? Theme.body : Theme.secondary)
                    .foregroundStyle(line % 4 == 1 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
        }
        .padding(16)
    }

    private static func send(_ message: Message, alongside: @escaping () -> Void) { alongside() }
}

/// 对照用的会话：草稿会话，没有工作机。
@Observable private final class ComposerPreviewScene {
    static let voiceOwner = "composer-preview"
    let thread = WorkThread(workspace: "composer-preview", project: "对照")
    let area = WorkArea()
}

/// 一种状态：草稿、在不在跑、能不能停和继续、录不录音、整块禁用，和卡片宽。
private struct ComposerPreviewState {
    let id: String
    let title: String
    var width: CGFloat = 560
    var draft = ""
    var running = false
    var interrupt = false
    var resume = false
    var connected = true
    var listening = false
    var disabled = false

    func apply(_ thread: WorkThread, voice: VoiceInput) {
        thread.connected = connected
        thread.configuringTemplate = disabled
        thread.transcript = Transcript(root: "", running: running)
        let state = """
            {"phase":"\(running ? "running" : "idle")","busy":\(running),"status":"open","error":null,"waitingForResume":false,
             "capabilities":{"send":true,"interrupt":\(interrupt),"resume":\(resume),"cancel":false}}
            """
        thread.state = interrupt || resume ? try? JSONDecoder().decode(RemoteState.self, from: Data(state.utf8)) : nil
        thread.draft = draft
        voice.previewOwner(listening ? ComposerPreviewScene.voiceOwner : nil)
    }

    private static let long = "第三行稍微长一点，看看折行的位置和原来是不是一样：the quick brown fox jumps over the lazy dog，再长一点再长一点。"

    static let all: [ComposerPreviewState] = [
        ComposerPreviewState(id: "empty", title: "空草稿"),
        ComposerPreviewState(id: "one-line", title: "一行草稿", draft: "帮我看一下这个函数为什么慢"),
        ComposerPreviewState(id: "multi-line", title: "多行草稿", draft: "第一行\n第二行\n" + long),
        ComposerPreviewState(id: "trailing-newline", title: "末尾换行", draft: "末尾有一个换行\n"),
        ComposerPreviewState(id: "eight-lines", title: "八行", draft: (1...8).map { "第 \($0) 行" }.joined(separator: "\n")),
        ComposerPreviewState(id: "nine-lines", title: "九行（框里滚）", draft: (1...9).map { "第 \($0) 行" }.joined(separator: "\n")),
        ComposerPreviewState(id: "running", title: "运行中，空草稿", running: true, interrupt: true),
        ComposerPreviewState(id: "running-draft", title: "运行中，有草稿", draft: "插一句话", running: true, interrupt: true),
        ComposerPreviewState(id: "stop-disabled", title: "运行中，断开连接", draft: "插一句话", running: true, interrupt: true, connected: false),
        ComposerPreviewState(id: "resume", title: "可继续", resume: true),
        ComposerPreviewState(id: "resume-draft", title: "可继续，有草稿", draft: "继续之前先补一句", resume: true),
        ComposerPreviewState(id: "listening", title: "录音中", draft: "语音识别出来的字", listening: true),
        ComposerPreviewState(id: "disabled", title: "整块禁用", draft: "建窗口中", disabled: true),
        ComposerPreviewState(id: "wide", title: "宽卡片（玻璃 720 居中）", width: 820, draft: "宽卡片里玻璃最宽 720，居中"),
        ComposerPreviewState(id: "narrow-buttons", title: "窄卡片，停止、继续、发送都在", width: 220, draft: "窄", running: true, interrupt: true, resume: true),
        ComposerPreviewState(id: "narrow-168", title: "最窄卡片", width: 168, draft: "窄"),
        ComposerPreviewState(id: "narrow-176", title: "窄卡片 176", width: 176, draft: "窄"),
        ComposerPreviewState(id: "narrow-184", title: "窄卡片 184", width: 184, draft: "窄"),
        ComposerPreviewState(id: "narrow-192", title: "窄卡片 192", width: 192, draft: "窄"),
    ]
}

private enum ComposerPreviewCapture {
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

    private static func resolve(_ color: NSColor?, _ name: NSAppearance.Name) -> String {
        guard let color else { return "-" }
        var text = ""
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) {
                text = String(format: "%.3f,%.3f,%.3f,%.3f", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
            }
        }
        return text
    }

    /// 两个输入框的类、位置（窗口坐标，左上角起）、字体和字段编辑器的配置。
    static func fieldReport(in window: NSWindow) -> [[String: String]] {
        guard let root = window.contentView else { return [] }
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap(fields)
        }
        return fields(root).map { field in
            var report = [
                "class": String(describing: type(of: field)),
                "frame": "\(field.convert(field.bounds, to: root))",
                "font": field.font?.description ?? "",
                "textColor": field.textColor?.description ?? "",
                "placeholder": field.placeholderString ?? "",
                "enabled": "\(field.isEnabled)",
                "attributes": field.attributedStringValue.length > 0
                    ? "\(field.attributedStringValue.attributes(at: 0, effectiveRange: nil))" : "",
                "placeholderAttributes": "\(field.placeholderAttributedString.map { $0.length > 0 ? "\($0.attributes(at: 0, effectiveRange: nil))" : "" } ?? "nil")",
                "windowKey": "\(field.window?.isKeyWindow ?? false)",
            ]
            if let editor = field.cell?.fieldEditor(for: field) {
                report["editor"] = "insertion=\(editor.insertionPointColor) selected=\(editor.selectedTextAttributes) "
                    + "quotes=\(editor.isAutomaticQuoteSubstitutionEnabled) dashes=\(editor.isAutomaticDashSubstitutionEnabled) "
                    + "spelling=\(editor.isContinuousSpellCheckingEnabled) grammar=\(editor.isGrammarCheckingEnabled) "
                    + "autocorrect=\(editor.isAutomaticSpellingCorrectionEnabled) replacement=\(editor.isAutomaticTextReplacementEnabled) "
                    + "completion=\(editor.isAutomaticTextCompletionEnabled) smartInsert=\(editor.smartInsertDeleteEnabled) "
                    + "links=\(editor.isAutomaticLinkDetectionEnabled) data=\(editor.isAutomaticDataDetectionEnabled) "
                    + "undo=\(editor.allowsUndo) rich=\(editor.isRichText) tk2=\(editor.textLayoutManager != nil) "
                    + "writingTools=\(editor.writingToolsBehavior.rawValue) inline=\(editor.inlinePredictionType.rawValue)"
                let selection = editor.selectedTextAttributes[.backgroundColor] as? NSColor
                report["colors"] = ["insertion": editor.insertionPointColor, "selection": selection,
                                    "selectedTextBackground": NSColor.selectedTextBackgroundColor, "controlAccent": NSColor.controlAccentColor,
                                    "accentAsset": NSColor(named: "AccentColor")]
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key) light=\(resolve($0.value, .aqua)) dark=\(resolve($0.value, .darkAqua))" }
                    .joined(separator: "; ")
            }
            return report
        }
    }
}
#endif
