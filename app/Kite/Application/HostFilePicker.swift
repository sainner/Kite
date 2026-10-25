import SwiftUI

/// 在一台工作机上选文件夹或文件（kited 的 GET /host-files），添加项目时用：选文件夹是选当前所在的目录，文件可以跨目录多选。
/// 只列名字，交回的是那台工作机上的绝对路径，文件内容由它在添加时自己读。
struct HostFilePicker: View {
    struct Request: Identifiable {
        let machineID: String
        /// 选文件夹；否则选文件。
        let folders: Bool
        /// 从哪个目录开始，读不了时退回主目录；为空时就是主目录。
        var start: String?
        var id: String { "\(machineID)|\(folders)" }
    }

    let request: Request
    let choose: ([String]) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var directory: FileDirectory?
    @State private var entries: [FileDirectory.Entry] = []
    @State private var selected: Set<String> = []
    /// 顶部地址栏里的路径，读到目录后换成它的绝对路径。
    @State private var location = ""
    @State private var phase = CardPhase.idle
    @FocusState private var typing: Bool

    var body: some View {
        CardSheet(title: request.folders ? "选择文件夹" : "选择文件", subtitle: request.folders ? "选项目所在的文件夹" : "选要带上的环境变量文件",
                  error: phase.error, typing: typing, size: CGSize(width: 480, height: 560), close: { dismiss() }) {
            CardField(label: nil, focused: typing) {
                TextField("工作机上的绝对路径，可写 ~/ 开头", text: $location)
                    .literal().focused($typing)
                    .onSubmit { open(location.trimmingCharacters(in: .whitespaces)) }
                    .cardInput { typing = true }
            }
            if let directory {
                CardSection {
                    if directory.path != "/" {
                        Button { open((directory.path as NSString).deletingLastPathComponent) } label: {
                            Label("上一级", systemImage: "arrow.turn.left.up")
                        }
                        .disabled(phase.working)
                    }
                    ForEach(entries) { entry in row(entry) }
                    if let next = directory.nextOffset {
                        Button("还有 \(directory.total - next) 项") { loadMore(from: next) }.disabled(phase.working)
                    }
                }
            }
        } actions: {
            [[.sheet("选择", disabled: phase.working || (request.folders ? directory == nil : selected.isEmpty)) {
                choose(request.folders ? directory.map { [$0.path] } ?? [] : selected.sorted())
                dismiss()
            }]]
        }
        .endsTyping(typing) { typing = false }
        .task {
            if let start = request.start, (try? await load(start)) != nil { return }
            open(nil)
        }
    }

    @ViewBuilder
    private func row(_ entry: FileDirectory.Entry) -> some View {
        if entry.kind == "directory" {
            Button { open(entry.path) } label: {
                HStack(spacing: 12) {
                    Label(entry.name, systemImage: "folder").foregroundStyle(.primary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(Theme.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .disabled(phase.working)
        } else if entry.kind == "file" && !request.folders {
            let on = selected.contains(entry.path)
            Button {
                if on { selected.remove(entry.path) } else { selected.insert(entry.path) }
            } label: {
                HStack(spacing: 12) {
                    Label(entry.name, systemImage: FileFormat(path: entry.path).symbol).foregroundStyle(.primary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark").opacity(on ? 1 : 0)
                }
            }
            .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            // 选文件夹时的文件、读不到目标的链接：只供辨认，不能选
            Label(entry.name, systemImage: entry.kind == "file" ? FileFormat(path: entry.path).symbol : "questionmark.square.dashed")
                .foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func load(_ path: String?) async throws {
        let listing = try await model.hostDirectory(path, on: request.machineID)
        directory = listing
        entries = listing.entries
        location = listing.path
    }

    /// 进入一个目录，path 为空时是主目录；读失败时停在原来的目录，地址栏留着输入的路径，可以改了再试。
    private func open(_ path: String?) {
        $phase.run { try await load(path) }
    }

    private func loadMore(from offset: Int) {
        guard let path = directory?.path else { return }
        $phase.run {
            let more = try await model.hostDirectory(path, offset: offset, on: request.machineID)
            guard more.path == directory?.path else { return }
            directory = more
            entries += more.entries
        }
    }
}
