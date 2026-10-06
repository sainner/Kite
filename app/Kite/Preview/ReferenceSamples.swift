import Foundation

/// 两次修改使用不同 diffId，当前文件与两份历史都可实际打开。
enum ReferenceSamples {
    static var transcript: Transcript {
        let first = ToolUse(id: "reference-patch-1", name: "patch", input: .object([
            "operations": .array([.object(["type": .string("update_file"), "path": .string("README.md"),
                                           "diff": .string("@@\n-先阅读文件。\n+文件与预览共用一个窗口。")])])]), batch: "reference-batch")
        let second = ToolUse(id: "reference-patch-2", name: "patch", input: .object([
            "operations": .array([.object(["type": .string("update_file"), "path": .string("README.md"),
                                           "diff": .string("@@\n-文件与预览共用一个窗口。\n+文件、预览和 diff 共用一个窗口。\n+历史引用可以回看每次修改。")])])]), batch: "reference-batch")
        return Transcript(root: "/sample/project", records: [
            Record(block: .human(Message(text: "演示文件引用，以及同一个文件两次修改后的历史差异。"))),
            Record(block: .text("""
            可以打开当前的 README.md:1-6，或中文路径 docs/窗口.md:1-4。

            下面两次修改指向各自保存的 diff。展开工具过程后，点击摘要中的文件名即可查看。
            """)),
            Record(block: .toolUse(first)),
            Record(block: .toolResult(ToolResult(call: first.id, content: [.text("已修改 README.md\n引用：README.md:diff_sample1")], isError: false,
                                               diff: .init(id: "diff_sample1", paths: ["README.md"])))),
            Record(block: .toolUse(second)),
            Record(block: .toolResult(ToolResult(call: second.id, content: [.text("已修改 README.md\n引用：README.md:diff_sample2")], isError: false,
                                               diff: .init(id: "diff_sample2", paths: ["README.md"])))),
            Record(block: .text("""
            第一次修改：`README.md:diff_sample1:5`。
            第二次修改：README.md:diff_sample2:5-6。

            普通 Markdown 链接也可用：[说明文件](README.md:1-6)。网页图标使用网站自己的 favicon：[Swift](https://www.swift.org)、https://www.apple.com。

            下面代码块保留原文，不转换为引用：
            ```text
            README.md:diff_sample1:5
            ```
            """)),
        ])
    }
}
