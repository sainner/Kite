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

当前提供 `read`、`patch`、`shell`、`credentials`，参数、失败和取消语义见 [基础工具契约](harness-主循环.md#工具执行约定)。上下文的编辑与生效见 [上下文模板](harness-上下文组装.md)。

文件工具限制在工作目录内，shell 使用操作系统沙箱。默认工作区可读写、必要工具链可读、网络关闭；宿主凭据和内部记录受保护，Git 元数据只读。授权范围和平台限制见 [执行边界](Agent与插件契约.md#71-插件与-harness-共用操作系统沙箱)。独立终端尚无授权编辑入口，服务中的实例可在 App「执行授权」页编辑，见 [实例执行授权](实例操作.md#实例执行授权)。每回合的请求上限可用 `--max-requests` 调整，达到上限后等待显式继续。

这个终端入口直接修改指定目录。需要独立工作树、快照与采纳时，通过 kited 创建工作区。独立终端未接 agent 协作工具与账号凭据服务；harness 的 skill 自动发现和 MCP 仍待实现；上下文压缩只有自动触发，没有手动入口。

异常退出留下的 `lock/` 不会自动删除。先根据会话目录中的 `lock/owner.json` 与 `processes.json` 确认原进程及命令均已停止，再清理锁并重新打开。执行效果未知时先核查，不重放旧工具。

## 会话后端与宿主边界

自研 harness 与 Claude 各自负责完整 agent 循环，Kite 宿主负责工作区、共享工具、授权、快照与显示协议。执行进程关闭后会话仍可继续，两种后端保留各自的原生恢复记录。

会话可通过 `/instances/:id/agent-config` 更换 `agent.runtime` 及对应模型，保留实例、窗口和其他配置；能力目录按实例当前后端返回。`state.capabilities.switchRuntime` 表示当前能否切换：须空闲、没有排队或交接未确认的输入、没有恢复阻塞，否则返回 409。服务端在同一控制队列中检查状态、交接上下文并保存后端与配置。

切换在回合边界交接上下文。两种后端在线程内各保留一份原生记录；切换时把来源后端自上次交接以来产生的内容翻译后追加到目标后端的记录，并标明来源位置。已有记录不改写，重复切换不重复导入，翻译失败时不切换。harness 一侧在上次交接之后压缩或撤销过压缩时，改为整体重组 Claude 会话：在会话文件末尾追加压缩分界与按 harness 当前上下文合成的完整历史，原条目留作显示，Claude 从分界之后接续。人发消息、Kite 通知、助手文字、工具调用与结果及图片按目标后端的原生形态交接；推理内容只保留在产生它的后端记录中，不跨厂商传递，提示缓存在切换后重新建立。历史显示按段拼接两份记录，每段只取自产生它的后端，显示记录不作为原生恢复数据。Claude 会话文件的合成依赖锁定版本 CLI 的内部格式，升级 SDK 时按 [实验记录](research/2026-10-08-跨后端上下文翻译.md) 重新验证。

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

显式重生不受相同消息位置的限制，使更早的在途标题结果失效。标题生成不打断或阻塞主会话控制。

### 模板点阵签名

每个创建会话模板有一枚点阵签名，App 在新会话的空白内容区按它铺满动画。签名是 `{expression, positive, negative, form}`：一行算式，客户端每帧对每格求值，结果截到 −1～1，绝对值为点的大小、正负选 `positive` 或 `negative` 颜色（参考色板字母 `B M L Y D`），`form` 为点的终态形状。算式只解析求值、不执行代码，语法以 `kited/src/emblem-expression.ts` 为准，App 的 `DotExpression.swift` 与之保持一致。

模板保存后用轻任务按模板正文生成，提示词是可编辑的「点阵签名」模板。回复不可用时附上原因重试一次，仍失败记为 `failed`，客户端沿用默认图案。手改的签名不被自动生成替换，只有 `force` 重新生成会覆盖；生成期间发生的手改也不会被在途结果覆盖。模板列表中创建会话模板带 `emblem`、`emblemState`（`ready`、`stale`、`missing`、`generating`、`failed`）与失败时的 `emblemError`；`stale` 表示模板内容已变、签名尚未更新。模板或签名状态变化时，目录事件流推送 `context-templates.changed`，客户端据此重新读取模板列表。

### 启动服务

macOS 用户级安装及登录自启使用仓库根目录的 `./install.command --service-only`，完整流程见 [macOS 安装与打包](macOS安装与打包.md)。以下命令供源码开发时前台运行：

```bash
cd kited && bun install
export PATH="$PWD/node_modules/.bin:$PATH"
bun src/main.ts
```

`KITE_HOME` 指定数据目录，默认 `~/.kite`；保存工作区、会话、登录及服务数据。`KITE_PORT` 默认是 5483，监听 127.0.0.1；组网与远程监听见下节。

同一数据目录重启或更换端口后，工作机身份保持不变；新数据目录生成新身份。名称初始取主机名，地址由账号目录发现并在客户端缓存。

项目以远程仓库为身份，项目 ID 由账号服务的项目登记表分配，规格见 [项目与远程仓库](项目与远程仓库.md)。登记检出要求工作机已加入 Kite 账号，否则返回 409。同一远程在本机或其他工作机的多个检出自动归入同一项目，各自保有工作区。每台 kited 只保存本机的目录、工作区、线程与执行记录。

默认 harness 使用前文独立授权的 ChatGPT 凭据。只有 `claude` 会话需要 Claude 登录，开放范围见下文附加功能清单。Claude 会话不自动读取用户、项目或本地设置，OAuth 与钥匙串认证保留。

命令行是薄客户端：

```bash
bun src/cli.ts add ~/thesis        # 登记本机文件夹，返回检出 id
bun src/cli.ts clone github.com/me/thesis  # clone 远程到 ~/code/github.com/me/thesis 并登记
bun src/cli.ts checkouts <项目>    # 列出该项目在本机的检出
bun src/cli.ts new <检出> "把第二章的图注统一成中文"
bun src/cli.ts send <线程> "再检查一遍参考文献"
bun src/cli.ts resume <线程>       # 继续暂停的上下文
bun src/cli.ts snapshots <工作区>
bun src/cli.ts restore <工作区> <快照>
bun src/cli.ts adopt <工作区>       # 合回主线并推送
bun src/cli.ts push <检出> "提交说明"  # 提交现场改动并推送
bun src/cli.ts archive <工作区>
bun src/cli.ts net up              # 开启已登录设备的组网
```

## 远程连接

Kite 托管账号与组网。Mac 和 iPhone 在 App 中使用账号密码登录，或扫描已登录设备的一次性二维码。两种 Mac 角色都入网，同账号设备可直接控制工作机；账号、设备发现与撤销的完整约定见 [托管账号与设备](托管账号与设备.md)。

工作机由 kite-net（tsnet）接入网络，控制端由 App 内的 TailscaleKit 接入，不占用系统 VPN。本机执行模式的 App 复用 kited 的 SOCKS 入口，只维护一个网络节点。链路加密由 WireGuard 承担，Headscale 策略限制同账号互通；kite-net 还通过 WhoIs 核验请求来源与本节点属于同一用户。内部代理使用进程内随机凭据，外部传入的同名字段被覆盖。

`kite net` 查看状态及各对端是直连还是经中继；已登录后可用 `kite net up`、`kite net down` 开启或暂停组网。新设备的入网密钥来自账号服务，工作机不保存 Headscale 管理密钥。移除设备会撤销其网络节点和账号会话；已有远程请求随撤销传播而关闭。网络错误和服务重启可以重连，401 提示重新登录，409 表示目标工作机身份不符。

本机接口边界见 [接口](#接口)，SSE 重连见 [会话显示协议](会话显示协议.md#历史与连接)。原生 iPhone 的新账号流程、前后台重连和蜂窝网络仍需真机验收。

## 工作区与线程的生命周期

| 操作 | 行为与限制 |
|---|---|
| 登记检出 | 按目录的 origin 归入项目，建立直接使用登记目录的根工作区，不创建线程。没有 origin 时建托管远程并推送，普通文件夹先由 Kite 初始化仓库并提交初始版本 |
| 创建独立工作区 | 从检出当前 HEAD 建立独立工作树；现场未提交的改动不带入，也不由 Kite 代为提交。可以先建空工作区，也可在准备完成后运行首条消息 |
| 添加线程 | 根工作区和独立工作区都可有多个线程，各自保存对话；当前同一 cwd 有执行或恢复阻塞时，不能启动另一线程。App 的新会话草稿只在本机，第一条消息连同所选定义、后端、模型和模板一次创建实例、线程与窗口 |
| 快照与回退 | 每批工具后与回合结束时保存变更，快照不改变 HEAD、分支或暂存区。回退先保存现状，再恢复文件；执行或恢复阻塞期间不允许回退 |
| 采纳（集成） | 将独立工作区改动合回检出主线并推送到远程。现场有未提交的改动或不在分支上时拒绝。同一检出的采纳串行执行，冲突留在独立工作树；采纳后工作区与线程仍可继续使用 |
| 现场提交并推送 | 由用户触发，把现场改动提交后推送。远程领先而现场没有新内容时快进；两边都有新内容时拒绝，提示新建工作区集成 |
| 归档实例 | 停止该实例的执行并关闭它的窗口，保留会话、业务数据、工作区和快照；随窗口回收的实例关闭窗口即可，不提供归档 |
| 归档工作区 | 停止所有线程、保存最后快照，回收独立工作树和分支，归档实例并关闭共享窗口。未采纳改动须显式 `force`；根工作区不能通过此操作删除 |

工作树准备可用 `worktree.symlinkDirectories` 链接依赖目录，用 `.worktreeinclude` 带入指定的忽略文件；随后运行项目的 `.kite/setup`，通过 `KITE_MAIN_DIR` 提供检出目录。准备失败或被打断时工作区为 `failed`；成功后保存初始快照并开放使用。准备中的首个线程被打断也会中止初始化。

采纳先拉取远程主线，把本地主线和远程主线依次合进工作区分支，主目录快进后推送；推送被拒时重新拉取、合并再推，最多三次。拉取或推送失败不撤销本地主线，结果中的 `push` 报告失败原因，下次采纳或现场推送时一并推上去。采纳冲突交给独立工作区中的一个打开线程处理，主目录不进入冲突状态。agent 仅编辑文件，Git 合并由宿主完成；解决回合正常完成后自动重试一次，仍有冲突则报告，等待用户手动重试。

发送、停止、队列退回和恢复属于线程控制，见 [会话状态机](会话状态机.md)。回退只恢复文件，不回退或分叉对话历史。

## Claude 会话的上下文

Claude 负责模型循环与原生对话恢复；Kite 负责工具、项目上下文、授权、工作区与快照。Claude 从空工具集接入，只开放实例配置与授权允许的 Kite 工具，以及显式授权的插件工具，不自动加载用户或项目中的 MCP、skills 和设置。

内置 Claude 定义提供 `read`、`patch`、`shell` 与五个 agent 操作，默认仅能管理自己创建的 agent。基础工具共用 [工具契约](harness-主循环.md#工具执行约定)，协作与授权共用 [实例操作](实例操作.md)，显示名称使用 Kite 短名称。工具执行完成并保存快照后才能继续模型请求。

模型、工具、基础上下文与请求预算绑定到实例；`KITE_CLAUDE_MODEL` 可覆盖创建时的模型。配置和执行授权须在空闲且无恢复阻塞时修改；可选型号与思考档位通过能力接口获取。项目规则与记忆索引仅由 Kite 的模板提供，Claude 不自行扫描。具体生效时机见 [线程通知投递](线程通知投递.md#claude-的交接边界)。

Claude Code 进程随实例常驻：首次需要时启动，回合结束后不退出，在实例归档、切换后端、手动停止或 kited 退出时结束；回合之间意外退出的，下一条消息到来时恢复原生会话。运行中插话沿用 Claude 原生输入队列，在自然请求边界纳入，不要求等整轮结束。发送确认、撤回、停止与异常恢复遵守 [会话状态机](会话状态机.md#手动停止与消息交接)；已有原生记录不能重复投递，未知执行效果不能自动重放。

App、HTTP 和 CLI 的显示与控制能力见 [会话显示协议](会话显示协议.md#当前边界)。搜索网页、定时任务、原生 Claude 子 agent 和附件尚未开放。Kite 工具受沙箱限制不表示整个 Claude SDK 进程已被隔离。

### 附加功能清单

以下边界只作用于 Kite 创建的 Claude 进程，不改变用户单独使用 Claude Code 的设置。新建和原生恢复须保持同一边界；具体开关与锁定依赖以 [Claude 配置](../kited/src/claude/options.ts) 和 [依赖配置](../kited/package.json) 为准。

| 能力 | 职责与开放范围 |
|---|---|
| 基础提示、日期、环境、模型与技能说明 | 由 Kite 模板提供；关闭 Claude 默认提示与可关闭的自动附加内容 |
| 项目指令、hooks、记忆和后台整理 | 不自动加载用户、项目或本地配置；仅使用 Kite 显式提供的材料与回调 |
| 上下文压缩与文件检查点 | 关闭 Claude 的自动行为；文件快照与上下文压缩由 Kite 负责，Claude 线程在回合之间重组会话，见 [上下文压缩](harness-主循环.md#上下文压缩) |
| 工具、技能、命令、子 agent 与插件 | 仅开放宿主明确接入的能力；不继承用户和项目插件 |
| 后台任务、定时、工作流与自动续跑 | 关闭，不因通知、额度恢复或中断回合自行启动工作 |
| 外部连接与同步 | 关闭自动 IDE、浏览器、Remote Control、channels、会话上传及云端同步 |
| 标题、通知、建议、遥测与更新 | 关闭重复及非必要行为；会话标题由 Kite 负责 |
| 登录、模型循环、原生历史与恢复 | 保留上游能力，不自行重做 |

提示过滤不是可靠的隔离层：上游加载或处理失败时可能回退到原始内容。SDK 固定身份文本及 billing header 没有公开关闭入口；服务端插入的额度提示无法靠客户端保证移除；组织管理配置仍由上游读取。模型循环为处理截断和错误工具调用产生的恢复消息也保留。不能把初始化事件或替换系统提示视为“零注入”的证明。

升级时须检查实际模型请求，验收要求见 [大测试清单](#大测试清单)。需要重新评估上游入口时查 [SDK 系统提示与附件](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts)、[配置来源边界](https://code.claude.com/docs/en/agent-sdk/claude-code-features#what-settingsources-does-not-control)、[环境变量](https://code.claude.com/docs/en/env-vars) 与 [mods 接口](https://code.claude.com/docs/en/plugins/mods/reference)。

## 项目检查

harness 与 Claude 均通过共享 shell 执行项目的 `.kite/check`。项目检查入口与输出约定见 [kited README](../kited/README.md#检查与测试)，不另设模型专用检查工具。

## 模型账号与额度

额度查询只使用工作机本身持有的授权，不登录、不续期、不分发模型凭据，也不发送模型请求。ChatGPT 使用前文的 Kite 专用认证目录；Claude 使用 Claude Code 原生登录存储（包括 macOS 钥匙串与显式指定的配置目录），或 `CLAUDE_CODE_OAUTH_TOKEN`。缺失和过期凭据分别返回未配置和需要重新授权，不借用日常 Codex 的登录。

App 的订阅登录由所选工作机执行原生登录工具，凭据不经过 App 或账号服务：ChatGPT 复用 [官方设备码登录](https://developers.openai.com/codex/auth)，写入 Kite 专用认证目录；Claude 复用 [原生 `auth login --claudeai`](https://code.claude.com/docs/en/cli-reference)，保留 Claude 自身的凭据存储。工作机须有可用的 Codex CLI；Claude 登录工具随固定版本的 Agent SDK 提供。登录完成不等于额度接口必定可用，额度查询失败单独显示。

| 方法与路径 | 调用约定 |
|---|---|
| `POST /subscription-logins` | `{id, provider}`，`id` 为客户端生成的 UUID，`provider` 为 `chatgpt` 或 `claude`；同 ID 幂等，同供应商已有活动登录时返回 409 |
| `GET /subscription-logins/:id` | 返回 `status`（`starting`、`waiting`、`complete`、`failed`、`cancelled`、`expired`）、`expiresAt`（Unix 秒）、`acceptsCode`，以及可选的官方授权 `url`、ChatGPT `userCode`、错误 `message`；不返回令牌或原始工具输出，服务重启后返回 404 |
| `POST /subscription-logins/:id` | `{code}` 提交 Claude 的单行授权码，最多 4096 字符；不接受输入的状态返回 409，格式错误返回 400 |
| `DELETE /subscription-logins/:id` | 幂等取消指定登录并结束等待中的进程；先取消后迟到的启动也不会创建进程；不撤销已完成的订阅授权 |

这些接口沿用工作机身份与同账号组网鉴权。弹窗关闭时取消登录，超时十分钟或服务正常关闭时也结束等待。自动续期仍未接入。


API 账号来自 Kite 账号中保存的 API 凭据（见 [凭据服务](托管账号与设备.md#凭据服务)），每把 Key 一个账号，`id` 为 `api:<凭据ID>`，`identity` 为用户起的名称；每次查询前重新领取；领取失败时无法得知有哪些账号，改为返回一条 `id` 为 `account-api`、状态为 `unavailable` 的账号说明原因。工作机还没加入 Kite 账号时不领取。kited 进程环境中的 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`DEEPSEEK_API_KEY` 与组织管理凭据 `OPENAI_ADMIN_KEY`、`ANTHROPIC_ADMIN_KEY` 另作为本机账号查询，`id` 为 `<供应商>-api`，未设置时不列出。查询 OpenAI、Anthropic 的组织费用需要管理 Key。账号读取不代表该 API 已被配置为会话的模型后端。

额度不由客户端轮询，打开账号页也不查询。kited 在内存中保留本机最新的账号快照：首个客户端订阅目录事件流时，若还没有查询过就查询一次上游；之后只在显式刷新时查询。会话响应带回的额度按观测时间覆盖对应周期；查询结果到达之前，快照只含会话观测到的订阅账号及其周期：Claude 取 SDK `rate_limit_event` 中的 5 小时与每周周期，ChatGPT 取订阅响应头中的主要、次要周期与 credits。按模型分开的周额度、ChatGPT 附加额度和 API 费用/余额没有会话来源，保留上次查询结果。刷新时某个账号暂时查询失败（限流、超时、服务错误等，状态为 `unavailable`），该账号沿用上次查询结果与会话观测，只更新状态与提示；未登录或需要重新授权时不沿用。快照变化时在目录事件流推送 `model-accounts.changed`（`modelAccounts` 字段），目录首帧 `catalog.snapshot` 也带当前快照，缓存为空时为 `null`。

`GET /model-accounts` 返回当前快照，缓存为空时先查询；`POST /model-accounts/refresh` 立即查询上游，进行中的查询会被复用，结果同时经事件流推送。二者都要求工作机身份与同账号访问授权，返回 `{checkedAt, accounts}`，`checkedAt` 是快照中最新数据的观测时间。每个账号包含 `id`、`provider`、`kind`（`subscription` 或 `api`）、`status`、`quotas`，以及可获得的 `identity`、`plan`、`message`。状态为 `ready`、`unconfigured`、`reauthentication` 或 `unavailable`；`ready` 表示凭据已配置或查询成功，不保证供应商开放余额查询。各提供方独立失败，HTTP 200 不代表所有账号均查询成功；查询之后有会话成功时，该账号按会话结果视为可用。响应不包含令牌、API Key 或上游错误正文。

- `quotas` 中的 `label` 是周期名称，`remainingPercent` 是周期剩余百分比，`windowMinutes` 是窗口长度，`resetsAt` 是 Unix 秒。窗口缺失表示未知，不能当成零或无限；只限某个模型或功能的额度分开返回，并以 `model` 标明范围，缺省表示整个账号共用。
- 订阅的 `plan` 是小写档位名。Claude 取 profile 接口中组织的当前订阅（如 `max 20x`），登录凭据缓存的 `subscriptionType` 升级后不更新，只在 profile 不可用时使用。
- `usage` 是按天的 token 用量：`days` 为最近 53 周里有用量的日期（`date` 为 `YYYY-MM-DD`，升序）及当天 `tokens`，`lifetimeTokens` 为累计。`scope` 为 `account` 时按天的数字是供应商给出的整个账号在所有设备上的用量，不在 kited 保存：ChatGPT 取 Codex 官方客户端使用的个人统计接口，没有公开文档，格式可能变化，统计有延迟，比它最后一天还新的日子用本机记录的合计；OpenAI、Anthropic 有组织管理凭据时取其按天用量接口（日期按 UTC）。`scope` 为 `machine` 时只含这台工作机的记录。
- 某天的 `hours` 是本地时间 0–23 时每小时的 token，只来自这台工作机的会话记录，`scope` 为 `account` 时与当天合计可能不一致；没有本机记录的日子省略。上游没有的部分由 kited 在每次查询时扫描本机记录、按小时存入数据库，同一小时取较大值，本地记录被清理后历史仍保留：Claude 扫 Claude Code 会话记录（含 Kite 的 Claude 会话），汇总输入、输出与缓存 token，按天的数字也由此而来；ChatGPT 扫 Kite 自研 harness 的线程日志与 Codex CLI 会话记录。其他 API 账号目前没有用量来源，不返回 `usage`。
- ChatGPT 的 `credits` 使用供应商的额度单位；`unlimited` 仅在上游明确返回时成立，未返回金额时省略 `value`。
- Claude 的 `extraUsage` 是额外用量（超出套餐额度后按金额计费）：`enabled` 表示是否开启，`used`、`limit`、`balance` 是按币种小数位换算后的金额，`currency` 为币种；上游没给的项省略。
- API 的 `cost` 是 UTC 当月到查询时刻的**组织费用**（`value`、`currency`、`from`、`to`），取完所有分页才返回；不是余额，也不是单个 API Key 的费用。普通调用 Key 没有组织费用权限时明确提示，不能推算余额。来源见 [OpenAI Costs](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs) 与 [Anthropic Usage and Cost](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)。
- DeepSeek 的 `balances` 保留各币种的可用余额 `total`、赠金 `granted`、充值余额 `toppedUp`，不混合人民币和美元；余额不足仍保留供应商实际返回值。来源见 [DeepSeek 查询余额](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/)。

查询失败后可重试；限流时应等待下一次刷新，不自动重试。每轮请求有总超时，不因一个提供方失败撤销其他查询。账号数据属于工作机，离线时上次结果只能作为历史信息。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/machine` | 读取这台工作机服务的持久身份，无需 `X-Kite-Machine`；远程访问须通过同账号组网认证 |
| GET | `/model-accounts` | 读取本机模型账号、订阅额度与 API 费用/余额的当前快照；凭据、额度与更新方式见下文 |
| POST | `/model-accounts/refresh` | 立即查询上游并推送新快照 |
| PUT | `/network/account` | 仅本机：`{deviceId, controlURL, authKey}`，接收账号服务的一次性入网授权 |
| GET/PUT | `/catalog/account` | 仅本机：查询上报状态，或用 `{deviceId, url, token}` 设置目录上报凭据；签发与版本约定见 [托管账号与设备](托管账号与设备.md) |
| GET/PUT | `/network` | 仅本机：组网状态，上线后 `peers` 列出对端设备的连接方式（`direct` 直连、`relay` 经中继、`idle` 近期无流量）；`{enabled}` 开启或关闭组网节点 |
| GET | `/projects` | 列出本机已登记的项目身份 |
| GET/POST | `/checkouts` | 列出本机检出（`?project=`）；登记本机文件夹 `{path}` 或 clone 远程 `{remote, path?}`，返回根工作区聚合 |
| GET/POST | `/workspaces` | 列出聚合（`?project=`），响应头 `X-Kite-Cursor` 标识列表版本；创建 `{checkout, name?, prompt?, runtime?, contextTemplate?}`，准备过程看事件 |
| GET | `/workspaces/:id` | 工作区上下文及 instances、threads、windows 的完整聚合 |
| GET / POST | `/plugin-definitions` | 读取定义或登记自定义包；包格式见 Bun 插件契约 |
| GET | `/operations` | 操作输入、输出、错误 schema，以及重试与取消规则 |
| POST | `/workspaces/:id/operations/:operation` | 调用 agent.start / list / send / resume / stop 或 files.list / read / state / select；修改操作必须带 operationId |
| GET | `/instances/:id/agent-capabilities` | 模型与思考档位、工具选择及配置生效边界；不发模型请求 |
| GET | `/plugin-definitions/:id/agent-capabilities` | 尚无实例的新会话草稿按定义读取同样的能力，`?runtime=` 选择后端 |
| GET / PUT | `/instances/:id/agent-config` | 读取绑定配置及 revision；以 expectedRevision 和完整 agent 配置更新 |
| GET / POST | `/context-templates` | 列出创建会话、标题、上下文压缩及五类通知模板和场景变量；以 `{definition}` 新建创建会话模板 |
| PUT | `/context-templates/:id` | 以 `{expectedRevision, definition}` 更新模板；不修改已有实例 |
| PUT | `/context-templates/:id/emblem` | 以 `{emblem}` 保存手改的点阵签名，返回带签名状态的模板；表达式不可用时 400 |
| POST | `/context-templates/:id/emblem/generate` | `{force}`：为 `true` 时连手改的签名一起重新生成，否则只补缺失或过期的签名；立即返回 `{emblem?, emblemState, emblemError?}`，结果随 `context-templates.changed` 送达；未启用轻任务时 503 |
| PUT | `/instances/:id/context-template` | 以 `{expectedRevision, templateId, templateRevision}` 为实例绑定模板内容；保留其他配置 |
| GET / PUT | `/threads/:id/title` | 读取标题与生成进度；以 expectedRevision 手动改名或恢复自动标题 |
| POST | `/threads/:id/title/regenerate` | 以 expectedRevision 立即重新生成标题，等待结果；不阻塞主会话控制 |
| GET / PUT | `/instances/:id/execution-grants` | 读取或修改执行授权；须停止且无恢复阻塞 |
| GET / PUT | `/instances/:id/operation-grants` | 读取实例操作授权及 revision；以 expectedRevision 和 grants 更新 |
| POST | `/workspaces/:id/windows` | 创建实例及默认窗口，或打开已有实例视图；请求使用稳定 id |
| DELETE | `/workspaces/:id/windows/:window` | 关闭共享窗口；最后窗口按插件生命周期回收实例或保留 |
| POST | `/workspaces/:id/threads` | 在已有工作区创建线程并打开窗口 `{prompt, definitionId?, runtime?, model?, contextTemplate?}`；省略 definitionId 时按 runtime 选内置定义，默认 harness。`model` 为 `{model, reasoning}`，优先于定义默认值；runtime 与定义不同时必须同时给出 model。模板选择为 `{id, revision}` |
| GET | `/threads/:id` | 线程和上下文，附带 `runner`、`busy` |
| GET | `/threads/:id/state` | 只读执行与恢复状态，不启动模型 |
| GET | `/threads/:id/history` | v1 显示历史、pending、state 和 cursor，只读 |
| POST | `/threads/:id/messages` | 发消息 `{text, id?}`，返回 `{id}`；harness 落盘后确认，同 id 和内容去重 |
| POST | `/threads/:id/messages/:message/cancel` | 按后端能力撤回尚未交接的输入 |
| POST | `/threads/:id/interrupt` | 停止会话，返回尚未纳入请求的队列；请求 `{id, inputs?}`，响应 `{returned}` |
| POST | `/threads/:id/resume` | 继续暂停的线程；可带 operationId 以安全重试 |
| POST | `/threads/:id/recover` | 确认恢复，不自动执行 |
| POST | `/threads/:id/compactions` | 手动压缩上下文 `{id, from, through}`，起止为输入 id；校验通过即返回，结果经显示事件送达 |
| DELETE | `/threads/:id/compactions/:compaction` | 撤销最外层的一次压缩 |
| POST | `/instances/:id/archive` | 归档独立存续的实例（agent 或 Bun 插件），保留所属工作区 |
| GET | `/workspaces/:id/snapshots` | 工作区快照，新的在前 |
| POST | `/workspaces/:id/restore` | 恢复文件到快照 `{commit}` |
| POST | `/workspaces/:id/adopt` | 合回主线并推送，返回 `{status: "adopted", commit, push}` 或 `{status: "conflict", files}`；`push` 为 `{status: "pushed"}` 或 `{status: "failed", message}` |
| GET | `/checkouts/:id/sync` | 现场的 `{branch, dirty, ahead, behind}`，按最近一次拉取的远程分支计算，不访问网络；未拉取过时 `ahead`、`behind` 为 null |
| POST | `/checkouts/:id/push` | 现场提交并推送，`{message?}`；有未提交改动时必须带说明。分叉返回 409，成功返回新的同步状态 |
| POST | `/workspaces/:id/archive` | 归档独立工作区 `{force?}` |
| GET | `/events` | 目录 SSE：首帧 `catalog.snapshot`，随后检出、工作区和线程概要变更 |
| GET | `/events?workspace=<id>` | 工作区 SSE：首帧 `workspace.model`，随后工作区操作与所属线程概要 |
| GET | `/events?thread=<id>` | 线程 SSE：首帧 `thread.history`，随后线程显示与状态事件 |

窗口创建请求为 `{id, content: {kind: "create", definitionId}}`；打开已有视图为 `{id, content: {kind: "open", instanceId, viewId}}`。`id` 使用 UUID。内置 agent 提供 `conversation`，文件提供 `files`，终端占位提供 `terminal`；文件视图包含预览。新建的空 agent 不调用模型；目标实例须属于当前工作区且处于可用状态，视图须由定义声明。

窗口响应包含 `{id, workspaceId, target: {instanceId, viewId}, state, createdAt}`。同一请求 ID 重试返回原结果，内容改变或窗口已关闭时拒绝，迟到重试不会复活窗口。实例回收与跨端布局的完整规则见 [Agent 与插件契约](Agent与插件契约.md#34-workspacewindow实例的一种呈现)。

`/threads/:id` 使用 agent 实例 ID；原生后端 ID 不用于此接口。工作区聚合包含所属实例、线程与共享窗口，具体类型见 [领域模型](../kited/src/model.ts)。实例操作的参数、授权和收据统一见 [实例操作](实例操作.md)，文件引用见 [资源引用](资源引用.md)。

`POST /checkouts` 登记本机文件夹时：

- 目录是仓库根且有 origin：按 origin 向账号登记，不访问 Git 远程。origin 无法识别为平台地址（如本地路径）时返回 400。
- 没有 origin：在托管服务建远程，写入 origin，并在托管远程为空时推送全部分支与标签。普通文件夹先初始化仓库、写入 `.gitignore` 模板并提交初始版本；放在同步目录里的，仓库本体放到 Kite 目录。中途失败可以重试，已写入的 origin 会找回同一个托管项目。
- 仓库没有任何提交、目录位于仓库内部、与已有检出重叠时拒绝。重复登记同一目录返回原检出及根工作区。

clone 远程时 `path` 默认为 `~/code/<域名>/<owner>/<repo>`，目标已有内容时返回 409；clone 期间请求不受空闲超时限制。访问远程时，账号为该平台绑定了凭据则临时改用 HTTPS 并注入凭据，否则照原样使用 origin 与用户自己的 Git 配置；kited 不改写 origin 的写法。

kited 在启动、加入账号后和每 5 分钟对照一次项目登记表。项目远程迁移后，各检出的 origin 改为新地址，目录上报随之带上新远程，托管服务据此回收托管仓库。

连接时先读 `GET /machine`。其余接口（包括 SSE）必须带 `X-Kite-Machine: <id>`：缺失返回 400，和服务身份不符返回 409，并在执行请求前拒绝。这个检查用于防止地址复用时操作错机器，不承担认证。本机监听的接口只接受 `Host` 为 `127.0.0.1` 或 `localhost` 的请求，其他主机名返回 403，用于阻止网页借 DNS 重绑定访问本机服务；远程监听只接受已核验身份的组网代理，见[远程连接](#远程连接)。App 会保存身份，重连时继续使用原 ID；CLI 在一次命令内固定目标 ID。

工作区聚合和线程上下文包含 `machine`，检出包含 `machineId`。SSE 按目录、工作区和线程分别订阅，每次重连从完整快照恢复；事件、游标与流式内容统一见 [会话显示协议](会话显示协议.md)。

## 验证入口

项目测试规则以 [AGENTS.md](../AGENTS.md#测试) 为准，构建与检查命令见 [kited README](../kited/README.md)，Swift、WebKit 和原生运行时的手动验证见 [手动验证入口](../kited/test/manual/README.md)。测试次数与耗时属于当次证据，不在本文维护。

## 大测试清单

升级 SDK 或 Claude Code 之后，用真实订阅手动跑一遍。kited 要在干净的环境变量里启动，不继承当前 Claude Code 会话的 `CLAUDE_*` 变量；终端版 Claude Code 要先登录。

1. 在 App 新建 Claude 实例，让它读取、修改文件并通过 shell 执行项目检查：工具行实时更新，出现工作区快照，patch 的历史引用在恢复后仍可打开。正常回复后进程关闭，实际模型请求只有实例配置和授权开放的 Kite 工具。
2. 检查发给模型的实际请求，不能只看 SDK 消息流：首轮、工具调用后与原生恢复只能带入 Kite 模板明确提供的上下文，不自动附加 Claude 的日期、环境、模型说明、技能、项目指令或自动记忆。单独验证高用量时的提醒，区分客户端与服务端注入。人发的消息仍带 `origin: human`，宿主工具和回调可用。
3. 再发一条消息：进程重新 resume，记下从发消息到进程就绪、到首条回复各用多久。
4. 归档：工作树被回收，线程历史仍可查看。
5. 核对新建和恢复后的工具集合；默认是 read / patch / shell 和五个 agent 操作工具，项目 `.mcp.json` 不自动增加能力。撤回操作或插件授权后执行被拒绝，新增插件授权在下一回合开始前重启进程后生效。验证排队取消、停止退回、模型及上下文更新，以及异常退出后的确认恢复。
6. 可选模型与最大上下文能力（`maxContextWindow`）维护在[共享模型目录](../shared/agent-models.json)，升级时核对模型资料与上游能力目录。最大能力不等于运行窗口：Claude 每回合用 `getContextUsage({ detail: 'summary' })` 获取当前窗口（不发模型请求）；harness 由宿主明确选择运行窗口并保存到请求配置。显示与压缩的契约见[上下文压缩](harness-主循环.md#上下文压缩)和[会话显示协议](会话显示协议.md#当前边界)。

## 当前能力边界

远程连接需要组网，iPhone 真机经组网连接的完整验收尚未完成。Linux 沙箱实机验证、资源配额、独立终端授权编辑和脱离进程组的后台任务尚未完成；Git 元数据只读，不能假设模型工具可直接暂存或提交。文件快照回退已提供，会话历史的回退与分叉尚未提供。

持续待办、待验证事项和候选产品决定已归入 [项目记忆](../.kite/memory/MEMORY.md)，不在本文重复维护排期。Claude 原生能力的开放范围以本文专节和当前接入决定为准。

## Bun 自定义插件

自定义插件使用预构建 Bun 包，提供 MCP 工具、资源和 App Web 视图。安装、模型授权、停止与未知结果处理见 [Bun 插件宿主](Bun插件.md)，共享身份与生命周期见 [Agent 与插件契约](Agent与插件契约.md)。
