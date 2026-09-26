import SwiftUI

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("服务地址", text: $address)
                    .autocorrectionDisabled()
                Text("Mac 和 iPhone 模拟器可使用 http://127.0.0.1:5483。真机需要能访问工作机的安全连接。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Button("连接") {
                    model.serverAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                }
            }
            .formStyle(.grouped)
            .navigationTitle("连接工作机")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onAppear { address = model.serverAddress }
        #if os(macOS)
        .frame(width: 480, height: 300)
        #endif
    }
}

struct NewSession: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var prompt = ""
    @State private var path = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("项目") {
                    Picker("项目", selection: $project) {
                        Text("选择项目").tag("")
                        ForEach(model.projects) { project in Text(project.name).tag(project.id) }
                    }
                    TextField("工作机上的文件夹绝对路径", text: $path).autocorrectionDisabled()
                    Button("登记项目") {
                        perform {
                            try await model.register(path: path)
                            project = model.projects.first { $0.path == path }?.id ?? model.projects.last?.id ?? ""
                            path = ""
                        }
                    }.disabled(working || !path.hasPrefix("/"))
                }
                Section("开始会话") {
                    TextField("说说要做什么", text: $prompt, axis: .vertical).lineLimit(3...8)
                    Button(working ? "正在创建…" : "创建会话") {
                        perform { try await model.create(project: project, prompt: prompt); dismiss() }
                    }.disabled(working || project.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("新会话")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onAppear {
            project = model.projects.first?.id ?? ""
            prompt = model.draftSession.draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .task(id: "\(model.serverAddress):\(phase == .active)") {
                if phase == .active { await model.connect() }
            }
            .sheet(isPresented: $model.showConnection) { ConnectionSettings().environment(model) }
            .sheet(isPresented: $model.showNewSession) { NewSession().environment(model) }
    }
}
