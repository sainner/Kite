import Foundation

/// 工具行的名字、摘要、信息 chip，以及汇总折叠时归到哪一类计数。
/// 工具名只在 ToolUse.kind 里认一次，之后都按这个类型分派。
/// Kite 会话里有哪些工具见 kited/README.md「会话的上下文」；没列到的（项目自己配的 MCP、以后新加的）
/// 按通用的方式显示：名字、参数、结果。
enum ToolKind: Hashable {
    case read, edit, notebookEdit, write, command, check, webSearch, webFetch, agent, skill, tools
    case cronCreate, cronDelete, cronList, monitor, taskStop, listAgents, sendMessage
    /// 项目自己配的 MCP 服务里的工具，带服务名。
    case mcp(String)
    case other

    var icon: String {
        switch self {
        case .read: "doc.text"
        case .edit, .notebookEdit: "pencil"
        case .write: "doc.badge.plus"
        case .command: "terminal"
        case .check: "checkmark.seal"
        case .webSearch: "magnifyingglass"
        case .webFetch: "globe"
        case .agent: "person.2"
        case .skill: "sparkles"
        case .tools: "wrench.and.screwdriver"
        case .cronCreate, .cronDelete, .cronList: "clock"
        case .monitor: "waveform.path.ecg"
        case .taskStop: "stop.circle"
        case .listAgents, .sendMessage: "paperplane"
        case .mcp: "puzzlepiece.extension"
        case .other: "circle.dashed"
        }
    }

    /// 折成一行时和哪一类算在一起：改 notebook 也算改文件。
    var tally: ToolKind { self == .notebookEdit ? .edit : self }

    /// 折成一行时这一类怎么说。count 是次数，files 是涉及几个不同的文件。加载工具是 agent 自己的准备，不提。
    func summary(count: Int, files: Int) -> String? {
        switch self {
        case .read: "读取了 \(files) 个文件"
        case .edit, .notebookEdit: "修改了 \(files) 个文件"
        case .write: "写了 \(files) 个文件"
        case .command: "执行了 \(count) 条命令"
        case .check: "跑了 \(count) 次检查"
        case .webSearch: "搜了 \(count) 次网页"
        case .webFetch: "看了 \(count) 个网页"
        case .agent: "派了 \(count) 个子 agent"
        case .skill: "用了 \(count) 个 skill"
        case .tools: nil
        case .cronCreate: "设了 \(count) 个定时任务"
        case .cronDelete: "取消了 \(count) 个定时任务"
        case .cronList: "查看了定时任务"
        case .monitor: "开始盯 \(count) 个后台输出"
        case .taskStop: "停了 \(count) 个后台任务"
        case .listAgents: "查看了能联系的 agent"
        case .sendMessage: "给其他 agent 发了 \(count) 条消息"
        case .mcp(let server): "调了 \(count) 次 \(server)"
        case .other: "其他 \(count) 个操作"
        }
    }
}

extension ToolUse {
    var kind: ToolKind {
        switch name {
        case "Read", "read": .read
        case "Edit", "patch": .edit
        case "NotebookEdit": .notebookEdit
        case "Write": .write
        case "Bash", "shell": .command
        case "check": .check
        case "WebSearch": .webSearch
        case "WebFetch": .webFetch
        case "Agent": .agent
        case "Skill": .skill
        case "ToolSearch": .tools
        case "CronCreate": .cronCreate
        case "CronDelete": .cronDelete
        case "CronList": .cronList
        case "Monitor": .monitor
        case "TaskStop": .taskStop
        case "ListAgents": .listAgents
        case "SendMessage": .sendMessage
        default: mcp.map { .mcp($0.server) } ?? .other
        }
    }

    /// 读、改、写的是哪个文件。
    var file: String? {
        input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string ?? patchedFiles.first
    }

    var patchedFiles: [String] {
        guard name == "patch", case .array(let operations) = input["operations"] else { return [] }
        return operations.compactMap { $0["path"]?.string }
    }

    /// MCP 工具：mcp__<服务>__<工具>。
    var mcp: (server: String, tool: String)? {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        return (parts[1], parts[2...].joined(separator: "__"))
    }

    /// 工具名和本次调用摘要分开，名字不会随参数流式生成而变化。
    var displayName: String {
        switch kind {
        case .read: "读取"
        case .edit, .notebookEdit: "编辑"
        case .write: "写入"
        case .command: "执行"
        case .check: "检查"
        case .webSearch: "搜索"
        case .webFetch: "网页"
        case .agent: "子 agent"
        case .skill: "技能"
        case .tools: "工具"
        case .cronCreate: "创建定时任务"
        case .cronDelete: "删除定时任务"
        case .cronList: "定时任务"
        case .monitor: "监视"
        case .taskStop: "停止任务"
        case .listAgents: "agent 列表"
        case .sendMessage: "发消息"
        case .mcp, .other: mcp?.tool ?? name
        }
    }

    func rowSummary(relativeTo root: String, generating: Bool) -> String {
        let path = file.map { relativePath($0, to: root) } ?? ""
        switch kind {
        case .read:
            guard !path.isEmpty else { return "" }
            // 当前 read 的默认值来自文件工具；参数还在生成时，不提前补默认范围。
            guard !generating || (input["offset"] != nil && input["limit"] != nil) else { return path }
            if case .number(let offset) = input["offset"] ?? .number(1),
               case .number(let limit) = input["limit"] ?? .number(200),
               offset.isFinite, limit.isFinite, (offset + limit - 1).isFinite {
                let format = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0))
                return "\(path):\(offset.formatted(format))-\((offset + limit - 1).formatted(format))"
            }
            return path
        case .edit:
            let paths = patchedFiles.isEmpty ? (path.isEmpty ? [] : [path]) : patchedFiles.map { relativePath($0, to: root) }
            return paths.joined(separator: " · ")
        case .command:
            return input["description"]?.string ?? firstLine(input["command"]?.string)
        default:
            return input["description"]?.string ?? input["query"]?.string ?? input["url"]?.string
                ?? input["skill"]?.string ?? input["to"]?.string ?? (path.isEmpty ? mcp?.server ?? "" : path)
        }
    }

    /// 统计参数中明确给出的补丁行，不代表已经写入的改动或 shell 的工作区 diff。
    /// 删除整个文件没有旧正文，整批计数因此保持未知；参数预览也尚未包含 diff。
    var diffSummary: String? {
        guard name == "patch", case .array(let operations) = input["operations"], !operations.isEmpty else { return nil }
        var added = 0, removed = 0
        for operation in operations {
            guard let diff = operation["diff"]?.string else { return nil }
            let lines = splitLines(diff)
            if operation["type"]?.string == "create_file" {
                let content = lines.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }.joined(separator: "\n")
                added += splitLines(content).count
            } else {
                added += lines.count { $0.hasPrefix("+") }
                removed += lines.count { $0.hasPrefix("-") }
            }
        }
        return "+\(added) −\(removed)"
    }

    var title: String {
        let fileName = file.map { ($0 as NSString).lastPathComponent } ?? ""
        switch kind {
        case .read: return "读取 \(fileName)"
        case .edit: return patchedFiles.count > 1 ? "修改 \(patchedFiles.count) 个文件" : "修改 \(fileName)"
        case .write: return "写 \(fileName)"
        case .notebookEdit:
            switch input["edit_mode"]?.string {
            case "insert": return "在 \(fileName) 里加一格"
            case "delete": return "删掉 \(fileName) 里的一格"
            default: return "改 \(fileName) 里的一格"
            }
        case .command: return "执行 \(input["description"]?.string ?? firstLine(input["command"]?.string))"
        case .check: return input["all"]?.bool == true ? "跑全量检查" : "跑检查"
        case .webSearch: return "搜索「\(input["query"]?.string ?? "")」"
        case .webFetch: return "看 \(URL(string: input["url"]?.string ?? "")?.host() ?? "网页")"
        case .agent: return input["description"]?.string ?? "派子 agent"
        case .skill: return "用 skill \(input["skill"]?.string ?? "")"
        case .tools:
            // select: 后面是点名加载的工具
            let query = input["query"]?.string ?? ""
            guard query.hasPrefix("select:") else { return "找工具「\(query)」" }
            let names = query.dropFirst("select:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return "加载 " + names.joined(separator: "、")
        case .cronCreate: return "定时：\(firstLine(input["prompt"]?.string))"
        case .cronDelete: return "取消定时任务 \(input["id"]?.string ?? "")"
        case .cronList: return "查看定时任务"
        case .monitor: return "盯着\(input["description"]?.string ?? "后台输出")"
        case .taskStop: return "停掉后台任务 \(input["task_id"]?.string ?? input["shell_id"]?.string ?? "")"
        case .listAgents: return "查看能联系的 agent"
        case .sendMessage: return "给 \(input["to"]?.string ?? "agent") 发消息"
        case .mcp: return mcp.map { "\($0.server) · \($0.tool)" } ?? name
        case .other: return name
        }
    }

    /// 标题后面淡一点的补充。
    var note: String? {
        switch kind {
        case .read:
            if let pages = input["pages"]?.string { return "第 \(pages) 页" }
            guard let offset = input["offset"], case .number(let start) = offset else { return nil }
            guard let limit = input["limit"], case .number(let count) = limit else { return "从第 \(Int(start)) 行起" }
            return "第 \(Int(start))–\(Int(start + count) - 1) 行"
        case .edit:
            if name == "patch" { return nil }
            let (added, removed) = LineDiff(old: input["old_string"]?.string ?? "", new: input["new_string"]?.string ?? "").counts
            return "+\(added) −\(removed)" + (input["replace_all"]?.bool == true ? " 全部替换" : "")
        case .write: return "\(splitLines(input["content"]?.string ?? "").count) 行"
        case .command: return input["run_in_background"]?.bool == true ? "后台" : nil
        case .webFetch:
            // 同一个网站看了几页时靠它分开
            let path = URL(string: input["url"]?.string ?? "")?.path() ?? ""
            return path.isEmpty || path == "/" ? nil : path
        case .agent:
            let type = input["subagent_type"]?.string
            let background = input["run_in_background"]?.bool == true ? "后台" : nil
            let parts = [type, background].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .cronCreate:
            let cron = input["cron"]?.string ?? ""
            return input["recurring"]?.bool == false ? "\(cron) 一次" : cron
        default: return nil
        }
    }
}

extension Work {
    /// 折成一行时的说法。只有一次调用就说这次调用本身，多次按类计数，按出现的先后。
    var summary: String {
        let uses = calls.map(\.use)
        if uses.count == 1, let use = uses.first {
            return [use.title, use.note].compactMap { $0 }.joined(separator: "  ")
        }
        let parts = appeared.compactMap { kind in
            let same = uses.filter { $0.kind.tally == kind }
            return kind.summary(count: same.count, files: Set(same.flatMap { $0.patchedFiles.isEmpty ? [$0.file ?? $0.id] : $0.patchedFiles }).count)
        }
        return parts.isEmpty ? "加载了工具" : parts.joined(separator: "，")
    }

    /// 出现过的几类工具，按先后，算在一起的归成一类。
    private var appeared: [ToolKind] {
        var seen: [ToolKind] = []
        for call in calls where !seen.contains(call.use.kind.tally) { seen.append(call.use.kind.tally) }
        return seen
    }

    func count(_ state: Call.State) -> Int { calls.count { $0.state == state } }

    /// 正在跑的那次调用。
    var running: Call? { calls.first { [.generating, .queued, .running].contains($0.state) } }

}

func firstLine(_ text: String?) -> String {
    String(text?.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
}

/// 按行拆开；结尾的换行不算多出一个空行。
func splitLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return (text.hasSuffix("\n") ? String(text.dropLast()) : text).components(separatedBy: "\n")
}

/// 绝对路径在工作目录里就显示成相对路径。
func relativePath(_ path: String, to root: String) -> String {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}

/// 按行比较改动前后，用标准库的 CollectionDifference（最长公共子序列）。
struct LineDiff {
    enum Line {
        case same(String), removed(String), added(String)
    }

    let lines: [Line]

    init(old: String, new: String) {
        let before = splitLines(old)
        let after = splitLines(new)
        let difference = after.difference(from: before)
        var removed = Set<Int>(), added = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        // 两边各走一遍：删掉的按旧的位置出，加上的按新的位置出，其余两边相同
        var lines: [Line] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                lines.append(.removed(before[i])); i += 1
            } else if j < after.count, added.contains(j) {
                lines.append(.added(after[j])); j += 1
            } else {
                lines.append(.same(before[i])); i += 1; j += 1
            }
        }
        self.lines = lines
    }

    var counts: (added: Int, removed: Int) {
        lines.reduce((0, 0)) { total, line in
            switch line {
            case .added: (total.0 + 1, total.1)
            case .removed: (total.0, total.1 + 1)
            case .same: total
            }
        }
    }
}


extension Call {
    var stageLabel: String {
        switch state {
        case .generating: "生成中"
        case .queued: "等待中"
        case .running: "执行中"
        case .done: ""
        case .failed: "失败"
        case .interrupted: "已停止"
        case .unknown: "结果未知"
        case .unfinished: "未完成"
        }
    }
}


extension Call {
    /// 修改引用只取实际工具结果；生成中的参数不冒充已保存的历史差异。
    var fileReferences: [FileReference] {
        if let diff = result?.diff { return diff.paths.map { FileReference(path: $0, diffID: diff.id) } }
        guard use.kind == .read, let path = use.file else { return [] }
        let start: Int? = { if case .number(let value) = use.input["offset"] { return Int(exactly: value) }; return 1 }()
        let count: Int? = { if case .number(let value) = use.input["limit"] { return Int(exactly: value) }; return 200 }()
        guard let start, start > 0, let count, count > 0, start <= Int.max - count else { return [FileReference(path: path)] }
        return [FileReference(path: path, startLine: start, endLine: start + count - 1)]
    }
}
