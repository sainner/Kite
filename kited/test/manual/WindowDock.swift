import SwiftUI

private enum DockContractError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        if case .failed(let message) = self { return message }
        return "窗口停靠合同失败"
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw DockContractError.failed(message) }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// 点阵图案引用的响度源，真实定义在 Conversation/VoiceInput.swift，连着语音识别和工作机客户端；
/// 窗口排布用不到声音，这里给最小定义，免得把整条语音链路编进来。
final class AudioLevel {
    func level(at date: Date) -> Double { 0 }
}

/// 等待呼吸用的逐帧时钟，真实定义在 Workspace/PaneWindow.swift，连着整个窗口视图；排布合同不渲染，给最小定义。
struct PaneTimeline<Content: View>: View {
    @ViewBuilder let content: (TimelineViewDefaultContext) -> Content

    var body: some View { TimelineView(.animation, content: content) }
}

private struct LayoutState {
    let empty: Bool
    let active: [Pane]
    let docked: [Pane]
    let all: [Pane]
    let focused: Pane?
    let frames: [Pane: CGRect]

    init(_ layout: WindowLayout, in bounds: CGRect) {
        let canvas = WindowRegions(in: bounds).canvas
        empty = layout.root == nil
        active = layout.root?.panes ?? []
        docked = layout.docked
        all = layout.panes
        focused = layout.focused
        frames = layout.root?.layout(in: canvas).panes ?? [:]
    }
}

private func requireSame(_ layout: WindowLayout, as before: LayoutState, in bounds: CGRect, _ step: String) throws {
    try requireArrangement(layout, as: before, in: bounds, step)
    try require(layout.focused == before.focused, "\(step) 改变了已提交的焦点")
}

private func requireArrangement(_ layout: WindowLayout, as before: LayoutState, in bounds: CGRect, _ step: String) throws {
    let after = LayoutState(layout, in: bounds)
    try require(after.empty == before.empty && after.active == before.active && after.docked == before.docked
                && after.all == before.all && after.frames == before.frames,
                "\(step) 改变了已提交的窗口布局")
}

private func requireComplete(_ layout: WindowLayout, _ step: String) throws {
    let visible = (layout.root?.panes ?? []) + layout.docked
    try require(visible.count == layout.panes.count && Set(visible) == Set(layout.panes),
                "\(step) 的树与 dock 窗口集合不一致")
    try require(Set(layout.panes).count == layout.panes.count, "\(step) 重复了窗口 ID")
    if let focused = layout.focused {
        try require(layout.panes.contains(focused), "\(step) 的焦点不在已打开窗口中")
    } else {
        try require(layout.panes.isEmpty, "\(step) 仍有窗口但焦点为空")
    }
}

private func requireProjectionComplete(_ layout: WindowLayout, _ step: String) throws {
    try requireComplete(layout, step)
    let projected = (layout.shown?.panes ?? []) + layout.shownDock
    try require(projected.count == layout.panes.count && Set(projected) == Set(layout.panes),
                "\(step) 的视口与停靠栏遗漏或重复了窗口")
}

private func dock(_ pane: Pane, layout: WindowLayout, in bounds: CGRect) {
    let frame = WindowRegions(in: bounds).dockFrame(at: layout.docked.count)
    layout.drag(pane, to: frame.center, in: bounds)
    layout.drop(in: bounds)
}

private func fixturePanes(_ name: String, count: Int) -> [Pane] {
    (0..<count).map { Pane("contract-\(name)-\($0)") }
}

/// 正在显示的排布，按视图的取法：bounds 是内容区所在的整块区域，原点为零。
private func shownTiles(_ layout: WindowLayout, in bounds: CGRect) -> TileLayout {
    layout.shown?.layout(in: layout.regions(in: bounds).canvas) ?? TileLayout()
}

/// first 与 second 之间的那道缝：左右缝在 first 右边、second 左边，上下缝在 first 下边、second 上边，且横跨两扇窗口。
private func gap(between first: Pane, and second: Pane, in tiles: TileLayout) throws -> TileLayout.Gap {
    guard let a = tiles.panes[first], let b = tiles.panes[second] else {
        throw DockContractError.failed("找缝时 \(first.id) 或 \(second.id) 不在排布里")
    }
    let found = tiles.gaps.filter { gap in
        let r = gap.rect
        if gap.split.axis == .horizontal {
            return abs(r.minX - a.maxX) < 0.001 && abs(r.maxX - b.minX) < 0.001
                && r.minY < a.maxY && r.maxY > a.minY && r.minY < b.maxY && r.maxY > b.minY
        }
        return abs(r.minY - a.maxY) < 0.001 && abs(r.maxY - b.minY) < 0.001
            && r.minX < a.maxX && r.maxX > a.minX && r.minX < b.maxX && r.maxX > b.minX
    }
    guard found.count == 1 else {
        throw DockContractError.failed("\(first.id) 与 \(second.id) 之间应有一道缝，找到 \(found.count) 道")
    }
    return found[0]
}

/// 按住 start 这道缝，指针从起拖时的缝中心沿缝的方向挪 offset。每一步按当前排布重取这道缝再交给 resize，
/// 同 TileViews 每次重建出来的缝。
private func dragGap(_ start: TileLayout.Gap, by offset: CGFloat, layout: WindowLayout, in bounds: CGRect) throws {
    guard let current = shownTiles(layout, in: bounds).gaps.first(where: { $0.id == start.id }) else {
        throw DockContractError.failed("拖动中找不到正在拖的缝")
    }
    let point = start.split.axis == .horizontal
        ? CGPoint(x: start.rect.midX + offset, y: start.rect.midY)
        : CGPoint(x: start.rect.midX, y: start.rect.midY + offset)
    layout.resize(current, to: point)
}

/// 需求里的挤法：lengths 按离缝（或内容区左边）由近到远排，整侧让出 amount，近的先让，各自到最小尺寸为止；
/// amount 为负时只有最近的那扇变长。
private func squeezed(_ lengths: [CGFloat], by amount: CGFloat) -> [CGFloat] {
    var remaining = amount
    return lengths.map { length in
        let next = max(length - remaining, Metrics.minPane)
        remaining -= length - next
        return next
    }
}

/// 一排铺满内容区的列，依次给宽度。宽度加缝之和不等于内容区宽度时，要么夹具算错，要么内容区没按 bounds 连续变化。
private func row(_ panes: [Pane], widths: [CGFloat], in canvas: CGRect) throws -> [Pane: CGRect] {
    var x = canvas.minX
    var frames: [Pane: CGRect] = [:]
    for (pane, width) in zip(panes, widths) {
        try require(width + 0.001 >= Metrics.minPane, "夹具的期望宽度 \(width) 小于最小尺寸")
        frames[pane] = CGRect(x: x, y: canvas.minY, width: width, height: canvas.height)
        x += width + Metrics.gap
    }
    try require(abs(x - Metrics.gap - canvas.maxX) < 0.001, "期望宽度 \(widths) 加缝与内容区 \(canvas) 不符")
    return frames
}

/// 位置尺寸允许 1 点以内的取整误差；fixed 里的窗口是这一步不相邻、尺寸必须一点不变的（这次需求的核心：
/// 变了就要多重排一份对话），只有它们的宽高严格比较。
private func requireFrames(_ actual: [Pane: CGRect], _ expected: [Pane: CGRect], fixed: [Pane] = [],
                           _ step: String) throws {
    try require(Set(actual.keys) == Set(expected.keys), "\(step)：显示的窗口集合变了")
    let near = { (a: CGFloat, b: CGFloat) in abs(a - b) <= 1.001 }
    for (pane, frame) in expected {
        let got = actual[pane]!
        try require(near(got.minX, frame.minX) && near(got.minY, frame.minY)
                    && near(got.width, frame.width) && near(got.height, frame.height),
                    "\(step)：\(pane.id) 应为 \(frame)，实际 \(got)")
        if fixed.contains(pane) {
            try require(abs(got.width - frame.width) < 0.001 && abs(got.height - frame.height) < 0.001,
                        "\(step)：不相邻的 \(pane.id) 尺寸变了，应为 \(frame.size)，实际 \(got.size)")
        }
    }
}

@MainActor
@main
private struct WindowDockContract {
    private static let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    static func main() throws {
        try allCardsCanDockAndReturn()
        try reorderCancelAndSwitchArrangement()
        try canvasEdgesPreviewAndCommit()
        try narrowCanvasEdgeDocksFarthestPane()
        try canvasTooNarrowForTwoHasNoSideEdge()
        try headerActionsPreserveWindowsAndCancelDrag()
        try persistedLayoutReconcilesRemoteWindows()
        try automaticPlacementPreservesFramesAndWindows()
        try compactFocusPreservesTiledArrangement()
        try viewportDockPreservesSavedArrangement()
        try viewportChangesKeepUserLayoutEdits()
        try columnGapMovesOnlyAdjacentColumns()
        try squeezedColumnsReturnWithinOneDrag()
        try nestedGapsMoveOnlyAdjacentPanes()
        try sidebarResizeMovesOnlyLeadingColumn()
        print("窗口停靠十五组手动合同验证通过")
    }

    /// 左右三列 A | B | C：两栏预设再在整个排布右边加一列，树是 H(H(A, B), C)。内容区宽高不是 12 的倍数。
    private static func threeColumns(_ name: String, in bounds: CGRect, leading: CGFloat = 0,
                                     storageKey: String? = nil,
                                     defaults: UserDefaults = .standard) throws -> (WindowLayout, [Pane]) {
        let panes = fixturePanes(name, count: 3)
        let layout = WindowLayout(panes: panes, arrangement: .sideBySide, storageKey: storageKey, defaults: defaults)
        layout.updateViewport(bounds.size, presentation: .tiled, leading: leading)
        layout.focus(panes[1])
        layout.activate(panes[2], in: bounds)
        let canvas = layout.regions(in: bounds).canvas
        let frames = shownTiles(layout, in: bounds).panes
        guard let a = frames[panes[0]], let b = frames[panes[1]], let c = frames[panes[2]] else {
            throw DockContractError.failed("三列预设没有把三扇窗口都排上")
        }
        try require(a.maxX < b.minX && b.maxX < c.minX
                    && [a, b, c].allSatisfy { abs($0.height - canvas.height) < 0.001 },
                    "三列预设没有排成左右三列")
        return (layout, panes)
    }

    // 拖缝的几部分配合：起拖时记下的排布、嵌套两刀比例的连带调整、按比例排版的半点取整、松手保存与重建。
    // 第二条缝是根上那一刀，要同时改里面那刀的比例，不相邻的 A 才能一点不动；松手不再吸附到 12 点模数；
    // 重建后两刀比例排出同样的位置尺寸。
    private static func columnGapMovesOnlyAdjacentColumns() throws {
        let suite = "kite-window-contract-gap-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DockContractError.failed("无法建立拖缝的独立 UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let bounds = placementBounds(canvasWidth: 1218, canvasHeight: 810)
        let canvas = WindowRegions(in: bounds).canvas
        try require(abs(canvas.width - 1218) <= 1 && abs(canvas.height - 810) <= 1, "内容区仍取到模数：\(canvas.size)")
        let (layout, panes) = try threeColumns("gap", in: bounds, storageKey: "layout", defaults: defaults)
        let a = panes[0], b = panes[1], c = panes[2]
        let start = shownTiles(layout, in: bounds)
        let widths = [a, b, c].map { start.panes[$0]!.width }

        // 第一条缝：指针挪 37 点，A、B 就差 37 点，C 不动
        let first = try gap(between: a, and: b, in: start)
        try dragGap(first, by: 37, layout: layout, in: bounds)
        let afterFirst = [widths[0] + 37, widths[1] - 37, widths[2]]
        try requireFrames(shownTiles(layout, in: bounds).panes, row(panes, widths: afterFirst, in: canvas), fixed: [c], "拖第一条缝")
        layout.finishResize()
        try requireFrames(shownTiles(layout, in: bounds).panes, row(panes, widths: afterFirst, in: canvas), fixed: [c], "第一条缝松手")

        // 第二条缝：同一次拖动先往左再往右，只有 B、C 改宽，A 保持起拖时的宽度
        let second = try gap(between: b, and: c, in: shownTiles(layout, in: bounds))
        try dragGap(second, by: -19, layout: layout, in: bounds)
        try requireFrames(shownTiles(layout, in: bounds).panes,
                          row(panes, widths: [afterFirst[0], afterFirst[1] - 19, afterFirst[2] + 19], in: canvas),
                          fixed: [a], "第二条缝往左拖")
        try dragGap(second, by: 41, layout: layout, in: bounds)
        let afterSecond = [afterFirst[0], afterFirst[1] + 41, afterFirst[2] - 41]
        try requireFrames(shownTiles(layout, in: bounds).panes, row(panes, widths: afterSecond, in: canvas), fixed: [a], "第二条缝往右拖")
        layout.finishResize()
        let released = shownTiles(layout, in: bounds).panes
        try requireFrames(released, row(panes, widths: afterSecond, in: canvas), fixed: [a], "第二条缝松手")

        defaults.synchronize()
        let rebuilt = WindowLayout(panes: panes, arrangement: .stacked, storageKey: "layout",
                                   defaults: UserDefaults(suiteName: suite)!)
        rebuilt.updateViewport(bounds.size, presentation: .tiled)
        try requireFrames(shownTiles(rebuilt, in: bounds).panes, released, "拖缝松手后重建")
    }

    // 碰到最小尺寸：最小尺寸的夹取、起拖时的排布和拖动途中的状态合起来。往左拖根上那刀，B 先到最小再挤 A，
    // 拖到底两边都停在最小尺寸；同一次拖动拖回起点，中途被挤小的 A、B 原样回来；往右拖到底只挤 C，A 不动。
    private static func squeezedColumnsReturnWithinOneDrag() throws {
        let bounds = placementBounds(canvasWidth: 1218, canvasHeight: 810)
        let canvas = WindowRegions(in: bounds).canvas
        let (layout, panes) = try threeColumns("squeeze", in: bounds)
        let a = panes[0], b = panes[1], c = panes[2]
        let start = shownTiles(layout, in: bounds)
        let widths = [a, b, c].map { start.panes[$0]!.width }
        let minimum = Metrics.minPane
        let cut = try gap(between: b, and: c, in: start)
        try require(abs(cut.region.minX - canvas.minX) < 0.001 && abs(cut.region.maxX - canvas.maxX) < 0.001,
                    "B、C 之间的缝不是整个排布的那一刀")

        // B 到最小后 A 再让 20
        let past = widths[1] - minimum + 20
        try dragGap(cut, by: -past, layout: layout, in: bounds)
        let left = squeezed([widths[1], widths[0]], by: past)
        try requireFrames(shownTiles(layout, in: bounds).panes,
                          row(panes, widths: [left[1], left[0], widths[2] + past], in: canvas), "B 到最小后继续往左拖")
        try dragGap(cut, by: -canvas.width, layout: layout, in: bounds)
        try requireFrames(shownTiles(layout, in: bounds).panes,
                          row(panes, widths: [minimum, minimum, canvas.width - minimum * 2 - Metrics.gap * 2], in: canvas),
                          "往左拖到底")
        try dragGap(cut, by: 0, layout: layout, in: bounds)
        try requireFrames(shownTiles(layout, in: bounds).panes, start.panes, "同一次拖动拖回起点")
        try dragGap(cut, by: canvas.width, layout: layout, in: bounds)
        try requireFrames(shownTiles(layout, in: bounds).panes,
                          row(panes, widths: [widths[0], widths[1] + widths[2] - minimum, minimum], in: canvas),
                          fixed: [a], "往右拖到底")
        try dragGap(cut, by: 0, layout: layout, in: bounds)
        layout.finishResize()
        try requireFrames(shownTiles(layout, in: bounds).panes, start.panes, "往右拖到底再拖回起点松手")
    }

    // 嵌套分栏：A | B/C/D | E（左一右三再在右边加一列）。左右缝一侧是上下切开的一整列，B、C、D 都贴着缝，一起改宽，
    // 缝另一侧更远的 A 不动；上下缝只改上下紧挨着的两扇，同一列里更远的那扇保持高度。要几刀比例连带调整合起来才知道。
    private static func nestedGapsMoveOnlyAdjacentPanes() throws {
        let bounds = placementBounds(canvasWidth: 1218, canvasHeight: 810)
        let canvas = WindowRegions(in: bounds).canvas
        let panes = fixturePanes("nested", count: 5)
        let a = panes[0], b = panes[1], c = panes[2], d = panes[3], e = panes[4]
        let layout = WindowLayout(panes: panes, arrangement: .oneAndThree)
        layout.updateViewport(bounds.size, presentation: .tiled)
        layout.focus(b)
        layout.activate(e, in: bounds)
        let start = shownTiles(layout, in: bounds).panes
        guard let fa = start[a], let fb = start[b], let fc = start[c], let fd = start[d], let fe = start[e] else {
            throw DockContractError.failed("嵌套预设没有把五扇窗口都排上")
        }
        try require(abs(fa.height - canvas.height) < 0.001 && abs(fe.height - canvas.height) < 0.001
                    && abs(fe.maxX - canvas.maxX) < 0.001 && fa.maxX < fb.minX && fb.maxX < fe.minX
                    && [fc, fd].allSatisfy { abs($0.minX - fb.minX) < 0.001 && abs($0.width - fb.width) < 0.001 }
                    && fb.maxY < fc.minY && fc.maxY < fd.minY,
                    "嵌套预设没有排成 A | B/C/D | E")
        let minimum = Metrics.minPane
        try require(fb.width - 31 > minimum && fb.height + 29 > minimum && fc.height - 29 - 23 > minimum,
                    "嵌套预设的窗口太小，拖缝会碰到最小尺寸")

        // 左右缝：整列 B、C、D 变窄，E 变宽，A 不动
        var expected = start
        let column = try gap(between: b, and: e, in: shownTiles(layout, in: bounds))
        try dragGap(column, by: -31, layout: layout, in: bounds)
        for pane in [b, c, d] {
            let frame = start[pane]!
            expected[pane] = CGRect(x: frame.minX, y: frame.minY, width: frame.width - 31, height: frame.height)
        }
        expected[e] = CGRect(x: fe.minX - 31, y: fe.minY, width: fe.width + 31, height: fe.height)
        try requireFrames(shownTiles(layout, in: bounds).panes, expected, fixed: [a], "拖整列右边的左右缝")
        layout.finishResize()
        try requireFrames(shownTiles(layout, in: bounds).panes, expected, fixed: [a], "左右缝松手")

        // 上下缝：B、C 之间往下 29，D 不动；C、D 之间往上 23，B 不动
        let upper = try gap(between: b, and: c, in: shownTiles(layout, in: bounds))
        try dragGap(upper, by: 29, layout: layout, in: bounds)
        let b1 = expected[b]!, c1 = expected[c]!
        expected[b] = CGRect(x: b1.minX, y: b1.minY, width: b1.width, height: b1.height + 29)
        expected[c] = CGRect(x: c1.minX, y: c1.minY + 29, width: c1.width, height: c1.height - 29)
        try requireFrames(shownTiles(layout, in: bounds).panes, expected, fixed: [a, d, e], "拖 B、C 之间的上下缝")
        layout.finishResize()
        let lower = try gap(between: c, and: d, in: shownTiles(layout, in: bounds))
        try dragGap(lower, by: -23, layout: layout, in: bounds)
        let c2 = expected[c]!, d2 = expected[d]!
        expected[c] = CGRect(x: c2.minX, y: c2.minY, width: c2.width, height: c2.height - 23)
        expected[d] = CGRect(x: d2.minX, y: d2.minY - 23, width: d2.width, height: d2.height + 23)
        try requireFrames(shownTiles(layout, in: bounds).panes, expected, fixed: [a, b, e], "拖 C、D 之间的上下缝")
        layout.finishResize()
        try requireFrames(shownTiles(layout, in: bounds).panes, expected, fixed: [a, b, e], "上下缝松手")
    }

    // 侧栏改宽：视口更新判断改宽来源、本轮起始排布的记录、最小尺寸夹取和按比例排版合起来。左边不动的系统改尺寸仍按比例分；
    // 宽度变化等于左边挪的那段时只改贴着侧栏的 A，A 到最小再依次挤 B、C；同一轮都从第一次改之前的排布算，
    // 改回去中途被挤小的 B、C 原样回来，收起再展开也回到原样。
    private static func sidebarResizeMovesOnlyLeadingColumn() throws {
        let leading: CGFloat = 200
        let narrow = placementBounds(canvasWidth: 1000, canvasHeight: 810)
        let bounds = placementBounds(canvasWidth: 1218, canvasHeight: 810)
        let (layout, panes) = try threeColumns("sidebar", in: narrow, leading: leading)
        layout.updateViewport(bounds.size, presentation: .tiled, leading: leading)
        let (reference, _) = try threeColumns("sidebar", in: bounds, leading: leading)
        let start = shownTiles(layout, in: bounds).panes
        try requireFrames(start, shownTiles(reference, in: bounds).panes, "系统窗口改尺寸后按比例分")

        let widths = panes.map { start[$0]!.width }
        let minimum = Metrics.minPane
        let steps: [(CGFloat, String)] = [
            (40, "侧栏加宽 40"),
            ((widths[0] - minimum).rounded(.up) + 30, "A 到最小后挤 B"),
            ((widths[0] - minimum + widths[1] - minimum).rounded(.up) + 40, "A、B 到最小后挤 C"),
            (40, "侧栏改回加宽 40"),
            (0, "侧栏改回原宽"),
            (-leading, "侧栏收起"),
            (0, "侧栏展开回原宽"),
        ]
        for (shift, step) in steps {
            let size = CGSize(width: bounds.width - shift, height: bounds.height)
            layout.updateViewport(size, presentation: .tiled, leading: leading + shift)
            let current = CGRect(origin: .zero, size: size)
            let expected = squeezed(widths, by: shift)
            // 贴着侧栏的 A 之外，没被挤到的列尺寸一点不变
            let fixed = panes.indices.dropFirst().filter { expected[$0] == widths[$0] }.map { panes[$0] }
            try requireFrames(shownTiles(layout, in: current).panes,
                              row(panes, widths: expected, in: layout.regions(in: current).canvas),
                              fixed: fixed, step)
        }
    }

    // 紧凑视口、焦点切换与 UserDefaults 交接：选择原 dock 窗口不能把单卡片投影写成原宽屏排布。
    private static func compactFocusPreservesTiledArrangement() throws {
        let suite = "kite-window-contract-compact-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DockContractError.failed("无法建立紧凑视口的独立 UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let panes = fixturePanes("compact", count: 5)
        let layout = WindowLayout(panes: panes, arrangement: .oneAndThree,
                                  storageKey: "layout", defaults: defaults)
        let wide = roomyBounds
        let compact = CGRect(x: 0, y: 0, width: 360, height: 760)
        layout.updateViewport(wide.size, presentation: .tiled)
        let canvas = WindowRegions(in: wide).canvas
        guard let gap = layout.root?.layout(in: canvas).gaps.first,
              let docked = layout.docked.first else {
            throw DockContractError.failed("紧凑往返需要已分栏的活动窗口和 dock 窗口")
        }
        layout.resize(gap, to: CGPoint(x: gap.rect.midX + 40, y: gap.rect.midY))
        layout.finishResize()
        layout.focus(panes[1])
        let original = LayoutState(layout, in: wide)

        layout.updateViewport(compact.size, presentation: .compact)
        try requireSame(layout, as: original, in: wide, "进入紧凑视口")
        layout.activate(docked, in: compact)
        try require(layout.focused == docked, "紧凑视口选择 dock 窗口没有聚焦它")
        try requireArrangement(layout, as: original, in: wide, "紧凑视口选择 dock 窗口")
        layout.updateViewport(wide.size, presentation: .tiled)
        try requireArrangement(layout, as: original, in: wide, "聚焦 dock 窗口后恢复宽屏")
        try require(layout.focused == docked && (layout.shown?.panes ?? []).contains(docked),
                    "紧凑视口选中的 dock 窗口回到宽屏后不可见")
        try requireProjectionComplete(layout, "宽屏临时显示聚焦的 dock 窗口")
        layout.minimize(docked)
        try requireArrangement(layout, as: original, in: wide, "收起临时显示的 dock 窗口")
        try require(layout.shown?.layout(in: canvas).panes == original.frames && layout.shownDock == original.docked,
                    "收起临时显示的 dock 窗口后没有恢复原宽屏排布")
        try requireProjectionComplete(layout, "收起临时显示的 dock 窗口后")
        layout.updateViewport(compact.size, presentation: .compact)
        layout.focus(panes[2])
        try require(layout.focused == panes[2], "紧凑视口再次切换焦点没有更新当前卡片")
        try requireArrangement(layout, as: original, in: wide, "紧凑视口切回原活动窗口")
        try requireComplete(layout, "紧凑视口切换焦点后")

        defaults.synchronize()
        let rebuilt = WindowLayout(panes: panes, arrangement: .stacked, storageKey: "layout",
                                   defaults: UserDefaults(suiteName: suite)!)
        rebuilt.updateViewport(compact.size, presentation: .compact)
        try requireArrangement(rebuilt, as: original, in: wide, "紧凑视口重建")
        try require(rebuilt.focused == panes[2], "紧凑视口重建没有保留新焦点")
        for current in [layout, rebuilt] {
            current.updateViewport(wide.size, presentation: .tiled)
            try requireArrangement(current, as: original, in: wide, "恢复宽屏")
            try require(current.focused == panes[2] && current.shown?.layout(in: canvas).panes == original.frames
                        && current.shownDock == original.docked,
                        "恢复宽屏没有恢复原分栏比例、dock 与当前焦点")
            try requireProjectionComplete(current, "紧凑往返后")
        }
    }

    // 尺寸投影、临时停靠与持久化交接：空间不足不能永久收起卡片，重建后仍须能恢复原排布。
    private static func viewportDockPreservesSavedArrangement() throws {
        let suite = "kite-window-contract-viewport-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DockContractError.failed("无法建立视口投影的独立 UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let panes = fixturePanes("viewport", count: 5)
        let layout = WindowLayout(panes: panes, arrangement: .oneAndThree,
                                  storageKey: "layout", defaults: defaults)
        let wide = roomyBounds
        let tight = placementBounds(canvasWidth: Metrics.minPane * 2 + Metrics.gap,
                                    canvasHeight: Metrics.minPane)
        layout.updateViewport(wide.size, presentation: .tiled)
        layout.focus(panes[2])
        let original = LayoutState(layout, in: wide)
        layout.updateViewport(tight.size, presentation: .tiled)
        try requireSame(layout, as: original, in: wide, "缩小宽屏空间")
        let visible = layout.shown?.panes ?? []
        let temporarilyDocked = original.active.filter { !visible.contains($0) }
        try require(!temporarilyDocked.isEmpty && visible.contains(panes[2])
                    && temporarilyDocked.allSatisfy { layout.shownDock.contains($0) }
                    && original.docked.allSatisfy { layout.shownDock.contains($0) },
                    "空间不足时没有保留聚焦卡片，或临时收起的卡片未进入停靠栏")
        let frames = layout.shown?.layout(in: WindowRegions(in: tight).canvas).panes ?? [:]
        for frame in frames.values {
            try require(frame.width + 0.001 >= Metrics.minPane && frame.height + 0.001 >= Metrics.minPane,
                        "投影仍把放不下的卡片挤在内容区")
        }
        try requireProjectionComplete(layout, "空间不足时")

        defaults.synchronize()
        let rebuilt = WindowLayout(panes: panes, arrangement: .stacked, storageKey: "layout",
                                   defaults: UserDefaults(suiteName: suite)!)
        rebuilt.updateViewport(tight.size, presentation: .tiled)
        try requireSame(rebuilt, as: original, in: wide, "空间不足时重建")
        try requireProjectionComplete(rebuilt, "空间不足时重建")
        for current in [layout, rebuilt] {
            current.updateViewport(wide.size, presentation: .tiled)
            try requireSame(current, as: original, in: wide, "空间恢复")
            try require(current.shown?.layout(in: WindowRegions(in: wide).canvas).panes == original.frames
                        && current.shownDock == original.docked,
                        "空间恢复后临时停靠仍占用了原活动窗口")
            try requireProjectionComplete(current, "空间恢复后")
        }
    }

    // 暂时停靠时调整分栏、点击、拖放与视口往返交接：投影不能吞掉用户动作，也不能覆盖已提交排布。
    private static func viewportChangesKeepUserLayoutEdits() throws {
        let panes = fixturePanes("viewport-edits", count: 4)
        let wide = roomyBounds
        let tight = placementBounds(canvasWidth: Metrics.minPane * 2 + Metrics.gap + 160,
                                    canvasHeight: Metrics.minPane)
        let activation = WindowLayout(panes: panes, arrangement: .oneAndThree)
        activation.updateViewport(wide.size, presentation: .tiled)
        let beforeResize = LayoutState(activation, in: wide)
        activation.updateViewport(tight.size, presentation: .tiled)
        let tightCanvas = WindowRegions(in: tight).canvas
        guard let projected = activation.shown?.layout(in: tightCanvas), let gap = projected.gaps.first else {
            throw DockContractError.failed("临时停靠后没有保留可调整的分栏")
        }
        try require((activation.shown?.panes.count ?? 0) < beforeResize.active.count,
                    "分栏调整验证没有临时省略任何活动窗口")
        activation.resize(gap, to: CGPoint(x: gap.rect.midX + 40, y: gap.rect.midY))
        activation.finishResize()
        try require(activation.shown?.layout(in: tightCanvas).panes != projected.panes,
                    "临时停靠时调整分栏没有改变当前卡片帧")
        let afterResize = LayoutState(activation, in: wide)
        try require(afterResize.frames != beforeResize.frames,
                    "投影分栏已调整，但原宽屏排布仍保留旧比例")
        activation.updateViewport(wide.size, presentation: .tiled)
        try requireSame(activation, as: afterResize, in: wide, "投影分栏调整后恢复宽屏")
        try require(activation.shown?.layout(in: WindowRegions(in: wide).canvas).panes == afterResize.frames
                    && activation.shown?.panes == beforeResize.active
                    && activation.shownDock == beforeResize.docked,
                    "恢复宽屏没有同时保留原窗口与调整后的分栏比例")
        activation.updateViewport(tight.size, presentation: .tiled)
        guard let activated = activation.shownDock.first(where: { !activation.docked.contains($0) }) else {
            throw DockContractError.failed("用户操作验证没有暂时停靠的窗口")
        }
        activation.activate(activated, in: tight)
        try require(activation.focused == activated && (activation.shown?.panes ?? []).contains(activated),
                    "激活暂时停靠的窗口后没有展开并聚焦它")
        try requireProjectionComplete(activation, "激活暂时停靠的窗口后")

        let layout = WindowLayout(panes: panes, arrangement: .oneAndThree)
        layout.updateViewport(wide.size, presentation: .tiled)
        layout.updateViewport(tight.size, presentation: .tiled)
        guard let restored = layout.shownDock.first(where: { !layout.docked.contains($0) }) else {
            throw DockContractError.failed("没有暂时停靠的窗口供点击恢复")
        }
        layout.restore(restored, in: tight)
        try require(layout.focused == restored && (layout.shown?.panes ?? []).contains(restored),
                    "恢复暂时停靠的窗口后没有展开并聚焦它")
        try requireProjectionComplete(layout, "恢复暂时停靠的窗口后")

        let dockFrame = WindowRegions(in: tight).dockFrame(at: layout.shownDock.count)
        layout.drag(restored, to: dockFrame.center, in: tight)
        layout.drop(in: tight)
        try require(layout.docked.contains(restored) && !(layout.root?.panes ?? []).contains(restored),
                    "用户主动拖进停靠栏的窗口没有从保存排布中移出")
        let committed = LayoutState(layout, in: wide)
        layout.updateViewport(wide.size, presentation: .tiled)
        try requireSame(layout, as: committed, in: wide, "拖动后恢复宽屏")
        try require(layout.shownDock.contains(restored) && !(layout.shown?.panes ?? []).contains(restored),
                    "恢复宽屏撤销了用户主动停靠")
        layout.restore(restored, in: wide)
        try require(layout.focused == restored && !layout.docked.contains(restored)
                    && (layout.shown?.panes ?? []).contains(restored),
                    "用户主动恢复停靠窗口没有更新排布")
        let afterRestore = LayoutState(layout, in: wide)
        layout.updateViewport(CGSize(width: 360, height: 760), presentation: .compact)
        layout.updateViewport(wide.size, presentation: .tiled)
        try requireSame(layout, as: afterRestore, in: wide, "恢复卡片后切换布局")
        try requireProjectionComplete(layout, "用户修改排布后切换布局")

        // 系统在手势中途调整尺寸或模式时，旧落点与占位不能成为新视口的已提交排布。
        let canvas = WindowRegions(in: wide).canvas
        let destinations: [(CGSize, WorkspacePresentation)] = [
            (tight.size, .tiled), (CGSize(width: 360, height: 760), .compact),
        ]
        for (size, presentation) in destinations {
            layout.updateViewport(wide.size, presentation: .tiled)
            layout.drag(restored, to: CGPoint(x: canvas.minX + 1, y: canvas.midY), in: wide)
            try require(layout.drag != nil && layout.shown?.layout(in: canvas).placeholder != nil,
                        "视口切换前没有形成未提交的拖动占位")
            layout.updateViewport(size, presentation: presentation)
            try require(layout.drag == nil, "视口变化没有取消未提交拖动")
            try requireSame(layout, as: afterRestore, in: wide, "拖动中改变视口")
            layout.drop(in: CGRect(origin: .zero, size: size))
            try requireSame(layout, as: afterRestore, in: wide, "视口变化后松开旧拖动")
        }
        layout.updateViewport(wide.size, presentation: .tiled)
        try require(layout.shown?.layout(in: canvas).placeholder == nil,
                    "拖动中切换视口后仍残留占位")
        try requireProjectionComplete(layout, "视口变化取消拖动后")
    }

    private static var roomyBounds: CGRect {
        placementBounds(canvasWidth: Metrics.minPane * 3 + Metrics.gap * 2 + 120,
                        canvasHeight: Metrics.minPane * 3 + Metrics.gap * 2 + 120)
    }

    // 自动放置、真实 frame、焦点、dock 与 UserDefaults 交接；树的最小尺寸不足以保证嵌套分栏比例可用。
    private static func automaticPlacementPreservesFramesAndWindows() throws {
        let suite = "kite-window-contract-placement-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DockContractError.failed("无法建立自动放置的独立 UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = fixturePanes("placement", count: 3)
        let a = initial[0], b = initial[1], opened = initial[2]
        let minimum = Metrics.minPane
        let gap = Metrics.gap

        // 三列能放下时，新窗口占根级右侧全高；原两列在新子树里的实际宽度也须达标。
        let wide = placementBounds(canvasWidth: minimum * 3 + gap * 2 + 20,
                                   canvasHeight: minimum * 2 + gap + 30)
        let columns = WindowLayout(panes: initial, arrangement: .sideBySide,
                                   storageKey: "columns", defaults: defaults)
        columns.focus(b)
        columns.activate(opened, in: wide)
        let columnState = LayoutState(columns, in: wide)
        let canvas = WindowRegions(in: wide).canvas
        guard let newColumn = columnState.frames[opened] else {
            throw DockContractError.failed("可容纳三列时新增窗口仍在 dock")
        }
        try require(abs(newColumn.minY - canvas.minY) < 0.001
                    && abs(newColumn.height - canvas.height) < 0.001
                    && abs(newColumn.maxX - canvas.maxX) < 0.001,
                    "新增窗口没有成为根级右侧全高列")
        try require([a, b].allSatisfy { pane in
            guard let frame = columnState.frames[pane] else { return false }
            return frame.maxX + gap <= newColumn.minX + 0.001
        }, "新增列插进了旧窗口的局部分栏")
        try require(columns.focused == opened && columns.docked.isEmpty
                    && Set(columns.panes) == Set(initial), "新增列改变了窗口集合、dock 或焦点")
        try requireMinimumFrames(columns, in: wide, "新增根级列")
        try requireComplete(columns, "新增根级列")

        let remote = Pane("contract-placement-remote")
        columns.reconcile(initial + [remote])
        try require(LayoutState(columns, in: wide).frames == columnState.frames
                    && columns.docked == [remote] && columns.focused == opened,
                    "远端新增窗口改变活动分栏或抢走焦点")
        try requirePlacementPersists(columns, panes: initial + [remote], key: "columns",
                                     defaults: defaults, suite: suite, in: wide)

        // 宽度只能容纳两列时，恢复窗口优先放在可分栏的聚焦窗口下方。
        let tall = placementBounds(canvasWidth: minimum * 2 + gap,
                                   canvasHeight: minimum * 2 + gap)
        let below = WindowLayout(panes: initial, arrangement: .sideBySide,
                                 storageKey: "below", defaults: defaults)
        below.focus(b)
        let beforeBelow = LayoutState(below, in: tall)
        below.restore(opened, in: tall)
        let belowState = LayoutState(below, in: tall)
        guard let focusedFrame = belowState.frames[b], let restoredFrame = belowState.frames[opened] else {
            throw DockContractError.failed("恢复窗口没有进入聚焦窗口的分栏")
        }
        try require(belowState.frames[a] == beforeBelow.frames[a]
                    && abs(focusedFrame.minX - restoredFrame.minX) < 0.001
                    && abs(focusedFrame.width - restoredFrame.width) < 0.001
                    && abs(focusedFrame.maxY + gap - restoredFrame.minY) < 0.001,
                    "恢复窗口未放在聚焦窗口下方，或改变了另一列")
        try require(below.focused == opened && below.docked.isEmpty
                    && Set(below.panes) == Set(initial), "下方分栏改变了窗口集合、dock 或焦点")
        try requireMinimumFrames(below, in: tall, "恢复到聚焦窗口下方")
        try requireComplete(below, "恢复到聚焦窗口下方")
        try requirePlacementPersists(below, panes: initial, key: "below",
                                     defaults: defaults, suite: suite, in: tall)

        // 两列都不能再分割时，保留聚焦窗口，把非聚焦窗口收进 dock 并让新窗口接住原位置。
        let tight = placementBounds(canvasWidth: minimum * 2 + gap, canvasHeight: minimum)
        let replacement = WindowLayout(panes: initial, arrangement: .sideBySide,
                                       storageKey: "replacement", defaults: defaults)
        replacement.focus(b)
        let beforeReplacement = LayoutState(replacement, in: tight)
        replacement.activate(opened, in: tight)
        let replaced = LayoutState(replacement, in: tight)
        try require(replaced.frames[opened] == beforeReplacement.frames[a]
                    && replaced.frames[b] == beforeReplacement.frames[b]
                    && replacement.docked == [a] && replacement.focused == opened
                    && Set(replacement.panes) == Set(initial),
                    "放不下时未替换非聚焦窗口的原位置，或丢失了窗口")
        try requireMinimumFrames(replacement, in: tight, "替换非聚焦窗口")
        try requireComplete(replacement, "替换非聚焦窗口")
        try requirePlacementPersists(replacement, panes: initial, key: "replacement",
                                     defaults: defaults, suite: suite, in: tight)
    }

    private static func placementBounds(canvasWidth: CGFloat, canvasHeight: CGFloat) -> CGRect {
        let canvas = WindowRegions(in: bounds).canvas
        return CGRect(x: 0, y: 0, width: canvasWidth + bounds.width - canvas.width,
                      height: canvasHeight + bounds.height - canvas.height)
    }

    private static func requireMinimumFrames(_ layout: WindowLayout, in bounds: CGRect, _ step: String) throws {
        for (pane, frame) in LayoutState(layout, in: bounds).frames {
            try require(frame.width + 0.001 >= Metrics.minPane && frame.height + 0.001 >= Metrics.minPane,
                        "\(step) 后 \(pane.id) 的实际 frame 小于 minPane：\(frame)")
        }
    }

    private static func requirePlacementPersists(_ layout: WindowLayout, panes: [Pane], key: String,
                                               defaults: UserDefaults, suite: String, in bounds: CGRect) throws {
        let committed = LayoutState(layout, in: bounds)
        defaults.synchronize()
        let rebuilt = WindowLayout(panes: panes, arrangement: .stacked, storageKey: key,
                                   defaults: UserDefaults(suiteName: suite)!)
        try requireSame(rebuilt, as: committed, in: bounds, "自动放置的 \(key) 重建")
        try requireComplete(rebuilt, "自动放置的 \(key) 重建")
    }

    // 卡片树、dock、焦点和恢复在连续转移中保持同一组窗口；最后一张卡片可离开树。
    private static func allCardsCanDockAndReturn() throws {
        let layout = WindowLayout(panes: fixturePanes("dock-return", count: 4), arrangement: .oneAndThree)
        let opened = layout.panes
        try require(opened.count >= 2, "预设没有足够的卡片来验证恢复")
        for (index, pane) in opened.enumerated() {
            dock(pane, layout: layout, in: bounds)
            try require(layout.docked == Array(opened.prefix(index + 1)), "停靠未按拖动顺序追加")
            try require(!(layout.root?.panes ?? []).contains(pane), "已停靠卡片仍留在树中")
            try requireComplete(layout, "停靠第 \(index + 1) 张卡片后")
        }
        try require(layout.root == nil, "最后一张卡片停靠后内容树应为空")

        let regions = WindowRegions(in: bounds)
        let draggedBack = opened[0]
        layout.drag(draggedBack, to: regions.canvas.center, in: bounds)
        layout.drop(in: bounds)
        try require((layout.root?.panes ?? []).contains(draggedBack), "空内容区没有接住 dock 卡片")
        try require(!layout.docked.contains(draggedBack), "拖回的卡片仍在 dock 中")
        try requireComplete(layout, "拖回空内容区后")

        let restored = opened[1]
        layout.restore(restored, in: bounds)
        try require((layout.root?.panes ?? []).contains(restored), "点击恢复没有把卡片放回内容区")
        try require(!layout.docked.contains(restored), "点击恢复的卡片仍在 dock 中")
        try requireComplete(layout, "点击恢复后")
    }

    // dock 重排、无效落点与预设切换接连发生时，待提交拖动不能污染下一次布局。
    private static func reorderCancelAndSwitchArrangement() throws {
        let initial = fixturePanes("reorder", count: 2)
        let layout = WindowLayout(panes: initial, arrangement: .sideBySide)
        let firstTwo = layout.root?.panes ?? []
        try require(firstTwo.count == 2, "双栏预设没有两张卡片")
        for pane in firstTwo { dock(pane, layout: layout, in: bounds) }
        try require(layout.root == nil, "两张卡片都停靠后内容树应为空")

        let secondFrame = WindowRegions(in: bounds).dockFrame(at: 1)
        layout.drag(firstTwo[0], to: CGPoint(x: secondFrame.maxX - 1, y: secondFrame.midY), in: bounds)
        layout.drop(in: bounds)
        try require(layout.docked == [firstTwo[1], firstTwo[0]], "dock 圆未按拖放位置重排")
        try requireComplete(layout, "dock 重排后")

        let beforeInvalidDrop = LayoutState(layout, in: bounds)
        layout.drag(layout.docked[0], to: CGPoint(x: bounds.minX - 80, y: bounds.minY - 80), in: bounds)
        layout.drop(in: bounds)
        try requireSame(layout, as: beforeInvalidDrop, in: bounds, "无效落点")

        let beforeExpansion = layout.panes
        layout.reconcile(fixturePanes("reorder", count: 4))
        try require(layout.panes.count > beforeExpansion.count, "服务端新增窗口没有进入布局")
        let activeBeforeExpansion = layout.root?.panes.count ?? 0
        layout.drag(layout.docked[0], to: WindowRegions(in: bounds).canvas.center, in: bounds)
        layout.arrange(.oneAndThree)
        try require((layout.root?.panes.count ?? 0) > activeBeforeExpansion, "较大的预设没有展开已有窗口")
        try require(beforeExpansion.allSatisfy { layout.panes.contains($0) }, "切换预设丢失已打开窗口")
        try requireComplete(layout, "切换到较大预设后")
        let expanded = LayoutState(layout, in: bounds)
        layout.drop(in: bounds)
        try requireSame(layout, as: expanded, in: bounds, "切换预设后松开旧拖动")

        let allOpen = layout.panes
        guard let active = layout.root?.panes.first else { throw DockContractError.failed("较大的预设没有活动卡片") }
        layout.drag(active, to: WindowRegions(in: bounds).dockFrame(at: layout.docked.count).center, in: bounds)
        layout.arrange(.sideBySide)
        try require(allOpen.allSatisfy { layout.panes.contains($0) }, "较小预设丢失已打开窗口")
        let omitted = allOpen.filter { !(layout.root?.panes ?? []).contains($0) }
        try require(!omitted.isEmpty && omitted.allSatisfy { layout.docked.contains($0) }, "预设遗漏的窗口没有进入 dock")
        try requireComplete(layout, "切换到较小预设后")
        let reduced = LayoutState(layout, in: bounds)
        layout.drop(in: bounds)
        try requireSame(layout, as: reduced, in: bounds, "再次切换预设后松开旧拖动")
    }

    // 坐标命中画布外缘、浮动占位、落下后的分割帧要一致；整幅画布的边缘与单卡片边缘不能混淆。
    private static func canvasEdgesPreviewAndCommit() throws {
        let layout = WindowLayout(panes: fixturePanes("canvas-edges", count: 4), arrangement: .oneAndThree)
        let opened = layout.panes
        guard let floating = opened.last else { throw DockContractError.failed("四边停靠没有可拖动窗口") }
        dock(floating, layout: layout, in: bounds)
        try require((layout.root?.panes ?? []).count >= 2, "四边停靠需要多个其余窗口")
        let canvas = WindowRegions(in: bounds).canvas
        let points: [(Edge, CGPoint)] = [
            (.leading, CGPoint(x: canvas.minX + 1, y: canvas.midY)),
            (.trailing, CGPoint(x: canvas.maxX - 1, y: canvas.midY)),
            (.top, CGPoint(x: canvas.midX, y: canvas.minY + 1)),
            (.bottom, CGPoint(x: canvas.midX, y: canvas.maxY - 1)),
        ]

        for (edge, point) in points {
            layout.drag(floating, to: point, in: bounds)
            try require(layout.drag?.spot == DropSpot.edge(edge), "画布 \(edge) 内侧落点没有命中整体边缘")
            guard let placeholder = layout.shown?.layout(in: canvas).placeholder else {
                throw DockContractError.failed("画布 \(edge) 没有占位预览")
            }
            try requireSpansCanvas(placeholder, along: edge, canvas: canvas)

            layout.drop(in: bounds)
            guard let frames = layout.root?.layout(in: canvas).panes,
                  let finalFrame = frames[floating] else {
                throw DockContractError.failed("画布 \(edge) 落下后窗口没有进入卡片树")
            }
            try require(finalFrame == placeholder, "画布 \(edge) 的预览和最终窗口帧不一致")
            try requireOtherPanesAreOpposite(frames, floating: floating, at: edge)
            try require(layout.panes.count == opened.count && opened.allSatisfy { layout.panes.contains($0) },
                        "画布 \(edge) 落下后窗口丢失或重复")
            try requireComplete(layout, "画布 \(edge) 落下后")
            dock(floating, layout: layout, in: bounds)
        }

        guard let rest = layout.root?.layout(in: canvas).panes,
              let target = rest.first(where: { $0.value.minX > canvas.minX + 20 && $0.value.height < canvas.height - 20 }) else {
            throw DockContractError.failed("预设没有可验证局部分割的内部卡片")
        }
        layout.drag(floating, to: CGPoint(x: target.value.minX + 1, y: target.value.midY), in: bounds)
        try require(layout.drag?.spot == DropSpot.beside(target.key, .leading), "内部卡片边缘被误判为整体画布边缘")
        guard let localPlaceholder = layout.shown?.layout(in: canvas).placeholder else {
            throw DockContractError.failed("内部卡片没有局部分割预览")
        }
        try require(localPlaceholder.height < canvas.height - 1, "内部落点的占位铺满了整幅画布")
        layout.drop(in: bounds)
        try require(layout.root?.layout(in: canvas).panes[floating] == localPlaceholder,
                    "内部卡片的预览和最终窗口帧不一致")
        try requireComplete(layout, "内部卡片局部分割后")
    }

    // 真实 bug：iPad 上台面已有两个左右并排的窗口（触屏窗口最小宽 360），从停靠栏拖一个到内容区左右外缘，
    // 其余窗口照旧排、让出这一边放不下，这条边被判成没有落点，排布不换成沿这一边贴满的预览，只有卡片里的局部分栏在变。
    // 修法是挤不下时把离这条边远的那扇收进停靠栏。这里用 Mac 的最小宽 168 取窄内容区（放得下两列、放不下三列），
    // 同时验 Mac 窗口窄时也走这条路：落点判断、预览排布（shown、shownDock）与松手提交的状态交接，
    // 占位帧等于松手后的窗口帧，被腾出的窗口留在停靠栏末尾，树与停靠栏的窗口集合完整不重复。
    private static func narrowCanvasEdgeDocksFarthestPane() throws {
        let minimum = Metrics.minPane, gap = Metrics.gap
        let bounds = placementBounds(canvasWidth: 450, canvasHeight: 500)
        for edge in [Edge.leading, .trailing] {
            let panes = fixturePanes("narrow-edge-\(edge)", count: 4)
            let a = panes[0], b = panes[1], floating = panes[2], waiting = panes[3]
            let layout = WindowLayout(panes: panes, arrangement: .sideBySide)
            layout.updateViewport(bounds.size, presentation: .tiled)
            let canvas = layout.regions(in: bounds).canvas
            try require(canvas.width >= minimum * 2 + gap && canvas.width < minimum * 3 + gap * 2,
                        "窄内容区 \(canvas.width) 应放得下两列、放不下三列")
            try require(layout.shown?.panes == [a, b] && layout.shownDock == [floating, waiting],
                        "夹具没有排成台面左右两扇、停靠栏两扇")
            let (kept, pushed) = edge == .leading ? (a, b) : (b, a)
            let point = edge == .leading
                ? CGPoint(x: canvas.minX + 1, y: canvas.midY)
                : CGPoint(x: canvas.maxX - 1, y: canvas.midY)

            layout.drag(floating, to: point, in: bounds)
            try require(layout.drag?.spot == DropSpot.edge(edge),
                        "窄内容区 \(edge) 外缘没有成为整条边的落点，实际 \(String(describing: layout.drag?.spot))")
            guard let preview = layout.shown?.layout(in: canvas), let placeholder = preview.placeholder else {
                throw DockContractError.failed("窄内容区 \(edge) 外缘没有占位预览")
            }
            try requireSpansCanvas(placeholder, along: edge, canvas: canvas)
            try require(Array(preview.panes.keys) == [kept],
                        "窄内容区 \(edge) 的预览台面上应只留离这条边近的 \(kept.id)，实际 \(preview.panes.keys.map(\.id))")
            try require(layout.shownDock.contains(pushed) && layout.shownDock.contains(waiting)
                        && !layout.shownDock.contains(kept) && !layout.shownDock.contains(floating),
                        "窄内容区 \(edge) 的预览停靠栏应有被腾出的 \(pushed.id)，实际 \(layout.shownDock.map(\.id))")
            let previewed = Array(preview.panes.keys) + layout.shownDock + [floating]
            try require(previewed.count == panes.count && Set(previewed) == Set(panes),
                        "窄内容区 \(edge) 的预览遗漏或重复了窗口")

            layout.drop(in: bounds)
            let committed = shownTiles(layout, in: bounds).panes
            guard let placed = committed[floating] else {
                throw DockContractError.failed("窄内容区 \(edge) 松手后放进去的窗口不在台面上")
            }
            try require(placed == placeholder, "窄内容区 \(edge) 的预览占位 \(placeholder) 和松手后的窗口帧 \(placed) 不一致")
            try require(committed[kept] == preview.panes[kept],
                        "窄内容区 \(edge) 留在台面上的 \(kept.id) 松手后和预览位置不一致")
            try require(Set(committed.keys) == [floating, kept] && Set(layout.root?.panes ?? []) == [floating, kept],
                        "窄内容区 \(edge) 松手后台面应是放进去的窗口和 \(kept.id)")
            try require(layout.docked == [waiting, pushed],
                        "窄内容区 \(edge) 被腾出的 \(pushed.id) 没有追加到停靠栏末尾，实际 \(layout.docked.map(\.id))")
            try requireProjectionComplete(layout, "窄内容区 \(edge) 松手后")
        }
    }

    // 这个方向连两张卡片都放不下时，这条边才不算落点：内容区比两列窄，左边外缘没有落点，松手回原位；
    // 同一内容区上下放得下两张，顶边仍是落点，挡住把「没有落点」放宽到所有方向。
    private static func canvasTooNarrowForTwoHasNoSideEdge() throws {
        let minimum = Metrics.minPane, gap = Metrics.gap
        let bounds = placementBounds(canvasWidth: 300, canvasHeight: 500)
        let panes = fixturePanes("too-narrow-edge", count: 4)
        let floating = panes[2]
        let layout = WindowLayout(panes: panes, arrangement: .sideBySide)
        layout.updateViewport(bounds.size, presentation: .tiled)
        let canvas = layout.regions(in: bounds).canvas
        try require(canvas.width < minimum * 2 + gap && canvas.height >= minimum * 2 + gap,
                    "内容区 \(canvas.size) 应左右放不下两列、上下放得下两行")
        let before = LayoutState(layout, in: bounds)

        layout.drag(floating, to: CGPoint(x: canvas.minX + 1, y: canvas.midY), in: bounds)
        try require(layout.drag != nil && layout.drag?.spot == nil,
                    "左右放不下两张卡片时左边外缘仍成了落点：\(String(describing: layout.drag?.spot))")
        layout.drop(in: bounds)
        try requireSame(layout, as: before, in: bounds, "左边外缘没有落点时松手")
        try requireProjectionComplete(layout, "左边外缘没有落点时松手后")

        layout.drag(floating, to: CGPoint(x: canvas.midX, y: canvas.minY + 1), in: bounds)
        try require(layout.drag?.spot == DropSpot.edge(.top),
                    "上下放得下两张卡片时顶边不是落点：\(String(describing: layout.drag?.spot))")
        layout.cancelDrag()
        try requireSame(layout, as: before, in: bounds, "取消顶边拖动")
    }

    // 展开、恢复、缩小与服务端删除连续改变树与 dock；各动作取消拖动，旧 drop 不能让已删窗口复活。
    private static func headerActionsPreserveWindowsAndCancelDrag() throws {
        let layout = WindowLayout(panes: fixturePanes("header-actions", count: 4), arrangement: .oneAndThree)
        let opened = layout.panes
        try require(opened.count >= 4, "预设没有足够窗口验证展开与删除")
        let initiallyDocked = opened.last!
        dock(initiallyDocked, layout: layout, in: bounds)
        let activeBefore = layout.root?.panes ?? []
        try require(activeBefore.count >= 3, "展开前需要多个活动窗口")
        let expanded = activeBefore[1]
        let restored = activeBefore[0]

        layout.drag(restored, to: WindowRegions(in: bounds).dockFrame(at: layout.docked.count).center, in: bounds)
        try require(layout.drag != nil, "展开前没有形成待提交拖动")
        layout.expand(expanded)
        try require(layout.drag == nil, "展开没有取消旧拖动")
        try require(layout.root?.panes == [expanded], "展开没有让目标窗口独占内容区")
        try require(layout.docked == [initiallyDocked] + activeBefore.filter { $0 != expanded },
                    "展开没有按原树顺序把其余窗口追加到 dock")
        try require(layout.focused == expanded, "展开后焦点没有指向目标窗口")
        let afterExpand = LayoutState(layout, in: bounds)
        layout.drop(in: bounds)
        try requireSame(layout, as: afterExpand, in: bounds, "展开后松开旧拖动")
        try requireComplete(layout, "展开后")

        layout.restore(restored, in: bounds)
        try require((layout.root?.panes ?? []).count == 2
                    && (layout.root?.panes ?? []).contains(expanded)
                    && (layout.root?.panes ?? []).contains(restored),
                    "恢复没有从单窗口布局加入目标卡片")
        try require(!layout.docked.contains(restored), "恢复的窗口仍在 dock")
        try requireComplete(layout, "展开后恢复一张卡片")

        let dockBeforeMinimize = layout.docked
        layout.drag(expanded, to: WindowRegions(in: bounds).dockFrame(at: layout.docked.count).center, in: bounds)
        try require(layout.drag != nil, "缩小前没有形成待提交拖动")
        layout.minimize(expanded)
        try require(layout.drag == nil, "缩小没有取消旧拖动")
        try require(layout.root?.panes == [restored], "缩小后内容区没有保留其余卡片")
        try require(layout.docked == dockBeforeMinimize + [expanded], "缩小没有把窗口追加到 dock 一次")
        let afterMinimize = LayoutState(layout, in: bounds)
        layout.drop(in: bounds)
        try requireSame(layout, as: afterMinimize, in: bounds, "缩小后松开旧拖动")
        try requireComplete(layout, "缩小后")

        layout.drag(restored, to: WindowRegions(in: bounds).dockFrame(at: layout.docked.count).center, in: bounds)
        try require(layout.drag != nil, "服务端删除前没有形成待提交拖动")
        layout.reconcile(opened.filter { $0 != restored })
        try require(layout.drag == nil, "服务端删除没有取消旧拖动")
        try require(layout.root == nil && !layout.docked.contains(restored) && !layout.panes.contains(restored),
                    "服务端删除活动窗口后仍能在树或 dock 找到它")
        let afterClose = LayoutState(layout, in: bounds)
        layout.drop(in: bounds)
        try requireSame(layout, as: afterClose, in: bounds, "服务端删除后松开旧拖动")
        try requireComplete(layout, "服务端删除活动窗口后")

        for pane in Array(layout.docked) {
            layout.reconcile(layout.panes.filter { $0 != pane })
            try require(!layout.panes.contains(pane), "服务端删除 dock 窗口后仍可找到它")
            try requireComplete(layout, "逐个删除 dock 窗口后")
        }
        try require(layout.root == nil && layout.docked.isEmpty && layout.panes.isEmpty
                    && layout.shown == nil && layout.focused == nil && layout.drag == nil,
                    "服务端删除最后一扇窗口后布局或焦点没有清空")
    }

    // UserDefaults 重建与服务端集合变化交错：已提交布局保留，新 ID 入 dock，远程删除不能被旧拖动或缓存复活。
    private static func persistedLayoutReconcilesRemoteWindows() throws {
        let suiteA = "kite-window-contract-a-\(UUID().uuidString)"
        let suiteB = "kite-window-contract-b-\(UUID().uuidString)"
        guard let defaultsA = UserDefaults(suiteName: suiteA),
              let defaultsB = UserDefaults(suiteName: suiteB) else {
            throw DockContractError.failed("无法建立独立 UserDefaults suite")
        }
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        let key = "window-layout"
        let base = fixturePanes("persisted", count: 4)
        let a = base[0], b = base[1], c = base[2], d = base[3]
        let e = Pane("contract-persisted-remote-new")
        let canvas = WindowRegions(in: bounds).canvas
        let first = WindowLayout(panes: base, arrangement: .sideBySide, storageKey: key, defaults: defaultsA)
        try require(first.root?.panes == [a, b] && first.docked == [c, d],
                    "首次布局没有按服务端顺序展开两张并停靠剩余窗口")

        let secondDockFrame = WindowRegions(in: bounds).dockFrame(at: 1)
        first.drag(c, to: CGPoint(x: secondDockFrame.maxX - 1, y: secondDockFrame.midY), in: bounds)
        first.drop(in: bounds)
        try require(first.docked == [d, c], "保存前 dock 重排没有完成")
        let beforeResize = LayoutState(first, in: bounds)
        guard let gap = first.root?.layout(in: canvas).gaps.first else {
            throw DockContractError.failed("双栏预设没有可调整的间距")
        }
        first.resize(gap, to: CGPoint(x: gap.rect.midX + 40, y: gap.rect.midY))
        let resizing = LayoutState(first, in: bounds)
        try require(resizing.frames != beforeResize.frames, "调整比例没有改变卡片帧")
        defaultsA.synchronize()
        let beforeRelease = WindowLayout(panes: base, arrangement: .stacked, storageKey: key,
                                         defaults: UserDefaults(suiteName: suiteA)!)
        try require(LayoutState(beforeRelease, in: bounds).frames == beforeResize.frames,
                    "松手前的比例已写入磁盘")
        first.finishResize()
        defaultsA.synchronize()
        let afterRelease = WindowLayout(panes: base, arrangement: .stacked, storageKey: key,
                                        defaults: UserDefaults(suiteName: suiteA)!)
        try require(LayoutState(afterRelease, in: bounds).frames == resizing.frames,
                    "松手后重建没有恢复调整后的比例")
        first.focus(b)
        let committed = LayoutState(first, in: bounds)

        first.drag(b, to: WindowRegions(in: bounds).dockFrame(at: first.docked.count).center, in: bounds)
        try require(first.drag != nil, "重建前没有待提交拖动")
        defaultsA.synchronize()
        let restored = WindowLayout(panes: base, arrangement: .stacked, storageKey: key,
                                    defaults: UserDefaults(suiteName: suiteA)!)
        try requireSame(restored, as: committed, in: bounds, "同设备重建")
        try require(restored.drag == nil, "拖动预览被持久化")

        restored.drag(b, to: WindowRegions(in: bounds).dockFrame(at: restored.docked.count).center, in: bounds)
        restored.reconcile(base + [e])
        try require(restored.drag == nil && restored.root?.layout(in: canvas).panes == committed.frames,
                    "服务端增加窗口时丢失已有分栏比例或未取消拖动")
        try require(restored.docked == [d, c, e] && restored.focused == b,
                    "新增窗口没有按顺序进入 dock 或改变了焦点")
        let afterAdd = LayoutState(restored, in: bounds)
        restored.drop(in: bounds)
        try requireSame(restored, as: afterAdd, in: bounds, "新增窗口后松开旧拖动")

        restored.drag(c, to: canvas.center, in: bounds)
        restored.reconcile([b, d, e])
        try require(restored.drag == nil && restored.root?.panes == [b] && restored.docked == [d, e],
                    "远程删除期间未清理旧窗口或未保留 dock 顺序")
        try require(restored.focused == b && Set(restored.panes) == Set([b, d, e]),
                    "远程删除改变焦点或窗口集合")
        let afterDelete = LayoutState(restored, in: bounds)
        restored.drop(in: bounds)
        try requireSame(restored, as: afterDelete, in: bounds, "远程删除后松开旧拖动")
        defaultsA.synchronize()
        let rebuiltAfterDelete = WindowLayout(panes: [b, d, e], arrangement: .oneAndThree, storageKey: key,
                                              defaults: UserDefaults(suiteName: suiteA)!)
        try requireSame(rebuiltAfterDelete, as: afterDelete, in: bounds, "远程删除后重建")
        try requireComplete(rebuiltAfterDelete, "远程删除后重建")

        let otherDevice = WindowLayout(panes: [b, d, e], arrangement: .oneAndTwo, storageKey: key, defaults: defaultsB)
        try require(otherDevice.root?.panes == [b, d, e] && otherDevice.docked.isEmpty,
                    "第二设备继承了第一设备的 dock 布局")
        otherDevice.focus(d)
        otherDevice.minimize(e)
        defaultsB.synchronize()
        let rebuiltOtherDevice = WindowLayout(panes: [b, d, e], arrangement: .sideBySide, storageKey: key,
                                              defaults: UserDefaults(suiteName: suiteB)!)
        try require(rebuiltOtherDevice.focused == d && rebuiltOtherDevice.docked == [e],
                    "第二设备没有恢复自己的焦点和 dock")
        let firstDeviceAgain = WindowLayout(panes: [b, d, e], arrangement: .oneAndTwo, storageKey: key,
                                            defaults: UserDefaults(suiteName: suiteA)!)
        try requireSame(firstDeviceAgain, as: afterDelete, in: bounds, "第二设备写入后重建第一设备")
        firstDeviceAgain.reconcile([])
        let replacement = Pane("contract-persisted-after-empty")
        firstDeviceAgain.reconcile([replacement])
        try require(firstDeviceAgain.root?.panes == [replacement] && firstDeviceAgain.docked.isEmpty
                    && firstDeviceAgain.focused == replacement && firstDeviceAgain.panes == [replacement],
                    "服务端清空后首个新窗口没有展开，或旧缓存复活了已删除窗口")
    }

    private static func requireSpansCanvas(_ frame: CGRect, along edge: Edge, canvas: CGRect) throws {
        let same: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 1 }
        switch edge {
        case .leading:
            try require(same(frame.minX, canvas.minX) && same(frame.minY, canvas.minY) && same(frame.maxY, canvas.maxY),
                        "左侧占位没有贴画布边并上下铺满")
        case .trailing:
            try require(same(frame.maxX, canvas.maxX) && same(frame.minY, canvas.minY) && same(frame.maxY, canvas.maxY),
                        "右侧占位没有贴画布边并上下铺满")
        case .top:
            try require(same(frame.minY, canvas.minY) && same(frame.minX, canvas.minX) && same(frame.maxX, canvas.maxX),
                        "顶部占位没有贴画布边并左右铺满")
        case .bottom:
            try require(same(frame.maxY, canvas.maxY) && same(frame.minX, canvas.minX) && same(frame.maxX, canvas.maxX),
                        "底部占位没有贴画布边并左右铺满")
        }
    }

    private static func requireOtherPanesAreOpposite(_ frames: [Pane: CGRect], floating: Pane, at edge: Edge) throws {
        guard let placed = frames[floating] else { throw DockContractError.failed("落下后找不到浮动窗口") }
        let others = frames.filter { $0.key != floating }.map(\.value)
        try require(others.count >= 2, "整体边缘落点没有保留多个其余窗口")
        let opposite: (CGRect) -> Bool
        switch edge {
        case .leading: opposite = { $0.minX >= placed.maxX - 1 }
        case .trailing: opposite = { $0.maxX <= placed.minX + 1 }
        case .top: opposite = { $0.minY >= placed.maxY - 1 }
        case .bottom: opposite = { $0.maxY <= placed.minY + 1 }
        }
        try require(others.allSatisfy(opposite), "整体边缘落点只分割了单张卡片")
    }
}
