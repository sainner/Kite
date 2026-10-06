import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 点阵的可调参数：静息点色、效果色、波的终态与参数。默认值就是代码与颜色资源里的取值；
/// 调试构建里可以在调试面板实时调整，调过的值存在本机，定下来后再写回代码。
@MainActor @Observable
final class DotTuning {
    static let shared = DotTuning()

    nonisolated struct Values: Codable, Equatable {
        /// nil 时取颜色资源 DotRest。
        var restLight: DotColor?
        var restDark: DotColor?
        var palette = DotColor.palette
        /// 波的单一颜色；nil 时每格从效果色里固定取一色。
        var waveColor: DotColor?
        var form = DotForm.square
        var wave = DotWave.Parameters()
    }

    var values = Values() {
        didSet { save() }
    }

    /// 循环发测试波。
    var looping = false {
        didSet { looping ? startLoop() : loop?.cancel() }
    }

    @ObservationIgnored private var stages: [Weak] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    private static let key = "kite.debug.dotTuning"

    private struct Weak {
        weak var stage: DotStage?
    }

    private init() {
        #if DEBUG
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Values.self, from: data) {
            values = saved
        }
        #endif
    }

    func attach(_ stage: DotStage) {
        stages.removeAll { $0.stage == nil }
        stages.append(Weak(stage: stage))
    }

    /// 在每个 App 窗口底部中间（控制区的位置）发一道波。
    func emitTestWave() {
        for stage in stages.compactMap(\.stage) where !stage.bounds.isEmpty {
            let bounds = stage.bounds
            stage.emitWave(from: CGRect(x: bounds.midX - 160, y: bounds.maxY - 96, width: 320, height: 72))
        }
    }

    /// 写回代码时要改的值。
    var summary: String {
        let rest = { (color: DotColor?) in color.map { "\($0.hex) α\(String(format: "%.3f", $0.alpha))" } ?? "颜色资源" }
        let wave = values.wave
        return """
        静息点色：浅色 \(rest(values.restLight))，深色 \(rest(values.restDark))
        波的颜色：\(values.waveColor.map { "单色 \($0.hex)" } ?? "效果色 " + values.palette.map(\.hex).joined(separator: " "))
        波：终态 \(values.form.title)，速度 \(Int(wave.speed)) 点/秒，半宽 \(String(format: "%.1f", wave.width)) 点，\
        距离 \(Int(wave.reach)) 点，\(String(format: "%.2f", wave.fadeStart)) 处开始变弱，峰值 \(String(format: "%.2f", wave.peak))，\
        颜色不透明度 \(String(format: "%.2f", wave.opacity))
        """
    }

    private func save() {
        #if DEBUG
        if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: Self.key) }
        #endif
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                emitTestWave()
                try? await Task.sleep(for: .seconds(values.wave.duration + 0.4))
            }
        }
    }
}

#if DEBUG
/// 点阵调试面板：改动立刻作用到所有 App 窗口的背景点阵。Mac 在「调试」菜单打开，iPhone 在侧边栏底部。
struct DotTuningPanel: View {
    @Bindable private var tuning = DotTuning.shared
    @Environment(\.self) private var environment
    @State private var copied = false

    var body: some View {
        Form {
            Section("静息点色") {
                restRow("浅色", \.restLight, scheme: .light)
                restRow("深色", \.restDark, scheme: .dark)
                Button("恢复颜色资源") {
                    tuning.values.restLight = nil
                    tuning.values.restDark = nil
                }
            }
            Section("波的颜色") {
                Picker("取色", selection: Binding { tuning.values.waveColor != nil } set: { single in
                    tuning.values.waveColor = single ? DotColor.palette.last : nil
                }) {
                    Text("效果色（每格一色）").tag(false)
                    Text("单色").tag(true)
                }
                if let color = tuning.values.waveColor {
                    ColorPicker("颜色", selection: Binding { color.color } set: { new in
                        var next = DotColor(new.resolve(in: environment))
                        next.alpha = 1
                        tuning.values.waveColor = next
                    }, supportsOpacity: false)
                } else {
                    HStack {
                        ForEach(tuning.values.palette.indices, id: \.self) { index in
                            ColorPicker("效果色 \(index + 1)", selection: paletteBinding(index), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    Button("恢复默认") { tuning.values.palette = DotColor.palette }
                }
            }
            Section("波") {
                Picker("终态", selection: $tuning.values.form) {
                    ForEach(DotForm.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                slider("速度（点/秒）", \.speed, 60...2400, format: "%.0f")
                slider("波前半宽（点）", \.width, 6...160, format: "%.1f")
                slider("传播距离（点）", \.reach, 120...2400, format: "%.0f")
                slider("开始变弱处", \.fadeStart, 0...1, format: "%.2f")
                slider("峰值", \.peak, 0...1, format: "%.2f")
                slider("颜色不透明度", \.opacity, 0...1, format: "%.2f")
                Button("恢复默认") {
                    tuning.values.wave = DotWave.Parameters()
                    tuning.values.form = .square
                }
            }
            Section {
                Button("发一道波") { tuning.emitTestWave() }
                Toggle("循环发波", isOn: $tuning.looping)
                Button(copied ? "已复制" : "复制当前参数") { copy() }
                Button("全部恢复默认", role: .destructive) { tuning.values = DotTuning.Values() }
            } footer: {
                Text(tuning.summary).font(Theme.caption).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func restRow(_ title: String, _ key: WritableKeyPath<DotTuning.Values, DotColor?>,
                         scheme: ColorScheme) -> some View {
        var resolving = environment
        resolving.colorScheme = scheme
        let fallback = DotColor(Theme.dotRest.resolve(in: resolving))
        let current = tuning.values[keyPath: key] ?? fallback
        return VStack(alignment: .leading, spacing: 6) {
            ColorPicker(title, selection: Binding {
                var opaque = current
                opaque.alpha = 1
                return opaque.color
            } set: { color in
                var next = DotColor(color.resolve(in: environment))
                next.alpha = current.alpha
                tuning.values[keyPath: key] = next
            }, supportsOpacity: false)
            HStack {
                Text("透明度").font(Theme.secondary).foregroundStyle(.secondary)
                Slider(value: Binding { current.alpha } set: { alpha in
                    var next = current
                    next.alpha = alpha
                    tuning.values[keyPath: key] = next
                }, in: 0...0.5)
                Text(String(format: "%.3f", current.alpha)).font(Theme.code).monospacedDigit()
            }
        }
    }

    private func paletteBinding(_ index: Int) -> Binding<Color> {
        Binding {
            tuning.values.palette[index].color
        } set: { color in
            var next = DotColor(color.resolve(in: environment))
            next.alpha = 1
            tuning.values.palette[index] = next
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<DotWave.Parameters, Double>,
                        _ range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, tuning.values.wave[keyPath: key])).font(Theme.code).monospacedDigit()
            }
            Slider(value: Binding { tuning.values.wave[keyPath: key] } set: { tuning.values.wave[keyPath: key] = $0 },
                   in: range)
        }
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tuning.summary, forType: .string)
        #else
        UIPasteboard.general.string = tuning.summary
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
#endif
