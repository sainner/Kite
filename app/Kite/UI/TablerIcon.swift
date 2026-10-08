import SwiftUI

/// 官方 SVG 作为模板资源，随所在控件的字号缩放并继承前景色。
struct TablerIcon: View {
    let resource: ImageResource
    var size: CGFloat?
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext

    init(_ resource: ImageResource, size: CGFloat? = nil) {
        self.resource = resource
        self.size = size
    }

    init(_ symbol: TablerSymbol, selected: Bool) {
        self.resource = selected ? symbol.filled : symbol.outline
    }

    var body: some View {
        // 基础尺寸与 SVG 画布留白的补偿分别控制。
        let size = size ?? ((font ?? Theme.body).resolve(in: fontContext).pointSize - 1) * 1.375
        Image(resource)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 可选中入口使用成对资源，避免图标只有线性版本时选中态不变。
struct TablerSymbol {
    let outline: ImageResource
    let filled: ImageResource

    static let folder = Self(outline: .tablerFolder, filled: .tablerFolderFilled)
    static let send = Self(outline: .tablerSend, filled: .tablerSendFilled)
    static let diamond = Self(outline: .tablerDiamond, filled: .tablerDiamondFilled)
    static let pointer = Self(outline: .tablerPointer, filled: .tablerPointerFilled)
    static let terminal = Self(outline: .tablerSquareChevronRight, filled: .tablerSquareChevronRightFilled)
    static let fileCode = Self(outline: .tablerFileCode, filled: .tablerFileCodeFilled)
    static let code = Self(outline: .tablerCodeCircle, filled: .tablerCodeCircleFilled)
    static let appWindow = Self(outline: .tablerAppWindow, filled: .tablerAppWindowFilled)
    static let world = Self(outline: .tablerWorld, filled: .tablerWorldFilled)
    static let book = Self(outline: .tablerBook, filled: .tablerBookFilled)
    static let fileText = Self(outline: .tablerFileText, filled: .tablerFileTextFilled)
    static let pencil = Self(outline: .tablerPencil, filled: .tablerPencilFilled)
    static let palette = Self(outline: .tablerPalette, filled: .tablerPaletteFilled)
    static let photo = Self(outline: .tablerPhoto, filled: .tablerPhotoFilled)
    static let camera = Self(outline: .tablerCamera, filled: .tablerCameraFilled)
    static let music = Self(outline: .tablerFileMusic, filled: .tablerFileMusicFilled)
    static let video = Self(outline: .tablerVideo, filled: .tablerVideoFilled)
    static let gamepad = Self(outline: .tablerDeviceGamepad, filled: .tablerDeviceGamepadFilled)
    static let sparkles = Self(outline: .tablerSparkles, filled: .tablerSparklesFilled)
    static let bulb = Self(outline: .tablerBulb, filled: .tablerBulbFilled)
    static let leaf = Self(outline: .tablerLeaf, filled: .tablerLeafFilled)
    static let bolt = Self(outline: .tablerBolt, filled: .tablerBoltFilled)
    static let star = Self(outline: .tablerStar, filled: .tablerStarFilled)
    static let heart = Self(outline: .tablerHeart, filled: .tablerHeartFilled)
    static let desktop = Self(outline: .tablerDeviceDesktop, filled: .tablerDeviceDesktopFilled)
    static let user = Self(outline: .tablerUser, filled: .tablerUserFilled)
    static let link = Self(outline: .tablerLink, filled: .tablerLinkFilled)
    static let puzzle = Self(outline: .tablerPuzzle, filled: .tablerPuzzleFilled)
}
