import SwiftUI

/// 初始配置的点阵标志，逐行字符画，字母表见 DotFigure.letters。风筝组 29×23 格。
enum OnboardingLogos {
    /// 风筝组，各自浮动；正在登录时在等待里呼吸。
    static func figure(colors: [Character: DotColor]) -> DotFigure {
        func part(_ lines: [String], _ motion: FigureMotion) -> DotFigure {
            DotFigure(lines, colors: colors, motion: motion)
        }
        return DotFigure(columns: 29, rows: 23)
            .adding(part(kite, .float(4, period: 5)), column: 3, row: 0)
            .adding(part(smallKite, .float(6, period: 3.6, phase: 0.3)), column: 0, row: 0)
            .adding(part(smallKiteMirrored, .float(6, period: 4.2, phase: 0.7)), column: 24, row: 10)
            .adding(part(tinyKite, .float(5, period: 3.2, phase: 0.5)), column: 1, row: 15)
    }

    /// 主风筝旁边的小风筝。
    private static let smallKite = [
        "..B..",
        ".BYB.",
        "BYBLB",
        ".BLB.",
        "..B..",
        "..D..",
        ".D...",
        "..D..",
    ]

    private static let smallKiteMirrored = [
        "..B..",
        ".BLB.",
        "BLBYB",
        ".BYB.",
        "..B..",
        "..D..",
        "...D.",
        "..D..",
    ]

    private static let tinyKite = [
        ".B.",
        "BYB",
        ".B.",
        ".D.",
        "D..",
    ]

    /// 主风筝向右倾斜，笔画仍落在点阵格位上。
    private static let kite = [
        ".......................",
        "...............B.......",
        "...........BBYBB.......",
        ".......BBYYYYYBLB......",
        "......BBYYYYYBLLB......",
        "......BBBYYYYBLLB......",
        "......BLLBBYBLLLB......",
        "......BLLLLBBLLLB......",
        "......BLLLLBYBLLB......",
        "......BLLLBYYYBBB......",
        "......BLLLBYYYYYBB.....",
        ".......BLBYYYYYBB......",
        ".......BLBYYYYBB.......",
        ".......BBYBBBB.........",
        ".......BBYB............",
        ".......B...............",
        "......B................",
        ".....DBD...............",
        ".....BB................",
        "...DBD.................",
        "...B...................",
        ".......................",
        ".......................",
    ]
}
