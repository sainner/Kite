import SwiftUI

struct AdaptiveWorkspace: View {
    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let size = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                              height: proxy.size.height + insets.top + insets.bottom)
            let presentation = WorkspacePresentation(size: size)
            Group {
                if presentation == .tiled {
                    MainWindow(availableWidth: proxy.size.width)
                } else {
                    CompactLayout()
                }
            }
            .environment(\.workspacePresentation, presentation)
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 360)
        #endif
    }
}
