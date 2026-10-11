import SwiftUI

/// 每一步的点阵标志，逐行字符画，字母表见 DotFigure.letters。显示器与二维码 23×23 格，登录的风筝组 29×23 格。
enum OnboardingLogos {
    /// 这一步的标志，各配一个小动画：风筝各自浮动，显示器的光标闪烁，二维码的黄格错开闪烁。
    /// 扫码时标志区让给取景框，没有标志。正在连接时沿用发起连接那一步的标志，在等待里呼吸。
    static func figure(for phase: Onboarding.Phase, colors: [Character: DotColor]) -> DotFigure? {
        func part(_ lines: [String], _ motion: FigureMotion = .still) -> DotFigure {
            DotFigure(lines, colors: colors, motion: motion)
        }
        /// 逐格改写字符画：transform 拿到列、行和原字符，给出新字符。
        func map(_ lines: [String], _ transform: (Int, Int, Character) -> Character) -> [String] {
            lines.enumerated().map { row, line in
                String(line.enumerated().map { column, character in transform(column, row, character) })
            }
        }
        switch phase {
        case .connect(.manual), .connecting(.manual):
            return DotFigure(columns: 29, rows: 23)
                .adding(part(kite, .float(4, period: 5)), column: 3, row: 0)
                .adding(part(smallKite, .float(6, period: 3.6, phase: 0.3)), column: 0, row: 0)
                .adding(part(smallKiteMirrored, .float(6, period: 4.2, phase: 0.7)), column: 24, row: 10)
                .adding(part(tinyKite, .float(5, period: 3.2, phase: 0.5)), column: 1, row: 15)
        case .prepare:
            // 提示符后面那条下划线是光标，熄掉时露出屏幕底色
            let cursor = { (column: Int, row: Int) in row == 9 && (8..<12).contains(column) }
            return part(map(desktop) { cursor($0, $1) ? "L" : $2 })
                .adding(part(map(desktop) { cursor($0, $1) ? $2 : "." }, .blink(period: 1.1)), column: 0, row: 0)
        case .connect(.scan):
            return nil
        case .connecting(.scan):
            // 二维码里的黄格分三组，错开闪烁
            return (0..<3).reduce(part(map(qr) { $2 == "Y" ? "." : $2 })) { figure, group in
                figure.adding(part(map(qr) { $2 == "Y" && ($1 * 7 + $0) % 3 == group ? $2 : "." },
                                   .blink(period: 1.8, duty: 0.6, phase: -Double(group) / 3)), column: 0, row: 0)
            }
        }
    }

    /// 登录时主风筝旁边的小风筝。
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

    /// 登录时：主风筝向右倾斜，笔画仍落在点阵格位上。
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

    /// 准备工作机：带提示符的显示器。
    private static let desktop = [
        ".......................",
        ".......................",
        ".BBBBBBBBBBBBBBBBBBBBB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLYLLLLLLLLLLLLLLLLB.",
        ".BLLLYLLLLLLLLLLLLLLLB.",
        ".BLLLLYLLLLLLLLLLLLLLB.",
        ".BLLLYLLLLLLLLLLLLLLLB.",
        ".BLLYLLLYYYYLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLMMMMMMMLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BLLLLLLLLLLLLLLLLLLLB.",
        ".BBBBBBBBBBBBBBBBBBBBB.",
        "..........BBB..........",
        "..........BBB..........",
        "..........BBB..........",
        "......BBBBBBBBBBB......",
        ".......................",
        ".......................",
        ".......................",
    ]

    /// 扫码后正在连接：二维码。
    private static let qr = [
        "BBBBBBB.Y.BY.BY.BBBBBBB",
        "B.....B...B...B.B.....B",
        "B.BBB.B.BYB.B.B.B.BBB.B",
        "B.BBB.B.YB.B.B..B.BBB.B",
        "B.BBB.B.B...BB..B.BBB.B",
        "B.....B.BB...B..B.....B",
        "BBBBBBB.......B.BBBBBBB",
        "...........B.BY........",
        "BBBB....BB.YB..YB......",
        "B...BBYYYYBB.BBB...YB.Y",
        "..BB...BB..B......BYBB.",
        "....BYB.....B....BB.B..",
        "YB.B..BY.......BB.BBB..",
        ".....BY.B..B..BB.......",
        "..........B..Y.BB..B.B.",
        "........BB..B.YBB.B..B.",
        "BBBBBBB..BBY...Y...Y..B",
        "B.....B...BB.B.Y.YYBBBB",
        "B.BBB.B.BB.B.B...BBBB..",
        "B.BBB.B.BYBYB..BBBBYBBB",
        "B.BBB.B.B..BBBYB..BBB.B",
        "B.....B..B.B....B......",
        "BBBBBBB...YBB.....B....",
    ]
}
