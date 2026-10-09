import SwiftUI

/// 还没有消息的会话：选用模板的点阵签名铺满整个窗口，连同标题栏和输入区后面；标题压在中间，模板在标题栏副标题里选，
/// 背后的图案收弱，标题栏一带也稍收弱，输入区是玻璃，不收。
/// 指针（触屏是手指）划过时图案跟着起反应，打字时更活跃；第一条消息发出、对话出现时图案收回。
/// Mac 上指针在整个窗口里移动都算，由 ThreadPane 报给同一个 slot。
/// 签名缺失或随模板修改过期时请工作机补上，生成好之前先用默认图案。
struct NewThreadStage: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(WorkThread.self) private var thread
    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.self) private var environment
    @Environment(\.paneWindowFrame) private var window
    let slot: String
    /// 模板读取或套用失败的说明，套用由标题栏的模板菜单发起。
    @Binding var templateError: String?
    @State private var center: CGRect?
    @State private var content: CGRect?
    /// 解析好的签名；body 随打字和窗口拖动频繁重算，只在签名或主题色变化时重新解析表达式。
    @State private var pattern: DotPattern?

    /// 标题栏一带留多少：标题文字压在上面，又不能把这一截压得太空。
    private static let headerFloor = 0.45

    private struct PatternSource: Equatable {
        let design: EmblemDesign?
        let accent: DotColor
    }

    var body: some View {
        let template = model.newThreadTemplate(for: thread, in: area)
        ZStack {
            DotPatternArea(pattern: pattern, quiet: quiet, area: window, slot: slot)
            VStack(spacing: 14) {
                Text("说说要做什么")
                    .font(Theme.heading1)
                if let templateError {
                    HStack(spacing: 8) {
                        Text(templateError).foregroundStyle(Theme.danger).lineLimit(2)
                        Button("重新读取") { Task { await loadTemplates() } }
                            .buttonStyle(.borderless).foregroundStyle(Color.accentColor).clickPointer()
                    }
                    .font(Theme.caption)
                    .multilineTextAlignment(.center)
                }
                if template?.emblemState == "generating" {
                    Text("正在为这个模板画点阵签名…")
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .animation(.easeOut(duration: 0.2), value: template?.emblemState)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: DotCarrier.coordinateSpace(carrier))
            } action: { center = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: DotCarrier.coordinateSpace(carrier))
        } action: { content = $0 }
        #if os(iOS)
        .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { stage?.patternPointer($0.location, slot: slot) }
            .onEnded { _ in stage?.patternPointer(nil, slot: slot) })
        #endif
        .onChange(of: thread.draft) { stage?.patternKeystroke(slot: slot) }
        .onChange(of: PatternSource(design: template?.emblem?.design, accent: DotColor(Color.accentColor.resolve(in: environment))),
                  initial: true) { _, source in
            pattern = source.design?.pattern(accent: source.accent) ?? EmblemDesign.fallback.pattern(accent: source.accent)
        }
        .task(id: template.map { "\($0.id):\($0.revision):\($0.emblemState ?? "")" }) { await ensureEmblem(template) }
        .task(id: model.revision(for: area)) { await loadTemplates() }
    }

    private func loadTemplates() async {
        do { try await model.refreshContextTemplates(in: area); templateError = nil }
        catch is CancellationError { }
        catch { templateError = error.localizedDescription }
    }

    private var quiet: [PatternQuiet] {
        var result = center.map { [PatternQuiet(rect: $0)] } ?? []
        if let window, let content, content.minY > window.minY {
            result.append(PatternQuiet(rect: CGRect(x: window.minX, y: window.minY, width: window.width, height: content.minY - window.minY),
                                       floor: Self.headerFloor))
        }
        return result
    }

    /// 签名缺失或过期时请工作机补上；失败不打扰，留着默认图案。
    private func ensureEmblem(_ template: ContextTemplate?) async {
        guard let template, ["missing", "stale"].contains(template.emblemState ?? ""), model.isConnected(area) else { return }
        try? await model.generateTemplateEmblem(template, force: false, connection: model.revision(for: area))
    }
}
