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
    let after = LayoutState(layout, in: bounds)
    try require(after.empty == before.empty && after.active == before.active && after.docked == before.docked
                && after.all == before.all && after.focused == before.focused && after.frames == before.frames,
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

private func dock(_ pane: Pane, layout: WindowLayout, in bounds: CGRect) {
    let frame = WindowRegions(in: bounds).dockFrame(at: layout.docked.count)
    layout.drag(pane, to: frame.center, in: bounds)
    layout.drop(in: bounds)
}

private func fixturePanes(_ name: String, count: Int) -> [Pane] {
    (0..<count).map { Pane("contract-\(name)-\($0)") }
}

@MainActor
@main
private struct WindowDockContract {
    private static let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    static func main() throws {
        try allCardsCanDockAndReturn()
        try reorderCancelAndSwitchArrangement()
        try canvasEdgesPreviewAndCommit()
        try headerActionsPreserveWindowsAndCancelDrag()
        try persistedLayoutReconcilesRemoteWindows()
        print("窗口停靠五组手动合同验证通过")
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
