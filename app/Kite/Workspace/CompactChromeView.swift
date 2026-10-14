#if os(iOS)
import SwiftUI
import UIKit

/// 只有外壳当前显示的标题栏、控制区读这个盒子；正文和横滑进度不经过它。
@MainActor @Observable final class CompactChromeState {
    var source: CompactPaneHeader?
    var headerHeight: CGFloat = 0
    /// 控制区的玻璃原地显现、消散，见 CompactRowView 的 prepareControlsTransition。
    var controlsMaterialize = false
}

/// 容器和命名空间一直在，窗口切换只替换里面的内容，玻璃由系统做形状交接。
struct CompactSharedHeader: View {
    let chrome: CompactChromeState
    let shell: CompactShellState
    @Namespace private var glass

    var body: some View {
        Group {
            if var source = chrome.source {
                let _ = prepare(&source)
                CompactPaneHeaderBar(source: source, glassNamespace: glass)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if chrome.headerHeight != height { chrome.headerHeight = height }
                    }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .safeAreaPadding(shell.covered)
    }

    private func prepare(_ source: inout CompactPaneHeader) {
        source.environment.paneTopSafeInset = shell.covered.top
        source.environment.windowGeometry = nil
        source.environment.compactSharedGlass = true
    }
}

struct CompactSharedControls: View {
    let chrome: CompactChromeState
    let shell: CompactShellState
    let controls: SharedPaneControls
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            if var source = chrome.source {
                let _ = prepare(&source)
                CompactPaneControlsBar(source: source, controls: controls, keyboardShown: shell.keyboardShown,
                                       glassNamespace: glass, materialize: chrome.controlsMaterialize)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .safeAreaPadding(shell.covered)
    }

    private func prepare(_ source: inout CompactPaneHeader) {
        source.environment.homeIndicatorInset = shell.home
        source.environment.windowGeometry = nil
        source.environment.compactSharedGlass = true
    }
}

/// 原生输入区只把高度变化、焦点事件交给外面的玻璃；effort 展开仍在原生输入区里排。
@MainActor @Observable final class CompactComposerState {
    var sizeRevision = 0
    var typing = false
    @ObservationIgnored let reservesSwipe: @MainActor (CGPoint) -> Bool

    init(bar: ControlsBarView) {
        reservesSwipe = { [weak bar] point in
            guard let bar else { return false }
            return bar.effortFrame.contains(bar.convert(point, from: nil))
        }
    }
}

struct CompactNativeControls: View {
    let bar: ControlsBarView
    let state: CompactComposerState

    var body: some View {
        PaneControlsBar(controls: NativeComposerHost(bar: bar, sizeRevision: state.sizeRevision)
            .frame(maxWidth: Metrics.transcriptWidth)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Metrics.controlRadius)),
                        typing: state.typing)
            .environment(\.nativePaneSwipeReservation, state.reservesSwipe)
    }
}

/// 输入区是会话手里的同一个原生视图，每个宿主各给一个容器装它：换窗口的淡出途中滑回来时，淡出的旧宿主和新宿主同时在，
/// 输入区挪进后接手的那个，旧宿主拆掉时它已不在里面，带不走。
private struct NativeComposerHost: UIViewRepresentable {
    let bar: ControlsBarView
    let sizeRevision: Int

    func makeUIView(context: Context) -> ComposerContainer { ComposerContainer(bar: bar) }
    func updateUIView(_ view: ComposerContainer, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerContainer, context: Context) -> CGSize? {
        let width = proposal.width ?? Metrics.transcriptWidth
        return CGSize(width: width, height: bar.height(forWidth: width))
    }
}

private final class ComposerContainer: UIView {
    let bar: ControlsBarView

    init(bar: ControlsBarView) {
        self.bar = bar
        super.init(frame: .zero)
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 被后接手的容器挪走了就不再管它
        if bar.superview === self, bar.frame != bounds { bar.frame = bounds }
    }
}

struct CompactThreadStatus: View {
    @Environment(WorkThread.self) private var thread
    @Environment(WorkArea.self) private var area
    @Environment(AppModel.self) private var model

    var body: some View {
        ThreadStatusRing().environment(\.paneNotice,
            model.connectionNotice(model.connection(for: area)) ?? model.threadNotice(thread, in: area))
    }
}
#endif
