#if os(iOS)
import CoreText
import Observation
import OSLog
import SwiftUI
import UIKit

/// 宋体由系统按需下载和缓存；多个表格共用一次请求，不随单个视图消失而取消。
@Observable
final class TableFont {
    static let shared = TableFont()
    private static let regularName = "STSongti-SC-Regular"
    private static let boldName = "STSongti-SC-Bold"
    private static var names: [String] { [regularName, boldName] }
    private var isAvailable = false
    private var isLoading = false

    func applying(to source: AttributedString, font: Font, in context: Font.Context) -> AttributedString {
        guard isAvailable else { return source }
        var text = source
        for run in source.runs {
            let intent = run.inlinePresentationIntent ?? []
            guard !intent.contains(.code) else { continue }
            // Font(CTFont) 不再接受 SwiftUI 字重修饰，先解析 Markdown 的粗体、斜体。
            var styled = font
            if intent.contains(.stronglyEmphasized) { styled = styled.bold() }
            if intent.contains(.emphasized) { styled = styled.italic() }
            text[run.range].font = Self.withSongtiFallback(styled.resolve(in: context).ctFont)
        }
        return text
    }

    private static func withSongtiFallback(_ serif: CTFont) -> Font {
        let name = CTFontGetSymbolicTraits(serif).contains(.traitBold) ? boldName : regularName
        let fallback = CTFontDescriptorCreateWithNameAndSize(name as CFString, 0)
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontCascadeListAttribute: [fallback],
        ] as CFDictionary)
        return Font(CTFontCreateCopyWithAttributes(serif, 0, nil, descriptor))
    }

    func prepare() {
        guard !isAvailable, !isLoading else { return }
        if Self.fontsAvailable {
            isAvailable = true
            return
        }
        isLoading = true
        let descriptors = Self.names.map {
            CTFontDescriptorCreateWithAttributes([
                kCTFontNameAttribute: $0,
                kCTFontDownloadableAttribute: true,
            ] as CFDictionary)
        }
        // CoreText 在私有队列回调；只在完整匹配结束后回主线程发布结果。
        let progress: CTFontDescriptorProgressHandler = { @Sendable state, info in
            if state == .didFailWithError {
                let error = (info as NSDictionary)[kCTFontDescriptorMatchingError]
                Logger(subsystem: "com.sainner.kite", category: "TableFont")
                    .error("下载宋体失败：\(String(describing: error), privacy: .public)")
            }
            if state == .didFinish {
                Task { @MainActor in
                    self.isLoading = false
                    self.isAvailable = Self.fontsAvailable
                }
            }
            return true
        }
        if !CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil, progress) {
            isLoading = false
        }
    }

    private static var fontsAvailable: Bool {
        names.allSatisfy { UIFont(name: $0, size: 17) != nil }
    }
}
#endif
