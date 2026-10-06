import CoreImage.CIFilterBuiltins
import SwiftUI

struct AppSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var controlURL = Tailnet.customControlURL
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") { AppearancePicker() }
                Section("插件") {
                    NavigationLink("管理插件定义") { PluginLibrary().id(model.connectionRevision) }
                        .disabled(SampleWorkspace.enabled || !model.connected)
                }
                Section("上下文") {
                    NavigationLink("管理上下文模板") { ContextTemplateLibrary().id(model.connectionRevision) }
                        .disabled(!SampleWorkspace.enabled && !model.connected)
                }
                if !model.connections.entries.isEmpty {
                    Section("已保存的工作机") {
                        ForEach(model.connections.entries) { connection in
                            Button {
                                do { try model.selectConnection(connection.id); dismiss() }
                                catch { self.error = error.localizedDescription }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(connection.machine.name)
                                        Text(connection.address).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if connection.id == model.machine?.id { Image(systemName: "checkmark") }
                                }
                            }.disabled(working)
                        }
                    }
                    .disabled(SampleWorkspace.enabled)
                }
                Section("连接地址") {
                    TextField("服务地址", text: $address)
                        .autocorrectionDisabled()
                    TextField("配对码（远程工作机首次连接时填写）", text: $code)
                        .autocorrectionDisabled()
                    Text("本机服务使用 http://127.0.0.1:5483。远程工作机填写它的组网地址，配对码在工作机上用 kite pair 或其 Kite 设置生成。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(working ? "正在连接…" : "连接并保存") {
                        working = true
                        error = nil
                        Task {
                            defer { working = false }
                            do { try await model.addConnection(address: address, code: code); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(working || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(SampleWorkspace.enabled)
                Section("组网") {
                    TextField("控制服务器（留空用 Tailscale）", text: $controlURL)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await Tailnet.shared.configure(controlURL: controlURL.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                    if let url = Tailnet.status.loginURL { Link("登录组网", destination: url) }
                    Text("连接组网地址的工作机时，这台设备自己作为组网节点上线。自建 headscale 时填它的地址；改动后重新连接并登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(SampleWorkspace.enabled)
                if !SampleWorkspace.enabled, model.connected, model.connections.selected?.token == nil {
                    PairedDevices().id(model.connectionRevision)
                }
                if let error = error ?? model.error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onAppear { address = model.serverAddress }
        #if os(macOS)
        .frame(width: 480, height: 500)
        #endif
    }
}

struct RemotePairing: Decodable {
    let code: String
    let expiresAt: Double
    let address: String?
    /// kite://pair 邀请链接，组网上线后才有。
    let invite: String?
}

struct RemoteDevice: Decodable, Identifiable {
    let id: String
    let name: String
    let createdAt: Double
    let lastSeenAt: Double?
}

/// 只在连本机服务时出现：配对码和撤销都由工作机本机发起。
struct PairedDevices: View {
    @Environment(AppModel.self) private var model
    @State private var pairing: RemotePairing?
    @State private var devices: [RemoteDevice] = []
    @State private var error: String?

    var body: some View {
        Section("远程设备") {
            if let pairing {
                if let invite = pairing.invite, let image = Self.qrCode(invite) {
                    image.resizable().interpolation(.none).scaledToFit().frame(width: 200, height: 200)
                        .frame(maxWidth: .infinity)
                }
                LabeledContent("配对码") { Text(pairing.code).font(.title3.monospaced()).textSelection(.enabled) }
                Text(pairing.address.map { "用 iPhone 相机扫码即可连接，也可以手动填写地址 \($0) 和配对码。\(Self.time(pairing.expiresAt)) 前有效，只能使用一次。" }
                     ?? "组网尚未上线，远程设备暂时连不上；先在终端运行 kite net up。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("添加设备") { perform { pairing = try await model.activeClient().request("/pairings", method: "POST", as: RemotePairing.self) } }
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.lastSeenAt.map { "最近使用 \(Self.time($0))" } ?? "尚未使用").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("撤销", role: .destructive) {
                        perform { let _: JSON = try await model.activeClient().request("/devices/\(device.id)", method: "DELETE", as: JSON.self) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .task { perform {} }
    }

    private static func qrCode(_ text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return Image(decorative: image, scale: 1)
    }

    private static func time(_ milliseconds: Double) -> String {
        Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    /// 每次操作后重新读取设备列表，配对成功的设备也会出现在这里。
    private func perform(_ action: @escaping () async throws -> Void) {
        error = nil
        Task {
            do {
                try await action()
                devices = try await model.activeClient().request("/devices", as: [RemoteDevice].self)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct NewWorkspace: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var checkoutID = ""
    @State private var projectID = ""
    @State private var prompt = ""
    @State private var path = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("项目") {
                    if let machine = model.machine { Text("工作机：\(machine.name)").font(.caption).foregroundStyle(.secondary) }
                    Picker("工作目录", selection: $checkoutID) {
                        Text("选择工作目录").tag("")
                        ForEach(model.checkouts) { checkout in Text(checkout.path).tag(checkout.id) }
                    }
                    .clickPointer()
                    Picker("登记到", selection: $projectID) {
                        Text("新建项目").tag("")
                        ForEach(model.knownProjects) { project in Text(model.projectLabel(project)).tag(project.id) }
                    }
                    .clickPointer()
                    TextField("工作机上的文件夹绝对路径", text: $path).autocorrectionDisabled()
                    Button("登记目录") {
                        perform {
                            checkoutID = try await model.registerCheckout(path: path, projectID: projectID)
                            path = ""
                        }
                    }.disabled(working || !path.hasPrefix("/"))
                }
                Section("开始会话") {
                    TextField("说说要做什么", text: $prompt, axis: .vertical).lineLimit(3...8)
                    Button(working ? "正在创建…" : "创建工作区") {
                        perform { try await model.create(checkout: checkoutID, prompt: prompt); dismiss() }
                    }.disabled(working || checkoutID.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .navigationTitle("新工作区")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onAppear {
            checkoutID = model.checkouts.first?.id ?? ""
            prompt = model.draftWorkspace.draftThread.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #if os(macOS)
        .frame(width: 520, height: 440)
        #endif
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

struct ServiceConnection: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .task(id: "\(model.connectionRevision):\(phase == .active)") {
                if !SampleWorkspace.enabled, !OnboardingPreview.enabled, phase == .active { await model.connect() }
            }
            // 组网节点首次上线需要登录，打开系统浏览器完成。
            .onChange(of: Tailnet.status.loginURL) { _, url in if let url { openURL(url) } }
            .onOpenURL { url in Task { await model.acceptInvite(url) } }
            #if os(iOS)
            .onChange(of: phase) { _, phase in if phase == .background { Task { await Tailnet.shared.stop() } } }
            #endif
            .sheet(isPresented: $model.showConnection) { AppSettings().environment(model).toastHost().appAppearance() }
            .sheet(isPresented: $model.showNewWorkspace) { NewWorkspace().environment(model).toastHost().appAppearance() }
    }
}
