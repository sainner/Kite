import CloudKit
import SwiftUI
import TailscaleKit
import UIKit
import UserNotifications

@main
struct SpikeApp: App {
    @UIApplicationDelegateAdaptor(SpikeDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            TabView {
                NetworkView().tabItem { Label("组网", systemImage: "network") }
                CloudView().tabItem { Label("iCloud", systemImage: "icloud") }
            }
        }
    }
}

// MARK: - 推送：注册、前台也显示横幅、点开时记下送达耗时

@MainActor final class Arrivals: ObservableObject {
    static let shared = Arrivals()
    @Published var lines: [String] = []
    @Published var token = "尚未注册"

    func add(_ notification: UNNotification, opened: Bool) {
        let info = notification.request.content.userInfo
        var line = "\(notification.date.formatted(date: .omitted, time: .standard)) \(opened ? "点开" : "前台收到")：\(notification.request.content.body)"
        if let query = CKNotification(fromRemoteNotificationDictionary: info) as? CKQueryNotification,
           let sent = query.recordFields?["sentAt"] as? Date {
            line += "；送达耗时 \(Int(notification.date.timeIntervalSince(sent) * 1000)) 毫秒"
        }
        lines.insert(line, at: 0)
    }
}

final class SpikeDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Arrivals.shared.token = "已注册（\(deviceToken.count) 字节令牌）" }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Arrivals.shared.token = "注册失败：\(error.localizedDescription)" }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { Arrivals.shared.add(notification, opened: false) }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { Arrivals.shared.add(response.notification, opened: true) }
    }
}

struct CloudView: View {
    @ObservedObject var arrivals = Arrivals.shared
    @State private var account = "读取中"
    @State private var subscription = "未订阅"

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    LabeledContent("iCloud 账号", value: account)
                    LabeledContent("推送", value: arrivals.token)
                    LabeledContent("订阅", value: subscription)
                }
                Section {
                    Button("开通知并订阅提醒") { Task { await subscribe() } }
                }
                Section("收到的提醒") {
                    if arrivals.lines.isEmpty { Text("还没有").foregroundStyle(.secondary) }
                    ForEach(arrivals.lines, id: \.self) { Text($0).font(.footnote) }
                }
            }
            .navigationTitle("iCloud")
            .task { account = await Spike.accountStatus() }
        }
    }

    /// 订阅「新建提醒记录」：iCloud 在记录写入后推一条可见通知，App 不在运行也会弹出；正文取记录的 body 字段。
    private func subscribe() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { subscription = "没有通知权限"; return }
            UIApplication.shared.registerForRemoteNotifications()
            let query = CKQuerySubscription(recordType: Spike.alertType, predicate: NSPredicate(value: true),
                                            subscriptionID: Spike.alertSubscription, options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.title = "Kite 实验"
            info.alertLocalizationKey = "%1$@"
            info.alertLocalizationArgs = ["body"]
            info.desiredKeys = ["title", "body", "sentAt"]
            info.soundName = "default"
            query.notificationInfo = info
            _ = try await Spike.database.save(query)
            subscription = "已订阅"
        } catch { subscription = "失败：\(error.localizedDescription)" }
    }
}

// MARK: - 组网：官方协调服务、交互式登录、访问 Mac 实验节点

@MainActor final class NetworkModel: ObservableObject {
    @Published var state = "未启动"
    @Published var loginURL: URL?
    @Published var identity = ""
    @Published var results: [String] = []
    private var node: TailscaleNode?
    private var session: URLSession?

    private struct Status: Decodable {
        struct Peer: Decodable { let HostName: String?; let TailscaleIPs: [String]?; let Relay: String?; let UserID: Int? }
        struct User: Decodable { let LoginName: String? }
        let BackendState: String?
        let AuthURL: String?
        let me: Peer?
        let User: [String: User]?
        enum CodingKeys: String, CodingKey { case BackendState, AuthURL, me = "Self", User }
    }

    func start() async {
        guard node == nil else { return }
        let started = Date()
        do {
            let directory = URL.applicationSupportDirectory.appending(path: "SpikeTailnet", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let node = try TailscaleNode(config: TailscaleKit.Configuration(
                hostName: "kite-spike-iphone", path: directory.path(percentEncoded: false), authKey: nil, controlURL: kDefaultControlURL), logger: nil)
            self.node = node
            state = "上线中"
            // up 等到登录完成才返回；同时轮询状态里的登录地址。
            let up = Task { try await node.up() }
            while true {
                if let data = try? await node.statusJSON(), let status = try? JSONDecoder().decode(Status.self, from: data) {
                    if let auth = status.AuthURL, !auth.isEmpty, loginURL == nil {
                        loginURL = URL(string: auth)
                        state = "等待登录（启动后 \(milliseconds(since: started)) 毫秒拿到地址）"
                        if let loginURL { await UIApplication.shared.open(loginURL) }
                    }
                    if status.BackendState == "Running" {
                        let user = status.me?.UserID.flatMap { status.User?[String($0)]?.LoginName } ?? "?"
                        identity = "\(status.me?.HostName ?? "?") \(status.me?.TailscaleIPs?.first ?? "")；用户 \(user)；主中继 \(status.me?.Relay ?? "?")"
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            try await up.value
            session = URLSession(configuration: try await URLSessionConfiguration.tailscaleSession(node).0)
            state = "已上线（启动后 \(milliseconds(since: started)) 毫秒）"
        } catch {
            state = "失败：\(error.localizedDescription)"
            if let node { try? await node.close() }
            node = nil
        }
    }

    /// 连访 Mac 实验节点几次：第一次含建立路径的耗时，之后的接近往返延迟。
    func visit(_ address: String) async {
        guard let session, let url = URL(string: "http://\(address)/") else { results.insert("还没上线", at: 0); return }
        for attempt in 1...5 {
            let start = Date()
            do {
                let (data, _) = try await session.data(from: url)
                results.insert("第 \(attempt) 次 \(milliseconds(since: start)) 毫秒：\(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))", at: 0)
            } catch { let e = error as NSError; results.insert("第 \(attempt) 次失败（\(milliseconds(since: start)) 毫秒）：\(e.domain) \(e.code) \(e.localizedDescription)", at: 0) }
        }
    }
}

struct NetworkView: View {
    @StateObject private var model = NetworkModel()
    @State private var address = "100.98.201.91"

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    Text(model.state)
                    if !model.identity.isEmpty { Text(model.identity).font(.footnote) }
                    if let url = model.loginURL { Link("打开登录地址", destination: url) }
                }
                Section {
                    Button("用官方服务上线") { Task { await model.start() } }
                    TextField("Mac 实验节点地址", text: $address).keyboardType(.numbersAndPunctuation)
                    Button("访问 Mac 实验节点") { Task { await model.visit(address) } }
                }
                Section("访问结果") {
                    ForEach(model.results, id: \.self) { Text($0).font(.footnote) }
                }
            }
            .navigationTitle("组网")
        }
    }
}
