import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 工作机的 `GET /update`：正在运行的版本、最近一次发布与自动更新的进度（docs/kited.md「接口」）。
struct UpdateStatus: Decodable, Equatable {
    struct Release: Decodable, Equatable {
        let build: String
        let `protocol`: Int
        let builtAt: String
        let by: String
    }
    /// 本机 kited 备好的新 Mac App。
    struct StagedApp: Decodable, Equatable {
        let build: String
        let path: String
    }
    let version: MachineVersion
    let release: Release?
    let state: String
    let reason: String?
    let done: Int?
    let total: Int?
    let waiting: [String]?
    let error: String?
    let retry: Bool?
    let app: StagedApp?

    /// 取文件、等空闲与换版期间，状态会接着变。
    var inProgress: Bool { ["downloading", "ready", "installing"].contains(state) }
}

/// 这个 App 带的服务运行目录的构建号；Debug 版与 iPhone、iPad 不带服务，为 nil。
enum AppBuild {
    private struct Manifest: Decodable { let build: String? }

    static let current: String? = {
        #if os(macOS)
        guard let url = Bundle.main.resourceURL?.appending(path: "Service/runtime/manifest.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Manifest.self, from: data))?.build
        #else
        return nil
        #endif
    }()

    #if os(macOS)
    /// 退出后用本机 kited 备好的新 App 换掉这个 App 再打开：等本进程退出，旧的挪开、新的放回原处，没放成就把旧的放回去。
    /// 一分钟还没退出（退出被取消）就不换了；换不成也重新打开，不让 App 就此消失。
    static func relaunch(with staged: String) throws {
        let app = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw KitedError(message: "Kite 所在的文件夹不能写入，请把 Kite 移到「应用程序」文件夹后再重启以更新")
        }
        let script = """
        i=0
        while /bin/kill -0 "$1" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 300 ] && exit 0
          /bin/sleep 0.2
        done
        backup="$3.previous"
        /bin/rm -rf "$backup"
        if ! /bin/mv "$3" "$backup"; then /usr/bin/open "$3"; exit 1; fi
        if /bin/mv "$2" "$3"; then /bin/rm -rf "$backup"; else /bin/mv "$backup" "$3"; fi
        /usr/bin/open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "kite-update", String(ProcessInfo.processInfo.processIdentifier), staged, app.path]
        try process.run()
        NSApplication.shared.terminate(nil)
    }
    #endif
}

extension AppModel {
    /// 侧栏用户栏的版本提示，点开到那台工作机的版本页：本机备好了新 App 时请重启以更新；有工作机比这个 App 新时请更新 App。
    var appUpdateNotice: (title: String, machineID: String)? {
        #if os(macOS)
        if let local = connections.values.first(where: { $0.client.isLocal }), let app = localUpdate?.app,
           let build = AppBuild.current, app.build != build {
            return ("新版本已就绪，重启以更新", local.id)
        }
        #endif
        if let newer = accountWorkers.first(where: { $0.outdated == .app }) { return ("App 需要更新", newer.id) }
        return nil
    }

    func openUpdatePage(_ machineID: String) {
        sidebarSection = .drive
        accountMachineID = machineID
        drivePage = .version
    }

    /// 本机 kited 的更新状态，侧栏提示与重启以更新用；只有作为工作机的 Mac 才有本机 kited。
    var localUpdate: UpdateStatus? { connections.values.first { $0.client.isLocal }?.update }

    /// 重读工作机的更新状态，版本页、设备标记与本机的重启以更新共用。
    func refreshUpdate(_ connection: WorkerConnection) async {
        guard let status = try? await connection.client.request("/update", as: UpdateStatus.self) else { return }
        if connection.update != status { connection.update = status }
    }
}

/// 工作机的版本页：正在运行的版本、最近一次发布与自动更新的进度；新版本等空闲时可以现在更新。
/// 本机备好了新 Mac App 时，在这里重启以更新。
struct UpdateSettingsPage: View {
    let connection: WorkerConnection
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var busy = false
    @State private var confirming = false

    private var status: UpdateStatus? { connection.update }

    var body: some View {
        Form {
            Section("版本") {
                if let outdated = connection.outdated { Text(outdated.detail).foregroundStyle(Theme.warning) }
                LabeledContent("工作机", value: (status?.version ?? connection.version).map(Self.describe) ?? "读取中")
                LabeledContent("这个 App", value: "协议 \(KiteProtocol.version)" + (AppBuild.current.map { " · 构建 \($0.prefix(8))" } ?? ""))
                if let release = status?.release {
                    LabeledContent("最近发布", value: "构建 \(release.build.prefix(8)) · 协议 \(release.protocol) · \(machineName(release.by))")
                }
            }
            if let status { Section("自动更新") { stateRows(status) } }
            #if os(macOS)
            if connection.client.isLocal, let app = status?.app, let build = AppBuild.current, app.build != build {
                Section("App") {
                    Text("这台 Mac 的新版 App 已备好，重启 App 后换上。").foregroundStyle(.secondary)
                    Button("重启以更新") {
                        do { try AppBuild.relaunch(with: app.path) } catch { self.error = error.localizedDescription }
                    }
                }
            }
            #endif
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .pageForm()
        .task(id: connection.id) { await load() }
        .confirmationDialog("现在更新", isPresented: $confirming) {
            Button("现在更新", role: .destructive) { Task { await apply() } }
        } message: {
            Text("工作机会重启，正在进行的回合、终端与后台命令都会中断。")
        }
    }

    @ViewBuilder private func stateRows(_ status: UpdateStatus) -> some View {
        switch status.state {
        case "dev": Text("源码运行的工作机不参与自动更新。").foregroundStyle(.secondary)
        case "current": Text("已是最近发布的版本。").foregroundStyle(.secondary)
        case "unsupported": Text(status.reason ?? "需要在这台工作机上手动安装。").foregroundStyle(Theme.warning)
        case "waiting-source": Text("新版本已发布，等正在运行它的工作机上线后取过来。").foregroundStyle(.secondary)
        case "downloading":
            let done = status.done ?? 0, total = max(status.total ?? 0, 1)
            ProgressView(value: Double(min(done, total)), total: Double(total)) {
                Text("正在取新版本")
            } currentValueLabel: {
                Text("\(Int64(done).formatted(.byteCount(style: .file))) / \(Int64(total).formatted(.byteCount(style: .file)))").monospacedDigit()
            }
        case "ready":
            let waiting = status.waiting ?? []
            if waiting.isEmpty {
                Text("新版本已准备好，马上换上。").foregroundStyle(.secondary)
            } else {
                Text("新版本已准备好，等这台工作机空闲后换上：").foregroundStyle(.secondary)
                ForEach(waiting, id: \.self) { Text($0) }
                Button("现在更新", role: .destructive) { confirming = true }.disabled(busy)
            }
        case "installing": Text("正在换上新版本，工作机会重启。").foregroundStyle(.secondary)
        case "failed":
            Text(status.error ?? "更新失败").foregroundStyle(Theme.danger).textSelection(.enabled)
            Text(status.retry == true ? "稍后自动重试。" : "这一版不再自动重试，可以在这台工作机上手动安装。").foregroundStyle(.secondary)
        default: Text(status.state).foregroundStyle(.secondary)
        }
    }

    private static func describe(_ version: MachineVersion) -> String {
        version.build == "dev" ? "源码运行 · 协议 \(version.protocol)" : "构建 \(version.build.prefix(8)) · 协议 \(version.protocol)"
    }

    private func machineName(_ id: String) -> String {
        model.connections[id]?.machine.name ?? (id == connection.id ? connection.machine.name : "另一台工作机")
    }

    private func load() async {
        do {
            connection.update = try await connection.client.request("/update", as: UpdateStatus.self)
            error = nil
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func apply() async {
        busy = true
        defer { busy = false }
        do { connection.update = try await connection.client.request("/update/apply", method: "POST", as: UpdateStatus.self) }
        catch { self.error = error.localizedDescription }
    }
}
