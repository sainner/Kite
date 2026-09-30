# kited

kited 新会话默认使用自研 harness 和 ChatGPT 订阅，已接通独立工作树、快照、回退、采纳和归档。产品模型保存工作机，以及「项目 → 检出 → 工作区 → 插件实例」及其专有 Thread 和窗口关系，`/workspaces` 提供完整聚合。工作区拥有目录、快照和采纳，线程拥有独立对话与执行状态；登记检出会建立一个没有线程的根工作区。终端入口可直接在指定目录工作；App 已接工作区列表、动态会话与插件窗口、harness 真实对话、统一历史与 SSE 重连，协议见 [会话显示协议](../docs/会话显示协议.md)。

## 终端试用

在 `kited` 目录运行，工作目录可以指定任意本地项目。先安装依赖并使用项目固定的 Bun 1.4.2（`.kite/check` 自动选择这个版本）：

```bash
bun install
export PATH="$PWD/node_modules/.bin:$PATH"
```

Bun 1.3.11 在沙箱内遇到不可读的父目录时会丢失环境变量，不能用于此入口；相关上游修复见 [Bun #27802](https://github.com/oven-sh/bun/issues/27802)。

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
| `/stop` 或执行中按 Ctrl+C | 停止会话并退回队列，等待命令及其进程组停止 |
| `/resume` | 继续暂停的上下文 |
| `/recover` | 确认旧执行已经停止后解除恢复阻塞；仍需 `/resume` |
| `/exit` 或空闲时按 Ctrl+C | 停止执行、保存记录并退出 |

当前提供 `read`、`patch`、`shell`。`read` 按行读取文本；`patch` 合并创建、修改和删除，支持一批多个文件，补丁解析复用 OpenAI Agents SDK 的 `applyDiff`。未读过、或自上次读取/修改后文件有变化，都仅提示；补丁无法匹配当前内容仍会失败。读取版本目前只保留在本次运行内，恢复会话后按没有本次运行记录提示；尚未实现持久化的观察账本。

`shell` 每次调用必须填写非空白的 `description`，用简短的话说明命令用途，不指定语言，前端直接显示为这次调用的描述；原始命令保留在详情里。`read`、`patch` 的摘要可由文件路径和操作生成，不要求模型另填描述。

每次请求前读取适用的 `AGENTS.md` 和 `.kite/memory/MEMORY.md`，由独立的上下文组装器展开段落、变量和条件分支。首次顶部指令固定；之后材料发生变化时，将更新追加到历史，保持已发送的前缀。定义引用场景，可用变量统一由场景表约束；终端使用 `thread.create` 场景。配置变更及基础上下文更新的通知正文也由场景定义组装，通知保存定义与变量快照，历史从快照还原。记忆正文按需读取。设计与接口见 [上下文组装器](../docs/harness-上下文组装.md)，前端编辑器和文件变化通知投递尚未接入。

文件工具限制在工作目录内，并和 shell 共用执行策略。shell 已通过 `@anthropic-ai/sandbox-runtime` 0.0.78 进入操作系统沙箱：默认工作树可读写、必要系统工具链可读、网络关闭；每次调用有独立配置、网络代理和临时目录。登录凭据、数据库和会话记录禁止模型工具读写；Git 元数据只读，快照与采纳由宿主执行。缺失依赖、隔离能力降级或配置错误会拒绝启动。

macOS 使用 Seatbelt；Linux 使用 bubblewrap，需要 `bwrap`、`socat`、`rg` 及上游 seccomp 支持，目前只在 macOS 验证。kited 的 harness 实例可通过 `GET / PUT /instances/:id/execution-grants` 保存和编辑工作区读写、额外目录及网络许可，须先停止并确认执行结果；变更在下一次自然模型请求追加通知，不唤醒或重放命令。App 编辑界面及独立终端的授权编辑尚未接入。本机 HTTP 尚未鉴权，当前不允许通过授权编辑开放回环地址。完整规则见 [实例执行授权](../docs/实例操作.md#实例执行授权)。命令输出限长并保留完整日志，后台任务暂不支持。每回合默认最多 50 次模型请求，达到后暂停，`--max-requests` 可调整。

这个终端入口直接修改指定目录。要使用独立工作树、快照和采纳流程，请通过下面的 kited HTTP 或 `kite` 客户端创建会话。独立终端未接 agent 协作工具；harness 的 skill 自动发现、MCP 和上下文压缩仍待实现。异常退出留下的 `lock/` 不会自动删除；先根据 `lock/owner.json` 与 `processes.json` 确认原进程及命令均已停止，再清理该会话的锁并重新打开。执行效果未知时保持暂停，不重放旧工具。

## 自研 harness 主循环

产品模型统一用 `Thread` 表示一段持久会话；`HarnessRunner` 是它的执行实例，接口为 `ThreadRunner`，宿主为 `ThreadHost`。实例关闭后可从同一记录恢复，不产生另一层 Session。历史、事件与订阅使用 `threadId`、`thread.*` 和 `?thread=`。既有记录目录 `sessions/<线程>/` 保留原路径，属于存储命名；上游协议的 `session_id` 等字段保持原名。

`HarnessRunner`（`src/harness/runner.ts`）直接管理输入、模型流、工具调度和回合收尾，不依赖 Claude SDK 或 Codex CLI。公开契约见 `src/harness/types.ts`，设计与恢复边界见 [harness 主循环](../docs/harness-主循环.md)。

宿主创建 `FileJournal`，注入模型、工具、工作目录、指令和快照回调：

```ts
import { FileJournal } from './src/harness/journal.ts';
import { HarnessRunner } from './src/harness/runner.ts';

const runner = new HarnessRunner({
  cwd: worktree,
  journal: new FileJournal(journalPath),
  prepareRequest: () => ({
    instructions, model, tools, // 工具负责参数校验、取消和受管执行的停止
    settings: { maxRequestsPerTurn: 50 },
  }),
  afterTools: async (_turnId, callIds) => captureToolSnapshot(callIds),
  afterTurn: async (_turnId, outcome) => captureTurnSnapshot(outcome),
});
await runner.send({ id: clientMessageId, text: '检查项目', source: 'human' });
```

消息可靠落盘后 `send` 才确认。完整工具调用先保存，再在响应流仍进行时调度；连续的 `parallel: true` 工具可并发，默认工具排他。工具结果按调用顺序组成下次上下文，原始输出的 opaque 字段保留。手动停止冻结并退回队列，等待工具和宿主回调结束；关闭实例保留队列。断流暂停，存储故障或未知工具结果要求恢复确认，已开始的旧工具不自动重放。

内核自动测试使用手动模型流；订阅适配器使用分段 SSE 夹具。另已用真实 ChatGPT 订阅验证文本回复、写文件、shell 读取，以及退出后的会话恢复和继续编辑，并确认订阅入口接受 `allowed_tools` 工具子集参数。kited 的生命周期集成测试使用真实工作树、patch/shell 与假模型，覆盖快照先于下一请求、采纳归档、同 home 停启续接，以及归档不唤醒排队输入。

## kited 会话宿主

`src/runtime.ts` 根据会话的 runtime 选择执行入口，`thread-host.ts` 与终端共用锁、journal 和进程登记。新会话默认 `harness`，也可在 HTTP 创建时显式指定 `claude`；每个线程有独立的 nativeId 和 journal。

每批工具的结果与快照完成后才请求下一次模型，回合结束后再补快照；快照失败会暂停 harness。恢复 journal 保留原始模型输出和工具结果，已完成的工具不会重跑。管理操作串行执行，归档先停止执行再判断是否有未采纳改动，打开旧会话做管理操作不会自动执行排队输入。

`harness` 的 AgentDefinition 保存于 `PluginInstance.config.agent`，创建时绑定模型、工具、上下文和回合请求预算。内置编程定义声明 read / patch / shell 及五个 agent 操作工具，实际调用受实例授权限制；只读审查定义只有 read。新实例可通过 `KITE_MODEL` 选模型，默认 `gpt-6-sol`、`medium`，每回合最多 50 次请求；重启沿用绑定配置。独立终端仍在自己的 metadata 保存入口设置。配置更新通过通知在自然请求边界纳入，接口和恢复规则见 [线程通知投递](../docs/线程通知投递.md)。认证固定读当前 kited home 下的 `auth/chatgpt/auth.json`。异常退出的锁仍须人工核查、清理；`recover` 只确认恢复，随后用 `resume` 继续。正常停机后重新发消息即可续接。

## 运行

```bash
cd kited && bun install
export PATH="$PWD/node_modules/.bin:$PATH"
bun src/main.ts
```

`KITE_HOME` 默认是 `~/.kite`，里面放数据库 `kite.db`、工作树 `worktrees/<项目>/<工作区>/`、初始化日志 `workspaces/<工作区>/setup.log` 和线程记录 `sessions/<线程>/`。`KITE_PORT` 默认是 5483，只监听 127.0.0.1。

工作机服务的 `Machine.id` 首次启动时生成 UUID，保存到 `kite.db`，同一数据目录重启或更换端口时保持不变；新数据目录生成新身份。名称初始取主机名，地址由客户端保存。检出通过 `machineId` 引用所属机器；项目也使用 UUID，不按文件夹名推断跨机器的项目关系。

同一项目可以在本机或其他工作机登记多个检出。关联时提供完整项目身份 `{id, name, createdAt}`，接收方保存同一个项目 ID，各自生成检出和根工作区 ID。每台 kited 只保存本机的目录、工作区、线程与执行记录；关联不复制文件，不克隆或同步 Git 仓库。App 缓存访问过的工作机所返回的项目身份，登记目录时可从中选择。

默认 harness 使用前文独立授权的 ChatGPT 凭据。只有 `claude` 会话需要 Claude 登录；它仍用 kited 自己的环境变量启动子进程，设置只带项目和本地两层。

命令行是薄客户端：

```bash
bun src/cli.ts add ~/thesis        # 新建项目并登记检出，返回检出 id
bun src/cli.ts add ~/thesis-copy <项目> # 将目录关联到本机已有项目 ID
bun src/cli.ts checkouts <项目>    # 列出该项目在本机的检出
bun src/cli.ts new <检出> "把第二章的图注统一成中文"
bun src/cli.ts send <线程> "再检查一遍参考文献"
bun src/cli.ts resume <线程>       # 继续暂停的上下文
bun src/cli.ts snapshots <工作区>
bun src/cli.ts restore <工作区> <快照>
bun src/cli.ts adopt <工作区>
bun src/cli.ts archive <工作区>
```

## 工作区与线程的生命周期

1. **登记检出**。可以新建项目，也可以显式关联已有项目。已有 Git 仓库的提交归用户（`commits: user`）；普通文件夹由 Kite 初始化 Git、写入 `.gitignore` 模板并提交初始版本（`commits: kite`）。同步盘里的仓库本体放到 `KITE_HOME/repos/<检出>.git`，同一项目的多个检出各用一个仓库。项目、检出和根工作区一次落库，根工作区直接使用登记的目录，不创建线程。
2. **建独立工作区**。起点是检出当前的 HEAD；Kite 代管提交时先提交主目录的改动。工作树放在 `worktrees/<项目>/<工作区>/`，分支为 `kite/<工作区>`。可以先建空工作区，也可以带首条消息，准备完成后启动首个线程。
3. **准备工作树**。`worktree.symlinkDirectories` 做软链接，`.worktreeinclude` 指定的忽略文件做 APFS 克隆。执行 `.kite/setup`，通过 `KITE_MAIN_DIR` 传入检出路径；脚本非零退出或被打断时工作区变为 `failed`。成功后保存「工作区开始」快照并变为 `open`。
4. **添加线程**。根工作区和独立工作区都可添加多个线程；每个线程有自己的身份、journal 和运行时，使用所属工作区的 cwd。目前同一 cwd 有线程运行或等待恢复确认时拒绝启动另一个线程；工具层的并行调度尚未接入。
5. **对话与收口**。harness 先将输入写入 journal 再确认，运行中插话在下一请求纳入。工具结果和快照完成后才继续请求模型，断流或快照失败会暂停。Claude runtime 使用 SDK 与 Stop 钩子管理进程和续接。
6. **快照与回退**。快照链属于工作区，位于 `refs/kite/snapshots/<工作区>`，由私有索引捕获，不改 HEAD、分支或暂存区。每批工具后与回合结束时捕获，树未变则不重复提交。回退只恢复文件，先保存现状；工作区内有线程运行或等待恢复确认时不允许回退。
7. **打断与继续**。线程控制作用于该线程；准备中的首个线程被打断时会中止工作区初始化。恢复确认只核查未知进程已停止，不自动执行输入，之后通过 `resume` 继续。
8. **采纳**。独立工作区把改动合回检出主线。同一检出的 Git 集成串行执行；冲突留在独立工作树，交给其中一个打开的线程处理，正常完成后自动重试。主目录不会进入冲突状态。采纳后工作区与线程仍可继续使用。
9. **归档线程**。停止该线程并记录 `archived`，保留工作区、文件、其他线程和快照。
10. **归档工作区**。停止所有线程，保存最后快照，删除独立工作树和分支，归档实例并关闭全部窗口记录；未采纳改动需要显式 `force`。根工作区不能用此操作删除。

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

**check**（`src/check.ts`）：跑工作树里的 `.kite/check`，只在有这个文件时提供，参数只有 `all`（跑全量）。比 agent 在 Bash 里直接跑多两样：`KITE_BASE` 由 Kite 给，取会话分支和主线的分叉点，会话里已经提交的改动也算进受影响的范围；结果发成 `thread.check` 事件，App 可以直接显示；完整日志经 `KITE_LOG_DIR` 写进 `KITE_HOME/sessions/<会话>/checks/<时间>/`。一台机器上一次只跑一个检查，后来的排队：检查按耗时预算判定，两个同时跑会互相拖慢、误报超时；预算把一次全量限在十几秒，排在后面最多等这么久。排队的时间不算进超时，排队时回合被打断就直接退出队列。检查命令自成一个进程组，超过 10 分钟或回合被打断时连子进程一起停掉。输出原样送回模型，太长时只留结尾；没通过时工具结果标为错误。什么时候该用写在工具说明里，AGENTS.md 不再重复。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/machine` | 读取这台工作机服务的持久身份，无需请求头 |
| GET | `/projects` | 列出本机已登记的项目身份 |
| GET/POST | `/checkouts` | 列出本机检出（`?project=`）；登记 `{path, project?}`，返回根工作区聚合 |
| GET/POST | `/workspaces` | 列出聚合（`?project=`），响应头 `X-Kite-Cursor` 标识列表版本；创建 `{checkout, name?, prompt?, runtime?}`，准备过程看事件 |
| GET | `/workspaces/:id` | 工作区上下文及 instances、threads、windows 的完整聚合 |
| GET | `/plugin-definitions` | 内置插件定义、agent 配置、视图及目标实例声明的操作 |
| GET | `/operations` | 操作输入、输出、错误 schema，以及重试与取消规则 |
| POST | `/workspaces/:id/operations/:operation` | 调用 agent.start / list / send / resume / stop 或 files.list / read / state / select；修改操作必须带 operationId |
| GET / PUT | `/instances/:id/agent-config` | 读取绑定配置及 revision；以 expectedRevision 和完整 agent 配置更新 |
| GET / PUT | `/instances/:id/operation-grants` | 读取实例操作授权及 revision；以 expectedRevision 和 grants 更新 |
| POST | `/workspaces/:id/windows` | 创建实例及默认窗口，或打开已有实例视图；请求使用稳定 id |
| DELETE | `/workspaces/:id/windows/:window` | 关闭共享窗口，保留实例与后台执行 |
| POST | `/workspaces/:id/threads` | 在已有工作区创建线程 `{prompt, runtime?}`，默认 harness |
| GET | `/threads/:id` | 线程和上下文，附带 `runner`、`busy` |
| GET | `/threads/:id/history` | v1 显示历史、pending、state 和 cursor，只读 |
| POST | `/threads/:id/messages` | 发消息 `{text, id?}`，返回 `{id}`；harness 落盘后确认，同 id 和内容去重 |
| POST | `/threads/:id/messages/:message/cancel` | 撤回尚未纳入模型请求的 harness 输入 |
| POST | `/threads/:id/interrupt` | 停止会话，返回尚未纳入请求的队列；请求 `{id, inputs?}`，响应 `{returned}` |
| POST | `/threads/:id/resume` | 继续暂停的 harness 线程；可带 operationId 以安全重试 |
| POST | `/threads/:id/recover` | 确认恢复，不自动执行 |
| POST | `/threads/:id/archive` | 归档线程，保留所属工作区 |
| GET | `/workspaces/:id/snapshots` | 工作区快照，新的在前 |
| POST | `/workspaces/:id/restore` | 恢复文件到快照 `{commit}` |
| POST | `/workspaces/:id/adopt` | 合回主线，返回 `adopted` 或 `conflict` |
| POST | `/workspaces/:id/archive` | 归档独立工作区 `{force?}` |
| GET | `/events` | 目录 SSE：首帧 `catalog.snapshot`，随后检出、工作区和线程概要变更 |
| GET | `/events?workspace=<id>` | 工作区 SSE：首帧 `workspace.model`，随后工作区操作与所属线程概要 |
| GET | `/events?thread=<id>` | 线程 SSE：首帧 `thread.history`，随后线程显示与状态事件 |

窗口创建请求为 `{id, content: {kind: "create", definitionId}}`；打开已有视图为 `{id, content: {kind: "open", instanceId, viewId}}`。`id` 使用 UUID。内置 `kite.agent.coding` 提供 `conversation`；`kite.files` 提供 `files` 和 `preview`；`kite.terminal`、`kite.preview` 分别提供同名视图。创建空 agent 同时写入实例、Thread 和窗口，不调用模型。服务核对工作区、实例生命周期和视图声明。

窗口响应包含 `{id, workspaceId, target: {instanceId, viewId}, state, createdAt}`。同一目标再次打开返回已有窗口；同一操作 id 重试读取持久收据，内容改变或窗口已关闭时拒绝，迟到重试不会复活窗口。关闭不停止业务执行；归档 agent 更新实例生命周期并关闭其窗口。

工作区聚合的 Thread 只有 `{instanceId, runtime, nativeId}`，实例保存标题、工作区归属、definitionId、config、state、presentation、status、创建时间及可选的 origin 创建来源。`/threads/:id` 的 id 就是实例 ID，返回联表组装的执行上下文，不另存一份共有字段。journal 仍在 `sessions/<instanceId>/`。

实例操作由 HTTP 和 harness 模型工具共用。宿主绑定调用身份，coding 默认只获准控制自己创建的 agent；授权撤回在执行前重新核验。start 可省略 prompt，也可用 inline / background 只创建实例而不开窗口；list 只读状态、不打开 Runner。send / stop 复用原收据，start / resume 保存操作结果处理跨重启重试。共享工作区仍保留执行互斥，具体语义见 [实例操作与授权](../docs/实例操作.md)。

文件实例在同一个 files 视图提供目录、文本、Markdown 预览和历史 diff。files.list / read 通过 `WorkspaceFiles` 服务读取工作区，agent 的 read / patch 共用其路径校验和文本读取。files.select 使用 expectedRevision 更新实例 state 中的所选文件及可选 diffId，状态经工作区聚合同步到两端；目录位置、行号定位和文本页码留在客户端。文件操作向 UI 和已授权插件开放，模型仍使用原来的文件工具。当前读取文本，不写文件，不监听磁盘变化；App 的刷新按钮读取最新内容。

`POST /checkouts` 的 `project` 为 `{id, name, createdAt}`，可直接使用另一台工作机返回的项目身份；省略则创建新项目。同 ID 的名称或创建时间冲突、已登记目录试图改属另一项目时返回 409，在修改目录之前拒绝。重复登记同一目录和项目返回原检出及根工作区。

连接时先读 `GET /machine`。其余接口（包括 SSE）必须带 `X-Kite-Machine: <id>`：缺失返回 400，和服务身份不符返回 409，并在执行请求前拒绝。这个检查用于防止地址复用时操作错机器；远程网络认证仍待实现。App 会保存身份，重连时继续使用原 ID；CLI 在一次命令内固定目标 ID。

工作区聚合和线程上下文包含 `machine`，检出包含 `machineId`。目录流中的 `checkout.changed`、`workspace.changed`、`thread.changed` 通知客户端重新读取聚合；工作区操作和线程正文按各自范围订阅。SSE 广播本身不落库，每次重连用对应范围的完整快照替换客户端副本，再按记录 id 更新。harness 以 `sessions/<线程>/journal.jsonl` 为准，Claude 以自己的会话记录为准，快照以 Git 为准。SQLite 保存领域对象、窗口操作收据及 start / resume / files.select 操作请求与结果，不保存线程对话历史。cursor、流式草稿和 Claude 支持范围见 [会话显示协议](../docs/会话显示协议.md)。

## 测试

改完在仓库根目录跑 `.kite/check`：先同时做类型检查和 lint（`eslint.config.js`，只开 TypeScript 查不出来的两条 Promise 规则），`app/` 有改动时一起编译 App 的 Mac 和 iOS 两端，再只跑这次改动影响到的测试，加 `--all` 跑全量。测试规则在 `.claude/agents/test-writer.md`，测试由这个子 agent 按需求写。

- `test/small/`：小测试，直接调模块，git 在临时目录里跑，不起 Claude Code。
- `test/medium/`：中测试，起真实的 Claude Code，模型换成 `test/fake-api.ts` 的假端点，不耗额度；agent 靠消息里的指令（`RUN`、`PAR`、`CALL`、`BG`、`HOLD`）做确定的事。kited 经 `test/harness.ts` 在本进程里启动，这样依赖图看得到测试用了哪些源码。
- `test/setup.ts` 在所有测试之前把环境变量换成一套隔离的，并起一个共用的假端点。测试常在别的 Claude Code 会话里跑，不清掉的话，子进程会连到真实服务、读到真实设置。

小测试按文件并行跑，中测试按顺序跑。个数和耗时会随改动变，实测记录在 `spikes/check/README.md`。

修改领域 DTO 时，可在仓库根目录运行 `bun kited/test/contract/verify-remote-workspace-swift.ts`：启动临时 kited，用 App 的实际 Swift 类型解码 HTTP 聚合。它需要编译 Swift，作为手动协议检查，不计入 small 的耗时预算。

## 大测试清单

升级 SDK 或 Claude Code 之后，用真实订阅手动跑一遍。kited 要在干净的环境变量里启动，不继承当前 Claude Code 会话的 `CLAUDE_*` 变量；终端版 Claude Code 要先登录。

1. 登记一个普通文件夹，新建会话，让 agent 改一个文件：出现「工作区开始」和一枚改动快照，回合结束后进程关闭。
2. 会话记录里的系统提示有记忆段落，路径是工作树的 `.kite/memory/`；人发的消息带 `origin: human`。
3. 再发一条消息：进程重新 resume，记下从发消息到进程就绪、到首条回复各用多久。
4. 采纳：主文件夹出现改动，git 历史干净；然后归档。
5. 量一次会话的上下文（办法见「会话的上下文」）：`src/runner.ts` 里去掉的工具和 skill 名字还对得上，没有新冒出来的无关功能；Kite 的工具名不带 `mcp__` 前缀。

## 还没做的

- 个人偏好放哪：Kite 会话不读 `~/.claude` 的用户级配置，用户的个人偏好（比如回答用简体中文）和关于人的记忆要有 Kite 自己的位置，还没定。
- 权限：harness 已接共享沙箱、宿主文件授权检查与实例授权管理接口；App 编辑界面、独立终端授权编辑、Linux 实机验证、CPU 和内存配额仍待做。Git 元数据只读，合并冲突后的暂存与提交还需宿主操作入口，当前需用户在工作树内完成。现有停止确认针对进程组，尚不支持脱离进程组的后台任务。Claude 仍采用原有 bypassPermissions 执行路径，未接本沙箱。见 [执行边界](../docs/Agent与插件契约.md#71-插件与-harness-共用操作系统沙箱)。
- 对话回退、分叉，以及旧 Claude 完整历史的元数据、插话附件和子 agent 适配尚未完成。
- 多机集成（推送、被拒后重合）。第一阶段只有一台工作机。
- 采纳的提交说明现在用会话标题，以后让 agent 写。
- 二进制文件冲突让用户二选一，现在一律交给 agent。
- Claude：被打断的回合不触发 Stop 钩子，读不到收口清单，进程留着，直到下一回合正常结束。
- Claude：有定时任务时不关进程这一半没有测试：假端点驱动不了 CronCreate。
- Claude 消息可能丢：kited 和它起的 Claude Code 在同一刻被杀，而 Claude Code 还没把刚收到的消息写进会话记录时，这条消息就没了。重启后再发消息能正常续接，但丢的那条不会补发。要保证送达，得等 Claude Code 确认收到（SDK 回放的用户消息）才算投递完成，之前一直由 kited 保存。

补丁结果可携带 `diff: {id, paths}`；实际完成文件的前后内容保存于 `diffs/<workspaceId>/<diffId>.json`，`files.diff` 经实例授权读取。文件被再次修改或删除后仍可回看历史。引用格式与窗口边界见 [资源引用](../docs/资源引用.md)。

引用与浏览器导航的手动 Swift 合同：`bun kited/test/contract/verify-resource-reference-swift.ts`；真实补丁、journal 与 App 的字段链路沿用 `verify-transcript-swift.ts`。这些编译合同不计入 small 耗时预算。

## Bun 自定义插件

预构建单文件插件通过 `POST /plugin-definitions` 登记；可创建后台实例，经 MCP 调用工具、资源和宿主授权能力。插件与 harness 共用 OS 沙箱，实例状态和工具收据由宿主持久保存。通过 `operation-grants` 给新 agent 授权具体实例和工具后，宿主从 MCP 声明生成模型工具；首次请求固定目录，后续撤权立即阻止执行，并在下一次自然请求追加通知。`kited/examples/todo-plugin.ts` 提供待办样例。接口、停止及未知结果处理见 [Bun 插件宿主](../docs/Bun插件.md)。App Web 视图、插件安装界面和资源配额仍待接入。
