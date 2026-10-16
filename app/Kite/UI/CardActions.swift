import SwiftUI

/// 按钮里的加载转圈：照系统转圈的样子画辐条，颜色跟着按钮文字。
/// 不用 ProgressView：Mac 上它按外观自己取色，在玻璃按钮上会先灰后黑。
struct CardSpinner: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let spokes = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Double(spokes), paused: reduceMotion)) { timeline in
            // 一秒转一圈，最亮的一根顺时针前进，后面的逐根变淡
            let lead = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * Double(spokes)) % spokes
            ZStack {
                ForEach(0..<spokes, id: \.self) { index in
                    let age = (lead - index + spokes) % spokes
                    Capsule()
                        .frame(width: size * 0.13, height: size * 0.3)
                        .offset(y: -size * 0.32)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(spokes)))
                        .opacity(1 - Double(age) / Double(spokes) * 0.8)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("正在处理")
    }
}

/// 一次提交的进度，主按钮据此变样子。
enum CardPhase: Equatable {
    case idle, working, succeeded
    /// 失败的原因，和重试要做的事。
    case failed(String, retry: () -> Void)

    var working: Bool { self == .working }
    var error: String? { if case .failed(let message, _) = self { message } else { nil } }

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.idle, .idle), (.working, .working), (.succeeded, .succeeded): true
        case let (.failed(x, _), .failed(y, _)): x == y
        default: false
        }
    }
}

extension Binding where Value == CardPhase {
    /// 跑一次请求：期间是加载态，失败记下原因、重试再跑同一件事。succeeds 为真时成功后停在成功态（保存后弹窗不关的），
    /// 否则回到平常（读取这类，或成功后弹窗直接关掉的）。
    func run(succeeds: Bool = false, _ action: @escaping () async throws -> Void) {
        guard !wrappedValue.working else { return }
        wrappedValue = .working
        Task {
            do {
                try await action()
                wrappedValue = succeeds ? .succeeded : .idle
            } catch {
                wrappedValue = .failed(error.localizedDescription) { run(succeeds: succeeds, action) }
            }
        }
    }
}

/// 卡片底部的按钮：主按钮占满剩下的宽度。iPhone 键盘升起时最左边多一个收起键盘。
/// 给了 phase 时主按钮跟着进度变：加载中转圈；成功打勾，直到再次能提交（又改了内容）才变回来；
/// 失败变成错误色，按钮里一行写原因，点它把完整原因复制到剪贴板，左边冒出圆形的重试。几个状态之间的形变交给玻璃效果的容器。
struct CardActions: View {
    let primary: String
    /// 主按钮文字前面的图标。
    var icon: Image?
    var enabled: Bool
    var phase: Binding<CardPhase>
    var succeeded: String
    var working: String?
    let action: () -> Void
    var succeededAction: (() -> Void)?
    @Namespace private var glass
    /// 刚复制了报错，按钮里短暂换成已复制。
    @State private var copied = false

    init(primary: String, icon: Image? = nil, enabled: Bool = true,
         phase: Binding<CardPhase>, succeeded: String = "已保存", working: String? = nil,
         action: @escaping () -> Void, succeededAction: (() -> Void)? = nil) {
        self.primary = primary
        self.icon = icon
        self.enabled = enabled
        self.phase = phase
        self.succeeded = succeeded
        self.working = working
        self.action = action
        self.succeededAction = succeededAction
    }

    var body: some View {
        let state = phase.wrappedValue
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                #if os(iOS)
                if ScreenKeyboard.shared.shown {
                    // 等按钮松手这次更新过去再收，同 KeyboardDismissButton
                    Button { Task { dismissKeyboard() } } label: {
                        Image(systemName: KeyboardDismissButton.icon).accessibilityLabel("收起键盘")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .glassEffectID("keyboard", in: glass)
                }
                #endif
                if case .failed(_, let retry) = state {
                    Button(action: retry) {
                        Image(systemName: "arrow.clockwise").accessibilityLabel("重试")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("重试")
                    .glassEffectID("retry", in: glass)
                }
                main(state).glassEffectID("primary", in: glass)
            }
            .font(Theme.body.weight(.semibold))
            .controlSize(InputMode.current.actionControlSize)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.snappy, value: state)
        .onChange(of: enabled) { _, enabled in
            if enabled, phase.wrappedValue == .succeeded { phase.wrappedValue = .idle }
        }
    }

    private func main(_ state: CardPhase) -> some View {
        Button {
            if let message = state.error { copy(message) }
            else if state == .succeeded { succeededAction?() }
            else { action() }
        } label: {
            ZStack {
                switch state {
                case .idle:
                    Group {
                        if let icon { Label { Text(primary) } icon: { icon } } else { Text(primary) }
                    }
                    .transition(.blurReplace)
                case .working:
                    HStack(spacing: 8) {
                        CardSpinner()
                        if let working { Text(working) }
                    }
                    .transition(.blurReplace)
                case .succeeded:
                    Label(succeeded, systemImage: "checkmark").transition(.blurReplace)
                case .failed(let message, _):
                    Label {
                        Text(copied ? "已复制报错" : message).lineLimit(1).truncationMode(.tail)
                            .contentTransition(.interpolate)
                    } icon: {
                        Image(systemName: copied ? "checkmark" : "exclamationmark.triangle.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help("\(message)\n点按复制")
                    .transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // 成功状态只在调用方提供后续动作时可点。
        .disabled(state == .idle && !enabled)
        .allowsHitTesting(state != .working && (state != .succeeded || succeededAction != nil))
        .tint(state.error != nil ? Theme.danger : nil)
        .buttonStyle(.glassProminent)
    }

    private func copy(_ message: String) {
        copyToPasteboard(message, toast: nil)
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy) { copied = false }
        }
    }
}

#if DEBUG
/// Debug build 带 --card-actions-preview 启动，窗口里只放底部按钮的演示，不连接服务：
/// 保存模拟一次 1.5 秒的请求，结果按选的来；成功后打开「有改动」变回保存。
struct CardActionsPreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--card-actions-preview") }

    @State private var phase = CardPhase.idle
    @State private var fails = true
    @State private var changed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("请求失败", isOn: $fails)
            Toggle("有改动（成功后打开，按钮变回保存）", isOn: $changed)
            Spacer(minLength: 0)
            CardActions(primary: "保存", enabled: changed, phase: $phase) {
                $phase.run(succeeds: true) {
                    try await Task.sleep(for: .seconds(1.5))
                    if fails { throw KitedError(message: "工作机连接已断开：请求 /instances/agent/execution-grants 超时（25 秒），请检查组网状态与 kited 是否仍在运行后重试。") }
                    changed = false
                }
            }
        }
        .padding(CardMetrics.sheetInset)
        .frame(maxWidth: 400, maxHeight: 320)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous))
        .padding(CardMetrics.sheetInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
#endif

extension View {
    /// Debug build 带 --card-actions-preview 启动时用按钮演示换掉整个窗口的内容，原内容（连同其中的服务连接）不再创建。
    @ViewBuilder func cardActionsPreview() -> some View {
        #if DEBUG
        if CardActionsPreview.enabled { CardActionsPreview() } else { self }
        #else
        self
        #endif
    }
}
