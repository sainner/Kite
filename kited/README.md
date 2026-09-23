# kited

跑在工作机上的 Kite 后台服务。它登记项目，让每个会话在自己的 git 工作树里跑 Claude Code，每批工具调用后给工作树打一枚快照，最后把会话的改动合回主线。它没有界面，App 和 `kite` 命令行都经本机 HTTP 接口和它说话。

## 运行

```bash
cd kited && bun install
bun src/main.ts
```

`KITE_HOME` 默认是 `~/.kite`，里面放数据库 `kite.db`、会话工作树 `worktrees/<项目>/<会话>/` 和初始化日志 `sessions/<会话>/setup.log`。`KITE_PORT` 默认是 5483，只监听 127.0.0.1。

kited 用自己的环境变量启动 Claude Code，读取的登录状态、设置、插件、MCP 都和在终端里直接运行 `claude` 一样。所以运行 kited 的那个用户要先在终端登录（`claude auth login`）。不要从别的 Claude Code 会话里启动 kited，那样会把会话自己的 `CLAUDE_*` 变量传给子进程。

命令行是薄客户端：

```bash
bun src/cli.ts add ~/thesis        # 登记项目，id 取文件夹名里的 ASCII 部分
bun src/cli.ts new thesis "把第二章的图注统一成中文"
bun src/cli.ts send <会话> "再检查一遍参考文献"
bun src/cli.ts snapshots <会话>
bun src/cli.ts restore <会话> <快照>
bun src/cli.ts adopt <会话>
bun src/cli.ts archive <会话>
```

## 一个会话的一生

1. **登记项目**。已有的 git 仓库直接用，提交归用户（`commits: user`）。普通文件夹由 Kite 执行 `git init`，写入 `.gitignore` 模板（项目规范 kite-onboard skill 里的 `templates/gitignore`，kited 直接 import 这一份），提交初始版本后立即打包对象库，之后的提交由 Kite 代做（`commits: kite`）。放在 iCloud、Dropbox 里的文件夹，仓库本体放到 `KITE_HOME/repos/`。
2. **建工作树**。起点是主文件夹当时的 HEAD。Kite 代管提交的项目先把主文件夹里没提交的改动存成一个提交，否则新会话看不到用户刚放进去的文件。工作树放在项目文件夹外，分支叫 `kite/<会话>`。
3. **带上被忽略的文件**，规则照 Claude Code 2.1.280 自己建工作树时的做法：设置里的 `worktree.symlinkDirectories` 做软链接（用 SDK 的 `resolveSettings` 读项目两层合并后的设置），`.worktreeinclude` 里同时被 `.gitignore` 忽略的文件以 APFS 克隆的方式复制。`.claude/settings.local.json` 不用复制：Claude Code 在工作树里会读主仓库的那一份（已实测）。
4. **初始化**。工作树里有 `.kite/setup` 就执行它，当前目录是工作树，主文件夹路径在 `KITE_MAIN_DIR` 里。只看退出码，非 0 时会话变为 `prepare_failed`，不启动 agent。然后打一枚「会话开始」快照。
5. **对话**。每个会话一个 `Runner`，管一个 Claude Code 进程。消息直接写进进程的输入流，进程已关闭就用原生会话 id 就地 resume（第一次用 `sessionId` 指定 id，所以 Kite 在启动前就知道它）。人发的消息带 `origin: {kind: 'human'}`，会话记录里据此区分人发的和 Kite 发的。系统提示用 `claude_code` 预设（SDK 不指定时只发一段极简提示，没有记忆、git 状态等段落），设置只读项目的两层（project、local，见「会话的上下文」），权限模式是 bypassPermissions，记忆目录指到工作树的 `.kite/memory`（经 `settings` 选项传入，优先级高于项目里的设置；上游只接受绝对路径，项目里提交的设置写不了每棵工作树各自的路径）。
6. **收口**。回合结束时看 Stop 钩子输入里的 `background_tasks` 和 `session_crons`：两份都是空数组，就关闭输入流让进程退出；读不到就当作不空。Stop 之后又来了消息就不关。关闭期间来的消息先存着，进程退出后带着它们重新 resume。进程被杀、kited 重启都等同于关闭。
7. **快照**。每批工具调用全部完成后（PostToolBatch 钩子，并行调用只触发一次）捕获一次，回合结束再捕获一次，以收进后台任务写的文件。快照是挂在 `refs/kite/snapshots/<会话>` 上的提交链（不用 `refs/kite/<会话>`，否则和会话分支 `kite/<会话>` 的短名撞车，git 会优先解析成快照），用工作树自己的私有索引，不动 HEAD、分支和暂存区；树没变就不产生新提交。提交说明的第一行是开启这一回合的用户消息，尾部用 `Kite-Session` 和 `Kite-Tool-Use` 记下会话和工具调用 id。
8. **回退**。把工作树恢复成某一枚快照，只动文件。回退前先捕获一次现状（现状已经在快照里就不重复存），所以回退本身可以撤销。agent 正在工作时不允许。
9. **打断**。回合在跑就调 SDK 的 `interrupt()`。消息已投递但回合还没开始（进程在启动或 resume），就在 UserPromptSubmit 钩子里拦下这条消息，它不会发给模型；这时直接调 `interrupt()` 不可靠：实测 resume 时打断先于回合到达，会被忽略，回合照常跑完。输入流已关、等进程退出时，打断就是撤回等着重启的消息。
10. **采纳**。同一项目的采纳按项目串行（本机锁）。先在会话工作树里提交全部改动，再把主线合进会话分支：有冲突就留在会话工作树里，写一条说明交给 agent（不带 human 标记），它这一轮结束后自动重试。最后主文件夹快进到会话分支。主线指主文件夹当前检出的分支。主文件夹永远不会处于冲突状态；用户仓库里没提交的改动只要不碰会话改过的文件，快进时原样保留，碰到了就拒绝采纳并说明原因。采纳之后会话照常可用，可以接着改、再采纳。
11. **归档**。关掉进程，存最后一枚快照，删掉工作树和会话分支，快照引用保留。有没合回主线的改动时要显式 force。

## 会话的上下文

在 Kite 仓库自己的工作树里实测（Claude Code 2.1.280），还没开始对话时模型看到约 7.9K token：

- **系统提示**（约 2.3K）：`claude_code` 预设。角色和安全边界、行为准则、记忆的用法（路径是工作树的 `.kite/memory/`）、模型列表。其中「输出显示在终端里」对 Kite 不准确，等 App 定下渲染方式再用 `append` 改。
- **工具**：常驻的是 Agent、Bash、Read、Edit、Write、Skill、ToolSearch、ListAgents，项目有 `.kite/check` 时还有 Kite 自己的 check（见下一节）；CronCreate、CronDelete、CronList、Monitor、TaskStop、SendMessage、NotebookEdit、WebFetch、WebSearch 只列名字，用到时经 ToolSearch 加载。本机版 Claude Code 没有 Glob、Grep，搜索走 Bash。
- **环境**：跟在第一条消息后面的一条系统消息。工作目录，并说明这是工作树、不要切回主仓库、不要用裸 `git stash`；子 agent 列表（Explore、general-purpose、Plan，加上项目自己的）；skill 列表（Claude Code 自带的 code-review、simplify、security-review、claude-api，加上项目自己的）；当天日期。
- **用户上下文**：项目的 CLAUDE.md（经 `@AGENTS.md` 引入 AGENTS.md）、账号邮箱、会话开始时的 git 状态。

Kite 会话只带做事用的上游功能，取舍列在 `src/runner.ts` 开头：

- 设置只读项目的两层（project、local）。用户级（`~/.claude` 下的设置、CLAUDE.md、skill、子 agent、插件）是给人自己用 Claude Code 的，不带进来；建工作树时读 `worktree.symlinkDirectories` 也只看这两层。
- 从 claude.ai 同步来的 skill、插件和连接器不带。开关经 SDK 的 `settings` 选项传入，只对这个会话生效，不动本机的文件。
- 去掉和 Kite 自己的机制冲突的（进出工作树、Claude Code 自己的后台会话、生成 CLAUDE.md 的 init），依赖 Kite 没有的宿主（终端、桌面 App、claude.ai）的，以及用不上的（Workflow、ScheduleWakeup 和配套的 skill，画图配色、改 Claude Code 设置、启动项目 App 的 skill）。
- 定时任务（CronCreate）保留：上游的 Stop 钩子把它算进 `session_crons`，有定时任务时 Kite 不关进程。

重新量的办法：SDK 的 `Query.getContextUsage()` 给出和 `/context` 一样的分类统计，用官方计数接口算，不耗额度，但 skill 和工具两项之间的拆分不准，只看总数；要看原文，把 `ANTHROPIC_BASE_URL` 指到假端点，抓第一次请求，同时设 `ENABLE_TOOL_SEARCH=true`，否则地址不是官方的时候不启用工具搜索，所有工具都会常驻。

## Kite 的工具

SDK 加自定义工具只有进程内 MCP 服务器这一条路（`src/tools.ts`）：工具代码就在 kited 里运行，不起进程、不走网络。启动 Claude Code 时设 `CLAUDE_AGENT_SDK_MCP_NO_PREFIX=1`，这类工具用裸名，模型看到的是 `check` 而不是 `mcp__kite__check`；这个变量上游没写进文档，Pigeon 从 2.1.226 用起，2.1.280 实测仍有效。再加 `alwaysLoad`，和内置工具一样常驻，不经 ToolSearch。工具在每次启动 Claude Code 进程时按工作树现状组装。

**check**（`src/check.ts`）：跑工作树里的 `.kite/check`，只在有这个文件时提供，参数只有 `all`（跑全量）。比 agent 在 Bash 里直接跑多两样：`KITE_BASE` 由 Kite 给，取会话分支和主线的分叉点，会话里已经提交的改动也算进受影响的范围；结果发成 `check` 事件，App 可以直接显示；完整日志经 `KITE_LOG_DIR` 写进 `KITE_HOME/sessions/<会话>/checks/<时间>/`。一台机器上一次只跑一个检查，后来的排队：检查按耗时预算判定，两个同时跑会互相拖慢、误报超时；预算把一次全量限在十几秒，排在后面最多等这么久。排队的时间不算进超时，排队时回合被打断就直接退出队列。检查命令自成一个进程组，超过 10 分钟或回合被打断时连子进程一起停掉。输出原样送回模型，太长时只留结尾；没通过时工具结果标为错误。什么时候该用写在工具说明里，AGENTS.md 不再重复。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET/POST | `/projects` | 列出项目；登记 `{path}` |
| GET/POST | `/sessions` | 列出会话（`?project=`）；新建 `{project, prompt}`，立即返回，准备过程看事件 |
| GET | `/sessions/:id` | 会话，附带进程状态 `runner` 和 `busy` |
| POST | `/sessions/:id/messages` | 发消息 `{text}` |
| POST | `/sessions/:id/interrupt` | 打断当前回合 |
| GET | `/sessions/:id/snapshots` | 快照，新的在前 |
| POST | `/sessions/:id/restore` | 恢复到快照 `{commit}` |
| POST | `/sessions/:id/adopt` | 合回主线，返回 `adopted` 或 `conflict` |
| POST | `/sessions/:id/archive` | 归档 `{force?}` |
| GET | `/events` | SSE 事件流（`?session=`）：SDK 原始消息，以及 status、runner、idle、setup、snapshot、adopt、check、error |

事件不落库。会话内容以 Claude Code 自己的会话记录为准，快照以 git 为准，数据库只记项目和会话的登记信息。

## 测试

改完在仓库根目录跑 `.kite/check`：先同时做类型检查和 lint（`eslint.config.js`，只开 TypeScript 查不出来的两条 Promise 规则），再只跑这次改动影响到的测试，加 `--all` 跑全量。测试规则在 `.claude/agents/test-writer.md`，测试由这个子 agent 按需求写。

- `test/small/`：小测试，直接调模块，git 在临时目录里跑，不起 Claude Code。
- `test/medium/`：中测试，起真实的 Claude Code，模型换成 `test/fake-api.ts` 的假端点，不耗额度；agent 靠消息里的指令（`RUN`、`PAR`、`CALL`、`BG`、`HOLD`）做确定的事。kited 经 `test/harness.ts` 在本进程里启动，这样依赖图看得到测试用了哪些源码。
- `test/setup.ts` 在所有测试之前把环境变量换成一套隔离的，并起一个共用的假端点。测试常在别的 Claude Code 会话里跑，不清掉的话，子进程会连到真实服务、读到真实设置。

小测试按文件并行跑，中测试按顺序跑。个数和耗时会随改动变，实测记录在 `spikes/check/README.md`。

## 大测试清单

升级 SDK 或 Claude Code 之后，用真实订阅手动跑一遍。kited 要在干净的环境变量里启动，不继承当前 Claude Code 会话的 `CLAUDE_*` 变量；终端版 Claude Code 要先登录。

1. 登记一个普通文件夹，新建会话，让 agent 改一个文件：出现「会话开始」和一枚改动快照，回合结束后进程关闭。
2. 会话记录里的系统提示有记忆段落，路径是工作树的 `.kite/memory/`；人发的消息带 `origin: human`。
3. 再发一条消息：进程重新 resume，记下从发消息到进程就绪、到首条回复各用多久。
4. 采纳：主文件夹出现改动，git 历史干净；然后归档。
5. 量一次会话的上下文（办法见「会话的上下文」）：`src/runner.ts` 里去掉的工具和 skill 名字还对得上，没有新冒出来的无关功能；Kite 的工具名不带 `mcp__` 前缀。

## 还没做的

- 个人偏好放哪：Kite 会话不读 `~/.claude` 的用户级配置，用户的个人偏好（比如回答用简体中文）和关于人的记忆要有 Kite 自己的位置，还没定。
- 权限：现在一律 bypassPermissions，没开 Claude Code 沙箱。沙箱挡不挡得住经链接写资源库、会话工作树里的 git 提交要写主仓库的 `.git`，这两件事都没验证。
- 对话回退（`resumeSessionAt` 加 `forkSession`）和统一格式的翻译器，放到第 3 步。
- 多机集成（推送、被拒后重合）。第一阶段只有一台工作机。
- 采纳的提交说明现在用会话标题，以后让 agent 写。
- 二进制文件冲突让用户二选一，现在一律交给 agent。
- 被打断的回合不触发 Stop 钩子，读不到收口清单，进程留着，直到下一回合正常结束。
- 有定时任务时不关进程这一半没有测试：假端点驱动不了 CronCreate。
- 消息可能丢：kited 和它起的 Claude Code 在同一刻被杀，而 Claude Code 还没把刚收到的消息写进会话记录时，这条消息就没了。重启后再发消息能正常续接，但丢的那条不会补发。要保证送达，得等 Claude Code 确认收到（SDK 回放的用户消息）才算投递完成，之前一直由 kited 保存。
