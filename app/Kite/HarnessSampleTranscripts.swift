import Foundation

/// 当前自研 harness 的静态界面样本。
/// 工具参数、输出和停止状态照 local-tools.ts、command.ts、transcript.ts；仅使用 read、patch、shell。
/// 不把旧版的附件、子 agent、MCP、后台任务和压缩记录当作 harness 已有能力。
enum HarnessSampleTranscripts {
    /// 两个可并发的 read 固定在执行阶段，供长短引用摘要的持续动画预览。
    static let ink = record("ink", running: true) { r in
        r.human("对比长短文件摘要里的风筝与蜡笔动画。")
        r.text("下面两次读取保持执行中，便于观察完整周期；这是样式样本，不执行工具。命令摘要可在「工具行 · 样式与动画」中对比。")
        r.batch { r in
            r.tool("read", ["path": "src/amount.ts", "offset": 1, "limit": 20], stage: "running")
            r.tool("read", ["path": "docs/工作流持续执行与跨端同步的显示检查说明.md", "offset": 1, "limit": 80], stage: "running")
        }
    }

    /// 固定在一帧，便于反复对比行样式和持续动画；不执行这些工具。
    static let toolStyles = record("tool-styles", running: true) { r in
        r.human("预览工具行的摘要、信息 chip、批次分割与状态动画。")
        r.text("展开下面的工具过程，可比较已完成、失败、执行、等待和参数生成中的样式。")
        r.batch { r in
            r.tool("read", ["path": "src/import/amount.ts", "offset": 1, "limit": 20],
                   "共 42 行\n1: export function parseAmount(raw: string) {\n2:   return Number(raw);\n3: }")
            r.tool("patch", ["operations": [["type": "update_file", "path": "src/import/amount.ts",
                                              "diff": "@@\n-  return Number(raw);\n+  const text = raw.replaceAll(',', '');\n+  return Number(text);"]]],
                   "已修改 src/import/amount.ts")
            r.tool("shell", ["description": "检查金额解析的修改", "command": ".kite/check"],
                   r.shell("检查通过。"), duration: 1.4)
        }
        r.batch { r in
            r.tool("read", ["path": "fixtures/missing.csv", "offset": 1, "limit": 20],
                   "Error: ENOENT: no such file or directory", status: "error")
        }
        r.batch { r in
            r.tool("shell", ["description": "运行导入器的构建与测试", "command": "bun run build && bun test"],
                   stage: "running", duration: 2)
            r.tool("read", ["path": "docs/import/amount-format.md", "offset": 1, "limit": 40], stage: "queued")
            r.tool("patch", ["operations": [["type": "update_file", "path": "docs/import/amount-for"]]],
                   stage: "generating", arguments: "{\"operations\":[{\"type\":\"update_file\",\"path\":\"docs/import/amount-for")
        }
    }

    /// 对照三种展开结构：普通单次调用、只有一批、包含多批；工具种类不决定批次。
    static let batches = record("batches") { r in
        r.human("核对构建说明和配置，补上检查命令。")
        r.text("先看说明，再确认当前有哪些修改。")
        r.tool("read", ["path": "README.md"], "共 2 行\n1: # 开发\n2: 使用 bun run build 构建。")
        r.tool("shell", ["description": "查看工作区改动", "command": "git status --short"], r.shell(" M README.md"))

        r.text("接着一起读取两份配置。")
        r.batch { r in
            r.tool("read", ["path": "package.json"], "共 3 行\n1: {\n2:   \"scripts\": { \"build\": \"bun build src/main.ts\" }\n3: }")
            r.tool("read", ["path": "tsconfig.json"], "共 3 行\n1: {\n2:   \"compilerOptions\": { \"strict\": true }\n3: }")
        }

        r.text("最后核对检查入口、补充说明，再运行检查。")
        r.batch { r in
            r.thinking("先确认检查命令与现有说明一致。")
            r.tool("read", ["path": ".kite/check"], "共 2 行\n1: #!/bin/sh\n2: exec bun scripts/check.ts")
            r.tool("shell", ["description": "核对构建说明的改动", "command": "git diff -- README.md"], r.shell("@@ -1,2 +1,2 @@\n # 开发\n-使用 npm run build 构建。\n+使用 bun run build 构建。"))
        }
        r.batch { r in
            r.thinking("保留已有的构建命令改动，只补检查说明。")
            r.tool("patch", ["operations": [[
                "type": "update_file", "path": "README.md",
                "diff": "@@\n 使用 bun run build 构建。\n+提交前运行 .kite/check。",
            ]]], "已修改 README.md")
        }
        r.batch { r in
            r.tool("shell", ["description": "运行项目检查", "command": ".kite/check"], r.shell("检查通过。"))
            r.tool("shell", ["description": "统计本次改动", "command": "git diff --stat"], r.shell(" README.md | 3 ++-\n 1 file changed, 2 insertions(+), 1 deletion(-)"))
        }
    }

    static let gallery = record("ledger") { r in
        r.human("导入账单时，带千分位的金额全变成了 0。帮我查一下，改好后跑检查。")
        r.thinking("先核对金额解析和样例数据，再用最小补丁修复。")
        r.text("我先看导入器和样例账单。")
        r.tool("read", ["path": "src/import/amount.ts"], """
            共 4 行
            1: export function parseAmount(raw: string): number {
            2:   return Number(raw.trim()) || 0;
            3: }
            4:
            """)
        r.tool("read", ["path": "fixtures/账单.csv", "offset": 2, "limit": 3], """
            共 18 行
            2: 2026-08-01,早餐,（18.00）
            3: 2026-08-03,工资,"12,800.00"
            4: 2026-08-05,还款,"（1,280.00）"
            """)
        r.tool("read", ["path": "docs/导入说明.md"], "共 2 行\n1: 金额支持千分位。\n2: 支出支持全角或半角括号。")
        r.tool("shell", ["description": "查找金额解析的实现与测试", "command": "rg -n 'parseAmount' src test"], r.shell("""
            src/import/amount.ts:1:export function parseAmount(raw: string): number {
            src/import/cmb.ts:16:    amount: parseAmount(row.amount),
            test/import/amount.test.ts:4:  expect(parseAmount('18.00')).toBe(18);
            """))
        r.text("原因找到了：`Number()` 不能解析千分位和全角括号，`|| 0` 又掩盖了错误。先去掉逗号，再把括号识别为支出；看不懂的金额直接报错。")
        r.tool("patch", ["operations": [
            ["type": "update_file", "path": "src/import/amount.ts", "diff": """
                @@
                 export function parseAmount(raw: string): number {
                -  return Number(raw.trim()) || 0;
                +  const text = raw.trim().replaceAll(',', '');
                +  const negative = /^[（(].*[）)]$/.test(text);
                +  const value = Number(negative ? text.slice(1, -1) : text);
                +  if (Number.isNaN(value)) throw new Error(`无法解析金额：${raw}`);
                +  return negative ? -value : value;
                 }
                """],
            ["type": "create_file", "path": "fixtures/千分位.csv", "diff": "+备注,金额\n+工资,\"12,800.00\"\n+还款,\"（1,280.00）\"\n+"],
            ["type": "delete_file", "path": "fixtures/旧账单.csv"],
        ]], """
            已修改 src/import/amount.ts
            已创建 fixtures/千分位.csv
            已删除 fixtures/旧账单.csv
            提示：fixtures/旧账单.csv 没有本次运行的读取或修改记录；依赖周边内容时请先 read。
            """)
        r.tool("shell", ["description": "检查金额解析的修改", "command": ".kite/check", "timeout_ms": 120000], r.shell("检查通过：类型检查和 lint 通过，受影响的测试 12 个，1.4 秒。"))
        r.text("""
            修好了，检查通过。

            | 输入 | 之前 | 现在 |
            |---|---|---|
            | `18.00` | 18 | 18 |
            | `12,800.00` | 0 | 12800 |
            | `（1,280.00）` | 0 | -1280 |

            修改了金额解析，新增一份样例，并删掉过时的账单文件。
            """)

        r.human("补一句说明：遇到其他人同时改文件时，保留他们的内容。")
        r.tool("patch", ["operations": [[
            "type": "update_file", "path": "docs/导入说明.md",
            "diff": "@@\n 金额支持千分位。\n+无法解析的金额会报错，不会记成 0。",
        ]]], """
            已修改 docs/导入说明.md
            提示：docs/导入说明.md 自上次读取或修改后已有其他变化；依赖周边内容时请重新 read。
            """)
        r.tool("read", ["path": "docs/导入说明.md"], """
            共 4 行
            1: 金额支持千分位。
            2: 无法解析的金额会报错，不会记成 0。
            3: 支出支持全角或半角括号。
            4: 导入前请先备份原始账单。
            """)
        r.text("说明补好了。文件里同时新增的备份提醒也保留了。")
        r.kite("工作区检查发现说明文件还有未保存的变更，请核对后再结束这一轮。")
        r.tool("shell", ["description": "核对说明文件的改动状态", "command": "git status --short"], r.shell(" M docs/导入说明.md"))
        r.text("说明文件的改动已核对，包含这轮新增的内容。")
    }

    static let running = record("kite", running: true, pending: [
        Message(id: "sample-pending-1", text: "时间显示成「3 分钟前」这种相对写法。", midTurn: true),
        Message(id: "sample-pending-2", text: "再看一下很长的标题会不会把右边的按钮挤掉。", midTurn: true),
    ]) { r in
        r.human("看看会话列表，确认长标题的显示和更新方式。")
        r.text("我先看列表和对应的数据模型。")
        r.tool("read", ["path": "app/Kite/Sidebar.swift", "offset": 1, "limit": 20], "共 178 行\n1: import SwiftUI\n2: \n3: struct WorkspaceRow: View {")
        r.human("只调整标题显示，数据模型有其他人正在改。", midTurn: true)
        r.text("收到，我会保留模型改动。正在读取标题和时间的展示代码。")
        // read 声明可并发，同一个工具组里可以同时出现多个未结束的读取。
        r.batch { r in
            r.tool("read", ["path": "app/Kite/ThreadPane.swift"])
            r.tool("read", ["path": "app/Kite/Theme.swift"])
        }
    }

    static let markdown = record("notes") { r in
        r.human("""
            帮我整理一下这段日志，解释原因和处理步骤。这里的 *星号* 和 `反引号` 是我原样粘贴的内容。

            ```text
            $ bun run build
            src/import/cmb.ts:18:9  error: Invalid amount
            input: （1,280.00）
            importer: cmb
            record: 108
            status: failed
            retry: false
            reason: Number() returned NaN
            file: fixtures/账单.csv
            line: 109
            column: amount
            encoding: UTF-8
            delimiter: comma
            quoted: true
            skipped: 0
            accepted: 107
            rejected: 1
            elapsed: 43ms
            exit code: 1
            ```

            错误前面的 107 条已经导入了，别重复写入。
            """)
        r.text("""
            ## 原因

            金额里的千分位和全角括号没有先处理，转换得到 `NaN`。这条记录应当是 **支出 1,280 元**。

            > 先保留原始文件，处理第 108 条及后续记录，避免重复导入前面已经完成的部分。

            ### 处理步骤

            1. 规范化金额格式。
               - 去掉千分位逗号。
               - 将括号识别成负号。
            2. 校验数值，保留出错的行号。
            3. 从断点继续，核对总金额。

            ```ts
            const text = raw.trim().replaceAll(',', '');
            const negative = /^[（(].*[）)]$/.test(text);
            const value = Number(negative ? text.slice(1, -1) : text);
            if (Number.isNaN(value)) throw new Error(`第 ${line} 行金额无效：${raw}`);
            return negative ? -value : value;
            ```

            | 写法 | 含义 | 处理 |
            |---|---|---|
            | `12,800.00` | 收入 | 12800 |
            | `（1,280.00）` | 支出 | -1280 |
            | `未知金额` | 无法确认 | 报错并保留原文 |

            ---

            ~~解析失败就填 0~~ 会掩盖问题。原始格式可以参考 [CSV 格式说明](https://www.rfc-editor.org/rfc/rfc4180)。
            """)
        r.human("好，先只整理说明。")
        r.human("代码下一轮再改。")
        r.thinking("这轮只需要文字说明，不调用文件工具。")
        r.text("好的，这轮只整理了说明，没有修改文件。")
        r.human("展示一条包含常见 Markdown 样式的消息，方便检查排版。")
        r.text(#"""
            # Markdown 渲染展示

            这是一条静态展示消息。普通段落可以包含中文、English、数字 12345，以及标点：逗号、句号和（括号）。较长的文字会自然换行，用来观察行高、段间距和文本选择。

            ## 文字样式

            普通文字、**粗体文字**、*斜体文字*、***粗斜体文字***、~~删除线文字~~，以及同一句话中的 **重点说明** 和 `inline code`。

            ### 三级标题与 `cornerRadius`

            这一段用于对比三级标题和普通正文之间的字号、字重与间距。

            ## 列表与引用

            - 第一项是短句。
            - 第二项包含 **强调** 和 `configuration`。
              - 这是一项嵌套列表。
              - 这是一项较长的嵌套列表，用来观察自动换行之后的文字是否与正文起点对齐。
            - 最后一项回到第一层。

            1. 阅读当前配置。
            2. 修改 `cornerRadius`，保留其他设置。
            3. 编译并打开预览。

            > 这是一段引用，包含 **强调文字** 和 `quotedCode`。
            > 较长的引用内容应当自然换行，并保留左侧装饰线和相同的文本缩进。

            ## 链接与文件引用

            网页链接：[Swift 官网](https://www.swift.org) 和 [Apple 开发者文档](https://developer.apple.com/documentation/)。

            本地文件引用：README.md:1-6；带标题的链接：[查看说明文件](README.md:1-6)。

            ## 独立代码块

            ```swift
            struct PreviewStyle {
                var cornerRadius: Double = 4
                var horizontalPadding: Double = 6

                func describe() -> String {
                    "圆角：\(cornerRadius)，水平边距：\(horizontalPadding)"
                }
            }
            let longMessage = "这是一行刻意写得很长的代码，用于检查代码块中的横向滚动，以及背景、内边距和相邻正文之间的关系。"
            ```

            代码块之后继续接普通正文，观察它们之间的间距。

            ## 表格

            | 样式 | 示例 | 说明 |
            |---|---|---|
            | 普通文字 | 中文与 English | 基础排版 |
            | 行内代码 | `cornerRadius = 4` | 等宽字体与背景 |
            | 强调文字 | **重点**、*补充* | 字重和倾斜 |
            | 链接 | [Swift](https://www.swift.org) | 图标、基线与点击 |

            同词对照：正文中的 `cornerRadius`、**`cornerRadius`** 和 *`cornerRadius`*。

            | 普通表头 | `cornerRadius` | **`cornerRadius`** |
            |---|---|---|
            | 普通代码 | `cornerRadius` | 与正文的同词对照 |
            | 强调代码 | **`cornerRadius`**、*`cornerRadius`* | 保留粗体与斜体 |
            | 文件引用 | `README.md:1-6` | 图标包含在代码背景中 |

            - 列表中的同词对照：`cornerRadius` 和 `README.md:1-6`。

            > 引用中的同词对照：`cornerRadius` 和 `README.md:1-6`。

            ---

            ## 行内代码细节

            代码中的文件引用：`README.md:1-6`；嵌在命令中的引用：`cat README.md:1-6`；网页引用：`https://www.swift.org`。

            短代码：`x`、`id`、`input`、`result`，前后紧接标点。

            连续代码：`let` `value` `=` `42`，观察相邻背景之间的空隙。

            中英混排：正文中的 `用户名称`、`message.text` 和 `count + 1` 应与周围文字对齐。

            带符号的代码：`{"enabled":true,"label":"预览"}`，以及包含反引号的 ``const text = `hello`;``。

            较长代码：`renderPreview(message, cornerRadius: 4, horizontalPadding: 6, verticalPadding: 2, preserveTextSelection: true)`，用于观察窄窗口中行内背景换行的表现。

            段落末尾也放一段代码，方便直接对照：`inlineCodeBackground`。
            """#)
        r.human(#"""
            用户消息中的代码块也使用相同样式：
            ```swift
            struct Greeting {
                let name = "Kite"
                // 保留缩进、中文和符号
                func text() -> String { "Hello, \(name)!" }
            }
            ```
            """#)
        r.text(#"""
            ## 独立代码块对照

            ```swift
            struct Greeting {
                let name = "Kite"
                // 保留缩进、中文和符号
                func text() -> String { "Hello, \(name)!" }
            }
            ```

            ```bash
            # 终端按钮首版仅展示
            printf '%s\n' 'Hello, Kite!'
            ```

            ```json
            {"name": "Kite", "enabled": true, "count": 3}
            ```

            ```
            未标注语言的代码保留纯文本。
                缩进仍然保留。
            ```
            """#)
        r.human("长消息展开预览（纯文本）\n\n" + (1...24).map {
            "第 \($0) 行：这是长用户消息，用于预览展开、收起与后续消息的位置。"
        }.joined(separator: "\n") + "\n\n纯文本末尾标记：展开后应能看到这里。")
        r.human("长消息展开预览（包含代码）\n\n```swift\n" + (1...24).map {
            "let sampleValue\($0) = \"第 \($0) 行代码\""
        }.joined(separator: "\n") + "\n```\n\n代码末尾标记：展开全文后应能看到第 24 行代码和这段正文。")
        r.text("上方两条消息用于预览用户气泡的折叠、展开和代码背景。")
    }

    static let errors = record("errors") { r in
        r.human("排查导入失败，先读文件，再运行检查。")
        r.tool("read", ["path": "fixtures/账单.png"], "Error: 文件不是可直接处理的文本", status: "error")
        r.tool("read", ["path": "../outside.csv"], "Error: 文件路径超出当前工作目录", status: "error")
        r.tool("read", ["path": "fixtures/large.csv"], "Error: 文件超过 2 MiB，请用 shell 按范围读取", status: "error")
        r.text("图片和超出目录的文件不能按文本读取。大文件改用命令按范围查看。")
        r.tool("shell", ["description": "导入账单数据", "command": "bun run import"], r.shell("Error: 无法解析第 108 条记录的金额", exit: 1), status: "error")
        r.tool("shell", ["description": "检查文档链接", "command": "bun run check-links", "timeout_ms": 1000], r.shell("正在检查第 8 个链接…", reason: "命令超时"), status: "error")
        r.text("检查没有全部通过：导入遇到无效金额，链接检查超时。")
        r.human("先把说明里的错误示例改掉。")
        r.tool("patch", ["operations": [["type": "create_file", "path": "README.md", "diff": "+导入说明\n+"]]],
               "Error: 新建目标已经存在：README.md", status: "error")
        r.tool("patch", ["operations": [["type": "update_file", "path": "README.md", "diff": "@@\n-旧的金额说明\n+新的金额说明"]]],
               "Error: README.md 的补丁无法应用，请 read 后重新生成：Failed to find expected lines: 旧的金额说明", status: "error")
        r.tool("patch", ["operations": [
            ["type": "create_file", "path": "docs/导入说明.md", "diff": "+导入遇到无效金额时会报错。\n+"],
            ["type": "create_file", "path": "readonly/说明.md", "diff": "+金额说明\n+"],
        ]], """
            已创建 docs/导入说明.md
            readonly/说明.md 写入失败：EACCES: permission denied。已列出的修改不会自动回滚，请检查实际文件后继续。
            """, status: "error")
        r.text("新增说明已保存，第二个文件写入失败。我会先核对已完成的修改。")
        r.apiError("订阅额度或请求速率受限（429），请稍后重试。")
        r.human("等额度恢复后继续。")
        r.apiError("订阅认证失败（401），请在当前凭据所属的认证目录重新登录后重试。")
    }

    static let interrupted = record("paused", pending: [Message(id: "sample-paused-input", text: "恢复后只检查 README。")]) { r in
        r.human("构建项目并核对 README。")
        r.tool("shell", ["description": "构建项目", "command": "bun run build"], r.shell("已完成 12 / 30 个模块", reason: "命令被打断，已经发生的改动未撤销"), status: "error")
        r.tool("read", ["path": "README.md"], "本次执行已停止，工具未启动。", status: "not_executed")
        r.interrupted()
    }

    static let recovery = record("recovery") { r in
        r.human("检查生成脚本是否正常退出。")
        r.tool("shell", ["description": "生成数据索引", "command": "bun scripts/generate.ts"], r.shell("已写入 dist/index.json", reason: "无法确认进程组已停止，需要人工检查。"), status: "unknown")
        r.apiError("工具 sample-call-1 的执行结果未知，需要确认恢复")
        // 没有落盘结果的调用在非运行状态下显示「没跑完」，不能补造成功结果。
        r.tool("read", ["path": "dist/index.json"])
    }

    static let output = record("output") { r in
        r.human("查看检查结果，只保留输出，不修改文件。")
        r.tool("shell", ["description": "确认文件是否有改动", "command": "git diff --quiet"], r.shell(""))
        let lines = (1...24).map { "通过：导入样例 \($0)，金额与预期一致" }.joined(separator: "\n")
        r.tool("shell", ["description": "运行项目检查", "command": ".kite/check"], r.shell(lines, omitted: 23104))
        r.tool("read", ["path": "fixtures/large.csv", "offset": 101, "limit": 20], "共 2400 行\n101: \"超长的账单备注……\n（输出已截断，请缩小读取范围）")
        r.text("命令已结束，日志只展示了尾部；文件读取结果也被截断，需要缩小范围后再读。")
    }

    static let streaming = record("streaming", running: true) { r in
        r.human("解释一下金额规范化应该怎么做。")
        r.thinking("先说明输入格式，再给出最小的转换示例。")
        // 停在一帧未完成的回复，覆盖未闭合 Markdown；不模拟持续的网络增量。
        r.text("## 金额规范化\n\n先清理千分位，再识别括号。这样 `1,280.00` 和 `（1,280.00）` 就能分别表示收入和支出。\n\n```ts\nconst text = raw.trim().replaceAll(',', '');\nconst negative =")
    }

    static let empty = Transcript(root: "/preview/harness/empty")

    private static func record(_ name: String, running: Bool = false, pending: [Message] = [],
                               _ build: (HarnessSampleRecorder) -> Void) -> Transcript {
        let recorder = HarnessSampleRecorder()
        build(recorder)
        return Transcript(root: "/preview/harness/" + name, records: recorder.records, running: running, pending: pending)
    }
}

/// 经 App 的显示协议解码层生成记录，success / error / not_executed / unknown 与真实历史走同一映射。
private final class HarnessSampleRecorder {
    private(set) var records: [Record] = []
    private var calls = 0
    private var batches = 0
    private var currentBatch: String?

    /// 同一次模型回复发起的一组调用；没有显式分组的 tool 各自模拟一轮模型回复。
    func batch(_ build: (HarnessSampleRecorder) -> Void) {
        let previous = currentBatch
        currentBatch = nextBatch()
        build(self)
        currentBatch = previous
    }

    private func nextBatch() -> String {
        batches += 1
        return "sample-batch-\(batches)"
    }

    func human(_ text: String, midTurn: Bool = false) {
        add(.init(type: "human", id: "sample-message-\(records.count)", text: text, midTurn: midTurn))
    }
    func text(_ text: String) { add(.init(type: "text", text: text)) }
    func thinking(_ text: String) { add(.init(type: "thinking", text: text)) }
    func kite(_ text: String) { add(.init(type: "kite", text: text)) }
    func apiError(_ text: String) { add(.init(type: "error", text: text)) }
    func interrupted() { add(.init(type: "interrupted")) }

    func tool(_ name: String, _ input: JSON, _ output: String? = nil, status: String = "success",
              stage: String? = nil, duration: Double? = nil, arguments: String? = nil) {
        calls += 1
        let id = "sample-call-\(calls)"
        let now = Date.now.timeIntervalSince1970 * 1000
        add(.init(type: "tool_use", id: id, name: name, input: input, batch: currentBatch ?? nextBatch(),
                  arguments: arguments, stage: stage, startedAt: duration.map { now - $0 * 1000 },
                  finishedAt: duration != nil && output != nil ? now : nil))
        if let output { add(.init(type: "tool_result", call: id, output: output, status: status)) }
    }

    func shell(_ output: String, exit code: Int = 0, reason: String? = nil, omitted: Int = 0) -> String {
        [reason ?? "退出码：\(code)", omitted > 0 ? "（前面省略 \(omitted) 个字符）" : "", output,
         "完整日志：/preview/harness/logs/sample-\(calls + 1).log"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func add(_ content: RemoteRecord.Content) {
        let remote = RemoteRecord(id: "sample-record-\(records.count)", parent: nil, block: content)
        if let record = remote.record { records.append(record) }
    }
}
