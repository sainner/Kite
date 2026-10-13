#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 原生按钮的公共底子，行为同 SwiftUI 的 Button：按下变样，拖出范围不算按着、拖回来接着算，在范围里松手才算一次
/// （UIControl 的跟踪）；所在的地方起了拖动手势（拉抽屉、横滑、滚动）时这次按下作废。子类只管自己的样子（stateChanged）。
/// - 停用：不接点按，读屏是停用的按钮。
/// - iPad 指针：tracksHover 打开时跟悬停（UIHoverGestureRecognizer），同 SwiftUI 的 onHover；过渡中整块不接输入时没有悬停。
/// - 读屏：按钮，按下就是这个动作；名字由子类给（accessibilityLabel）。
/// Mac 的对应是 NativeButton（AppKit）。
class NativeButton: UIControl {
    var action: (() -> Void)?
    private(set) var hovered = false {
        didSet { if hovered != oldValue { stateChanged() } }
    }
    /// 悬停时要不要变样子。
    var tracksHover = false {
        didSet {
            guard tracksHover != oldValue else { return }
            if tracksHover {
                let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
                addGestureRecognizer(hover)
                self.hover = hover
            } else if let hover {
                removeGestureRecognizer(hover)
                self.hover = nil
                hovered = false
            }
        }
    }
    private var hover: UIHoverGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(released), for: .primaryActionTriggered)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self,
                                 UITraitAccessibilityContrast.self]) { (self: Self, _) in self.stateChanged() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { hovered = false }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            stateChanged()
        }
    }

    override var isHidden: Bool {
        didSet { if oldValue && !isHidden { setNeedsLayout() } }
    }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { stateChanged() } }
    }

    /// 按着：手指在按钮上按下、还没松开也没拖出去。
    var pressed: Bool { isHighlighted && isEnabled }

    /// 样子跟着状态变。
    func stateChanged() {}

    /// 上次按哪种深浅色上的色。藏着时深浅色变了，系统不一定当场通知（2026-10-14 真机：藏着的「继续」露出来时还是浅色的字），
    /// 排版时再对一次。
    private var paintedStyle: UIUserInterfaceStyle?

    override func layoutSubviews() {
        super.layoutSubviews()
        if paintedStyle != traitCollection.userInterfaceStyle {
            paintedStyle = traitCollection.userInterfaceStyle
            stateChanged()
        }
    }

    /// 这一点（自己的坐标）在不在按钮的范围里：命中按它，默认整个视图。
    func contains(_ point: CGPoint) -> Bool { bounds.contains(point) }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        contains(point)
    }

    @objc private func released() {
        action?()
    }

    @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: hovered = isEnabled && contains(recognizer.location(in: self))
        default: hovered = false
        }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }
}

/// 悬停垫一块灰、按下深一点的按钮，同 PaneButtonHover：灰色胶囊按 inset 缩进，悬停 0.10、按下 0.20；
/// 范围是整个按钮大小的胶囊（PaneButtonHover 的 contentShape(Capsule())）；停用时整体淡到 0.45；
/// pressedOpacity 是按下时整体淡到多少（PaneButtonStyle 0.7）。灰块在内容下面；实心按钮的灰块盖在填色和内容上面
/// （PaneButtonHover 有填色时把反馈放在 overlay 里）。Mac 的对应是 HighlightButton（AppKit）。
class HighlightButton: NativeButton {
    let highlight = CALayer()
    var inset = CGSize(width: 2, height: 2) { didSet { setNeedsLayout() } }
    var pressedOpacity: CGFloat = 0.7
    /// 灰块盖在内容上面。
    var highlightsOverContent = false {
        didSet { highlight.zPosition = highlightsOverContent ? 1 : 0 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        tracksHover = true
        // 按下、停用时的透明度一层层各自乘上去，不先合成一组再淡：同 SwiftUI 的 opacity（没有 compositingGroup），
        // 停用的发送键箭头透出底下的主题色（2026-10-14 iPad 真机逐像素比过）
        layer.allowsGroupOpacity = false
        layer.addSublayer(highlight)
        highlight.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func contains(_ point: CGPoint) -> Bool {
        UIBezierPath(roundedRect: bounds, cornerRadius: min(bounds.width, bounds.height) / 2).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx: inset.width, dy: inset.height)
        highlight.cornerRadius = min(highlight.frame.width, highlight.frame.height) / 2
        CATransaction.commit()
    }

    override func stateChanged() {
        let opacity: CGFloat = pressed ? 0.20 : hovered && isEnabled ? 0.10 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.backgroundColor = resolved(Color.gray.opacity(opacity), traits: traitCollection).cgColor
        CATransaction.commit()
        alpha = !isEnabled ? 0.45 : pressed ? pressedOpacity : 1
    }
}

/// 控制区和工具条按钮的原生版，照 PaneButtonStyle 与 PaneButtonHover：图标占 paneButton 见方，文字按字宽加左右 paneToolbarInset、
/// 至少 paneButton 宽；比按钮四边各缩 2 的胶囊在悬停时垫 0.10 灰、按下时 0.20 灰，按下时整个按钮 0.7 透明；
/// 实心的（发送、停止）胶囊填色，内容白色粗体，悬停、按下的灰盖在填色和内容上面。玻璃由所在容器提供。
/// Mac 的对应是同名的 AppKit 版。
final class PaneButtonView: HighlightButton {
    enum Label: Equatable {
        case symbol(String)
        case text(String)
    }

    var label: Label = .symbol("circle") {
        didSet { if label != oldValue { labelChanged() } }
    }
    /// 实心按钮的填色；nil 是普通按钮。
    var fill: Color? {
        didSet {
            guard fill != oldValue else { return }
            highlightsOverContent = fill != nil
            labelChanged()
        }
    }
    /// 内容色，实心按钮不用（白色）。
    var foreground: Color = .secondary {
        didSet { if foreground != oldValue { applyColors() } }
    }
    /// 读屏念的名字。
    var title = "" {
        didSet { accessibilityLabel = title }
    }
    /// 解析颜色用的 SwiftUI 环境（主题色等从这里来），外观按这个视图自己的。
    var environment: EnvironmentValues? {
        didSet { applyColors() }
    }

    /// 实心按钮的填色，在最下面。
    private let fillLayer = CALayer()
    private let image = UIImageView()
    private let text = UILabel()
    private var font = UIFont.preferredFont(forTextStyle: .body)

    init() {
        super.init(frame: .zero)
        fillLayer.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull()]
        layer.insertSublayer(fillLayer, at: 0)
        image.contentMode = .center
        image.isUserInteractionEnabled = false
        text.isUserInteractionEnabled = false
        text.lineBreakMode = .byClipping
        addSubview(image)
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 正文字号；实心按钮加粗。字体随环境变时由外面再设一次。
    func setFont(_ font: UIFont) {
        guard font != self.font else { return }
        self.font = font
        labelChanged()
    }

    /// 按内容的宽：图标是 paneButton 见方，文字按字宽加两边留白，至少 paneButton。字宽在标签、字体变了时量一次。
    var width: CGFloat {
        switch label {
        case .symbol: Metrics.paneButton
        case .text: max(textBox + 2 * Metrics.paneToolbarInset, Metrics.paneButton)
        }
    }

    private var textWidth: CGFloat = 0

    /// 字占的宽：字宽向上取整到像素，同 SwiftUI 的 Text（2026-10-14 iPad 真机逐像素比过）。
    private var textBox: CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return (textWidth * scale).rounded(.up) / scale
    }

    /// 实心按钮的字和图标是正文字号的 bold，同 SwiftUI 的 Theme.body.weight(.bold)（不用粗体特征：那样出来的是 semibold，箭头细一圈）。
    private var weightedFont: UIFont {
        guard fill != nil else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private func labelChanged() {
        switch label {
        case .symbol(let name):
            let configuration = UIImage.SymbolConfiguration(font: weightedFont, scale: .medium)
            image.image = UIImage(systemName: name, withConfiguration: configuration)
            image.isHidden = false
            text.isHidden = true
            text.text = nil
            textWidth = 0
        case .text(let string):
            image.image = nil
            image.isHidden = true
            text.isHidden = false
            text.font = weightedFont
            text.text = string
            textWidth = NSAttributedString(string: string, attributes: [.font: weightedFont]).size().width
        }
        applyColors()
        setNeedsLayout()
    }

    private func applyColors() {
        // 字和图标用动态色，按当时的深浅色自己解析：藏着的按钮换深浅色时不一定收到通知
        let foreground = foreground, environment = environment
        let content = fill != nil ? .white : foreground == .secondary ? .secondaryLabel
            : UIColor { resolved(foreground, traits: $0, in: environment) }
        image.tintColor = content
        text.textColor = content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = fill.map { resolved($0, traits: traitCollection, in: environment).cgColor }
        CATransaction.commit()
    }

    override func stateChanged() {
        super.stateChanged()
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = highlight.frame
        fillLayer.cornerRadius = highlight.cornerRadius
        CATransaction.commit()
        // 字从左边留白处起排（同 SwiftUI 的 padding），字本身不在取整后的宽里居中
        text.frame = CGRect(x: max((bounds.width - textBox) / 2, Metrics.paneToolbarInset), y: 0, width: textWidth, height: bounds.height)
        if let symbol = image.image {
            // 横向按字形的对齐范围居中、取整到像素，同 SwiftUI（Mac 版 2026-10-13 逐像素比过）
            let size = symbol.size, alignment = symbol.alignmentRectInsets
            let scale = traitCollection.displayScale
            let alignedWidth = size.width - alignment.left - alignment.right
            let x = (((bounds.width - alignedWidth) / 2 - alignment.left) * scale).rounded() / scale
            // 竖向按整张图居中、取整到像素（2026-10-14 iPad 真机逐像素比过：按对齐范围居中时麦克风高半点，不取整时停止键高半点）
            let y = (((bounds.height - size.height) / 2) * scale).rounded() / scale
            image.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }
}

/// SwiftUI 的颜色按这个 trait 的深浅色解析成同样的值（主题色、资源色、带透明度的系统色）。主题色要从 SwiftUI 交过来的环境里解析：
/// 新建的 EnvironmentValues 里 accentColor 是系统蓝，不是 App 的 AccentColor。
func resolved(_ color: Color, traits: UITraitCollection, in environment: EnvironmentValues? = nil) -> UIColor {
    var environment = environment ?? EnvironmentValues()
    environment.colorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
    return UIColor(cgColor: color.resolve(in: environment).cgColor)
}
#endif
