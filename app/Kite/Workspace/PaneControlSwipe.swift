import SwiftUI

extension EnvironmentValues {
    /// 紧凑窗口提供：左滑传 1，右滑传 -1；宽屏与抽屉展开时没有此动作。
    @Entry var switchPane: (@MainActor (Int) -> Void)?
    @Entry var trackPaneSwipe: (@MainActor (CGFloat) -> Void)?
    @Entry var endPaneSwipe: (@MainActor (CGFloat, CGFloat) -> Void)?
    @Entry var cancelPaneSwipe: (@MainActor () -> Void)?
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
    @Environment(\.switchPane) private var switchPane
    @Environment(\.trackPaneSwipe) private var trackPaneSwipe
    @Environment(\.endPaneSwipe) private var endPaneSwipe
    @Environment(\.cancelPaneSwipe) private var cancelPaneSwipe
    @Environment(\.keyboardShown) private var keyboardShown
    @FocusedValue(\.paneControls) private var focusedControls
    @State private var focusID = UUID()
    @State private var reservations: [CGRect] = []
    @State private var switching: Bool?
    @GestureState private var dragging = false

    private var enabled: Bool {
        switchPane != nil && !keyboardShown && !typing && focusedControls != focusID
    }

    func body(content: Content) -> some View {
        content
            .focusedValue(\.paneControls, focusID)
            .contentShape(Rectangle())
            .onPreferenceChange(PaneSwipeReservations.self) { frames in
                Task { @MainActor in reservations = frames }
            }
            .simultaneousGesture(swipe, isEnabled: enabled)
            .onChange(of: dragging) { _, dragging in
                if !dragging { if switching == true { cancelPaneSwipe?() }; switching = nil }
            }
            .onChange(of: enabled) { _, enabled in
                if !enabled { if switching == true { cancelPaneSwipe?() }; switching = nil }
            }
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
                if switching == true { trackPaneSwipe?(value.translation.width) }
            }
            .onEnded { value in
                defer { switching = nil }
                guard enabled, switching == true else { return }
                if let endPaneSwipe { endPaneSwipe(value.translation.width, value.predictedEndTranslation.width) }
                else if abs(value.translation.width) >= 48 { switchPane?(value.translation.width < 0 ? 1 : -1) }
            }
    }
}
