import SwiftUI

/// 主对话怎么滚。规则：
/// - 打开时不留末尾空白，停在最后一条内容的底部，跟着最底下；人往上翻就不跟了，翻回最底下又跟。
/// - 内容、可见区变高变矮（展开收起一步、回复变长、键盘、底栏）时：跟着最底下、底下也没露着留白，就按底部对齐，
///   最后几行贴着底边，键盘升起时和键盘一起顶上去；不然按顶部对齐，对话不动。
///   收起后旧坐标超出内容范围时收回新末尾；从手指按下到惯性结束，暂停程序定位和尺寸对齐。
/// - 发送：开启新一轮的消息滑到可见区顶上，最后一轮至少占满一屏，不够在底下留白（TailSpace）；
///   排在后面的消息接在最后面，滑到最底下把它顶上来，不另留空白。
/// - 留白：人往上翻多少裁掉多少，裁到最后一条内容为止，下一次开启新一轮才重新留；回复把它填满以后照常跟着最底下。
///
/// 下面的做法都是在 iPhone 模拟器上用单独的探针 app 逐帧记位置试出来的，改之前先看：
/// - 对齐交给滚动视图（defaultScrollAnchor 的 sizeChanges，按状态换，见 anchor）：它在排版时对齐，跟着那一次变化的动画走。
///   在回调里自己滚没有动画，会先一下跳到位。换对齐和内容变化在同一次更新里也当场生效。
/// - 滚动位置（ScrollPosition）里的目标会一直留着：滚到某一行的目标让对齐不起作用；滚到最底下的目标在内容变了时
///   没有动画地跳过去，可见区变了不管；什么目标都没有时，停在最底下就一直贴着最底下，也不管对齐。
///   程序滚完钉住位置（pin）；人滚完只在正文中部钉住，边缘由系统回弹，不重新夹正位置。打开时先给滚到最底下：打开时本来就停在最底下，
///   它只在内容变了时跳，比什么都没有强。和键盘升起同一次更新里钉住的话底部对齐不起作用，所以键盘动之前不钉。
///   用户进入 tracking 时用 isPositionedByUser 清除旧目标；回到 idle 后更新跟随状态，边缘不写定位目标。
/// - withAnimation 的 completion 对滚动十几毫秒就回调，不等滚完，这时钉住会把滚动停在原地；glide 名义上 0.5 秒，
///   实际 0.8 秒左右才停稳，所以滚完一秒再钉（settle）。
/// - 键盘升起的动画没走完时内容变短，滚动视图会把对话往下挪一个键盘高，同一次排版、晚一次排版、不带动画都一样；
///   所以可见区变矮时留白等 0.6 秒再缩，缩掉的在键盘后面。变高时留白在排版里当场跟着变，内容和可见区一起变长，不用动。
/// - 留白要在排版里和新消息一次算出来（TranscriptStack）：量出来再补会晚一次排版，滑的那一刻底下还没有留白，滑不到位。
/// - 带动画加进内容的话，紧接着的滚动整个不动；所以发送时不带动画地加，下一拍再滑。
@Observable
final class TranscriptScroll {
    /// 绑给滚动视图。
    fileprivate var position = ScrollPosition(edge: .bottom)
    /// 跟着最底下。
    private var following = true
    /// 底下的留白这会儿露在可见区里。
    private var blankShown = false
    /// 留白被人往上翻裁掉了多少。打开时为 nil，不生成留白；发送并开启新一轮时才从 0 开始。
    private var trim: CGFloat?
    /// 程序正在滚的次数。滚的时候按顶部对齐，回调也不插手。
    private var gliding = 0
    /// 留白按多高的可见区算：变高时当场跟上，变矮时等一会儿再跟（visibleChanged）。
    private var heldVisible: CGFloat = 0
    /// 可见区这会儿多高。
    @ObservationIgnored private var visible: CGFloat = 0
    /// 从手指按下到惯性结束都交给用户；此时也暂停尺寸变化的自动对齐。
    private var phase = ScrollPhase.idle
    private var userScrolling: Bool { phase == .tracking || phase == .interacting || phase == .decelerating }
    /// 同一次回调里的尺寸和位置，避免分开读取时混用折叠前后的坐标。
    @ObservationIgnored private var geometry: ScrollGeometry?
    /// 等着让留白跟上变矮的可见区。
    @ObservationIgnored private var shrinking: Task<Void, Never>?

    /// 内容、可见区变了时怎么对齐。底下露着留白时按顶部对齐：键盘升起时留白要等一会儿才缩，按底部对齐会先把对话顶上去再落回来。
    /// 程序在滚时按顶部对齐：发送时不带动画加进去的消息和留白不能被它一下推到底，要留给那一下滑。
    fileprivate var anchor: UnitPoint? {
        guard !userScrolling else { return nil }
        return following && !blankShown && gliding == 0 ? .bottom : .top
    }

    /// 给 TranscriptView 的留白，visible 是这一次排版时可见区多高。仅查看历史时没有留白。
    func tail(visible: CGFloat) -> TailSpace? {
        guard let trim else { return nil }
        return TailSpace(height: max(visible, heldVisible) - Metrics.transcriptPadding - trim, scroll: self)
    }

    /// 发一条消息：append 不带动画地把它加进对话，返回它会不会开启新的一轮；然后滑过去，alongside 和滑同一个动画。
    /// 开启新一轮的滑到最后一轮顶上的标记，底下重新留白；排在后面的滑到最底下，裁掉的留白不长回来。
    func send(_ append: () -> Bool, alongside: @escaping () -> Void) {
        following = true
        // 和加消息同一次更新：加进去的那一次排版就按顶部对齐，也钉在当前位置，不然开头给的滚到最底下会在内容变长时一下跟过去
        gliding += 1
        pin()
        let startsTurn = append()
        if startsTurn { trim = 0 }
        // 等新消息和它底下的留白排好再滑
        DispatchQueue.main.async {
            withAnimation(.glide) {
                if startsTurn {
                    self.position.scrollTo(id: TailSpace.marker, anchor: .top)
                } else {
                    self.position.scrollTo(edge: .bottom)
                }
                alongside()
            }
            self.settle()
        }
    }

    fileprivate func phaseChanged(from old: ScrollPhase, to phase: ScrollPhase, geometry: ScrollGeometry) {
        self.geometry = geometry
        let wasUserScrolling = userScrolling
        self.phase = phase
        if userScrolling && !wasUserScrolling {
            // 进入 tracking 就解除首次贴底或上一次程序滚动留下的目标，不和手势争位置。
            position.isPositionedByUser = true
        }
        if phase == .idle, wasUserScrolling {
            following = geometry.atBottom
            // 原生回弹尚可能停在边界外；此时写夹正后的坐标会让内容突然跳到边缘。
            if gliding == 0, geometry.scrollOffset > 1, geometry.scrollOffset < geometry.bottom - 1 {
                pin()
            }
        }
    }

    fileprivate func geometryChanged(from old: ScrollGeometry, to new: ScrollGeometry) {
        geometry = new
        if userScrolling {
            following = new.atBottom
            // 人往上翻、底下的留白还露着：翻上去多少就裁掉多少。
            if phase != .tracking, blankShown, new.distanceToBottom > 0.5,
               new.distanceToBottom != old.distanceToBottom, let trim {
                self.trim = trim + new.distanceToBottom
            }
            return
        }
        // 程序滚的这一阵子交给那一下滚动，不插手，不然会把滑到一半的一下子跳过去
        guard gliding == 0 else { return }
        if old.contentSize == new.contentSize && old.containerSize == new.containerSize && old.contentInsets == new.contentInsets {
            // 只是滚了：翻上去就不跟了，翻回最底下又跟
            following = new.atBottom
        } else if max(new.scrollOffset, position.y ?? 0) > new.bottom + 1 {
            // 原生视图可能先夹正可见位置，绑定的旧目标却仍然越界；两者都要收回新末尾。
            position.scrollTo(y: new.bottom)
        } else if following && !blankShown && !new.atBottom {
            // 留白刚被回复填满的那一下还按顶部对齐，多出来的一截补滚过去；之后按底部对齐，不会再差。
            position.scrollTo(y: new.bottom)
        }
    }

    /// 可见区变矮时，等它最后一次变完 0.6 秒再让留白跟上，那时已经变回去了就不缩。
    fileprivate func visibleChanged(_ height: CGFloat) {
        visible = height
        shrinking?.cancel()
        shrinking = nil
        if height >= heldVisible {
            heldVisible = height
        } else {
            shrinking = Task {
                do { try await Task.sleep(for: .seconds(0.6)) } catch { return }
                heldVisible = visible
            }
        }
    }

    fileprivate func blankShownChanged(_ shown: Bool) {
        blankShown = shown
    }

    /// 程序滚完一下，等它停稳再钉住。期间又有一下滚动的，等最后一下；人已经上手滚了就不钉，那会和手抢。
    private func settle() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            gliding -= 1
            if gliding == 0, !userScrolling { pin() }
        }
    }

    /// 钉在这会儿的位置，滚动位置里只留一个位置。
    private func pin() {
        guard let geometry else { return }
        position.scrollTo(y: min(max(geometry.scrollOffset, 0), geometry.bottom))
    }
}

private extension Animation {
    /// 发送后对话往上滑，气泡同时浮进来。
    static let glide = Animation.smooth(duration: 0.5)
}

/// 主对话最后一轮底下的留白：最后一轮（从最近一条开启新一轮的人发的消息算起）至少多高，不够就在底下留白。
/// TranscriptScroll 给出，TranscriptView 排（见 TranscriptStack）：最后一轮顶上放一个 id 是 marker 的标记，发送后滑到它；
/// 最后一行的底边放一个 TailEnd。
struct TailSpace {
    /// 最后一轮至少多高，已经减掉了人往上翻时裁掉的。
    var height: CGFloat
    let scroll: TranscriptScroll

    /// 最后一轮顶上那个标记的 id。
    static let marker = "transcript.tail"
}

/// 最后一行底边的标记：报告底下的留白露没露在可见区里，最后一条内容的底边在可见区底边上面就是露着。
/// 单独一个视图：拉底栏、Mac 上拖窗口时可见区高度每一帧都变，只有它跟着重画。
struct TailEnd: View {
    let tail: TailSpace
    @Environment(\.visibleHeight) private var visibleHeight

    var body: some View {
        // .scrollView 的原点在标题栏底下，可见区的底边在 visibleHeight，最后一行的底边还要再留出对话底下的边距（实测）。
        // 不按 tail.height 比：可见区变矮时它要等一会儿才跟上
        Color.clear.frame(height: 0)
            .onGeometryChange(for: Bool.self) {
                $0.frame(in: .scrollView).minY < visibleHeight - Metrics.transcriptPadding - 1
            } action: { tail.scroll.blankShownChanged($0) }
    }
}

extension View {
    /// 滚动视图按 scroll 滚。visibleHeight 是可见区这一次排版时多高，也给里面的内容（见 EnvironmentValues.visibleHeight）；
    /// 人上手滚时调 userScrollBegan。
    func transcriptScroll(_ scroll: TranscriptScroll, visibleHeight: CGFloat, userScrollBegan: @escaping () -> Void) -> some View {
        modifier(TranscriptScrolling(scroll: scroll, visibleHeight: visibleHeight, userScrollBegan: userScrollBegan))
    }
}

private struct TranscriptScrolling: ViewModifier {
    @Bindable var scroll: TranscriptScroll
    let visibleHeight: CGFloat
    let userScrollBegan: () -> Void

    func body(content: Content) -> some View {
        content
            .scrollPosition($scroll.position)
            .onScrollPhaseChange { old, phase, context in
                scroll.phaseChanged(from: old, to: phase, geometry: context.geometry)
                if phase == .interacting { userScrollBegan() }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(scroll.anchor, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { scroll.geometryChanged(from: $0, to: $1) }
            .onChange(of: visibleHeight, initial: true) { scroll.visibleChanged(visibleHeight) }
            .environment(\.visibleHeight, visibleHeight)
    }
}

private extension ScrollGeometry {
    /// scrollTo(y:) 比 contentOffset 少算标题栏让出的那一截（实测）。
    var scrollOffset: CGFloat { contentOffset.y + contentInsets.top }

    /// 内容底边在可见区底边下面多远，滚过了头是负的。可见区的底边在控制区后面，要减掉控制区让出的那一截。
    var distanceToBottom: CGFloat {
        contentSize.height + contentInsets.bottom - visibleRect.maxY
    }

    var atBottom: Bool { distanceToBottom <= 1 }

    /// 滚到最底下时 scrollTo(y:) 给多少。containerSize 已经扣掉了上下让出的一截，scrollTo(y:) 又比 contentOffset 多算上面那一截（实测），
    /// 两边抵掉，只剩内容比可见区高出多少。
    var bottom: CGFloat {
        max(contentSize.height - containerSize.height, 0)
    }
}
