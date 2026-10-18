import SwiftUI

/// 原生对话列表跟不跟着最底下、底下留多少白、发送后的那一下滑：两端共用的状态，规则见 TranscriptListView 开头。
/// 平台把自己的滚动事件翻译成这几个调用：人开始滑（userBegan）、滚了一下（scrolled）、滑完（userEnded）、
/// 每次排版报可见区多高（visibleChanged）、排好以后报留白露没露出来（arranged）；发送见 send、glideStart。
/// 排列循环（TranscriptArrangement.arrange）按这里的状态决定贴底、按住顶上那一行，还是交给程序的那一下滑。
@MainActor final class TranscriptFollow {
    /// 跟着最底下。
    private(set) var following = true
    /// 留白被人往上翻裁掉了多少。打开时为 nil，不留白；发送并开启新一轮时从 0 开始。
    private(set) var trim: CGFloat?
    /// 留白按多高的可见区算：变高时当场跟上，变矮时等 0.6 秒，见 visibleChanged。
    private(set) var heldVisible: CGFloat = 0
    /// 可见区这会儿多高，每次排版报上来。
    private var visible: CGFloat = 0
    private var shrinking: Task<Void, Never>?
    /// 底下的留白这会儿露在可见区里。
    private(set) var blankShown = false
    /// 人在滚（含惯性）。
    private(set) var userScrolling = false
    /// 发送后滑到最底下的那一下。
    var glide: Glide?
    /// 发出去、等新消息排好再滑的那一下：发的时候排进来过几条新消息（TranscriptArrangement.arrivals）、和滑同一个动画的 alongside、
    /// 什么时候发的（systemUptime）。
    private(set) var pendingGlide: (arrivals: Int, alongside: () -> Void, since: TimeInterval)?
    /// 新消息迟迟不排进来时最多等多久，过了照样滑。
    static let arrivalWait: TimeInterval = 0.25
    /// 留白跟上变矮的可见区时请平台重排。
    var relayout: (() -> Void)?

    /// 内容、可见区变了时贴底：跟着最底下、底下没露着留白、程序也没在滚。
    var keepsBottom: Bool { following && !blankShown && glide == nil && pendingGlide == nil }

    /// 排好、定了滚动位置以后：最后一行的底边比可见区底边（再留出对话底下的边距）高，底下的留白就露着。
    func arranged(lastBottom: CGFloat, visible: CGRect) {
        blankShown = lastBottom < visible.maxY - Metrics.transcriptPadding - 1 && trim != nil
    }

    /// 不是程序滚的一下：程序的那一下让给人；底下露着的留白，翻上去多少就裁掉多少（返回 true，要重排）。
    /// 手在滑（含惯性、回弹）时滑完再看停在哪；滚轮一格一格的没有这一段，当场看。
    func scrolled(distanceToBottom: CGFloat) -> Bool {
        if glide != nil { glide = nil }
        var trimmed = false
        if let trim, blankShown, distanceToBottom > 0.5 {
            self.trim = trim + distanceToBottom
            trimmed = true
        }
        if !userScrolling { following = distanceToBottom <= 1 }
        return trimmed
    }

    /// 手一滑就不再贴底：展开、流式变高时贴底每帧都改滚动位置，滑到底回弹时就和回弹抢。
    func userBegan() {
        userScrolling = true
        following = false
    }

    /// 滑完（含惯性）：停在最底下就接着跟。wasFollowing：这次按下前跟着、手指没拖起来（iOS 的轻点、长按），按着的那会儿
    /// 流式变长、底下没跟上也照旧跟：轻点不影响跟底。
    func userEnded(distanceToBottom: CGFloat, wasFollowing: Bool = false) {
        userScrolling = false
        following = wasFollowing || distanceToBottom <= 1
    }

    /// 可见区变矮时，等它最后一次变完 0.6 秒再让留白跟上，那时已经变回去了就不缩：每变一次都从头计时。
    /// iPhone 上试出来的：键盘升起的动画没走完时内容变短，滚动视图会把对话往下挪一个键盘高，所以等一会儿再缩，缩掉的在键盘后面。
    /// 平台每次排版都报，高没变的不算一次变化，不然流式回复不停重排时留白一直缩不下去。
    func visibleChanged(_ height: CGFloat) {
        guard height != visible else { return }
        visible = height
        shrinking?.cancel()
        shrinking = nil
        if height >= heldVisible {
            heldVisible = height
        } else {
            shrinking = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(0.6)) } catch { return }
                guard let self else { return }
                heldVisible = visible
                shrinking = nil
                relayout?()
            }
        }
    }

    // MARK: - 发送

    /// 发一条消息：append 把它加进对话，返回它会不会开启新的一轮（开启的重新留白）；arrivals 是加进去时排进来过几条新消息，
    /// 等它变了（新消息排好了）再滑，见 glideStart。
    func send(_ append: () -> Bool, arrivals: () -> Int, alongside: @escaping () -> Void) {
        following = true
        glide = nil
        let startsTurn = append()
        if startsTurn { trim = 0 }
        pendingGlide = (arrivals(), alongside, ProcessInfo.processInfo.systemUptime)
    }

    enum GlideStart {
        /// 没有要滑的，或者正在滑。
        case none
        /// 新消息还没排进来，过一会儿再看。
        case wait
        /// 开始滑，alongside 和滑同一个动画。
        case start(alongside: () -> Void)
    }

    /// 新消息排进来了就开始滑；还没到时过一会儿再看，最多等 arrivalWait。不按行有没有换过看：上一轮的回复还在长、
    /// 标题换了这些也换行，滑就抢在新消息前头起步，等它排进来，目标一下远了一截、气泡也没跟着浮（2026-10-18 实发测到）。
    func glideStart(arrivals: Int) -> GlideStart {
        guard let pending = pendingGlide, glide == nil else { return .none }
        if pending.arrivals == arrivals && ProcessInfo.processInfo.systemUptime - pending.since < Self.arrivalWait { return .wait }
        pendingGlide = nil
        return .start(alongside: pending.alongside)
    }

    /// 滑到了：接着跟着最底下。
    func glideEnded() {
        glide = nil
        following = true
    }
}
