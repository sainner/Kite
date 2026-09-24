import SwiftUI

/// 两段话之间 agent 做的事，折成一行：「读了 3 个文件，改了 1 个文件，跑了 2 条命令」；有调用在跑时说正在做什么。
/// 点开列出每一步，每一步再点开看参数和结果。只有思考的，点开直接是思考的内容。
struct WorkRow: View {
    let work: Work
    @State private var expanded = false

    var body: some View {
        let thinkingOnly = work.calls.isEmpty
        let failed = work.count(.failed), unfinished = work.count(.unfinished)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if let running = work.running {
                        Spinner()
                        Text("正在" + running.use.title)
                    } else if thinkingOnly {
                        Image(systemName: "brain")
                        Text("思考")
                        if !expanded { Text(firstLine(work.thinking.first)).foregroundStyle(.tertiary) }
                    } else {
                        HStack(spacing: 4) {
                            ForEach(work.icons, id: \.self) { Image(systemName: $0) }
                        }
                        Text(work.summary)
                    }
                    if failed > 0 {
                        Text("\(failed) 步出错").foregroundStyle(.red)
                    }
                    if unfinished > 0 {
                        Text("\(unfinished) 步没跑完")
                    }
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Group {
                    if thinkingOnly {
                        ThinkingText(text: work.thinking.joined(separator: "\n\n"))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(work.steps.indices, id: \.self) { StepRow(step: work.steps[$0]) }
                        }
                    }
                }
                .leadingRule()
            }
        }
    }
}

/// 一步：一次工具调用或一段思考。
private struct StepRow: View {
    let step: Step
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    icon.frame(width: 16)
                    Text(title).foregroundStyle(failed ? .red : .primary)
                    if let note {
                        Text(note).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.secondary)
                .lineLimit(1)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                detail
                    .padding(.leading, 24)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch step {
        case .thinking:
            Image(systemName: "brain").foregroundStyle(.secondary)
        case .call(let call):
            if call.state == .running {
                Spinner()
            } else {
                Image(systemName: call.use.kind.icon).foregroundStyle(failed ? .red : .secondary)
            }
        }
    }

    private var title: String {
        switch step {
        case .thinking: "思考"
        case .call(let call): call.use.title
        }
    }

    private var note: String? {
        switch step {
        case .thinking(let text): firstLine(text)
        case .call(let call):
            switch call.state {
            case .unfinished: "没跑完"
            case .interrupted: "被打断"
            default: call.use.note
            }
        }
    }

    private var failed: Bool {
        if case .call(let call) = step { call.state == .failed } else { false }
    }

    @ViewBuilder
    private var detail: some View {
        switch step {
        case .thinking(let text):
            ThinkingText(text: text)
        case .call(let call):
            CallDetail(call: call)
        }
    }
}

private struct ThinkingText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.secondary)
            .italic()
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一次调用的参数和结果，按工具挑要紧的显示；认不出的工具列出全部参数和结果原文。
private struct CallDetail: View {
    let call: Call
    @Environment(\.workingDirectory) private var root

    private var input: JSON { call.use.input }
    private var output: String { call.result?.text ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch call.use.kind {
            case .command:
                CodeBlock(text: "$ " + (input["command"]?.string ?? ""), maxLines: 6)
                outcome { CodeBlock(text: output.isEmpty ? "（没有输出）" : output) }
            case .read:
                path
                outcome {
                    if let image = call.result?.content.first(where: { if case .image = $0 { true } else { false } }),
                       case .image(let width, let height) = image {
                        ImagePlaceholder(width: width, height: height)
                    } else {
                        CodeBlock(text: output)
                    }
                }
            case .edit:
                path
                DiffView(diff: LineDiff(old: input["old_string"]?.string ?? "", new: input["new_string"]?.string ?? ""))
                outcome {}
            case .write:
                path
                DiffView(diff: LineDiff(old: "", new: input["content"]?.string ?? ""))
                outcome {}
            case .notebookEdit:
                path
                if let cell = input["cell_id"]?.string {
                    Text("单元格 \(cell)").foregroundStyle(.secondary)
                }
                if input["edit_mode"]?.string != "delete" {
                    DiffView(diff: LineDiff(old: "", new: input["new_source"]?.string ?? ""))
                }
                outcome {}
            case .webSearch:
                outcome { SearchResults(text: output) }
            case .webFetch:
                if let url = input["url"]?.string, let link = URL(string: url) {
                    Link(url, destination: link).lineLimit(1)
                }
                Text(input["prompt"]?.string ?? "").foregroundStyle(.secondary)
                outcome { MarkdownView(output) }
            case .agent:
                AgentDetail(call: call)
                outcome { MarkdownView(output) }
            case .check:
                outcome { CodeBlock(text: output, tint: .green) }
            default:
                InputList(input: input)
                outcome { CodeBlock(text: output.isEmpty ? "（没有输出）" : output) }
            }
        }
        .font(Theme.secondary)
    }

    private var path: some View {
        Text(relativePath(call.use.file ?? "", to: root))
            .font(Theme.code)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    /// 结果：成功时是 success（改文件这类成功时结果只是一句套话，给空的），出错时是错误原文，没有正常结果时说一句为什么。
    @ViewBuilder
    private func outcome(@ViewBuilder success: () -> some View) -> some View {
        switch call.state {
        case .done: success()
        case .failed: CodeBlock(text: output, tint: .red)
        case .running: Text("正在跑…").foregroundStyle(.secondary)
        case .interrupted: Text("跑到一半被打断了。").foregroundStyle(.secondary)
        case .unfinished: Text("没有结果：这一步跑到一半时进程没了。").foregroundStyle(.secondary)
        }
    }
}

/// 子 agent：交给它的任务和它做的事。它交回来的结果照一般的结果显示。
private struct AgentDetail: View {
    let call: Call
    @State private var promptExpanded = false

    var body: some View {
        Text(call.use.input["prompt"]?.string ?? "")
            .foregroundStyle(.secondary)
            .lineLimit(promptExpanded ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture { promptExpanded.toggle() }
        if !call.children.isEmpty {
            TranscriptView(items: call.children).leadingRule()
        }
    }
}

/// 改动前后按行对比，删的标红、加的标绿。长的先显示开头。
private struct DiffView: View {
    let diff: LineDiff

    var body: some View {
        Folded(lines: diff.lines, limit: 24) { shown in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown.indices, id: \.self) { index in
                    let (sign, text, color) = parts(shown[index])
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sign).foregroundStyle(.secondary)
                        Text(text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.code)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color)
                }
            }
            .padding(.vertical, 6)
        }
        .textSelection(.enabled)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func parts(_ line: LineDiff.Line) -> (String, String, Color) {
        switch line {
        case .same(let text): (" ", text, .clear)
        case .removed(let text): ("-", text, Theme.removed)
        case .added(let text): ("+", text, Theme.added)
        }
    }
}

/// WebSearch 的结果：原文里「Links: 」那一行是 JSON 数组，列成链接；其余是模型的说明。
private struct SearchResults: View {
    let text: String

    var body: some View {
        let (links, rest) = parse()
        VStack(alignment: .leading, spacing: 6) {
            ForEach(links.indices, id: \.self) { index in
                let link = links[index]
                if let url = URL(string: link.url) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Text(link.title).lineLimit(1)
                            Text(url.host() ?? "").foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .font(Theme.secondary)
                }
            }
            if !rest.isEmpty {
                MarkdownView(rest)
            }
        }
    }

    private func parse() -> ([(title: String, url: String)], String) {
        var links: [(title: String, url: String)] = []
        var rest: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("Links: "), let data = line.dropFirst("Links: ".count).data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                links = array.compactMap { item in
                    guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
                    return (title, url)
                }
            } else if !line.hasPrefix("Web search results for query:") {
                rest.append(line)
            }
        }
        return (links, rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 认不出的工具：参数一条一行。
private struct InputList: View {
    let input: JSON

    var body: some View {
        if case .object(let object) = input, !object.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    GridRow {
                        Text(key).foregroundStyle(.secondary)
                        Text(object[key]?.display ?? "")
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(Theme.secondary)
        }
    }
}

/// 工具结果里的图片。假数据没有图片本身，先按尺寸画个框。
private struct ImagePlaceholder: View {
    let width: Int
    let height: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.codeBackground)
            .aspectRatio(CGFloat(width) / CGFloat(max(height, 1)), contentMode: .fit)
            .frame(maxHeight: 180)
            .overlay {
                Label("图片 \(width)×\(height)", systemImage: "photo")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }
    }
}

private extension View {
    /// 往里缩一截，左边画一条竖线：展开的步骤、子 agent 做的事。
    func leadingRule() -> some View {
        padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1).padding(.leading, 5) }
    }
}

/// 在跑的小转圈。
struct Spinner: View {
    var body: some View {
        ProgressView().controlSize(.mini)
    }
}
