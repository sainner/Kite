import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// 对话正文的属性串在 iPhone（UITextView）和 Mac（NSTextView）上共用一份构建代码，字体、颜色、描述符按平台取别名；
// 两端 API 只差名字和可选性的地方在这里补齐，构建代码里不写平台分支。

#if canImport(UIKit)
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformFontDescriptor = UIFontDescriptor

extension UIFontDescriptor.SymbolicTraits {
    /// 和 AppKit 同名。
    static var bold: Self { .traitBold }
    static var italic: Self { .traitItalic }
}
#else
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformFontDescriptor = NSFontDescriptor

extension NSColor {
    /// 和 UIKit 同名。
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var link: NSColor { .linkColor }
}
#endif

extension PlatformFont {
    /// 按描述符建字体。UIKit 的构造器不返回可选，统一成 AppKit 的口径。
    static func font(descriptor: PlatformFontDescriptor) -> PlatformFont? {
        #if canImport(UIKit)
        UIFont(descriptor: descriptor, size: 0)
        #else
        NSFont(descriptor: descriptor, size: 0)
        #endif
    }

    /// 在原字体上加粗体、斜体这类特征。两端描述符 API 的可选性相反，统一成找不到对应字体就返回 nil。
    func addingTraits(_ traits: PlatformFontDescriptor.SymbolicTraits) -> PlatformFont? {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        #if canImport(UIKit)
        guard let descriptor = fontDescriptor.withSymbolicTraits(combined) else { return nil }
        #else
        let descriptor = fontDescriptor.withSymbolicTraits(combined)
        #endif
        return PlatformFont.font(descriptor: descriptor)
    }

    /// 数字等宽，列表的编号对得齐。
    var monospacedDigits: PlatformFont {
        #if canImport(UIKit)
        let feature: [PlatformFontDescriptor.FeatureKey: Any] = [.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector]
        #else
        let feature: [PlatformFontDescriptor.FeatureKey: Any] = [.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]
        #endif
        return PlatformFont.font(descriptor: fontDescriptor.addingAttributes([.featureSettings: [feature]])) ?? self
    }
}

extension Color {
    /// TextKit 的绘制片段只保存 CGColor，要在主线程按所在窗口的外观解析。
    func resolvedCGColor(for colorScheme: ColorScheme) -> CGColor {
        #if canImport(UIKit)
        UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)).cgColor
        #else
        PlatformColor(self).resolved(for: colorScheme).cgColor
        #endif
    }
}

extension PlatformColor {
    /// 动态颜色按给定外观定下来；文本视图里的字色留着动态色让系统跟外观变，这里只给要烤进图片或 CGColor 的用。
    func resolved(for colorScheme: ColorScheme) -> PlatformColor {
        #if canImport(UIKit)
        resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        #else
        var resolved = self
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: cgColor) ?? self
        }
        return resolved
        #endif
    }
}
