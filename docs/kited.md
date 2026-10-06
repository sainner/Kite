# 工作机：使用与服务契约

kited 在工作机上管理项目、工作区、会话和插件。本文面向使用服务和调用 HTTP 的人，说明运行入口、工作区操作及服务边界。对象职责见 [产品架构](产品架构.md)，工程入口见 [kited README](../kited/README.md)。新会话默认使用自研 harness 和 ChatGPT 订阅，也可选择 Claude。

## 终端试用

在 `kited` 目录运行，工作目录可以指定任意本地项目。先安装依赖并使用项目固定的 Bun（版本以依赖配置为准，`.kite/check` 自动选择）：

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

浏览器打开命令显示的地址并输入设备码。若 PATH 中的 `codex` 不可用，换成有效的 Codex 可执行文件路径。

harness 每次请求只读加载凭据，模型循环和工具执行不启动 Codex 或 Claude Code。自动刷新、系统钥匙串支持仍未接入；凭据过期或返回 401 时，在同一认证目录重新执行设备登录。无需 Platform API key。

可选型号见 [模型目录](../shared/agent-models.json)。用 `--model`、`--reasoning` 指定模型与推理强度，模型名也可通过 `KITE_MODEL` 设置。一次任务跑完就退出：

```bash
bun run harness --cwd /你的项目目录 --prompt "读取项目说明，概括目录结构"
```

启动时打印会话 id 和记录目录；退出后可以恢复，工作目录、模型配置与上下文随会话保留：

```bash
bun run harness --resume <会话id>
```

`--resume` 也接受启动时显示的会话记录目录绝对路径。恢复会话不能更换工作目录。

| 操作 | 行为 |
|---|---|
| 直接输入 | 空闲时开始新回合；执行中插话，在下一次模型请求纳入 |
| `/status` | 查看状态与上一回合结果 |
| `/stop` 或执行中按 Ctrl+C | 停止会话并退回队列，等待命令及其进程组停止 |
| `/resume` | 继续暂停的上下文 |
| `/recover` | 确认旧执行已经停止后解除恢复阻塞；仍需 `/resume` |
| `/exit` 或空闲时按 Ctrl+C | 停止执行、保存记录并退出 |

当前提供 `read`、`patch`、`shell`，参数、失败和取消语义见 [基础工具契约](harness-主循环.md#工具执行约定)。上下文的编辑与生效见 [上下文模板](harness-上下文组装.md)。

文件工具限制在工作目录内，shell 使用操作系统沙箱。默认工作区可读写、必要工具链可读、网络关闭；宿主凭据和内部记录受保护，Git 元数据只读。授权范围和平台限制见 [执行边界](Agent与插件契约.md#71-插件与-harness-共用操作系统沙箱)。独立终端尚无授权编辑入口，服务中的实例可在 App「执行授权」页编辑，见 [实例执行授权](实例操作.md#实例执行授权)。每回合的请求上限可用 `--max-requests` 调整，达到上限后等待显式继续。

这个终端入口直接修改指定目录。需要独立工作树、快照与采纳时，通过 kited 创建工作区。独立终端未接 agent 协作工具；harness 的 skill 自动发现、MCP 和上下文压缩仍待实现。

异常退出留下的 `lock/` 不会自动删除。先根据会话目录中的 `lock/owner.json` 与 `processes.json` 确认原进程及命令均已停止，再清理锁并重新打开。执行效果未知时先核查，不重放旧工具。

## 会话后端与宿主边界

自研 harness 与 Claude 各自负责完整 agent 循环，Kite 宿主负责工作区、共享工具、授权、快照与显示协议。执行进程关闭后会话仍可继续，两种后端保留各自的原生恢复记录。

agent 配置绑定到实例，重启沿用已保存内容。默认编程定义提供 read、patch、shell 及 agent 操作，只读审查定义提供 read；工具选择不能扩大授权。默认型号见 [共享模型目录](../shared/agent-models.json)，配置生效见 [线程通知投递](线程通知投递.md)，执行与恢复要求见 [harness 执行约定](harness-主循环.md) 和 [会话状态机](会话状态机.md)。

## 运行

### 轻任务与会话标题

轻任务用于标题等一次性文本生成，不提供工具、不创建线程、不写入主会话历史。辅助模型独立配置，统一使用工作机的 ChatGPT 授权；Claude 会话也由 Kite 生成标题，不依赖 Claude 登录。失败保留原题，不升级到主模型；日志不记录输入正文。

| 环境变量 | 用途 |
|---|---|
| `KITE_LIGHT_MODEL` | 选择轻任务模型，可用型号见 [共享模型目录](../shared/agent-models.json) |
| `KITE_LIGHT_REASONING` | 设置轻任务推理强度 |
| `KITE_LIGHT_TASKS` | 设为 `0` 关闭自动轻任务 |

首条消息接收后，以其文字作即时标题并开始生成。自动模式下，每次接收新消息都检查是否需要改名，不等待主会话完成、不定时扫描历史。默认命名要求是：工作方向转变或内容增加时更新，继续、追问或汇报进展且原题仍准确时保留。

材料来自近期用户请求与完成的回复，包括已接收的排队消息；不使用工具、思考及代码块。命名规则和材料使用可编辑的标题模板，每次生成读取最新保存内容，在途请求不受后续编辑影响。模板格式见 [上下文模板](harness-上下文组装.md)。

| 接口 | 请求与结果 |
|---|---|
| `GET /threads/:id/title` | 返回 `{title, mode, revision, generatedAt, through}`；后两项标识最近成功检查的时间与输入截止位置 |
| `PUT /threads/:id/title` | `{expectedRevision, mode: "manual", title}` 手动命名；`{expectedRevision, mode: "auto"}` 恢复自动并立即检查已接收消息 |
| `POST /threads/:id/title/regenerate` | `{expectedRevision}`，等待本次生成完成并返回标题快照；保持原 auto/manual 模式 |

标题须为 1～80 字符的单行文本。版本冲突返回 409。手动命名后停止自动覆盖，创建 agent 时显式给出的标题也视为手动命名。生成期间发生的改名或模式切换不能被旧结果覆盖；显式重生期间被其他操作改名则返回 409。生成失败保留原题与进度，后续新消息仍可触发检查。

显式重生不受相同消息位置的限制，使更早的在途标题结果失效。标题生成不打断或阻塞主会话控制。App 操作见 [标题、模型与状态](App.md#标题模型与状态)。

### 启动服务

macOS 用户级安装及登录自启使用仓库根目录的 `./install.command --service-only`，完整流程见 [macOS 安装与打包](macOS安装与打包.md)。以下命令供源码开发时前台运行：

```bash
cd kited && bun install
export PATH="$PWD/node_modules/.bin:$PATH"
bun src/main.ts
```

`KITE_HOME` 指定数据目录，默认 `~/.kite`；保存工作区、会话、登录及服务数据。`KITE_PORT` 默认是 5483，监听 127.0.0.1；组网与远程监听见下节。

同一数据目录重启或更换端口后，工作机身份保持不变；新数据目录生成新身份。名称初始取主机名，地址由客户端保存。项目关系通过稳定 ID 显式关联，不按文件夹名推断。

同一项目可以在本机或其他工作机登记多个检出。关联时提供完整项目身份 `{id, name, createdAt}`，关联后的目录属于同一项目，各自保有工作区。每台 kited 只保存本机的目录、工作区、线程与执行记录；关联不复制文件，不克隆或同步 Git 仓库。App 登记目录时可选择此前访问过的项目。

默认 harness 使用前文独立授权的 ChatGPT 凭据。只有 `claude` 会话需要 Claude 登录，开放范围见下文附加功能清单。Claude 会话不自动读取用户、项目或本地设置，OAuth 与钥匙串认证保留。

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
bun src/cli.ts net up              # 开启组网，首次按提示登录
bun src/cli.ts pair                # 生成远程设备的配对码
bun src/cli.ts devices             # 列出已配对设备
bun src/cli.ts revoke <设备>       # 撤销设备
```

## 远程连接

手机和其他电脑经内嵌组网节点连接工作机，无需另装 Tailscale 客户端，也不占用系统 VPN。链路加密由 WireGuard 承担，kited 负责设备认证。控制服务器默认使用 Tailscale；自建 headscale 时，kited 设置 `KITE_CONTROL_URL`，App 在连接页填写控制服务器。

- **组网。** `kite net up` 开启，`kite net` 查看状态，`kite net down` 停止并保留登录。首次按返回网址登录；headscale 的登录页可能要求在服务器执行注册命令。服务重启沿用开启状态和登录，密钥过期后重新登录。`GET /network` 与 `PUT /network {enabled}` 仅本机开放，返回 `{enabled, state, loginURL?, ips?, name?, address?, error?}`；上线后的 address 可交给远程设备。
- **headscale 管理密钥。** `kite net admin <API 密钥> [用户]` 校验并保存密钥，供工作机签发一次性入网密钥。入网密钥有效期 10 分钟。管理密钥仅本用户可读，不向插件或模型工具开放；Tailscale 官方服务不支持此入口。
- **配对。** 在工作机执行 `kite pair`，或本机 App 的「远程设备 → 添加设备」。配对码为 8 位，10 分钟内有效、仅用一次，服务重启后失效。组网上线后可生成 `kite://pair?address=…&code=…&control=…&key=…` 邀请：控制服务器和入网密钥按需提供。iPhone 扫码后连接；未提供入网密钥时首次连接需浏览器登录。邀请相当于一次性密码，只在本机显示。远程客户端以 `POST /pair {code, name}` 换取 `{machine, device, token}`。
- **认证。** 远程监听除 `/pair` 外的接口（含 `/machine` 和 SSE）均需 `Authorization: Bearer <token>`；机器身份头另按下文接口规则发送。每台设备的令牌持续有效，直到撤销；缺失或撤销返回 401。配对码生成、设备列表和撤销仅本机开放，远程设备不能管理令牌。App 将令牌保存在本机钥匙串。
- **撤销与恢复。** `kite revoke <设备>` 或 App 撤销后，已有事件流立即断开，后续请求返回 401。网络错误和服务重启可重连；401 停止自动重试并提示重新配对，409 表示地址背后的工作机不符。同一机器地址变化时保留身份和令牌，只更新地址。App 回到前台后重新连接。

本机接口与远程认证边界见 [接口](#接口)，SSE 重连见 [会话显示协议](会话显示协议.md#历史与连接)。iPhone 真机经组网连接的完整验收尚未完成。

## 工作区与线程的生命周期

| 操作 | 行为与限制 |
|---|---|
| 登记检出 | 新建或显式关联项目，建立直接使用登记目录的根工作区，不创建线程。已有 Git 仓库由用户管理提交；普通文件夹由 Kite 初始化并代管提交 |
| 创建独立工作区 | 从检出当前 HEAD 建立独立工作树；Kite 代管提交时先保存主目录改动。可以先建空工作区，也可在准备完成后运行首条消息 |
| 添加线程 | 根工作区和独立工作区都可有多个线程，各自保存对话；当前同一 cwd 有执行或恢复阻塞时，不能启动另一线程 |
| 快照与回退 | 每批工具后与回合结束时保存变更，快照不改变 HEAD、分支或暂存区。回退先保存现状，再恢复文件；执行或恢复阻塞期间不允许回退 |
| 采纳 | 将独立工作区改动合回检出主线。同一检出的采纳串行执行，冲突留在独立工作树；采纳后工作区与线程仍可继续使用 |
| 归档线程 | 停止该线程，保留工作区、文件、其他线程和快照 |
| 归档工作区 | 停止所有线程、保存最后快照，回收独立工作树和分支，归档实例并关闭共享窗口。未采纳改动须显式 `force`；根工作区不能通过此操作删除 |

工作树准备可用 `worktree.symlinkDirectories` 链接依赖目录，用 `.worktreeinclude` 带入指定的忽略文件；随后运行项目的 `.kite/setup`，通过 `KITE_MAIN_DIR` 提供检出目录。准备失败或被打断时工作区为 `failed`；成功后保存初始快照并开放使用。准备中的首个线程被打断也会中止初始化。

采纳冲突交给独立工作区中的一个打开线程处理，主目录不进入冲突状态。agent 仅编辑文件，Git 合并由宿主完成；解决回合正常完成后自动重试一次，仍有冲突则报告，等待用户手动重试。

发送、停止、队列退回和恢复属于线程控制，见 [会话状态机](会话状态机.md)。回退只恢复文件，不回退或分叉对话历史。

## Claude 会话的上下文

Claude 负责模型循环与原生对话恢复；Kite 负责工具、项目上下文、授权、工作区与快照。Claude 从空工具集接入，只开放实例配置与授权允许的 Kite 工具，以及显式授权的插件工具，不自动加载用户或项目中的 MCP、skills 和设置。

内置 Claude 定义提供 `read`、`patch`、`shell` 与五个 agent 操作，默认仅能管理自己创建的 agent。基础工具共用 [工具契约](harness-主循环.md#工具执行约定)，协作与授权共用 [实例操作](实例操作.md)，显示名称使用 Kite 短名称。工具执行完成并保存快照后才能继续模型请求。

模型、工具、基础上下文与请求预算绑定到实例；`KITE_CLAUDE_MODEL` 可覆盖创建时的模型。配置和执行授权须在空闲且无恢复阻塞时修改；可选型号与思考档位通过能力接口获取。项目规则与记忆索引仅由 Kite 的模板提供，Claude 不自行扫描。具体生效时机见 [线程通知投递](线程通知投递.md#claude-的交接边界)。

运行中插话沿用 Claude 原生输入队列，在自然请求边界纳入，不要求等整轮结束。发送确认、撤回、停止与异常恢复遵守 [会话状态机](会话状态机.md#手动停止与消息交接)；已有原生记录不能重复投递，未知执行效果不能自动重放。

App、HTTP 和 CLI 的显示与控制能力见 [会话显示协议](会话显示协议.md#当前边界)。搜索网页、定时任务、原生 Claude 子 agent 和附件尚未开放。Kite 工具受沙箱限制不表示整个 Claude SDK 进程已被隔离。

### 附加功能清单

以下边界只作用于 Kite 创建的 Claude 进程，不改变用户单独使用 Claude Code 的设置。新建和原生恢复须保持同一边界；具体开关与锁定依赖以 [Claude 配置](../kited/src/claude/options.ts) 和 [依赖配置](../kited/package.json) 为准。

| 能力 | 职责与开放范围 |
|---|---|
| 基础提示、日期、环境、模型与技能说明 | 由 Kite 模板提供；关闭 Claude 默认提示与可关闭的自动附加内容 |
| 项目指令、hooks、记忆和后台整理 | 不自动加载用户、项目或本地配置；仅使用 Kite 显式提供的材料与回调 |
| 上下文压缩与文件检查点 | 关闭 Claude 的自动行为；文件快照由 Kite 负责，长上下文压缩尚未接入 |
| 工具、技能、命令、子 agent 与插件 | 仅开放宿主明确接入的能力；不继承用户和项目插件 |
| 后台任务、定时、工作流与自动续跑 | 关闭，不因通知、额度恢复或中断回合自行启动工作 |
| 外部连接与同步 | 关闭自动 IDE、浏览器、Remote Control、channels、会话上传及云端同步 |
| 标题、通知、建议、遥测与更新 | 关闭重复及非必要行为；会话标题由 Kite 负责 |
| 登录、模型循环、原生历史与恢复 | 保留上游能力，不自行重做 |

提示过滤不是可靠的隔离层：上游加载或处理失败时可能回退到原始内容。SDK 固定身份文本及 billing header 没有公开关闭入口；服务端插入的额度提示无法靠客户端保证移除；组织管理配置仍由上游读取。模型循环为处理截断和错误工具调用产生的恢复消息也保留。不能把初始化事件或替换系统提示视为“零注入”的证明。

升级时须检查实际模型请求，验收要求见 [大测试清单](#大测试清单)。需要重新评估上游入口时查 [SDK 系统提示与附件](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts)、[配置来源边界](https://code.claude.com/docs/en/agent-sdk/claude-code-features#what-settingsources-does-not-control)、[环境变量](https://code.claude.com/docs/en/env-vars) 与 [mods 接口](https://code.claude.com/docs/en/plugins/mods/reference)。

## 项目检查

harness 与 Claude 均通过共享 shell 执行项目的 `.kite/check`。项目检查入口与输出约定见 [kited README](../kited/README.md#检查与测试)，不另设模型专用检查工具。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/machine` | 读取这台工作机服务的持久身份，无需 `X-Kite-Machine`；远程监听需带令牌 |
| POST | `/pairings` | 仅本机：生成配对码，返回 `{code, expiresAt, address, invite}`；组网未上线时 `address`、`invite` 为 null |
| PUT | `/network/admin` | 仅本机：`{apiKey, user}` 校验并保存 headscale 管理密钥 |
| GET/PUT | `/network` | 仅本机：组网状态；`{enabled}` 开启或关闭组网节点 |
| GET | `/devices` | 仅本机：列出已配对设备 `{id, name, createdAt, lastSeenAt}` |
| DELETE | `/devices/:id` | 仅本机：撤销设备并断开它的事件流 |
| POST | `/pair` | 仅远程，无需令牌：`{code, name?}` 换取 `{machine, device, token}`，配对码无效返回 401 |
| GET | `/projects` | 列出本机已登记的项目身份 |
| GET/POST | `/checkouts` | 列出本机检出（`?project=`）；登记 `{path, project?}`，返回根工作区聚合 |
| GET/POST | `/workspaces` | 列出聚合（`?project=`），响应头 `X-Kite-Cursor` 标识列表版本；创建 `{checkout, name?, prompt?, runtime?, contextTemplate?}`，准备过程看事件 |
| GET | `/workspaces/:id` | 工作区上下文及 instances、threads、windows 的完整聚合 |
| GET / POST | `/plugin-definitions` | 读取定义或登记自定义包；包格式见 Bun 插件契约 |
| GET | `/operations` | 操作输入、输出、错误 schema，以及重试与取消规则 |
| POST | `/workspaces/:id/operations/:operation` | 调用 agent.start / list / send / resume / stop 或 files.list / read / state / select；修改操作必须带 operationId |
| GET | `/instances/:id/agent-capabilities` | 模型与思考档位、工具选择及配置生效边界；不发模型请求 |
| GET / PUT | `/instances/:id/agent-config` | 读取绑定配置及 revision；以 expectedRevision 和完整 agent 配置更新 |
| GET / POST | `/context-templates` | 列出创建会话、标题及四类通知模板和场景变量；以 `{definition}` 新建创建会话模板 |
| PUT | `/context-templates/:id` | 以 `{expectedRevision, definition}` 更新模板；不修改已有实例 |
| PUT | `/instances/:id/context-template` | 以 `{expectedRevision, templateId, templateRevision}` 为实例绑定模板内容；保留其他配置 |
| GET / PUT | `/threads/:id/title` | 读取标题与生成进度；以 expectedRevision 手动改名或恢复自动标题 |
| POST | `/threads/:id/title/regenerate` | 以 expectedRevision 立即重新生成标题，等待结果；不阻塞主会话控制 |
| GET / PUT | `/instances/:id/execution-grants` | 读取或修改执行授权；须停止且无恢复阻塞 |
| GET / PUT | `/instances/:id/operation-grants` | 读取实例操作授权及 revision；以 expectedRevision 和 grants 更新 |
| POST | `/workspaces/:id/windows` | 创建实例及默认窗口，或打开已有实例视图；请求使用稳定 id |
| DELETE | `/workspaces/:id/windows/:window` | 关闭共享窗口；最后窗口按插件生命周期回收实例或保留 |
| POST | `/workspaces/:id/threads` | 在已有工作区创建线程 `{prompt, runtime?, contextTemplate?}`，默认 harness；模板选择为 `{id, revision}` |
| GET | `/threads/:id` | 线程和上下文，附带 `runner`、`busy` |
| GET | `/threads/:id/state` | 只读执行与恢复状态，不启动模型 |
| GET | `/threads/:id/history` | v1 显示历史、pending、state 和 cursor，只读 |
| POST | `/threads/:id/messages` | 发消息 `{text, id?}`，返回 `{id}`；harness 落盘后确认，同 id 和内容去重 |
| POST | `/threads/:id/messages/:message/cancel` | 按后端能力撤回尚未交接的输入 |
| POST | `/threads/:id/interrupt` | 停止会话，返回尚未纳入请求的队列；请求 `{id, inputs?}`，响应 `{returned}` |
| POST | `/threads/:id/resume` | 继续暂停的线程；可带 operationId 以安全重试 |
| POST | `/threads/:id/recover` | 确认恢复，不自动执行 |
| POST | `/threads/:id/archive` | 归档线程，保留所属工作区 |
| GET | `/workspaces/:id/snapshots` | 工作区快照，新的在前 |
| POST | `/workspaces/:id/restore` | 恢复文件到快照 `{commit}` |
| POST | `/workspaces/:id/adopt` | 合回主线，返回 `adopted` 或 `conflict` |
| POST | `/workspaces/:id/archive` | 归档独立工作区 `{force?}` |
| GET | `/events` | 目录 SSE：首帧 `catalog.snapshot`，随后检出、工作区和线程概要变更 |
| GET | `/events?workspace=<id>` | 工作区 SSE：首帧 `workspace.model`，随后工作区操作与所属线程概要 |
| GET | `/events?thread=<id>` | 线程 SSE：首帧 `thread.history`，随后线程显示与状态事件 |

窗口创建请求为 `{id, content: {kind: "create", definitionId}}`；打开已有视图为 `{id, content: {kind: "open", instanceId, viewId}}`。`id` 使用 UUID。内置 agent 提供 `conversation`，文件提供 `files`，终端占位提供 `terminal`；文件视图包含预览。新建的空 agent 不调用模型；目标实例须属于当前工作区且处于可用状态，视图须由定义声明。

窗口响应包含 `{id, workspaceId, target: {instanceId, viewId}, state, createdAt}`。同一请求 ID 重试返回原结果，内容改变或窗口已关闭时拒绝，迟到重试不会复活窗口。实例回收与跨端布局的完整规则见 [Agent 与插件契约](Agent与插件契约.md#34-workspacewindow实例的一种呈现)。

`/threads/:id` 使用 agent 实例 ID；原生后端 ID 不用于此接口。工作区聚合包含所属实例、线程与共享窗口，具体类型见 [领域模型](../kited/src/model.ts)。实例操作的参数、授权和收据统一见 [实例操作](实例操作.md)，文件引用见 [资源引用](资源引用.md)。

`POST /checkouts` 的 `project` 为 `{id, name, createdAt}`，可直接使用另一台工作机返回的项目身份；省略则创建新项目。同 ID 的名称或创建时间冲突、已登记目录试图改属另一项目时返回 409，在修改目录之前拒绝。重复登记同一目录和项目返回原检出及根工作区。

连接时先读 `GET /machine`。其余接口（包括 SSE）必须带 `X-Kite-Machine: <id>`：缺失返回 400，和服务身份不符返回 409，并在执行请求前拒绝。这个检查用于防止地址复用时操作错机器，不承担认证。本机监听的接口只接受 `Host` 为 `127.0.0.1` 或 `localhost` 的请求，其他主机名返回 403，用于阻止网页借 DNS 重绑定访问本机服务；远程监听改用配对令牌认证，见[远程连接](#远程连接)。App 会保存身份，重连时继续使用原 ID；CLI 在一次命令内固定目标 ID。

工作区聚合和线程上下文包含 `machine`，检出包含 `machineId`。SSE 按目录、工作区和线程分别订阅，每次重连从完整快照恢复；事件、游标与流式内容统一见 [会话显示协议](会话显示协议.md)。

## 验证入口

项目测试规则以 [AGENTS.md](../AGENTS.md#测试) 为准，构建与检查命令见 [kited README](../kited/README.md)，Swift、WebKit 和原生运行时的手动验证见 [手动验证入口](../kited/test/manual/README.md)。测试次数与耗时属于当次证据，不在本文维护。

## 大测试清单

升级 SDK 或 Claude Code 之后，用真实订阅手动跑一遍。kited 要在干净的环境变量里启动，不继承当前 Claude Code 会话的 `CLAUDE_*` 变量；终端版 Claude Code 要先登录。

1. 在 App 新建 Claude 实例，让它读取、修改文件并通过 shell 执行项目检查：工具行实时更新，出现工作区快照，patch 的历史引用在恢复后仍可打开。正常回复后进程关闭，实际模型请求只有实例配置和授权开放的 Kite 工具。
2. 检查发给模型的实际请求，不能只看 SDK 消息流：首轮、工具调用后与原生恢复只能带入 Kite 模板明确提供的上下文，不自动附加 Claude 的日期、环境、模型说明、技能、项目指令或自动记忆。单独验证高用量时的提醒，区分客户端与服务端注入。人发的消息仍带 `origin: human`，宿主工具和回调可用。
3. 再发一条消息：进程重新 resume，记下从发消息到进程就绪、到首条回复各用多久。
4. 归档：工作树被回收，线程历史仍可查看。
5. 核对新建和恢复后的工具集合；默认是 read / patch / shell 和五个 agent 操作工具，项目 `.mcp.json` 不自动增加能力。撤回操作或插件授权后执行被拒绝，新增插件授权在下次空闲后启动进程时生效。验证排队取消、停止退回、模型及上下文更新，以及异常退出后的确认恢复。

## 当前能力边界

远程连接需要组网，iPhone 真机经组网连接的完整验收尚未完成。Linux 沙箱实机验证、资源配额、独立终端授权编辑和脱离进程组的后台任务尚未完成；Git 元数据只读，不能假设模型工具可直接暂存或提交。文件快照回退已提供，会话历史的回退与分叉尚未提供。

持续待办、待验证事项和候选产品决定已归入 [项目记忆](../.kite/memory/MEMORY.md)，不在本文重复维护排期。Claude 原生能力的开放范围以本文专节和当前接入决定为准。

## Bun 自定义插件

自定义插件使用预构建 Bun 包，提供 MCP 工具、资源和 App Web 视图。安装、模型授权、停止与未知结果处理见 [Bun 插件宿主](Bun插件.md)，共享身份与生命周期见 [Agent 与插件契约](Agent与插件契约.md)。
