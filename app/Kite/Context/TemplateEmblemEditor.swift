import SwiftUI

/// 角色编辑器里的点阵签名：动画预览、表达式、正负两种颜色与点的形状。手改后随角色一起保存，之后不再被自动生成替换；
/// 「重新生成」交给模型按提示词重画，连手改过的一起替换。
struct TemplateEmblemField: View {
    @Binding var design: EmblemDesign
    /// 工作机上的最新状态；新角色还没有。
    let role: AgentRole?
    var regenerate: (() -> Void)?
    @Environment(\.self) private var environment
    /// 表达式改到一半无效时，预览停在上一个有效的图案。
    @State private var shown: DotPattern?
    @State private var error: String?

    private var generating: Bool { role?.emblemState == "generating" }

    var body: some View {
        CardField(label: "点阵签名", note: note) {
            VStack(alignment: .leading, spacing: 10) {
                EmblemPreview(pattern: shown)
                TextField("表达式", text: $design.expression, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.code)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                if let error {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                }
                HStack(spacing: 8) {
                    colorMenu("正值", selection: $design.positive)
                    colorMenu("负值", selection: $design.negative)
                    Menu {
                        Picker("形状", selection: $design.form) {
                            ForEach(DotForm.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: {
                        Text("形状：\(DotForm(rawValue: design.form)?.title ?? design.form)")
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                    if let regenerate {
                        if generating { CardSpinner() }
                        Button("重新生成", systemImage: "sparkles", action: regenerate)
                            .disabled(generating)
                    }
                }
                .font(Theme.secondary)
                .buttonStyle(.borderless)
            }
            .padding(12)
        }
        .onChange(of: design, initial: true) { update() }
        .onChange(of: environment.colorScheme) { update() }
    }

    private var note: String {
        let help = "变量：t 秒，x y 格坐标，r a 极坐标，d 到指针的距离，k 打字活跃度。"
        switch role?.emblemState {
        case "generating": return "正在按提示词生成签名。" + help
        case "failed": return "生成失败：\(role?.emblemError ?? "未知原因")。" + help
        case "stale": return "提示词已修改，签名会随之重新生成。" + help
        default:
            if role == nil || role?.emblem == nil { return "保存后由模型按提示词生成；手改后保留手改的版本。" + help }
            if role?.emblem?.source == "manual" { return "手改过的签名不会被自动替换。" + help }
            return help
        }
    }

    private func update() {
        do {
            _ = try DotExpression(design.expression)
            error = nil
            shown = design.pattern(accent: DotColor(Color.accentColor.resolve(in: environment)))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func colorMenu(_ title: String, selection: Binding<String>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(EmblemDesign.letters, id: \.self) { Text(EmblemDesign.letterTitles[$0] ?? $0).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text("\(title)：\(EmblemDesign.letterTitles[selection.wrappedValue] ?? selection.wrappedValue)")
        }
        .fixedSize()
    }
}

/// 弹窗里没有窗口点阵，预览自带一块舞台和取景框。指针划过时图案跟着起反应。
private struct EmblemPreview: View {
    let pattern: DotPattern?
    @State private var stage = DotStage()
    @State private var slot = "preview.\(UUID().uuidString)"

    var body: some View {
        ZStack {
            DotCanvas()
            DotPatternArea(pattern: pattern, slot: slot)
        }
        .environment(\.dotStage, stage)
        .environment(\.dotCarrier, nil)
        .frame(height: DotMetrics.pitch * 16)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        #if os(macOS)
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case .active(let point) = phase { stage.patternPointer(point, slot: slot) }
            else { stage.patternPointer(nil, slot: slot) }
        }
        #else
        .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { stage.patternPointer($0.location, slot: slot) }
            .onEnded { _ in stage.patternPointer(nil, slot: slot) })
        #endif
        .accessibilityHidden(true)
    }
}
