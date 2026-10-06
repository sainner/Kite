import SwiftUI

/// 本地动态样本经过真实事件合并入口；不请求模型，也不执行命令。
extension WorkThread {
    func playStreamingPreview() async {
        let running = RemoteState(phase: "running", busy: true, status: "open", error: nil,
                                  capabilities: .init(send: false, interrupt: false, resume: false, cancel: false))
        func emit(_ record: RemoteRecord) throws {
            try apply(RemoteEvent(type: "thread.record", threadId: id, record: record))
        }
        func delta(_ record: String, _ field: String, _ text: String, limit: Int? = nil, input: JSON? = nil) throws {
            try apply(RemoteEvent(type: "thread.record.delta", threadId: id,
                                  delta: RemoteDelta(id: record, field: field, text: text, limit: limit, input: input)))
        }
        func chunks(_ text: String, into record: String, field: String = "text", input: JSON? = nil) async throws {
            let characters = Array(text)
            var offset = 0
            while offset < characters.count {
                try Task.checkCancellation()
                let end = min(offset + 4, characters.count)
                try delta(record, field, String(characters[offset..<end]), input: end == characters.count ? input : nil)
                offset = end
                try await Task.sleep(for: .milliseconds(65))
            }
        }
        do {
            try apply(RemoteEvent(type: "thread.history", version: 1, threadId: id,
                                  records: [RemoteRecord(id: "preview-human", parent: nil,
                                                        block: .init(type: "human", id: "preview-input", text: "检查金额解析，修好后说明结果。"))],
                                  pending: [], state: running))
            try await Task.sleep(for: .milliseconds(600))
            let thought = "先检查千分位与括号金额的处理，再核对测试。"
            try emit(RemoteRecord(id: "preview-thought", parent: nil, generation: "streaming", block: .init(type: "thinking", text: "")))
            try await chunks(thought, into: "preview-thought")
            try await Task.sleep(for: .seconds(1))
            try emit(RemoteRecord(id: "preview-thought", parent: nil, generation: "complete", block: .init(type: "thinking", text: thought)))

            let opening = "我先读取实现，再运行检查。\n\n1. 支持 **千分位**。\n2. 将括号识别为负数。\n"
            try emit(RemoteRecord(id: "preview-opening", parent: nil, generation: "streaming", block: .init(type: "text", text: "")))
            try await chunks(opening, into: "preview-opening")
            try emit(RemoteRecord(id: "preview-opening", parent: nil, generation: "complete", block: .init(type: "text", text: opening)))

            let readArguments = "{\"path\":\"src/amount.ts\",\"offset\":1,\"limit\":20}"
            let readInput: JSON = ["path": "src/amount.ts", "offset": 1, "limit": 20]
            var read = RemoteRecord(id: "call:preview-read", parent: nil, generation: "streaming",
                                    block: .init(type: "tool_use", id: "preview-read", name: "read", input: .null,
                                                 batch: "preview-batch", arguments: "", stage: "generating"))
            try emit(read)
            try await chunks(readArguments, into: read.id, field: "arguments", input: readInput)
            read.generation = "complete"
            read.block.arguments = readArguments
            read.block.input = readInput
            read.block.stage = "queued"
            try emit(read)
            try await Task.sleep(for: .milliseconds(500))
            read.block.stage = "running"
            read.block.startedAt = Date.now.timeIntervalSince1970 * 1000
            try emit(read)

            let commandArguments = "{\"description\":\"运行金额解析测试\",\"command\":\"bun test amount.test.ts\"}"
            let commandInput: JSON = ["description": "运行金额解析测试", "command": "bun test amount.test.ts"]
            var shell = RemoteRecord(id: "call:preview-shell", parent: nil, generation: "streaming",
                                     block: .init(type: "tool_use", id: "preview-shell", name: "shell", input: .null,
                                                  batch: "preview-batch", arguments: "", stage: "generating"))
            try emit(shell)
            try await chunks(commandArguments, into: shell.id, field: "arguments", input: commandInput)
            shell.generation = "complete"
            shell.block.arguments = commandArguments
            shell.block.input = commandInput
            shell.block.stage = "queued"
            try emit(shell)
            try await Task.sleep(for: .milliseconds(800))
            read.block.stage = "finished"
            read.block.finishedAt = Date.now.timeIntervalSince1970 * 1000
            try emit(read)
            try emit(RemoteRecord(id: "result:preview-read", parent: nil,
                                  block: .init(type: "tool_result", call: "preview-read", output: "1: export function parseAmount(text) {\n2:   return normalize(text);\n3: }", status: "success")))
            shell.block.stage = "running"
            shell.block.startedAt = Date.now.timeIntervalSince1970 * 1000
            try emit(shell)
            let output = ["bun test v1.x\n", "✓ 千分位金额\n", "✓ 中文括号负数\n", "✓ 空值与非法字符\n", "3 pass, 0 fail\n"]
            for line in output {
                try delta(shell.id, "output", line, limit: 20000)
                try await Task.sleep(for: .milliseconds(750))
            }
            shell.block.stage = "finished"
            shell.block.output = output.joined()
            shell.block.finishedAt = Date.now.timeIntervalSince1970 * 1000
            try emit(shell)
            try emit(RemoteRecord(id: "result:preview-shell", parent: nil,
                                  block: .init(type: "tool_result", call: "preview-shell", output: "退出码：0\n" + output.joined(), status: "success")))
            let answer = "## 检查结果\n\n金额解析的三个用例均已通过。\n\n```ts\nconst text = raw.replaceAll(',', '');\nconst negative = /^[（(].*[）)]$/.test(text);\n```\n\n| 输入 | 输出 |\n| --- | --- |\n| 1,280.00 | 1280 |\n| （18.00） | -18 |\n\n可继续阅读[项目说明](https://example.com)。"
            try emit(RemoteRecord(id: "preview-answer", parent: nil, generation: "streaming", block: .init(type: "text", text: "")))
            try await chunks(answer, into: "preview-answer")
            try emit(RemoteRecord(id: "preview-answer", parent: nil, generation: "complete", block: .init(type: "text", text: answer)))
            try apply(RemoteEvent(type: "thread.state", threadId: id,
                                  state: RemoteState(phase: "idle", busy: false, lastOutcome: .init(kind: "completed"),
                                                     status: "open", error: nil, capabilities: .init(send: false, interrupt: false, resume: false, cancel: false))))
        } catch is CancellationError {
            // 切换会话会取消演示；再次进入或按重播时从完整快照重新开始。
        } catch {
            self.error = "流式样本错误：\(error.localizedDescription)"
        }
    }
}
