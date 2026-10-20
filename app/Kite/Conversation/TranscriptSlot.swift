import SwiftUI

extension EnvironmentValues {
    /// 会话的工作目录，工具参数里的路径按它显示成相对路径。
    @Entry var workingDirectory = ""
    /// 刚发出、气泡还在下面藏着的消息：对话往上滑的同时，气泡从下往上浮进来。会话窗口给出，见 ThreadPaneModel.send。
    @Entry var arrivingMessages: Set<String> = []
}

/// 原生对话列表里一行要用的外部环境。Mac、iOS 的原生列表共用。
struct TranscriptRowContext {
    /// 字体、外观、引用范围、打开链接、选中的行等，主对话的 SwiftUI 环境整份转交。
    var environment: EnvironmentValues
    /// 点 agent 的话弹出操作栏：主对话里是。
    var actionable: Bool
    /// 右键开关这一行的操作栏。
    var toggleActions: (RowID) -> Void
}

extension TranscriptRowContext {
    /// 开着操作栏的那一行。SwiftUI 外壳经环境里的 selectedRow 给，以后的 UIKit 外壳换掉这里和 select 就能接。
    var selected: RowID? { environment.selectedRow.wrappedValue }

    /// 打开这一行的操作栏（别的收起），给 nil 收起。iPhone 上长按时用，右键开关见 toggleActions。
    func select(_ id: RowID?) {
        if let id { environment.selectedRow.show(id) } else if selected != nil { environment.selectedRow.close() }
    }
}

/// 原生对话列表（Mac 的 TranscriptListView、iOS 的 PhoneTranscriptView）里的一行：内容、量过的高、视图。两端共用这个基类，行视图各端各写子类。
/// 视图只在可见区附近时放进列表：AppKit 改动一个视图在窗口里的位置时要通知它整棵子树，拖缝时每帧都在挪（2026-10-13 实测，
/// 一个长会话的行全建成视图时每步比按需只建可见区附近多约 8 ms）。
@MainActor class TranscriptRowSlot {
    let id: RowID
    private(set) var row: TranscriptRow
    /// 量过的：按哪个内容宽、多高。内容变了作废。
    var measured: (width: CGFloat, height: CGFloat)?
    /// 量的时候在拖缝，用的是省时的近似（见 BubbleRowSlot），停下要按精确的重量。
    var provisional = false
    /// 这一次量是在拖缝或吸附中，排列循环量之前给（见 TranscriptArrangement.arrange），行自己不读外壳。
    var resizing = false
    /// 在文档里占的范围（内容列的宽），排列时算出来。
    var frame = CGRect.zero
    /// 自己变高变矮时告诉列表：motion 是人点了展开收起时的走法（RowMotion），下面的行跟着挪；附件量完、图标载完这类给 nil，直接换。
    var heightChanged: ((_ motion: RowMotion?) -> Void)?
    /// 刚发出去、还在下面藏着的程度：1 在下面，0 到位，见 TranscriptListView 的发送。
    var rise: CGFloat = 0

    init(row: TranscriptRow) {
        id = row.id
        self.row = row
    }

    /// 视图建好了没有。没建过的行按估的高占位。
    var hasView: Bool { false }
    /// 视图，第一次要时建。
    var view: PlatformView { preconditionFailure("子类给出") }

    /// 换上这一行的新内容和环境（内容或外观变了才调），量过的高作废。
    func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        self.row = row
        measured = nil
    }

    /// 按内容列的宽量出多高，量过同宽的直接给。
    func height(width: CGFloat) -> CGFloat { 0 }

    /// 拖缝时量：只要排准行内 band 这一截（行内坐标，按这一行眼下的排版）。长正文只排这截，其余估着占位、记作 provisional；别的行整行量。
    func height(width: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat { height(width: width) }

    /// 量高前记下行内 y 处（行内坐标）的内容，量完由 pinShift 给出它在行内挪了多少。长正文拖缝时上面没排的按估的高占位，
    /// 看着的那截在行里的位置跟着估的变，列表按它把可见区挪回去（见 TranscriptArrangement.arrange）；别的行不挪。
    func pin(at y: CGFloat) {}
    var pinShift: CGFloat { 0 }

    /// 视图在文档里的 frame：column 是这一行在内容列里占的范围。
    func viewFrame(in column: CGRect) -> CGRect { column }

    /// 视图摆好以后摆里面的东西：frame 是这一行这会儿的范围（展开收起的动画中和量的高不一样）。
    func layoutView(in frame: CGRect) {}

    /// 操作栏和这一行的哪一块对齐。
    var actionAnchor: CGRect { frame }
}

/// 一行该用哪种实现：agent 的话、气泡（人发的消息、代理来信、Kite 的通知）、工具组、思考、压缩分界。
/// 判断两端共用，各端的工厂按它建自己的子类（Mac 见 makeTranscriptRowSlot，iOS 见 makePhoneTranscriptRowSlot）。
enum SlotKind { case prose, bubble, work, thinking, compaction }

func slotKind(_ row: TranscriptRow) -> SlotKind {
    switch row.content {
    case .message: .bubble
    case .item(let item):
        switch item.kind {
        case .text: .prose
        // 人发的消息在 TranscriptRow.rows 里都成了 .message，走不到这里
        case .human, .agent, .kite: .bubble
        case .work: .work
        case .thinking: .thinking
        case .compacted: .compaction
        }
    }
}
