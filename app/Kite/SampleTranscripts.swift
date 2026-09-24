import Foundation

/// 假的会话记录，接上 kited 之前用来做会话窗口。
/// gallery 把 Kite 会话里有的工具（kited/README.md「会话的上下文」）都调一遍，成功、出错、后台、子 agent 各种情况都有；
/// 其余几个是会话的几种状态：回合正在跑、不写代码的项目、刚开的空会话、压缩打断出错这些边角情况。
/// 工具的参数照 Claude Code 2.1.280 的参数表（SDK 的 sdk-tools.d.ts）写，结果照它回给模型的原文写。
enum SampleTranscripts {
    static let gallery = record(root: "/Users/sainner/.kite/worktrees/ledger/k7f3a2") { r in
        // 读：整个文件、一段、PDF 的几页、图片；搜；改出错后重读再改；全部替换；新建文件；测试失败再修好；检查
        r.human("导入招商银行的账单时金额全是 0，帮我查一下，修好后跑一遍检查。")
        r.thinking("金额全是 0，多半是解析失败后被兜底成了 0。先看招行导入器怎么解析金额，再对照一份真实导出的账单。")
        r.text("我先看看招行的导入代码和一份样例账单。")
        r.tool("Read", ["file_path": r.path("src/import/cmb.ts")], numbered(cmbSource))
        r.tool("Read", ["file_path": r.path("fixtures/cmb-2026-08.csv"), "offset": 1, "limit": 6], numbered("""
            交易日期,交易时间,收入/支出,金额,交易类型,交易备注
            2026-08-01,08:12:40,支出,（18.00）,快捷支付,早餐
            2026-08-01,12:30:05,支出,（56.50）,快捷支付,午饭
            2026-08-03,09:00:00,收入,"12,800.00",代发工资,八月工资
            2026-08-05,20:14:31,支出,"1,280.00",信用卡还款,
            2026-08-06,18:02:11,支出,（32.00）,快捷支付,地铁
            """))
        r.tool("Read", ["file_path": r.path("docs/招行导出说明.pdf"), "pages": "1-2"], """
            招商银行 个人账户交易明细导出说明

            1. 金额使用千分位分隔，保留两位小数。
            2. 支出金额以全角括号标注，例如（56.50）。
            3. 导出文件编码为 UTF-8，首行为表头。
            """)
        r.tool("Read", ["file_path": r.path("screenshots/导入结果.png")], image: (1280, 760))
        r.tool("Bash", ["command": #"rg -n "parseAmount" src test"#, "description": "找金额解析在哪些地方用到"], """
            src/import/cmb.ts:14:export function parseAmount(raw: string): number {
            src/import/cmb.ts:31:    amount: parseAmount(row.amount) || 0,
            test/import/cmb.test.ts:8:  expect(parseAmount('18.00')).toBe(18);
            """)
        r.text("""
            找到原因了：招行导出的金额带千分位逗号（`1,280.00`），支出还写在全角括号里（`（56.50）`）。\
            `parseAmount` 直接 `Number()`，得到 `NaN`，又被后面的 `|| 0` 吞成了 0。

            我改一下解析，顺便补一份带千分位的样例账单。
            """)
        r.tool("Edit", ["file_path": r.path("src/import/cmb.ts"), "old_string": "  return Number(raw) || 0", "new_string": "  return Number(raw)"],
               "<tool_use_error>String to replace not found in file.\nString:   return Number(raw) || 0</tool_use_error>", error: true)
        r.tool("Read", ["file_path": r.path("src/import/cmb.ts"), "offset": 12, "limit": 6], numbered("""

            export function parseAmount(raw: string): number {
              const value = Number(raw.trim());
              return value;
            }

            """, from: 12))
        r.tool("Edit", [
            "file_path": r.path("src/import/cmb.ts"),
            "old_string": """
                export function parseAmount(raw: string): number {
                  const value = Number(raw.trim());
                  return value;
                }
                """,
            "new_string": """
                export function parseAmount(raw: string, line: number): number {
                  const text = raw.trim().replaceAll(',', '');
                  // 支出写在全角括号里
                  const negative = text.startsWith('（') && text.endsWith('）');
                  const value = Number(negative ? text.slice(1, -1) : text);
                  if (Number.isNaN(value)) throw new ImportError(`第 ${line} 行的金额看不懂：${raw}`);
                  return negative ? -value : value;
                }
                """,
        ], "The file \(r.root)/src/import/cmb.ts has been updated successfully.")
        r.tool("Edit", [
            "file_path": r.path("src/import/cmb.ts"),
            "old_string": "parseAmount(row.amount) || 0",
            "new_string": "parseAmount(row.amount, index + 2)",
            "replace_all": true,
        ], "The file \(r.root)/src/import/cmb.ts has been updated successfully. All occurrences were replaced.")
        r.tool("Write", ["file_path": r.path("test/fixtures/cmb-thousands.csv"), "content": """
            交易日期,交易时间,收入/支出,金额,交易类型,交易备注
            2026-08-03,09:00:00,收入,"12,800.00",代发工资,八月工资
            2026-08-05,20:14:31,支出,"（1,280.00）",信用卡还款,
            2026-08-06,18:02:11,支出,（32.00）,快捷支付,地铁

            """], "File created successfully at: \(r.root)/test/fixtures/cmb-thousands.csv")
        r.tool("Bash", ["command": "bun test test/import", "description": "跑导入相关的测试"], """
            Exit code 1
            test/import/cmb.test.ts:
            ✓ 普通金额 [0.41ms]
            ✗ 千分位 [0.88ms]
              error: expect(received).toBe(expected)
              Expected: -1280
              Received: 1280
                at test/import/cmb.test.ts:14:52

             3 pass
             1 fail
            Ran 4 tests across 1 file. [38.00ms]
            """, error: true)
        r.tool("Edit", [
            "file_path": r.path("src/import/cmb.ts"),
            "old_string": "  const negative = text.startsWith('（') && text.endsWith('）');",
            "new_string": "  const negative = /^[（(].*[）)]$/.test(text);",
        ], "The file \(r.root)/src/import/cmb.ts has been updated successfully.")
        r.tool("Bash", ["command": "bun test test/import", "description": "跑导入相关的测试"], """
            test/import/cmb.test.ts:
            ✓ 普通金额 [0.39ms]
            ✓ 千分位 [0.52ms]
            ✓ 全角括号是支出 [0.21ms]
            ✓ 看不懂的金额报错 [0.33ms]

             4 pass
             0 fail
            Ran 4 tests across 1 file. [35.00ms]
            """)
        r.tool("check", [:], """
            类型检查和 lint 通过
            受影响的测试：3 个文件，21 个通过
            用时 2.4 秒
            """)
        r.text("""
            修好了，检查通过。

            | 账单里的写法 | 之前 | 现在 |
            |---|---|---|
            | `18.00` | 18 | 18 |
            | `1,280.00` | 0 | 1280 |
            | `（56.50）` | 0 | -56.5 |

            改了三处：

            1. `parseAmount` 先去掉千分位逗号，括号（全角半角都算）当作支出。
            2. 解析失败时直接报错，指出是哪一行，**不再悄悄记成 0**：
               ```ts
               throw new ImportError(`第 ${line} 行的金额看不懂：${raw}`);
               ```
            3. 补了一份带千分位的样例账单 `test/fixtures/cmb-thousands.csv`。
            """)

        // 延迟加载的工具：先经 ToolSearch 点名加载，再搜网页、看网页（一次 404）
        r.human("我们自己写的金额解析能不能换成 csv-parse 自带的转换？查一下，再把支持的银行整理成一篇文档。")
        r.tool("ToolSearch", ["query": "select:WebSearch,WebFetch", "max_results": 2], "WebSearch\nWebFetch")
        r.tool("WebSearch", ["query": "csv-parse cast 选项 自定义转换", "allowed_domains": ["csv.js.org", "github.com"]], """
            Web search results for query: "csv-parse cast 选项 自定义转换"

            Links: [{"title":"Option cast | CSV","url":"https://csv.js.org/parse/options/cast/"},{"title":"Option columns | CSV","url":"https://csv.js.org/parse/options/columns/"},{"title":"adaltas/node-csv","url":"https://github.com/adaltas/node-csv"}]

            csv-parse 的 `cast` 选项可以是布尔值，也可以是一个函数，按字段自己转换值。
            """)
        r.tool("WebFetch", ["url": "https://csv.js.org/parse/options/cast/", "prompt": "cast 选项怎么用？能不能按列自定义转换？"], """
            `cast` 可以传一个函数 `(value, context) => any`，`context.column` 是当前列（开了 `columns` 时是列名），\
            返回值就是这一格的结果。所以可以只对「金额」这一列做自定义转换，其余列原样返回。
            """)
        r.tool("WebFetch", ["url": "https://csv.js.org/parse/options/cast_amount/", "prompt": "有没有现成的金额转换？"],
               "Request failed with status code 404", error: true)
        r.tool("Write", ["file_path": r.path("docs/支持的银行.md"), "content": """
            # 支持的银行

            | 银行 | 导入器 | 金额写法 |
            |---|---|---|
            | 招商银行 | `src/import/cmb.ts` | 千分位，支出在全角括号里 |
            | 工商银行 | `src/import/icbc.ts` | 千分位，支出带负号 |
            | 中国银行 | `src/import/boc.ts` | 无千分位，收支分两列 |

            新加一家银行：照 `cmb.ts` 写一个导入器，在 `test/fixtures/` 放一份脱敏的真实账单。

            """], "File created successfully at: \(r.root)/docs/支持的银行.md")
        r.text("""
            查了一下：csv-parse 的 `cast` 可以只对「金额」这一列做自定义转换，但千分位和全角括号还是得自己处理，\
            省不了几行，还要多一个依赖。建议先不换。

            文档写在 `docs/支持的银行.md`，列了三家银行各自的金额写法。
            """)

        // 子 agent：一个前台的（它做的事挂在调用下面），一个后台的；notebook 的改、加、删
        r.human("派子 agent 看看其他银行的导入器有没有同样的问题。你这边把 notebook 里的月度汇总更新一下。")
        r.tool("Agent", [
            "description": "排查其他银行的金额解析",
            "prompt": "看 src/import/ 下除了 cmb.ts 以外的导入器，金额是怎么解析的，有没有遇到千分位或括号就变成 NaN、再被兜底成 0 的问题。只看不改，列出有问题的文件和行号。",
            "subagent_type": "Explore",
        ], """
            工商银行（`icbc.ts`）有同样的问题：第 22 行直接 `Number(row.amount) || 0`，千分位会变成 0。

            中国银行（`boc.ts`）没问题：收支分两列，金额没有千分位。
            """) { sub in
            sub.tool("Bash", ["command": #"rg -n "Number\(" src/import"#], """
                src/import/cmb.ts:17:  const value = Number(negative ? text.slice(1, -1) : text);
                src/import/icbc.ts:22:    amount: Number(row.amount) || 0,
                src/import/boc.ts:19:  const income = Number(row.income);
                """)
            sub.tool("Read", ["file_path": sub.path("src/import/icbc.ts"), "offset": 15, "limit": 12], numbered("""
                export function importIcbc(rows: Row[]): Entry[] {
                  return rows.map((row) => ({
                    date: row.date,
                    // 工行导出的金额带千分位
                    amount: Number(row.amount) || 0,
                    note: row.note,
                  }));
                }
                """, from: 15))
            sub.tool("Read", ["file_path": sub.path("src/import/boc.ts")], numbered("""
                export function importBoc(rows: Row[]): Entry[] {
                  return rows.map((row) => {
                    const income = Number(row.income);
                    const expense = Number(row.expense);
                    return { date: row.date, amount: income - expense, note: row.note };
                  });
                }
                """))
            sub.text("工商银行的有问题，中国银行的没问题。")
        }
        r.tool("Agent", [
            "description": "核对工商银行的导入器",
            "prompt": "拿 fixtures/icbc-2026-08.csv 逐行核对 importIcbc 的结果，找出所有金额不对的行，说明原因。",
            "subagent_type": "general-purpose",
            "run_in_background": true,
            "name": "icbc-checker",
        ], """
            Async agent launched successfully.
            agentId: a3f9c1 (internal ID)
            The agent is working in the background. You will be notified automatically when it completes.
            """)
        r.tool("NotebookEdit", [
            "notebook_path": r.path("analysis/月度汇总.ipynb"),
            "cell_id": "c4",
            "new_source": "monthly = df.groupby(df.date.dt.to_period('M')).amount.sum()\nmonthly.plot(kind='bar', title='每月收支')",
            "cell_type": "code",
        ], "Updated cell c4 with monthly = df.groupby(df.date.dt.to_period('M')).amount.sum()")
        r.tool("NotebookEdit", [
            "notebook_path": r.path("analysis/月度汇总.ipynb"),
            "cell_id": "c4",
            "new_source": "## 说明\n8 月之前的招行账单金额有误，重新导入后再看这张图。",
            "cell_type": "markdown",
            "edit_mode": "insert",
        ], "Inserted cell c5 with ## 说明")
        r.tool("NotebookEdit", [
            "notebook_path": r.path("analysis/月度汇总.ipynb"),
            "cell_id": "c7",
            "new_source": "",
            "edit_mode": "delete",
        ], "Deleted cell c7")
        r.text("""
            查完了：工商银行的导入器也有同样的问题，中国银行的没问题。后台还有一个 agent 在逐行核对工行的账单，完成后我接着处理。

            notebook 里的月度汇总改成按月看收支，加了一段说明，删掉了已经过时的那张饼图。
            """)
        r.notification("后台 agent「核对工商银行的导入器」完成了：共 214 行，37 行金额不对，都是千分位；另有 3 行支出的符号反了。")
        r.text("工行有两处问题：千分位，还有支出的符号。我照招行的改法修。")
        r.tool("Edit", [
            "file_path": r.path("src/import/icbc.ts"),
            "old_string": "    amount: Number(row.amount) || 0,",
            "new_string": "    amount: parseAmount(row.amount, index + 2),",
        ], "The file \(r.root)/src/import/icbc.ts has been updated successfully.")
        r.tool("check", ["all": true], """
            Exit code 1
            类型检查通过
            全量测试：58 个通过，1 个失败

            ✗ import/icbc > 支出是负数
              期望 -56.5，实际 56.5

            完整日志：/Users/sainner/.kite/sessions/k7f3a2/checks/2026-09-24T10-42-07/
            """, error: true)
        r.tool("Edit", [
            "file_path": r.path("src/import/icbc.ts"),
            "old_string": "    amount: parseAmount(row.amount, index + 2),",
            "new_string": "    amount: (row.direction === '支出' ? -1 : 1) * Math.abs(parseAmount(row.amount, index + 2)),",
        ], "The file \(r.root)/src/import/icbc.ts has been updated successfully.")
        r.tool("check", ["all": true], """
            类型检查通过
            全量测试：59 个通过
            用时 11.8 秒
            """)
        r.text("工行也修好了，全量检查通过。")

        // 定时任务、后台命令、盯输出
        r.human("每天早上 9 点帮我跑一次全量检查，有问题就告诉我；今天下午六点半提醒我看导入结果。另外把开发服务器开起来，盯着日志里的报错。")
        r.tool("ToolSearch", ["query": "cron schedule monitor", "max_results": 4], "CronCreate\nCronList\nCronDelete\nMonitor")
        r.tool("CronCreate", ["cron": "0 9 * * *", "prompt": "跑一次全量检查，没通过就总结失败原因", "recurring": true],
               "Scheduled recurring job 7c2e91 (Every day at 9:00 AM). Session-only (not written to disk, dies when Claude exits). Auto-expires after 7 days.")
        r.tool("CronCreate", ["cron": "30 18 24 9 *", "prompt": "提醒我看一下今天的导入结果", "recurring": false],
               "Scheduled one-shot task 4b8d02 (Sep 24 at 6:30 PM). Session-only (not written to disk, dies when Claude exits).")
        r.tool("CronList", [:], """
            7c2e91 — Every day at 9:00 AM (recurring) [session-only]: 跑一次全量检查，没通过就总结失败原因
            4b8d02 — Sep 24 at 6:30 PM (one-shot) [session-only]: 提醒我看一下今天的导入结果
            """)
        r.tool("Bash", ["command": "bun run dev", "description": "在后台启动开发服务器", "run_in_background": true],
               "Command running in background with ID: b2k9x7. Output is being written to: /private/tmp/claude-501/tasks/b2k9x7.output")
        r.tool("Monitor", [
            "description": "开发服务器日志里的报错",
            "command": "tail -f logs/dev.log | grep --line-buffered ERROR",
            "timeout_ms": 1_800_000,
        ], "Monitor started (task m5p3q8, timeout 1800000ms). You will be notified on each event.")
        r.text("""
            都设好了：

            - 每天 9:00 跑全量检查（这个会话开着时有效，7 天后自动失效）
            - 今天 18:30 提醒你看导入结果
            - 开发服务器在后台跑着，日志里一出现 ERROR 我就会收到
            """)

        // 停后台任务、取消定时任务、联系后台 agent
        r.human("定时任务都取消吧，开发服务器也停掉。刚才那个核对工行的 agent 还在的话，让它把结论写进 docs。")
        r.tool("CronDelete", ["id": "7c2e91"], "Cancelled job 7c2e91.")
        r.tool("CronDelete", ["id": "4b8d02"], "Cancelled job 4b8d02.")
        r.tool("TaskStop", ["task_id": "m5p3q8"], #"{"message":"Successfully stopped task: m5p3q8 (tail -f logs/dev.log | grep --line-buffered ERROR)","task_id":"m5p3q8","task_type":"monitor"}"#)
        r.tool("TaskStop", ["task_id": "b2k9x7"], #"{"message":"Successfully stopped task: b2k9x7 (bun run dev)","task_id":"b2k9x7","task_type":"local_bash"}"#)
        r.tool("ListAgents", [:], "icbc-checker — 核对工商银行的导入器（已完成，可以接着发消息）")
        r.tool("SendMessage", ["to": "icbc-checker", "message": "把你的结论整理成 docs/工行导入问题.md：原因、改法、还没覆盖的情况。"],
               "Message delivered to icbc-checker.")
        r.text("两个定时任务都取消了，开发服务器和盯日志的都停了。已经让 icbc-checker 写文档，它写完会通知我。")

        // skill、项目自己配的 MCP 工具
        r.human("用 simplify 过一遍今天的改动，然后在 GitHub 上开个 issue，记一下还有哪些银行没覆盖。")
        r.tool("Skill", ["skill": "simplify"], "Launching skill: simplify")
        r.tool("Bash", ["command": "git diff --stat main...HEAD", "description": "看今天改了哪些文件"], """
             analysis/月度汇总.ipynb          | 14 ++++----
             docs/支持的银行.md               | 12 +++++++
             src/import/cmb.ts                | 11 ++++--
             src/import/icbc.ts               |  4 +-
             test/fixtures/cmb-thousands.csv  |  4 +++
             test/import/cmb.test.ts          | 18 ++++++++--
             6 files changed, 52 insertions(+), 11 deletions(-)
            """)
        r.tool("Write", ["file_path": r.path("src/import/amount.ts"), "content": """
            import { ImportError } from './errors.ts';

            /** 账单里的金额：去掉千分位，括号（全角半角都算）是支出。看不懂就报错，不记成 0。 */
            export function parseAmount(raw: string, line: number): number {
              const text = raw.trim().replaceAll(',', '');
              const negative = /^[（(].*[）)]$/.test(text);
              const value = Number(negative ? text.slice(1, -1) : text);
              if (Number.isNaN(value)) throw new ImportError(`第 ${line} 行的金额看不懂：${raw}`);
              return negative ? -value : value;
            }

            """], "File created successfully at: \(r.root)/src/import/amount.ts")
        r.tool("Edit", [
            "file_path": r.path("src/import/cmb.ts"),
            "old_string": "import { ImportError } from './errors.ts';",
            "new_string": "import { parseAmount } from './amount.ts';",
        ], "The file \(r.root)/src/import/cmb.ts has been updated successfully.")
        r.tool("check", [:], "类型检查和 lint 通过\n受影响的测试：4 个文件，25 个通过\n用时 2.9 秒")
        r.tool("mcp__github__create_issue", [
            "owner": "sainner",
            "repo": "ledger",
            "title": "导入器：还没覆盖的银行",
            "body": "已支持招行、工行、中行。还没有：建设银行、农业银行、交通银行。新加的照 docs/支持的银行.md 的步骤来。",
            "labels": ["导入"],
        ], #"{"number":42,"html_url":"https://github.com/sainner/ledger/issues/42","state":"open"}"#)
        r.text("""
            simplify 把两家银行重复的金额解析抽成了 `src/import/amount.ts`，检查通过。

            issue 开好了：[#42 导入器：还没覆盖的银行](https://github.com/sainner/ledger/issues/42)。
            """)
    }

    /// 回合正在跑：检查跑到一半，人又插了一句话。
    static let running = record(root: "/Users/sainner/.kite/worktrees/kite/p2d8e1", running: true) { r in
        r.human("侧边栏的会话行现在是占位色块，改成显示会话标题和最后一条消息的时间。")
        r.thinking("会话模型里还没有标题和时间，要先加字段，再改 SessionRow。")
        r.text("我先看一下侧边栏和会话模型。")
        r.tool("Read", ["file_path": r.path("app/Kite/Sidebar.swift"), "offset": 1, "limit": 24], numbered("""
            import SwiftUI

            /// 侧边栏里的一行，一个会话。
            struct SessionRow: View {
                let session: Session
                let current: Bool
            """))
        r.tool("Read", ["file_path": r.path("app/Kite/AppModel.swift")], numbered("""
            @Observable
            final class Session: Identifiable {
                let id: Int
                let tint: Color
            }
            """))
        r.text("会话模型里还没有标题，我先加上标题和最后活动的时间，再改侧边栏那一行。")
        r.tool("Edit", [
            "file_path": r.path("app/Kite/AppModel.swift"),
            "old_string": "    let tint: Color\n",
            "new_string": "    let tint: Color\n    var title: String\n    var lastActive: Date\n",
        ], "The file \(r.root)/app/Kite/AppModel.swift has been updated successfully.")
        r.tool("Edit", [
            "file_path": r.path("app/Kite/Sidebar.swift"),
            "old_string": "            RoundedRectangle(cornerRadius: 4).fill(Theme.placeholder).frame(height: 10)",
            "new_string": "            Text(session.title).lineLimit(1)\n            Spacer(minLength: 4)\n            Text(session.lastActive, style: .time).foregroundStyle(.secondary)",
        ], "The file \(r.root)/app/Kite/Sidebar.swift has been updated successfully.")
        r.tool("check", [:], nil)
        r.human("时间用「3 分钟前」这种相对的写法。", midTurn: true)
    }

    /// 不写代码的项目：一篇 LaTeX 论文。
    static let thesis = record(root: "/Users/sainner/.kite/worktrees/thesis/t9c4b0") { r in
        r.human("把第二章的图注统一成「图 2-1 标题」这种格式，编号按出现顺序。")
        r.tool("Bash", ["command": #"grep -n '\\caption' chapters/ch2.tex"#, "description": "找第二章所有的图注"], #"""
            42:  \caption{实验装置示意图}
            67:  \caption{Fig. 2 样品的 XRD 图谱}
            95:  \caption{图2.3：不同温度下的电导率}
            121:  \caption{（d）循环稳定性测试}
            """#)
        r.tool("Read", ["file_path": r.path("chapters/ch2.tex"), "offset": 38, "limit": 8], numbered(#"""
            \begin{figure}[htbp]
              \centering
              \includegraphics[width=0.8\textwidth]{figures/setup.pdf}
              \caption{实验装置示意图}
              \label{fig:setup}
            \end{figure}
            """#, from: 38))
        r.text("""
            第二章一共 4 张图，写法各不一样：有的没编号，有的是英文的 Fig.，有的自己手写了编号。

            其实编号该交给 LaTeX：导言区设好「图 2-1」的格式，图注里只写标题。我这样改。
            """)
        for (old, new) in [
            (#"\caption{Fig. 2 样品的 XRD 图谱}"#, #"\caption{样品的 XRD 图谱}"#),
            (#"\caption{图2.3：不同温度下的电导率}"#, #"\caption{不同温度下的电导率}"#),
            (#"\caption{（d）循环稳定性测试}"#, #"\caption{循环稳定性测试}"#),
        ] {
            r.tool("Edit", ["file_path": r.path("chapters/ch2.tex"), "old_string": .string(old), "new_string": .string(new)],
                   "The file \(r.root)/chapters/ch2.tex has been updated successfully.")
        }
        r.tool("Edit", [
            "file_path": r.path("main.tex"),
            "old_string": #"\usepackage{graphicx}"#,
            "new_string": .string(#"\usepackage{graphicx}"# + "\n" + #"\renewcommand{\thefigure}{\thechapter-\arabic{figure}}"#),
        ], "The file \(r.root)/main.tex has been updated successfully.")
        r.tool("Bash", ["command": "latexmk -xelatex -interaction=nonstopmode main.tex", "description": "重新编译论文"], """
            Latexmk: applying rule 'xelatex'...
            Output written on main.xdv (86 pages).
            Latexmk: All targets (main.pdf) are up-to-date
            """)
        r.text(#"""
            改好了，重新编译通过。第二章的图注现在是：

            - 图 2-1 实验装置示意图
            - 图 2-2 样品的 XRD 图谱
            - 图 2-3 不同温度下的电导率
            - 图 2-4 循环稳定性测试

            正文里引用这几张图用的是 `\ref`，编号会自己跟着变，不用改。
            """#)
    }

    /// 刚开的会话，还没说话。
    static let empty = Transcript(root: "/Users/sainner/.kite/worktrees/notes/n1b7c3")

    /// 边角情况：压缩、调用模型出错、打断、Kite 发来的合并冲突说明、进程没了的调用。
    static let edgeCases = record(root: "/Users/sainner/.kite/worktrees/blog/e5a1f6") { r in
        r.compacted("""
            用户在整理个人博客的仓库。已经做完：把文章从 `posts/` 挪进 `content/`，修好了 12 处坏链接，\
            RSS 改成全文输出。还没做：README 翻译成英文。
            """)
        r.human("接着把 README 翻译成英文吧。")
        r.tool("Read", ["file_path": r.path("README.md")], numbered("# 我的博客\n\n用 Astro 搭的个人博客。\n\n## 写文章\n\n在 content/ 下新建 Markdown 文件。"))
        r.apiError("调用模型出错：服务过载（529），自动重试 3 次都没成功。")
        r.human("继续")
        r.text("好，我接着翻译。先跑一遍站点构建，确认现有的链接没坏。")
        r.tool("Bash", ["command": "bun run build && bun run check-links", "description": "构建站点并检查链接"],
               "[Request interrupted by user for tool use]", error: true, interrupted: true)
        r.interrupted()
        r.human("先别跑构建了，太慢。只翻译 README 前两节就行。")
        r.tool("Edit", [
            "file_path": r.path("README.md"),
            "old_string": "# 我的博客\n\n用 Astro 搭的个人博客。\n\n## 写文章\n\n在 content/ 下新建 Markdown 文件。",
            "new_string": "# My Blog\n\nA personal blog built with Astro.\n\n## Writing\n\nCreate a Markdown file under content/.",
        ], "The file \(r.root)/README.md has been updated successfully.")
        r.text("前两节翻译好了。")
        r.kite("""
            采纳时合并冲突：主线上也改了 README.md。冲突留在这个会话的工作树里，解决后这一轮结束时 Kite 会自动重试采纳。

            冲突的文件：README.md
            """)
        r.tool("Bash", ["command": "git diff --name-only --diff-filter=U", "description": "列出有冲突的文件"], "README.md")
        r.tool("Read", ["file_path": r.path("README.md"), "offset": 1, "limit": 14], numbered("""
            <<<<<<< HEAD
            # My Blog

            A personal blog built with Astro.
            =======
            # 我的博客

            用 Astro 搭的个人博客。

            ## 部署

            推到 main 后自动部署到 Cloudflare Pages。
            >>>>>>> main
            """))
        r.tool("Edit", [
            "file_path": r.path("README.md"),
            "old_string": "<<<<<<< HEAD\n# My Blog\n\nA personal blog built with Astro.\n=======\n# 我的博客\n\n用 Astro 搭的个人博客。\n\n## 部署\n\n推到 main 后自动部署到 Cloudflare Pages。\n>>>>>>> main",
            "new_string": "# My Blog\n\nA personal blog built with Astro.\n\n## Deployment\n\nPushing to main deploys to Cloudflare Pages automatically.",
        ], "The file \(r.root)/README.md has been updated successfully.")
        r.tool("Bash", ["command": "git add README.md && git commit --no-edit", "description": "提交解决好的冲突"],
               "[kite/e5a1f6 3d9a0b2] Merge branch 'main' into kite/e5a1f6")
        r.text("冲突解决了：保留了主线新加的「部署」一节，也翻译成了英文。")
        r.human("再把 RSS 的生成脚本跑一下。")
        r.tool("Bash", ["command": "bun scripts/rss.ts", "description": "生成 RSS"], nil)
    }

    private static func record(root: String, running: Bool = false, _ build: (Recorder) -> Void) -> Transcript {
        let recorder = Recorder(root: root)
        build(recorder)
        return Transcript(root: root, records: recorder.records, running: running)
    }

    private static let cmbSource = """
        import { ImportError } from './errors.ts';
        import type { Entry, Row } from './types.ts';

        /** 招商银行导出的个人账户交易明细。 */
        export function importCmb(rows: Row[]): Entry[] {
          return rows.map((row, index) => ({
            date: row.交易日期,
            amount: parseAmount(row.amount) || 0,
            note: row.交易备注,
          }));
        }

        export function parseAmount(raw: string): number {
          const value = Number(raw.trim());
          return value;
        }
        """
}

/// 按顺序记下假记录，工具调用的 id 自动编号。
private final class Recorder {
    let root: String
    private(set) var records: [Record] = []
    /// 正在记的子 agent 是哪次调用发起的。
    private var parent: String?
    private var count = 0

    init(root: String) {
        self.root = root
    }

    func path(_ relative: String) -> JSON {
        .string(root + "/" + relative)
    }

    func human(_ text: String, midTurn: Bool = false) { add(.human(text, midTurn: midTurn)) }
    func kite(_ text: String) { add(.kite(text)) }
    func notification(_ text: String) { add(.notification(text)) }
    func text(_ text: String) { add(.text(text)) }
    func thinking(_ text: String) { add(.thinking(text)) }
    func interrupted() { add(.interrupted) }
    func compacted(_ summary: String) { add(.compacted(summary)) }
    func apiError(_ message: String) { add(.apiError(message)) }

    /// 一次工具调用和它的结果。result 和 image 都没有就是还没有结果。sub 里记的是子 agent 做的事。
    func tool(_ name: String, _ input: JSON, _ result: String? = nil, error: Bool = false, interrupted: Bool = false,
              image: (Int, Int)? = nil, sub: ((Recorder) -> Void)? = nil) {
        count += 1
        let id = "toolu_\(count)"
        add(.toolUse(ToolUse(id: id, name: name, input: input)))
        if let sub {
            let outer = parent
            parent = id
            sub(self)
            parent = outer
        }
        if let image {
            add(.toolResult(ToolResult(call: id, content: [.image(width: image.0, height: image.1)], isError: false)))
        } else if let result {
            add(.toolResult(ToolResult(call: id, content: [.text(result)], isError: error, interrupted: interrupted)))
        }
    }

    private func add(_ block: Block) {
        records.append(Record(parent: parent, block: block))
    }
}

/// Read 的结果带行号，和 cat -n 一样。
private func numbered(_ text: String, from start: Int = 1) -> String {
    text.components(separatedBy: "\n").enumerated()
        .map { String(repeating: " ", count: max(6 - String($0.offset + start).count, 0)) + "\($0.offset + start)\t\($0.element)" }
        .joined(separator: "\n")
}
