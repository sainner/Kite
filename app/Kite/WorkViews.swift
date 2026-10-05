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
                            .modifier(ToolRowActivity(state: !expanded && work.count(.running) > 0 ? .running : nil))
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
        // 收起整个工具组时，仍在退场的列表不能画到后续消息上。
        .clipped()
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
                        HStack(spacing: Metrics.toolLabelGap) {
                            Image(systemName: call.use.kind.icon)
                                #if os(iOS)
                                .imageScale(.small)
                                #endif
                                .foregroundStyle(failed ? .red : .secondary)
                                .frame(width: Metrics.toolIcon)
                            Text(call.use.displayName).fontWeight(.semibold)
                                .foregroundStyle(failed ? .red : .primary)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .allowsHitTesting(false)
                        if call.state != .generating, !call.fileReferences.isEmpty {
                            ToolReferenceSummary(references: call.fileReferences)
                                .foregroundStyle(failed ? .red : .secondary)
                                .tint(failed ? .red : .secondary)
                        } else {
                            Text(verbatim: summary)
                                .truncationMode(call.use.kind == .command ? .tail : .middle)
                                .foregroundStyle(failed ? .red : .secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    .modifier(ToolRowActivity(state: call.state))
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
            if expanded {
                CallDetail(call: call)
                    .padding(.horizontal, Metrics.toolRowInset)
                    .padding(.bottom, 10)
            }
        }
        // 一条展开时，旁边收起的工具行也保留自身高度，不参与父容器的纵向压缩。
        .fixedSize(horizontal: false, vertical: true)
        // 详情的退场动画可能晚于行高收缩，始终按当前行的边界裁剪。
        .clipped()
    }

    private func toggle() { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }

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

/// 兜底详情分为参数和结果两张卡片，名称与状态由工具标题行表达。
private struct CallDetail: View {
    let call: Call

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolDetailCard {
                JSONFields(value: input)
                if call.state == .generating {
                    JSONField(key: "arguments（原文）", value: .string(call.use.arguments ?? ""))
                }
            }
            ToolDetailCard {
                JSONFields(value: result)
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

    private var input: JSON {
        guard case .object(let fields) = call.use.input else { return call.use.input }
        return .object(fields.filter { $0.key != "description" })
    }

    private var result: JSON {
        var fields: [String: JSON] = [:]
        if let result = call.result {
            fields["output"] = .string(result.text)
            if let diff = result.diff {
                fields["diff"] = .object(["id": .string(diff.id), "paths": .array(diff.paths.map(JSON.string))])
            }
            // 旧记录中的非文本内容仍保留在结果卡片中。
            if result.content.contains(where: { if case .image = $0 { true } else { false } }) {
                fields["content"] = .array(result.content.map { part in
                    switch part {
                    case .text(let text): .object(["type": "text", "text": .string(text)])
                    case .image(let width, let height): .object(["type": "image", "width": .number(Double(width)), "height": .number(Double(height))])
                    }
                })
            }
        } else if !call.use.output.isEmpty {
            fields["output"] = .string(call.use.output)
            fields["outputTruncated"] = .bool(call.use.outputTruncated)
        }
        return .object(fields)
    }
}

private struct ToolDetailCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Metrics.toolGroupRadius))
    }
}

/// 只列顶层键；嵌套对象和数组作为完整值序列化，不再递归排版。
private struct JSONFields: View {
    let value: JSON

    @ViewBuilder
    var body: some View {
        switch value {
        case .object(let object) where !object.isEmpty:
            ForEach(object.keys.sorted(), id: \.self) { key in
                if let value = object[key] { JSONField(key: key, value: value) }
            }
        default:
            JSONField(key: "", value: value)
        }
    }
}

private struct JSONField: View {
    let key: String
    let value: JSON

    var body: some View {
        GridRow(alignment: .top) {
            Text(verbatim: key)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 96, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ReferenceLabel(serialized, compact: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var serialized: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "无法序列化" }
        return String(decoding: data, as: UTF8.self)
    }
}
