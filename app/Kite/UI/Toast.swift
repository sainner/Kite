import Accessibility
import SwiftUI

/// 同一展示层只保留最新提示；不同 App 窗口各自持有，不跨窗口广播。
@Observable
final class ToastCenter {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let systemImage: String?
    }

    private(set) var message: Message?

    func show(_ text: String, systemImage: String? = nil) {
        message = Message(text: text, systemImage: systemImage)
        AccessibilityNotification.Announcement(text).post()
    }

    func dismiss(id: UUID) {
        guard message?.id == id else { return }
        message = nil
    }
}

extension EnvironmentValues {
    @Entry var toast: ToastCenter?
}

extension View {
    /// 在 App 窗口或独立呈现的面板根部安装，业务视图只负责发出提示。
    func toastHost() -> some View { modifier(ToastHost()) }
}

private struct ToastHost: ViewModifier {
    @State private var toast = ToastCenter()

    func body(content: Content) -> some View {
        content
            .environment(\.toast, toast)
            .overlay(alignment: .bottom) {
                VStack {
                    if let message = toast.message {
                        HStack(spacing: 6) {
                            if let symbol = message.systemImage {
                                Image(systemName: symbol).accessibilityHidden(true)
                            }
                            Text(message.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Theme.secondary)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: 420)
                .padding(16)
                .animation(.easeOut(duration: 0.18), value: toast.message)
                .allowsHitTesting(false)
            }
            .task(id: toast.message?.id) {
                guard let id = toast.message?.id else { return }
                do { try await Task.sleep(for: .seconds(1.5)) }
                catch { return }
                toast.dismiss(id: id)
            }
    }
}
