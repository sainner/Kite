# kited

kited 新会话默认使用自研 harness 和 ChatGPT 订阅，已接通独立工作树、快照、回退、采纳和归档。旧 Claude 会话按原 runtime 续接。终端入口仍可直接在指定目录工作；App 已接项目和会话列表、harness 真实对话、统一历史与 SSE 重连，协议见 [会话显示协议](../docs/会话显示协议.md)。

## 终端试用

在 `kited` 目录运行，工作目录可以指定任意本地项目：

```bash
bun run harness --cwd /你的项目目录
```

默认凭据位于 `$KITE_HOME/auth/chatgpt/auth.json`（`KITE_HOME` 默认 `~/.kite`），通过设备登录独立授权，不再默认读取日常 Codex 的登录。也可用 `--auth /绝对路径/auth.json` 指定文件。

授权借用官方登录工具，给它单独的认证目录；每台工作机各登录一次，不跨机器同步凭据：

```bash
mkdir -p -m 700 "${KITE_HOME:-$HOME/.kite}/auth/chatgpt"
CODEX_HOME="${KITE_HOME:-$HOME/.kite}/auth/chatgpt" codex -c 'cli_auth_credentials_store="file"' login --device-auth
```

浏览器打开命令显示的地址并输入设备码。若 PATH 中的 `codex` 不可用，换成有效的 Codex 可执行文件路径。本机此次使用的是桌面 App 内置的 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。

harness 每次请求只读加载凭据，模型循环和工具执行不启动 Codex 或 Claude Code。自动刷新、系统钥匙串支持仍未接入；凭据过期或返回 401 时，在同一认证目录重新执行设备登录。无需 Platform API key。

默认模型 `gpt-6-sol`、推理强度 `medium`，可用 `--model`、`--reasoning` 指定，模型名也可通过 `KITE_MODEL` 设置。一次任务跑完就退出：

```bash
bun run harness --cwd /你的项目目录 --prompt "读取项目说明，概括目录结构"
```

启动时打印会话 id 和记录目录；退出后可以恢复，工作目录、模型配置与上下文随会话保留：

```bash
bun run harness --resume <会话id>
```

`--resume` 也接受会话记录目录的绝对路径。记录默认位于 `~/.kite/sessions/<会话id>/`（可用 `KITE_HOME` 改变）；`journal.jsonl` 是会话正文，`commands/` 保存完整命令输出。恢复会话不能更换工作目录。

| 操作 | 行为 |
|---|---|
| 直接输入 | 空闲时开始新回合；执行中插话，在下一次模型请求纳入 |
| `/status` | 查看状态与上一回合结果 |
| `/stop` 或执行中按 Ctrl+C | 打断回合，等待命令及其进程组停止 |
| `/resume` | 继续暂停的上下文 |
| `/recover` | 确认旧执行已经停止后解除恢复阻塞；仍需 `/resume` |
| `/exit` 或空闲时按 Ctrl+C | 停止执行、保存记录并退出 |

当前提供 `read`、`patch`、`shell`。`read` 按行读取文本；`patch` 合并创建、修改和删除，支持一批多个文件，补丁解析复用 OpenAI Agents SDK 的 `applyDiff`。未读过、或自上次读取/修改后文件有变化，都仅提示；补丁无法匹配当前内容仍会失败。读取版本目前只保留在本次运行内，恢复会话后按没有本次运行记录提示；尚未实现持久化的观察账本。

每次请求前读取适用的 `AGENTS.md` 和 `.kite/memory/MEMORY.md`，由独立的上下文组装器展开段落、变量和条件分支。定义引用场景，可用变量统一由场景表约束；终端使用 `session.create` 场景。定义与当次材料保存为快照，请求记录关联其版本，旧版快照仍可还原。记忆正文按需读取。设计与接口见 [上下文组装器](../docs/harness-上下文组装.md)，前端编辑器和文件变化通知投递尚未接入。

文件工具限制在工作目录内，shell 使用当前用户权限；命令输出限长并保留完整日志，后台任务暂不支持。每回合默认最多 50 次模型请求，达到后暂停，`--max-requests` 可调整。

这个终端入口直接修改指定目录。要使用独立工作树、快照和采纳流程，请通过下面的 kited HTTP 或 `kite` 客户端创建会话。当前尚无子 agent、skill 自动发现、MCP 或上下文压缩。异常退出留下的 `lock/` 不会自动删除；先根据 `lock/owner.json` 与 `processes.json` 确认原进程及命令均已停止，再清理该会话的锁并重新打开。执行效果未知时保持暂停，不重放旧工具。

## 自研 harness 主循环

`HarnessSession`（`src/harness/session.ts`）直接管理输入、模型流、工具调度和回合收尾，不依赖 Claude SDK 或 Codex CLI。公开契约见 `src/harness/types.ts`，设计与恢复边界见 [harness 主循环](../docs/harness-主循环.md)。

宿主创建 `FileJournal`，注入模型、工具、工作目录、指令和快照回调：

```ts
import { FileJournal } from './src/harness/journal.ts';
import { HarnessSession } from './src/harness/session.ts';

const session = new HarnessSession({
  cwd: worktree,
  instructions,
  journal: new FileJournal(journalPath),
  model, // 实现 Model.stream(request, signal)
  tools, // 每个工具负责参数校验、取消和受管执行的停止
  afterTools: async (_turnId, callIds) => captureToolSnapshot(callIds),
  afterTurn: async (_turnId, outcome) => captureTurnSnapshot(outcome),
});
await session.send({ id: clientMessageId, text: '检查项目', source: 'human' });
```

消息可靠落盘后 `send` 才确认。完整工具调用先保存，再在响应流仍进行时调度；连续的 `parallel: true` 工具可并发，默认工具排他。工具结果按调用顺序组成下次上下文，原始输出的 opaque 字段保留。打断要等工具和宿主回调结束；关闭保留队列。断流暂停，存储故障或未知工具结果要求恢复确认，已开始的旧工具不自动重放。

内核自动测试使用手动模型流；订阅适配器使用分段 SSE 夹具。另已用真实 ChatGPT 订阅验证文本回复、写文件、shell 读取，以及退出后的会话恢复和继续编辑。kited 的生命周期集成测试使用真实工作树、patch/shell 与假模型，覆盖快照先于下一请求、采纳归档、同 home 停启续接，以及归档不唤醒排队输入。未对本轮 daemon 接入额外消耗真实订阅。

## kited 会话宿主

`src/runtime.ts` 根据会话的 runtime 选择执行入口，`session-host.ts` 与终端共用锁、journal 和进程登记。新会话默认 `harness`，也可在 HTTP 创建时显式指定 `claude`；不会把旧 nativeId 改用于新后端。

每批工具的结果与快照完成后才请求下一次模型，回合结束后再补快照；快照失败会暂停 harness。恢复 journal 保留原始模型输出和工具结果，已完成的工具不会重跑。管理操作串行执行，归档先停止执行再判断是否有未采纳改动，打开旧会话做管理操作不会自动执行排队输入。

`harness` 的模型配置保存在会话 metadata 中，新会话可通过 `KITE_MODEL` 选模型，默认 `gpt-6-sol`、`medium`，每回合最多 50 次请求。认证固定读当前 kited home 下的 `auth/chatgpt/auth.json`。异常退出的锁仍须人工核查、清理；`recover` 只确认恢复，随后用 `resume` 继续。正常停机后重新发消息即可续接。

## 运行

```bash
cd kited && bun install
bun src/main.ts
```

`KITE_HOME` 默认是 `~/.kite`，里面放数据库 `kite.db`、会话工作树 `worktrees/<项目>/<会话>/` 和初始化日志 `sessions/<会话>/setup.log`。`KITE_PORT` 默认是 5483，只监听 127.0.0.1。

默认 harness 使用前文独立授权的 ChatGPT 凭据。只有 `claude` 会话需要 Claude 登录；它仍用 kited 自己的环境变量启动子进程，设置只带项目和本地两层。

命令行是薄客户端：

```bash
bun src/cli.ts add ~/thesis        # 登记项目，id 取文件夹名里的 ASCII 部分
bun src/cli.ts new thesis "把第二章的图注统一成中文"
bun src/cli.ts send <会话> "再检查一遍参考文献"
bun src/cli.ts resume <会话>       # 继续暂停的上下文
bun src/cli.ts snapshots <会话>
bun src/cli.ts restore <会话> <快照>
bun src/cli.ts adopt <会话>
bun src/cli.ts archive <会话>
```

## 一个会话的一生

1. **登记项目**。已有的 git 仓库直接用，提交归用户（`commits: user`）。普通文件夹由 Kite 执行 `git init`，写入 `.gitignore` 模板（项目规范 kite-onboard skill 里的 `templates/gitignore`，kited 直接 import 这一份），提交初始版本后立即打包对象库，之后的提交由 Kite 代做（`commits: kite`）。放在 iCloud、Dropbox 里的文件夹，仓库本体放到 `KITE_HOME/repos/`。
2. **建工作树**。起点是主文件夹当时的 HEAD。Kite 代管提交的项目先把主文件夹里没提交的改动存成一个提交，否则新会话看不到用户刚放进去的文件。工作树放在项目文件夹外，分支叫 `kite/<会话>`。
3. **带上被忽略的文件**，规则照 Claude Code 2.1.280 自己建工作树时的做法：设置里的 `worktree.symlinkDirectories` 做软链接（用 SDK 的 `resolveSettings` 读项目两层合并后的设置），`.worktreeinclude` 里同时被 `.gitignore` 忽略的文件以 APFS 克隆的方式复制。`.claude/settings.local.json` 不用复制：Claude Code 在工作树里会读主仓库的那一份（已实测）。
4. **初始化**。工作树里有 `.kite/setup` 就执行它，当前目录是工作树，主文件夹路径在 `KITE_MAIN_DIR` 里。只看退出码，非 0 时会话变为 `prepare_failed`，不启动 agent。脚本和检查命令一样自成一个进程组（`src/script.ts`），超过 15 分钟连子进程一起停掉，记退出码 124。然后打一枚「会话开始」快照。
5. **对话**。harness 把输入可靠写入 journal 后确认，运行中插话在下一请求纳入，每请求重新组装项目指令。消息可带客户端 id 去重，来源区分 human 与 kite。旧 Claude 会话继续由 `Runner` 管子进程，以原 nativeId 续接。
6. **收口**。harness 等工具及快照收齐后结束回合；断流或快照失败暂停，未知工具结果要求恢复确认。旧 Claude Runner 仍按 Stop 钩子的后台任务和定时任务清单关闭输入流、等待进程退出。
7. **快照**。每批工具调用全部完成后（harness 的 afterTools / Claude 的 PostToolBatch）捕获一次，回合结束再捕获一次，以收齐本回合剩余改动。快照是挂在 `refs/kite/snapshots/<会话>` 上的提交链（不用 `refs/kite/<会话>`，否则和会话分支 `kite/<会话>` 的短名撞车，git 会优先解析成快照），用工作树自己的私有索引，不动 HEAD、分支和暂存区；树没变就不产生新提交。提交说明的第一行是开启这一回合的用户消息，尾部用 `Kite-Session` 和 `Kite-Tool-Use` 记下会话和工具调用 id。
8. **回退**。把工作树恢复成某一枚快照，只动文件。回退前先捕获一次现状（现状已经在快照里就不重复存），所以回退本身可以撤销。agent 正在工作时不允许。
9. **打断**。harness 中止当前模型请求，等待工具进程和收尾快照结束。准备中的会话会中止初始化脚本。旧 Claude 会话继续使用 SDK interrupt 和启动边界的拦截逻辑。
10. **采纳**。同一项目的采纳按项目串行（本机锁）。先在会话工作树里提交全部改动，再把主线合进会话分支：有冲突就留在会话工作树里，写一条说明交给 agent（来源 kite），正常完成且没有待处理输入时自动重试；暂停或中断不触发自动采纳。最后主文件夹快进到会话分支。主线指主文件夹当前检出的分支。主文件夹永远不会处于冲突状态；用户仓库里没提交的改动只要不碰会话改过的文件，快进时原样保留，碰到了就拒绝采纳并说明原因。采纳之后会话照常可用，可以接着改、再采纳。
11. **归档**。关掉进程，存最后一枚快照，删掉工作树和会话分支，快照引用保留。有没合回主线的改动时要显式 force。

## Claude 会话的上下文

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
- Bash 工具的 edit diff 关掉（设置 `bashEditDiffEnabled`，经 `settings` 选项传入）。它在 bypassPermissions 下默认开，在 git 仓库里每次调用前后各打一次快照，把命令改了哪些文件算成 diff，放在 SDK 消息的 `tool_use_result.bashEditDiff` 里给界面显示，模型看不到；每次串行约 13 条 git、约 0.2 秒。改动由 Kite 自己的快照记录。

重新量的办法：SDK 的 `Query.getContextUsage()` 给出和 `/context` 一样的分类统计，用官方计数接口算，不耗额度，但 skill 和工具两项之间的拆分不准，只看总数；要看原文，把 `ANTHROPIC_BASE_URL` 指到假端点，抓第一次请求，同时设 `ENABLE_TOOL_SEARCH=true`，否则地址不是官方的时候不启用工具搜索，所有工具都会常驻。

## Claude runtime 的 check 工具

这部分目前仍只用于 Claude。harness 通过 shell 执行 `.kite/check`；结构化 check 事件、会话分叉点和跨会话检查排队尚待接入。

SDK 加自定义工具只有进程内 MCP 服务器这一条路（`src/tools.ts`）：工具代码就在 kited 里运行，不起进程、不走网络。启动 Claude Code 时设 `CLAUDE_AGENT_SDK_MCP_NO_PREFIX=1`，这类工具用裸名，模型看到的是 `check` 而不是 `mcp__kite__check`；这个变量上游没写进文档，Pigeon 从 2.1.226 用起，2.1.280 实测仍有效。再加 `alwaysLoad`，和内置工具一样常驻，不经 ToolSearch。工具在每次启动 Claude Code 进程时按工作树现状组装。

**check**（`src/check.ts`）：跑工作树里的 `.kite/check`，只在有这个文件时提供，参数只有 `all`（跑全量）。比 agent 在 Bash 里直接跑多两样：`KITE_BASE` 由 Kite 给，取会话分支和主线的分叉点，会话里已经提交的改动也算进受影响的范围；结果发成 `check` 事件，App 可以直接显示；完整日志经 `KITE_LOG_DIR` 写进 `KITE_HOME/sessions/<会话>/checks/<时间>/`。一台机器上一次只跑一个检查，后来的排队：检查按耗时预算判定，两个同时跑会互相拖慢、误报超时；预算把一次全量限在十几秒，排在后面最多等这么久。排队的时间不算进超时，排队时回合被打断就直接退出队列。检查命令自成一个进程组，超过 10 分钟或回合被打断时连子进程一起停掉。输出原样送回模型，太长时只留结尾；没通过时工具结果标为错误。什么时候该用写在工具说明里，AGENTS.md 不再重复。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET/POST | `/projects` | 列出项目；登记 `{path}` |
| GET/POST | `/sessions` | 列出会话（`?project=`）；新建 `{project, prompt, runtime?}`，默认 harness，立即返回，准备过程看事件 |
| GET | `/sessions/:id` | 会话，附带运行状态 `runner` 和 `busy`；harness 的 runner 为 Phase，Claude 为进程状态 |
| POST | `/sessions/:id/messages` | 发消息 `{text, id?}`，返回 `{id}`；harness 在 journal 落盘后确认，相同 id 和内容去重 |
| POST | `/sessions/:id/interrupt` | 打断当前回合 |
| POST | `/sessions/:id/resume` | 继续暂停的 harness 会话 |
| POST | `/sessions/:id/recover` | 核查登记进程已停止后确认恢复，不自动执行 |
| GET | `/sessions/:id/snapshots` | 快照，新的在前 |
| POST | `/sessions/:id/restore` | 恢复到快照 `{commit}` |
| POST | `/sessions/:id/adopt` | 合回主线，返回 `adopted` 或 `conflict` |
| POST | `/sessions/:id/archive` | 归档 `{force?}` |
| GET | `/sessions/:id/history` | v1 显示历史、pending、state 和 cursor，只读，不启动 agent |
| POST | `/sessions/:id/messages/:message/cancel` | 撤回尚未纳入模型请求的 harness 输入 |
| GET | `/events` | SSE（`?session=`）：首帧完整 history，随后 record、pending、state 与管理事件；全局流首帧 ready |

SSE 广播本身不落库，每次重连用完整历史替换客户端副本，再按记录 id 接续更新。harness 以 `sessions/<会话>/journal.jsonl` 为准，Claude 以自己的会话记录为准，快照以 git 为准，数据库只记项目和会话登记。cursor、流式草稿和旧 Claude 支持范围见 [会话显示协议](../docs/会话显示协议.md)。

## 测试

改完在仓库根目录跑 `.kite/check`：先同时做类型检查和 lint（`eslint.config.js`，只开 TypeScript 查不出来的两条 Promise 规则），`app/` 有改动时一起编译 App 的 Mac 和 iOS 两端，再只跑这次改动影响到的测试，加 `--all` 跑全量。测试规则在 `.claude/agents/test-writer.md`，测试由这个子 agent 按需求写。

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
- 权限：harness 的 shell 使用当前用户权限，Claude 采用 bypassPermissions，尚无操作系统沙箱。沙箱挡不挡得住经链接写资源库、会话工作树里的 git 提交要写主仓库的 `.git`，这两件事都没验证。
- 对话回退、分叉，以及旧 Claude 完整历史的元数据、插话附件和子 agent 适配尚未完成。
- 多机集成（推送、被拒后重合）。第一阶段只有一台工作机。
- 采纳的提交说明现在用会话标题，以后让 agent 写。
- 二进制文件冲突让用户二选一，现在一律交给 agent。
- Claude：被打断的回合不触发 Stop 钩子，读不到收口清单，进程留着，直到下一回合正常结束。
- Claude：有定时任务时不关进程这一半没有测试：假端点驱动不了 CronCreate。
- Claude 消息可能丢：kited 和它起的 Claude Code 在同一刻被杀，而 Claude Code 还没把刚收到的消息写进会话记录时，这条消息就没了。重启后再发消息能正常续接，但丢的那条不会补发。要保证送达，得等 Claude Code 确认收到（SDK 回放的用户消息）才算投递完成，之前一直由 kited 保存。
