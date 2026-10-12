import SwiftUI

/// 控制区横滑切窗口：track 跟手，end 松手（位移、预测位移），cancel 中途作罢。紧凑布局的 PaneRow 建好就不再换。
struct PaneSwipeActions {
    let track: @MainActor (CGFloat) -> Void
    let end: @MainActor (CGFloat, CGFloat) -> Void
    let cancel: @MainActor () -> Void
}

extension EnvironmentValues {
    /// 紧凑布局提供；宽屏没有，控制区不接横滑。
    @Entry var paneSwipe: PaneSwipeActions?
}

private struct PaneControlsFocus: FocusedValueKey {
    typealias Value = UUID
}

private extension FocusedValues {
    var paneControls: UUID? {
        get { self[PaneControlsFocus.self] }
        set { self[PaneControlsFocus.self] = newValue }
    }
}

private struct PaneSwipeReservations: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// 控件自己要横向拖动时，保留起手区域，避免调节控件同时切换窗口。
    func reservesPaneSwipe() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: PaneSwipeReservations.self, value: [geometry.frame(in: .global)])
            }
        }
    }
}

struct PaneControlSwipe: ViewModifier {
    let typing: Bool
    @Environment(\.paneSwipe) private var paneSwipe
    @Environment(\.keyboardShown) private var keyboardShown
    @FocusedValue(\.paneControls) private var focusedControls
    @State private var focusID = UUID()
    @State private var reservations: [CGRect] = []
    @State private var switching: Bool?
    @GestureState private var dragging = false

    private var enabled: Bool {
        paneSwipe != nil && !keyboardShown && !typing && focusedControls != focusID
    }

    func body(content: Content) -> some View {
        content
            .focusedValue(\.paneControls, focusID)
            .contentShape(Rectangle())
            .onPreferenceChange(PaneSwipeReservations.self) { frames in
                Task { @MainActor in reservations = frames }
            }
            .simultaneousGesture(swipe, isEnabled: enabled)
            .onChange(of: dragging) { _, dragging in if !dragging { stopSwitching() } }
            .onChange(of: enabled) { _, enabled in if !enabled { stopSwitching() } }
    }

    private func stopSwitching() {
        if switching == true { paneSwipe?.cancel() }
        switching = nil
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: Metrics.dragThreshold, coordinateSpace: .global)
            .updating($dragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if switching == nil {
                    // 起手方向只判一次；竖向拉底栏和控件自身的横拖都不能半路变成切窗口。
                    switching = enabled && DrawerPull.isHorizontal(value.translation)
                        && !reservations.contains { $0.contains(value.startLocation) }
                }
                if switching == true { paneSwipe?.track(value.translation.width) }
            }
            .onEnded { value in
                defer { switching = nil }
                guard enabled, switching == true else { return }
                paneSwipe?.end(value.translation.width, value.predictedEndTranslation.width)
            }
    }
}
