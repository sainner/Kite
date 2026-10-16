import SwiftUI

/// 输入区里思考强度左边的审批模式：越界请求（连名单外的主机、申请出沙箱）怎么处理。一个图标，点开选三种模式，当前的打勾。
/// 已有代理改工作机上的实例，运行中也能改，下一次越界时生效；草稿改本机选择，随第一条消息提交，和角色默认一样时不提交。
struct ApprovalModeControl: View {
    let controls: ThreadControlsModel
    /// 选了、工作机推回的实例配置还没跟上时先显示它。
    @State private var pending: ApprovalMode?
    @State private var error: String?

    private var thread: WorkThread { controls.thread }
    private var instanceID: String? { controls.instance?.id }
    private var roleDefault: ApprovalMode { controls.model.newThreadRole(for: thread, in: controls.area)?.role.approval ?? .allowlist }
    /// 工作机上实例当前的；草稿是本机选择，没选是角色的默认。
    private var stored: ApprovalMode {
        guard let instanceID else { return thread.draftChoice?.approval ?? roleDefault }
        return controls.area.instances.first { $0.id == instanceID }?.config?.approval ?? .allowlist
    }
    private var current: ApprovalMode { pending ?? stored }

    var body: some View {
        Menu {
            ForEach(ApprovalMode.allCases, id: \.self) { mode in
                Toggle(mode.title, isOn: Binding(get: { current == mode }, set: { _ in choose(mode) }))
            }
        } label: {
            Image(systemName: current.symbol)
        }
        // 同输入区的附件、语音按钮：一样的字号、按钮大小和悬停反馈
        .menuStyle(.button)
        .buttonStyle(PaneButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!controls.model.isConnected(controls.area) || pending != nil)
        .help("审批模式：\(current.title)")
        .accessibilityLabel("审批模式")
        .accessibilityValue(current.title)
        .onChange(of: stored) { _, value in if value == pending { pending = nil } }
        .alert("修改审批模式失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func choose(_ mode: ApprovalMode) {
        guard mode != current else { return }
        guard let instanceID else {
            thread.draftChoice?.approval = mode == roleDefault ? nil : mode
            return
        }
        pending = mode
        let model = controls.model, area = controls.area
        Task {
            struct Update: Encodable { let mode: ApprovalMode }
            do {
                _ = try await model.activeClient(in: area).request("/instances/\(instanceID)/approval-mode", method: "PUT",
                                                                   body: Update(mode: mode), as: InstanceApprovalMode.self)
                if stored == mode { pending = nil }
            } catch {
                pending = nil
                self.error = error.localizedDescription
            }
        }
    }
}

extension ApprovalMode {
    /// 输入区图标：仅白名单是锁，越界询问是举手，全放行是打勾的盾。
    var symbol: String {
        switch self {
        case .allowlist: "lock.shield"
        case .ask: "hand.raised"
        case .allowAll: "checkmark.shield"
        }
    }
}
