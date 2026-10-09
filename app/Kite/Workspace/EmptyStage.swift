import SwiftUI

/// 内容区没有窗口时的画板。场景图形摆在所在 App 窗口的点阵上，画板离场或消失时逐格收回：
/// - 图形画在卡片底色上方；打开窗口后画板退出。
/// - 场景图形用风筝和线讲连接状态：人握着线，风筝在远处飞。标题、说明和操作按钮直接放在上面。
/// - 指针划过（触屏是手指拖过）空白处留下一道慢慢退去的轨迹。
struct EmptyStage: View {
    let scene: StageScene
    let title: String
    var details: [String] = []
    var error: String?
    var actions: [StageAction] = []

    @Environment(\.dotStage) private var stage
    @Environment(\.dotCarrier) private var carrier
    @Environment(\.self) private var environment
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.paneTopSafeInset) private var topInset
    @State private var canvas: CGRect?
    @State private var figureArea: CGRect?
    /// 放得下的画幅，见 StageFigures.sizes。
    @State private var sizeIndex: Int?
    @State private var lastTrace: CGPoint?

    @State private var sceneSlot = "stage.scene.\(UUID().uuidString)"
    /// 场景切换（如连接成功）时发出的慢波，与初始配置完成一步相同。
    private static let wavePace = 0.24

    var body: some View {
        GeometryReader { geo in
            // 标题、说明和按钮大约占的高度；挑放得下的最大画幅，都放不下时只留文字
            let fitting = StageFigures.sizes.firstIndex { size in
                CGFloat(size.columns) * DotMetrics.pitch + Metrics.padding * 4 <= geo.size.width
                    && CGFloat(size.rows) * DotMetrics.pitch + 240 <= geo.size.height
            }
            let figureSize = fitting.map { CGSize(width: CGFloat(StageFigures.sizes[$0].columns) * DotMetrics.pitch,
                                                  height: CGFloat(StageFigures.sizes[$0].rows) * DotMetrics.pitch) }
            let showsFigure = figureSize != nil
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onContinuousHover(coordinateSpace: .global) { phase in
                        if case .active(let point) = phase { trace(to: point) } else { lastTrace = nil }
                    }
                    #else
                    .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { trace(to: $0.location) }
                        .onEnded { _ in lastTrace = nil })
                    #endif
                VStack(spacing: Metrics.padding * 2) {
                    if showsFigure, let figureSize {
                        Color.clear
                            .frame(width: figureSize.width, height: figureSize.height)
                            // 在会移动的卡片里时用卡片坐标，图形的位置由点阵按卡片每一帧的位置换算
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: DotCarrier.coordinateSpace(carrier))
                            } action: {
                                figureArea = $0
                                refresh()
                            }
                            .allowsHitTesting(false)
                    }
                    titleBlock
                    if !actions.isEmpty { buttons }
                }
                .padding(Metrics.padding * 2)
                .onChange(of: fitting, initial: true) { _, index in
                    sizeIndex = index
                    if index == nil { figureArea = nil }
                    refresh()
                }
            }
        }
        .stageCard(usesDots: true)
        .onDisappear { stage?.show(nil, in: .zero, slot: sceneSlot) }
        .preference(key: DotSlots.self, value: [sceneSlot])
        // 容器给出侧边栏入口时（iPhone），左上角放按钮，位置同窗口标题栏
        .overlay(alignment: .topLeading) {
            if let openSidebar {
                PaneHeaderButtonGroup {
                    Button(action: openSidebar) { PaneHeaderButtonLabel("侧边栏", systemImage: "sidebar.left") }
                }
                .padding(.horizontal, Metrics.paneMargin)
                .padding(.top, max(Metrics.paneMargin, topInset) - topInset)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            canvas = $0
            refresh()
        }
        .onChange(of: scene) { old, new in
            refresh()
            // 连上了：从刚才的图形发出一道慢波
            if old == .connecting, new != .unreachable, let frame = stage?.figureFrame(sceneSlot) {
                stage?.emitWave(from: frame, pace: Self.wavePace)
            }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 10) {
            Text(title).font(Theme.display)
            ForEach(details, id: \.self) { line in
                Text(line).font(Theme.body).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error {
                Text(error).font(Theme.secondary).foregroundStyle(Theme.danger)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .waitingBreath(scene == .connecting)
        .id(title)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
        .animation(.snappy, value: title)
    }

    /// 操作按钮直接放在画板上。
    private var buttons: some View {
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            HStack(spacing: Metrics.paneButtonGap) {
                ForEach(actions) { action in
                    let button = Button(action.title, action: action.action).disabled(!action.enabled)
                    if action.prominent {
                        button.buttonStyle(.glassProminent)
                    } else {
                        button.buttonStyle(.glass)
                    }
                }
            }
            .font(Theme.body.weight(.semibold))
            #if os(macOS)
            .controlSize(.extraLarge)
            #else
            .controlSize(.large)
            #endif
        }
    }

    private var sceneFigure: DotFigure? {
        guard let sizeIndex else { return nil }
        let colors = DotFigure.letters(accent: DotColor(Color.accentColor.resolve(in: environment)))
        return StageFigures.figure(for: scene, colors: colors, size: StageFigures.sizes[sizeIndex])
    }

    /// 按当前范围摆场景图形；同一图形在同一处时 DotStage 什么也不做。
    private func refresh() {
        if let figureArea, let figure = sceneFigure {
            stage?.show(figure, in: figureArea, breathing: scene == .unreachable, slot: sceneSlot, carrier: carrier)
        } else {
            stage?.show(nil, in: .zero, slot: sceneSlot)
        }
    }

    /// 指针移得快时两次事件隔得远，中间按格补上，轨迹连成一条。
    private func trace(to point: CGPoint) {
        guard let canvas, canvas.insetBy(dx: DotMetrics.pitch, dy: DotMetrics.pitch).contains(point) else {
            lastTrace = nil
            return
        }
        let from = lastTrace ?? point
        let steps = max(1, Int((hypot(point.x - from.x, point.y - from.y) / (DotMetrics.pitch / 2)).rounded(.up)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            stage?.trace(at: CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t))
        }
        lastTrace = point
    }
}

/// 画板卡片上的一个操作。
struct StageAction: Identifiable {
    var id: String { title }
    let title: String
    var prominent = false
    var enabled = true
    let action: () -> Void
}

/// 画板上的场景，各配一个小动画。
enum StageScene: Hashable {
    /// 还没有工作机：风筝落在地上，线松着，隔一会儿被风吹起又落下。
    case grounded
    /// 正在连接：风筝飞着，一串点沿着线往上走。
    case connecting
    /// 可以添加第一个项目：风筝稳稳地飞，线的这头有一个等着装东西的文件夹。
    case addProject
    /// 工作机暂不可达：线中间断了一截，风筝在原处呼吸。
    case unreachable
    /// 平常的空画板：风筝在飞。
    case idle
}

/// 画板上的点阵图形。字母沿用 DotFigure.letters，小写字母是不满格的细线。
enum StageFigures {
    /// 画幅：宽屏 32 × 24 格；iPhone 卡片放不下时用 24 × 18 格，图案相同，线短一些。
    static let sizes = [(columns: 32, rows: 24), (columns: 24, rows: 18)]

    static func figure(for scene: StageScene, colors: [Character: DotColor], size: (columns: Int, rows: Int)) -> DotFigure? {
        let columns = size.columns, rows = size.rows
        // 风筝放在右上，线头在左下
        let kiteOrigin = (column: columns - 13, row: 0)
        let spoolCenter = (column: 4, row: rows - 3)
        func canvas(_ points: [(Int, Int)], _ character: Character) -> [String] {
            StageFigures.canvas(points, character, columns: columns, rows: rows)
        }
        var colors = colors
        // 线用细一些的格子
        colors["d"] = colors["D"]
        let shapes: [Character: Double] = ["d": 0.5]
        func part(_ lines: [String], _ motion: FigureMotion = .still) -> DotFigure {
            DotFigure(lines, colors: colors, shapes: shapes, motion: motion)
        }
        let tip = (column: kiteOrigin.column + 5, row: kiteOrigin.row + 11)
        let line = path(from: tip, to: (spoolCenter.column + 2, spoolCenter.row - 1))
        let flying = { (string: [(Int, Int)], float: Double) in
            DotFigure(columns: columns, rows: rows)
                .adding(part(canvas(string, "d")), column: 0, row: 0)
                .adding(part(spool), column: spoolCenter.column - 1, row: spoolCenter.row - 1)
                .adding(part(kite, .float(float, period: 4.6)), column: kiteOrigin.column, row: kiteOrigin.row)
        }
        switch scene {
        case .idle:
            return flying(line, 3)
        case .addProject:
            return flying(line, 3)
                .adding(part(folder, .pulse(period: 2.4, duration: 1.4)), column: 0, row: rows - 13)
        case .connecting:
            // 从线头往风筝一格接一格亮起来
            let points = Array(line.reversed())
            return points.enumerated().reduce(flying(line, 3)) { figure, item in
                figure.adding(part(canvas([item.element], "B"),
                                   .blink(period: 1.8, duty: 0.12, phase: -Double(item.offset) / Double(points.count) * 0.6)),
                              column: 0, row: 0)
            }
        case .unreachable:
            // 中间断开三成
            let gap = (line.count * 35 / 100)..<(line.count * 65 / 100)
            let broken = line.enumerated().filter { !gap.contains($0.offset) }.map(\.element)
            return flying(broken, 6)
        case .grounded:
            // 两帧：落在地上，被风吹起一点；线跟着风筝的左角
            func frame(lift: Int) -> [String] {
                let top = rows - kite.count - lift
                let left = (column: kiteOrigin.column, row: top + 5)
                let landing = max(columns - 18, spoolCenter.column + 4)
                var string = path(from: (left.column - 1, left.row + 1), to: (landing, rows - 2))
                // 落地的那段松松地拖在地上
                string += (spoolCenter.column + 2...landing - 1).map { ($0, rows - 2 - ($0 % 4 == 0 ? 1 : 0)) }
                var grid = canvas(string, "d")
                stamp(kite, into: &grid, column: kiteOrigin.column, row: top)
                stamp(spool, into: &grid, column: spoolCenter.column - 1, row: spoolCenter.row - 1)
                return grid
            }
            return DotFigure(frames: [frame(lift: 0), frame(lift: 3)], colors: colors, shapes: shapes,
                             holds: [3.2, 0.4], transition: 0.7, stagger: 0.25)
        }
    }

    /// 两格之间的直线，按较长的那一维逐格走。
    private static func path(from start: (Int, Int), to end: (Int, Int)) -> [(Int, Int)] {
        let dx = end.0 - start.0, dy = end.1 - start.1
        let steps = max(abs(dx), abs(dy), 1)
        return (0...steps).map { step in
            let t = Double(step) / Double(steps)
            return (start.0 + Int((Double(dx) * t).rounded()), start.1 + Int((Double(dy) * t).rounded()))
        }
    }

    private static func canvas(_ points: [(Int, Int)], _ character: Character, columns: Int, rows: Int) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("."), count: columns), count: rows)
        for (column, row) in points where column >= 0 && column < columns && row >= 0 && row < rows {
            grid[row][column] = character
        }
        return grid.map { String($0) }
    }

    private static func stamp(_ lines: [String], into grid: inout [String], column: Int, row: Int) {
        var cells = grid.map(Array.init)
        for (r, line) in lines.enumerated() {
            for (c, character) in line.enumerated() where character != "." {
                let y = row + r, x = column + c
                guard y >= 0, y < cells.count, x >= 0, x < cells[y].count else { continue }
                cells[y][x] = character
            }
        }
        grid = cells.map { String($0) }
    }

    /// 菱形风筝，横骨把它分成黄蓝四块。
    private static let kite = [
        ".....B.....",
        "....BYB....",
        "...BYYLB...",
        "..BYYYLLB..",
        ".BYYYYLLLB.",
        "BMMMMBMMMMB",
        ".BLLLYYYYB.",
        "..BLLYYYB..",
        "...BLYYB...",
        "....BYB....",
        ".....B.....",
    ]

    /// 握在手里的线轴。
    private static let spool = [
        ".M.",
        "MBM",
        ".M.",
    ]

    /// 等着装进第一个项目的文件夹。
    private static let folder = [
        "DDD....",
        "DDDDDDD",
        "D.....D",
        "D.....D",
        "DDDDDDD",
    ]
}
