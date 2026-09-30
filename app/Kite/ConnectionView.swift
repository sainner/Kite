import SwiftUI

struct AppSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") { AppearancePicker() }
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
                    Text("Mac 和 iPhone 模拟器可使用 http://127.0.0.1:5483。真机需要能访问工作机的安全连接。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(working ? "正在连接…" : "连接并保存") {
                        working = true
                        error = nil
                        Task {
                            defer { working = false }
                            do { try await model.addConnection(address: address); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(working || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(SampleWorkspace.enabled)
                if let error = error ?? model.error { Text(error).foregroundStyle(.red) }
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
                if let error { Text(error).foregroundStyle(.red) }
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

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .task(id: "\(model.connectionRevision):\(phase == .active)") {
                if !SampleWorkspace.enabled, phase == .active { await model.connect() }
            }
            .sheet(isPresented: $model.showConnection) { AppSettings().environment(model).appAppearance() }
            .sheet(isPresented: $model.showNewWorkspace) { NewWorkspace().environment(model).appAppearance() }
    }
}
