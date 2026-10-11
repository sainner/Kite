import SwiftUI

/// 相邻窗口从手势第一帧就一起移动；松手只补完剩余距离，旧窗口到屏幕外后才回收。
struct CompactPaneStack: View {
    let group: PaneGroup
    let motion: DrawerMotion
    let width: CGFloat
    @State private var origin: Pane?
    @State private var neighbour: Pane?
    @State private var step = 0
    @State private var gestureOrigin: CGFloat?
    @State private var settling: UUID?
    @State private var commits = false
    @State private var slide = WindowMotion(WindowPose(frame: .zero))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panes: [Pane] {
        [origin ?? group.layout.focused, neighbour].compactMap { $0 }
    }

    var body: some View {
        ZStack {
            ForEach(panes, id: \.self) { pane in
                SlidingPane(motion: slide, offset: pane == neighbour ? CGFloat(step) * width : 0) {
                    PaneBody(group: group, pane: pane)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .modifier(DotsPresence(presented: origin == nil && pane == group.layout.focused))
                .allowsHitTesting(pane == (origin ?? group.layout.focused))
                .transition(.identity)
            }
        }
        .environment(\.windowMotion, slide)
        .environment(\.switchPane, switchPane)
        .environment(\.trackPaneSwipe, track)
        .environment(\.endPaneSwipe, end)
        .environment(\.cancelPaneSwipe, cancel)
        .task(id: settling) {
            guard settling != nil else { return }
            repeat {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            } while slide.moving
            if commits, let neighbour, group.layout.panes.contains(neighbour) { group.layout.focus(neighbour) }
            reset()
        }
        .onChange(of: width) { reset() }
        .onChange(of: motion.collapsed) { _, collapsed in if !collapsed { reset() } }
        .onChange(of: group.layout.focused) { _, focused in
            if focused != origin { reset() }
        }
        .onChange(of: group.layout.panes) { _, panes in
            if origin.map({ !panes.contains($0) }) == true || neighbour.map({ !panes.contains($0) }) == true { reset() }
        }
    }

    private func track(_ translation: CGFloat) {
        guard motion.collapsed, width > 0 else { return }
        if gestureOrigin == nil {
            gestureOrigin = slide.presentation(at: .now).frame.minX
            settling = nil
            origin = origin ?? group.layout.focused
        }
        slide.interacting = true
        let displacement = (gestureOrigin ?? 0) + translation
        choose(displacement < 0 ? 1 : -1)
        move(neighbour == nil ? displacement * 0.2 : displacement, kind: .immediate)
    }

    private func choose(_ direction: Int) {
        let panes = group.layout.panes
        guard let focused = origin ?? group.layout.focused, let index = panes.firstIndex(of: focused) else { return }
        origin = focused
        step = direction
        neighbour = panes.indices.contains(index + direction) ? panes[index + direction] : nil
    }

    private func end(_ translation: CGFloat, _ predicted: CGFloat) {
        guard gestureOrigin != nil else { return }
        let distance = (gestureOrigin ?? 0) + translation
        let projected = (gestureOrigin ?? 0) + predicted
        let commit = neighbour != nil && (abs(distance) >= width * 0.25
            || (abs(projected) >= width * 0.4 && projected * distance > 0))
        finish(commit)
    }

    private func switchPane(_ direction: Int) {
        guard motion.collapsed, origin == nil else { return }
        choose(direction)
        guard neighbour != nil else { reset(); return }
        finish(true)
    }

    private func cancel() { if gestureOrigin != nil { finish(false) } }

    private func finish(_ commit: Bool) {
        gestureOrigin = nil
        slide.interacting = false
        commits = commit
        move(commit ? -CGFloat(step) * width : 0, kind: reduceMotion ? .immediate : .settle)
        settling = UUID()
    }

    private func move(_ x: CGFloat, kind: WindowMotionKind) {
        slide.move(to: WindowPose(frame: CGRect(x: x, y: 0, width: 0, height: 0)), kind: kind)
    }

    private func reset() {
        settling = nil
        origin = nil
        neighbour = nil
        gestureOrigin = nil
        slide.interacting = false
        move(0, kind: .immediate)
    }
}

/// 只平移已经排好的页面，不把逐帧进度传进会话内容与安全区排版。
private struct SlidingPane<Content: View>: View {
    let motion: WindowMotion
    let offset: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.animation(paused: !motion.moving)) { clock in
            content.modifier(WindowTranslation(point: CGPoint(x: motion.presentation(at: clock.date).frame.minX + offset, y: 0)).ignoredByLayout())
        }
    }
}
