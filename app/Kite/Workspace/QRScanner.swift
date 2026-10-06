#if os(iOS)
import AVFoundation
import SwiftUI
import Vision
import VisionKit

/// 初始配置里的扫码取景框：先确认相机权限，再用系统的 DataScanner 识别二维码，识别到的文本交给 onScan。
/// 相机不可用（模拟器、权限被关）时显示原因；预览时轻点取景框模拟扫到。
struct QRScanWindow: View {
    let onScan: (String) -> Void
    var onSimulate: (() -> Void)?
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @Environment(\.openURL) private var openURL

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        ZStack {
            Theme.card
            if access == .authorized, DataScannerViewController.isSupported {
                QRScanner(onScan: onScan)
            } else {
                unavailable
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5) }
        .contentShape(shape)
        .onTapGesture { onSimulate?() }
        .task {
            guard access == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    @ViewBuilder
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera").font(.title2).foregroundStyle(.secondary)
            switch access {
            case .notDetermined:
                EmptyView()
            case .denied, .restricted:
                Text("相机权限已关闭").font(Theme.secondary).foregroundStyle(.secondary)
                Button("前往设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glass)
            default:
                Text("这台设备不能扫码").font(Theme.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(Metrics.padding)
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: false,
                                                isGuidanceEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        // 刚创建时还没进窗口，等下一轮再开相机
        Task { try? scanner.startScanning() }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                if let text = code.payloadStringValue { onScan(text) }
            }
        }
    }
}
#endif
