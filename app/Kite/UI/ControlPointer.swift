import SwiftUI

/// 只给可操作的控件加手形，不覆盖文字选择、窗口拖动与缩放的光标。
private struct ClickPointer: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        #if os(macOS)
        content.pointerStyle(enabled ? .link : .default)
        #else
        content
        #endif
    }
}

extension View {
    func clickPointer() -> some View { modifier(ClickPointer()) }

    /// 拖动手柄：平时张开的手，拖动中握紧。
    @ViewBuilder func grabPointer(_ grabbing: Bool) -> some View {
        #if os(macOS)
        pointerStyle(grabbing ? .grabActive : .grabIdle)
        #else
        self
        #endif
    }

    /// 内联链接只在文字实际占用的范围内显示手形，不影响整段的选字。
    @ViewBuilder func referencePointer() -> some View {
        #if os(macOS)
        modifier(ReferencePointer())
        #else
        self
        #endif
    }
}

struct ReferenceLinkAttribute: TextAttribute {}

extension Text {
    func referenceLink(_ linked: Bool = true) -> Text {
        linked ? customAttribute(ReferenceLinkAttribute()) : self
    }
}

#if os(macOS)
struct ReferenceLinkRects: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// 鼠标位置和排版范围只用于命中计算，只有进出链接才通知视图刷新。
@Observable private final class ReferenceHover {
    @ObservationIgnored var rectangles: [CGRect] = [] { didSet { updateHit() } }
    @ObservationIgnored var location: CGPoint? { didSet { updateHit() } }
    private(set) var isLink = false

    private func updateHit() {
        let hit = location.map { point in rectangles.contains { $0.contains(point) } } ?? false
        if hit != isLink { isLink = hit }
    }
}

private struct ReferencePointer: ViewModifier {
    @State private var hover = ReferenceHover()
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    Color.clear.preference(key: ReferenceLinkRects.self, value: layouts.flatMap { anchored in
                        let origin = proxy[anchored.origin]
                        return anchored.layout.flatMap { line in
                            line.compactMap { run in
                                guard run[ReferenceLinkAttribute.self] != nil else { return nil as CGRect? }
                                return run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                            }
                        }
                    })
                }
                .allowsHitTesting(false)
            }
            .onPreferenceChange(ReferenceLinkRects.self) { hover.rectangles = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover.location = point
                case .ended: hover.location = nil
                }
            }
            .pointerStyle(enabled && hover.isLink ? .link : nil)
    }
}
#endif

/// 沿用系统按钮的外观和按压行为，只统一光标反馈。
struct PointerButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let base: Base

    func makeBody(configuration: Configuration) -> some View {
        base.makeBody(configuration: configuration).clickPointer()
    }
}

extension PrimitiveButtonStyle where Self == PointerButtonStyle<PlainButtonStyle> {
    static var pointingPlain: Self { Self(base: PlainButtonStyle()) }
}

extension PrimitiveButtonStyle where Self == PointerButtonStyle<DefaultButtonStyle> {
    static var pointingAutomatic: Self { Self(base: DefaultButtonStyle()) }
}
