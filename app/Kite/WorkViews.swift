import SwiftUI

/// 两段话之间 agent 做的事，折成一行：「读取了 3 个文件，修改了 1 个文件，执行了 2 条命令」；有调用在跑时说正在做什么。
/// 汇总行只放文字和紧跟文字的箭头。点开按模型回复分批列出每一步，同批调用之间用横向虚线分隔。
/// 每一步再点开看参数和结果。
struct WorkRow: View {
    let work: Work
    @State private var expanded = false

    var body: some View {
        let failed = work.count(.failed) + work.count(.unknown), unfinished = work.count(.unfinished)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if let running = work.running {
                        Text(running.use.title)
                            .modifier(ToolSummaryActivity(running: !expanded && work.count(.running) > 0))
                    } else {
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
                    Spacer(minLength: 0)
                }
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointingPlain)
            if expanded {
                WorkSteps(work: work)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 步骤仍按原来的序号识别，后续调用到来、形成批次时，不重建已经展开的工具详情。
private struct WorkSteps: View {
    let work: Work

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(work.calls.indices, id: \.self) { index in
                if index > 0 {
                    let batch = work.calls[index - 1].use.batch
                    WorkSeparator(sameBatch: batch != nil && batch == work.calls[index].use.batch)
                }
                CallRow(call: work.calls[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.toolGroupRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.toolGroupRadius).strokeBorder(Theme.toolRule, lineWidth: 1)
        }
    }
}

/// 同批用横向虚线，不同批用实线；两者占用相同的高度。
private struct WorkSeparator: View {
    let sameBatch: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(Theme.toolRule, style: StrokeStyle(lineWidth: 1, dash: sameBatch ? [4, 3] : []))
        }
        .frame(height: 1)
        .allowsHitTesting(false)
    }
}

/// 一次工具调用。
private struct CallRow: View {
    let call: Call
    @Environment(\.workingDirectory) private var root
    @ScaledMetric(relativeTo: .subheadline) private var headerHeight = Metrics.toolRowHeight
    @State private var expanded = false

    var body: some View {
        let summary = call.use.rowSummary(relativeTo: root, generating: call.state == .generating)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // 容器统一接收点击；展示内容穿透，文件引用在前景自行处理跳转。
                Button(action: toggle) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.pointingPlain)
                .accessibilityLabel(call.use.displayName + " " + summary)
                .accessibilityValue(call.stageLabel.isEmpty ? "成功" : call.stageLabel)
                .accessibilityHint(expanded ? "收起参数与结果" : "展开参数与结果")
                HStack(spacing: Metrics.toolLabelGap) {
                    HStack(spacing: Metrics.toolLabelGap) {
                        Image(systemName: call.use.kind.icon)
                            .foregroundStyle(failed ? .red : active ? Color.accentColor : .secondary)
                            .frame(width: Metrics.toolIcon)
                        Text(call.use.displayName).fontWeight(.semibold)
                            .foregroundStyle(failed ? .red : call.state == .running ? Color.accentColor : .primary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .allowsHitTesting(false)
                    if call.state != .generating, !call.fileReferences.isEmpty {
                        ToolReferenceSummary(references: call.fileReferences)
                            .modifier(ToolSummaryActivity(running: call.state == .running))
                            .foregroundStyle(failed ? .red : .secondary)
                            .tint(failed ? .red : .secondary)
                    } else {
                        Text(verbatim: summary)
                            .truncationMode(call.use.kind == .command ? .tail : .middle)
                            .modifier(ToolSummaryActivity(running: call.state == .running))
                            .foregroundStyle(failed ? .red : call.state == .running ? Color.accentColor.opacity(0.65) : .secondary)
                            .allowsHitTesting(false)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if let diff = call.use.diffSummary {
                            ToolInfoChip(text: diff)
                                .accessibilityLabel("补丁行数 \(diff)")
                                .help("参数中的新增与删除行数，不代表已写入的改动")
                        }
                        ToolDurationChip(call: call)
                    }
                    .allowsHitTesting(false)
                }
                .font(Theme.secondary)
                .lineLimit(1)
                .padding(.horizontal, Metrics.toolRowInset)
            }
            .frame(height: headerHeight)
            .background { ToolRowActivity(state: call.state).allowsHitTesting(false) }
            if expanded {
                CallDetail(call: call)
                    .padding(.leading, Metrics.toolRowInset + Metrics.toolIcon + Metrics.toolLabelGap)
                    .padding(.trailing, Metrics.toolRowInset)
                    .padding(.bottom, 10)
            }
        }
        // 一条展开时，旁边收起的工具行也保留自身高度，不参与父容器的纵向压缩。
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle() { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }

    private var active: Bool { call.state == .queued || call.state == .running }

    private var failed: Bool {
        call.state == .failed || call.state == .unknown
    }
}

private struct ToolInfoChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.status)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.codeBackground, in: Capsule())
    }
}

private struct ToolDurationChip: View {
    let call: Call

    var body: some View {
        if call.use.kind == .command, let start = call.use.startedAt {
            if let finish = call.use.finishedAt {
                chip(milliseconds: finish - start)
            } else if call.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    chip(milliseconds: timeline.date.timeIntervalSince1970 * 1000 - start)
                }
            }
        }
    }

    private func chip(milliseconds: Double) -> some View {
        let duration = max(0, milliseconds)
        let text = duration < 1000
            ? duration.formatted(.number.precision(.fractionLength(0))) + " ms"
            : (duration / 1000).formatted(.number.precision(.fractionLength(0...1))) + " s"
        return ToolInfoChip(text: text).accessibilityLabel("运行时间 \(text)")
    }
}

/// 只在思考条目生成期间显示，完整摘要仍保留在记录中。
struct ThinkingRow: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? "思考中" : text.replacingOccurrences(of: "\n", with: " "))
            .font(Theme.secondary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 所有工具共用完整参数和结果展示；生成中的原文不是完整 JSON，单独保留。
private struct CallDetail: View {
    let call: Call

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("name", .string(call.use.name))
            field("input", call.use.input)
            if call.state == .generating {
                field("arguments", .string(call.use.arguments ?? ""))
            }
            if let result = call.result {
                field("result", .object([
                    "status": .string(result.unknown ? "unknown" : result.interrupted ? "not_executed" : result.isError ? "error" : "success"),
                    "output": .string(result.text),
                ].merging(result.diff.map { ["diff": JSON.object(["id": .string($0.id), "paths": .array($0.paths.map(JSON.string))])] } ?? [:]) { _, new in new }))
                // 旧记录中的非文本内容也保留字段，不再换成各工具专用的展示。
                if result.content.contains(where: { if case .image = $0 { true } else { false } }) {
                    field("content", .array(result.content.map { part in
                        switch part {
                        case .text(let text): .object(["type": "text", "text": .string(text)])
                        case .image(let width, let height): .object(["type": "image", "width": .number(Double(width)), "height": .number(Double(height))])
                        }
                    }))
                }
            } else {
                field("stage", .string(call.use.stage ?? (call.state == .running ? "running" : "unfinished")))
                if !call.use.output.isEmpty {
                    field("output", .string(call.use.output))
                    field("outputTruncated", .bool(call.use.outputTruncated))
                }
            }
            if !call.children.isEmpty {
                TranscriptView(items: call.children)
                    .padding(.leading, 12)
            }
        }
        .font(Theme.code)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ key: String, _ value: JSON) -> some View {
        JSONField(key: key, value: value)
    }
}

/// 对象按键列出，数组保留索引；字符串原样换行，不把 output 再猜成另一份 JSON。
private struct JSONFields: View {
    let value: JSON

    @ViewBuilder
    var body: some View {
        switch value {
        case .object(let object) where !object.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    if let value = object[key] { JSONField(key: key, value: value) }
                }
            }
        case .array(let values) where !values.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(values.indices, id: \.self) { index in
                    JSONField(key: "[\(index)]", value: values[index])
                }
            }
        case .string(let text):
            ReferenceLabel(text.isEmpty ? "\"\"" : text, compact: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text(verbatim: scalar)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scalar: String {
        switch value {
        case .string(let text): text.isEmpty ? "\"\"" : text
        case .number(let number): number.formatted(.number.grouping(.never).precision(.significantDigits(1...17)))
        case .bool(let flag): flag ? "true" : "false"
        case .null: "null"
        case .object: "{}"
        case .array: "[]"
        }
    }
}

private struct JSONField: View {
    let key: String
    let value: JSON

    var body: some View {
        // 容器和多行值另起一行，窄窗口也不会被长键名挤掉正文宽度。
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: key).foregroundStyle(.secondary)
            JSONFields(value: value).padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
