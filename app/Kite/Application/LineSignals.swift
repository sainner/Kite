import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 关注设备（docs/Line与工作区流转.md「会话状态与关注设备」）：Kite 在前台、拿着焦点时告诉 Line 所在的工作机这台设备在关注，
/// 失去焦点或进后台时告诉它不在了。设备还要连着那台工作机带 device 的目录事件流才算在关注，断开即移出，重连后再报一次。
@MainActor final class LineAttention {
    static let shared = LineAttention()
    /// 这台设备的标识，装好后不变；事件流和 PUT /attention 都带它。
    nonisolated static let deviceID: String = {
        let key = "KiteDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
    private weak var model: AppModel?
    private var focused = false
    private var observers: [NSObjectProtocol] = []

    func install(model: AppModel) {
        self.model = model
        let center = NotificationCenter.default
        #if os(macOS)
        focused = NSApplication.shared.isActive
        let pairs: [(Notification.Name, Bool)] = [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)]
        #else
        focused = UIApplication.shared.applicationState == .active
        let pairs: [(Notification.Name, Bool)] = [(UIApplication.didBecomeActiveNotification, true), (UIApplication.willResignActiveNotification, false),
                                                  (UIApplication.didEnterBackgroundNotification, false)]
        #endif
        for (name, value) in pairs {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LineAttention.shared.changed(value) }
            })
        }
    }

    private func changed(_ value: Bool) {
        guard value != focused else { return }
        focused = value
        report()
    }

    /// 把这台设备此刻是否在关注报给 Line 所在的工作机；Line 的目录快照到了（含重连）也报一次。
    func report() {
        guard let model, let area = model.lineArea, let client = area.pluginClient else { return }
        let body = JSON.object(["device": .string(Self.deviceID), "focused": .bool(focused)])
        Task {
            do { let _: JSON = try await client.request("/attention", method: "PUT", body: body, as: JSON.self) }
            catch { TimingTrace.mark("报告关注状态失败：\(error.localizedDescription)") }
        }
    }
}

/// Line 找用户的系统通知（docs/Line与工作区流转.md「系统通知」）：Line 所在的工作机在目录事件流上推 line.notification，App 发本地通知。
/// 只带「交给 Line」一个按钮，批准和回答要点开看清了再做；点开切到 Line 的工作区，收件箱展开那一项。
@MainActor final class LineNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LineNotifications()
    nonisolated private static let category = "kite.line"
    nonisolated private static let delegateAction = "kite.line.delegate"
    private weak var model: AppModel?
    private var authorized: Bool?

    func install(model: AppModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.delegateAction, title: "交给 Line", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: [])])
    }

    func post(_ payload: LineNotificationPayload) {
        Task {
            let center = UNUserNotificationCenter.current()
            if authorized == nil { authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            if let item = payload.item {
                content.userInfo = ["item": item]
                // Line 能代处理的才带「交给 Line」：等待、回合结束与失败
                if ["waiting:", "turn:", "failed:"].contains(where: item.hasPrefix) { content.categoryIdentifier = Self.category }
            }
            try? await center.add(UNNotificationRequest(identifier: payload.id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let item = response.notification.request.content.userInfo["item"] as? String
        let delegating = response.actionIdentifier == Self.delegateAction
        await LineNotifications.shared.handle(item: item, delegating: delegating)
    }

    private func handle(item: String?, delegating: Bool) async {
        guard let model else { return }
        if delegating, let item {
            try? await model.lineInboxOperation("monitor.delegate", ["item": .string(item)])
            return
        }
        #if os(macOS)
        NSApplication.shared.activate()
        #endif
        model.openLine()
        model.lineFocusItem = item
    }

    /// Kite 在前台时工作机不会发（有设备在关注）；万一赶上切换的那一刻，照样显示横幅。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
