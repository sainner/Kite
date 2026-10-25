# 工作机：使用与服务契约

kited 在工作机上管理项目、工作区、会话和插件。本文面向使用服务和调用 HTTP 的人，说明运行入口、工作区操作及服务边界。对象职责见 [产品架构](产品架构.md)，工程入口见 [kited README](../kited/README.md)。新会话默认使用自研 harness 和 ChatGPT 订阅，也可选择 DeepSeek 或 Claude。

## 终端试用

在 `kited` 目录运行，工作目录可以指定任意本地项目。先安装依赖并使用项目固定的 Bun（版本以依赖配置为准，`.kite/check` 自动选择）：

```bash
bun install
export PATH="$PWD/node_modules/.bin:$PATH"
```

```bash
bun run harness --cwd /你的项目目录
```

默认凭据位于 `$KITE_HOME/auth/chatgpt/auth.json`（`KITE_HOME` 默认 `~/.kite`），通过设备登录独立授权，不读取日常 Codex 的登录。也可用 `--auth /绝对路径/auth.json` 指定文件。

授权借用官方登录工具，给它单独的认证目录；每台工作机各登录一次，不跨机器同步凭据：

```bash
mkdir -p -m 700 "${KITE_HOME:-$HOME/.kite}/auth/chatgpt"
CODEX_HOME="${KITE_HOME:-$HOME/.kite}/auth/chatgpt" codex -c 'cli_auth_credentials_store="file"' login --device-auth
```

浏览器打开命令显示的地址并输入设备码。若 PATH 中的 `codex` 不可用，换成有效的 Codex 可执行文件路径。

harness 每次请求只读加载凭据，模型循环和工具执行不启动 Codex 或 Claude Code。自动刷新、系统钥匙串支持仍未接入；凭据过期或返回 401 时，在同一认证目录重新执行设备登录。无需 Platform API key。

可选型号见 [模型目录](../shared/agent-models.json)。用 `--model`、`--reasoning` 指定模型与推理强度，模型名也可通过 `KITE_MODEL` 设置。DeepSeek 型号（如 `--model deepseek-flash`）改读环境变量 `DEEPSEEK_API_KEY`，不需要 ChatGPT 登录。一次任务跑完就退出：

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
| `/exit` 或空闲时按 Ctrl+C | 停止执行、保存记录并退出 |

当前提供 `read`、`patch`、`shell`、`credentials`，参数、失败和取消语义见 [基础工具契约](harness-主循环.md#工具执行约定)。上下文的编辑与生效见 [上下文模板](harness-上下文组装.md)。

文件工具限制在工作目录内，shell 使用操作系统沙箱。默认工作区可读写、必要工具链可读、网络关闭；命令连接网络许可之外的主机时按实例的审批模式处理，默认问人，见 [工具审批与提问](工具审批与提问.md)。宿主凭据和内部记录受保护，Git 元数据只读。授权范围和平台限制见 [执行边界](Agent与插件契约.md#71-插件与-harness-共用操作系统沙箱)。独立终端尚无授权编辑入口，服务中的实例可在 App「执行授权」页编辑，见 [实例执行授权](实例操作.md#实例执行授权)。

这个终端入口直接修改指定目录。需要独立工作树、快照与采纳时，通过 kited 创建工作区。独立终端不提供 agent 协作工具、账号凭据服务、skill 清单（skill 工具仍在，能按名字加载系统层与项目层的）或外部 MCP 连接；上下文压缩只有自动触发，没有手动入口。服务中的 MCP 工具由 [Bun 插件宿主](Bun插件.md) 接入并授权。

异常退出留下的 `lock/` 不会自动删除。先根据会话目录中的 `lock/owner.json` 与 `processes.json` 确认原进程及命令均已停止，再清理锁并重新打开。执行效果未知时先核查，不重放旧工具。

## 会话后端与宿主边界

自研 harness 与 Claude 各自负责完整 agent 循环，Kite 宿主负责工作区、共享工具、授权、快照与显示协议。执行进程关闭后会话仍可继续，两种后端保留各自的原生恢复记录。

后端由模型的厂商决定：Claude 模型经 Claude Code 订阅运行，其他厂商的模型由自研 harness 运行，调用方不单独指定后端。代理可通过 `/instances/:id/agent-config` 换用另一厂商的模型；新厂商属于另一后端时后端随之更换，保留实例和其他配置；同一后端内换模型或只改思考强度时后端不变，在下一次模型请求生效。能力目录列出可选模型。`state.capabilities.switchRuntime` 表示当前能否切换后端：须空闲、没有排队的输入，否则返回 409。

自研 harness 接 OpenAI 与 DeepSeek。OpenAI 型号用前文独立授权的 ChatGPT 订阅。DeepSeek 没有订阅，用 Kite 账号凭据里的 DeepSeek API Key（有几把时取凭据列表里的第一把），账号里没有时用 kited 环境的 `DEEPSEEK_API_KEY`，按量计费；请求走 DeepSeek 的 [Responses 兼容接口](https://api-docs.deepseek.com/zh-cn/guides/responses_api)，按 1M 的上下文窗口自动压缩。两家之间换模型时，助手文字与工具调用照常交给新厂商，推理只交还给产生它的厂商。

切换在回合边界交接上下文，两种后端各保留原生记录。人发消息、Kite 通知、助手文字、工具调用与结果及图片随当前有效上下文交接；压缩或撤销后的结果同样生效。推理内容不跨厂商传递；普通切换只追加历史，保留原后端的推理。Claude 历史经压缩或撤销重组时，只保留未改动前缀中仍有效的 thinking，已退出当前上下文的块不因撤销而恢复。原始记录仍供查看，显示记录不作为原生恢复数据。提示缓存是否复用取决于请求前缀与服务端缓存状态。重复切换不重复导入，翻译失败时不切换。

Claude 恢复依赖锁定版本 CLI 的原生记录格式。升级时须重新验证上下文交接与压缩后的恢复，条件和证据见 [上下文翻译实验](research/2026-10-08-跨后端上下文翻译.md) 和 [Claude 会话重组实验](research/2026-10-09-Claude会话重组.md)。

代理配置由创建时的角色加草稿里的调整得来，绑定到实例，重启沿用已保存内容。内置角色「工作」可用全部工具（read、patch、shell、credentials、向用户提问的 question 及 agent 操作），「只读审查」只用 read 且 read 为必需；工具的逐层约束见 [Agent 与插件契约](Agent与插件契约.md#32-角色与代理配置)，工具选择不能扩大授权。默认型号见 [共享模型目录](../shared/agent-models.json)，配置生效见 [线程通知投递](线程通知投递.md)，执行与恢复要求见 [harness 执行约定](harness-主循环.md) 和 [会话状态机](会话状态机.md)。

## 运行

### 轻任务与会话标题

轻任务即资源库里的辅助生成（会话标题、工作区名称与点阵签名），用于一次性文本生成，不提供工具、不创建线程、不写入主会话历史。模型与思考强度随各自的模板保存，在资源库里设置，只能选 [共享模型目录](../shared/agent-models.json) 里的 ChatGPT 型号，内置默认是最轻的一档与 `low`；统一使用工作机的 ChatGPT 授权，Claude 会话也由 Kite 生成标题，不依赖 Claude 登录。失败保留原题，不升级到主模型；日志不记录输入正文。环境变量 `KITE_LIGHT_TASKS=0` 关闭自动轻任务。

首条消息接收后，以其文字作即时标题并开始生成。自动模式下，每次接收新消息都检查是否需要改名，不等待主会话完成、不定时扫描历史。默认命名要求是：标题概括会话的主线，只在主线换了时改名；在原来的工作上追加需求、顺手修补、追问、讨论细节或汇报进展时保留原题。

材料来自近期用户请求与完成的回复，包括已接收的排队消息；不使用工具、思考及代码块。命名规则和材料使用可编辑的标题模板，每次生成读取最新保存内容，在途请求不受后续编辑影响。模板格式见 [上下文模板](harness-上下文组装.md)。

工作区名称默认跟着顶级代理（用户开的代理，不含别的代理起的子代理）的标题走。顶级代理的标题变了时看工作区里有几个顶级代理：只有它一个时，工作区名称改成它的标题，首条消息的即时标题、生成的新标题和手动命名都算；有几个时，标题经生成或手动命名改变后由辅助模型按各顶级代理的标题重起工作区名称，原名仍能概括时保留，首条消息的即时标题不触发，等随后生成的标题。命名规则使用可编辑的工作区名称模板。不带首条消息新建的工作区先叫「新工作区」。用户手动命名后不再自动改名，生成期间被手动改过的也不覆盖；切回自动时当场重起：只有一个顶级代理就用它的标题，有几个时由辅助模型重起、不沿用原名，还没有代理时名字不变，之后照常跟随。

### 语音识别

语音识别也是辅助生成的一类：App 录音，经 `/voice` 把声音推给工作机，工作机连识别服务，识别结果不进入代理上下文。识别模型随「语音识别」模板保存，只能选识别模型目录里的型号，目前是千问 `qwen3-asr-flash-realtime`；凭据用工作机上的语音识别 Key（见 [凭据](#凭据)）。

识别不按停顿分句，说完一次提交：边收声音边推中间结果，App 发出结束后给整段定稿。开录时按模板把这个会话最近的请求和回复（代码不略去，取到 6000 字）作为背景文本交给识别服务；新会话还没有实例时不带对话。定稿再做一次确定性整理，不用 LLM：夹在英文之间念出来的「点」「斜杠」「杠」「下划线」换成符号，英文词对得上背景文本里的标识符时按它的写法恢复。选型依据见 [语音识别选型](research/2026-10-12-语音识别选型.md)。

| 接口 | 请求与结果 |
|---|---|
| `GET /threads/:id/title` | 返回 `{title, mode, revision, generatedAt, through}`；后两项标识最近成功检查的时间与输入截止位置 |
| `PUT /threads/:id/title` | `{expectedRevision, mode: "manual", title}` 手动命名；`{expectedRevision, mode: "auto"}` 恢复自动并立即检查已接收消息 |
| `POST /threads/:id/title/regenerate` | `{expectedRevision}`，等待本次生成完成并返回标题快照；保持原 auto/manual 模式 |

标题须为 1～80 字符的单行文本。版本冲突返回 409。手动命名后停止自动覆盖，创建 agent 时显式给出的标题也视为手动命名。生成期间发生的改名或模式切换不能被旧结果覆盖；显式重生期间被其他操作改名则返回 409。生成失败保留原题与进度，后续新消息仍可触发检查。

显式重生不受相同消息位置的限制，使更早的在途标题结果失效。标题生成不打断或阻塞主会话控制。

### 账号级数据

资源库（角色、后台场景的上下文模板、点阵签名、插件包与 Bun 插件的定义级授权、用户层的 skill）、项目登记表与项目外观、项目约束、项目的布局、凭据，以及各工作机的目录摘要，是所有工作机共有的账号级数据，任一台都能修改，设计见 [分布式架构](分布式架构.md#数据的归属与同步)。每台工作机在数据目录的 `account.db` 里存一份完整副本，离线时照常读写。

- **同步。** 工作机之间直接同步，不经服务器。发现见 [远程连接](#远程连接)；每台工作机向其他每台在线的工作机增量拉取，没有新变化时请求挂着等，对方一有变化就返回，断线后从上次的位置续传。收到的变化也会被第三台拉走，不要求两两直接连通。只有工作机能拉取（`/sync/changes`），因为其中有凭据明文；App 经任一台连着的工作机读写。
- **并发修改。** 每条数据带版本，两台工作机同时改了同一条时以后写的为准，被覆盖的那份另存下来，`/sync/conflicts` 可以找回。删除也是一次修改，与另一台的并发修改相遇时，修改的那份同样另存。
- **凭据落地加密。** 保密内容用每台工作机自己的密钥加密保存：安装版的 macOS 服务把密钥放登录钥匙串，其他情况放数据目录里只有本人可读的文件。明文只在工作机之间经组网的 WireGuard 传输，收到后用本机密钥重新加密。本机密钥暂时取不到（钥匙串锁着、在等人允许）时，同步照常写入凭据以外的数据、凭据留到下次，新版本的发布不能被凭据卡住，否则没人看着的旧版工作机永远收不到新版。

资源库的写入先进账号级数据，再更新本机缓存；读取用缓存。内置角色和模板只保存自建或修改的内容，未修改项跟随 kited 版本；改回与默认一样或恢复默认时删掉那一条，其他工作机同步后退回默认。写入时按本机缓存给出期望的版本，基于已被删掉或改过的旧内容保存返回 409。插件包装到本机时一并写入，其他工作机同步后用到时再装。skill 是多文件包（SKILL.md 保持 UTF-8 文本，可附带文本、图片、PDF 等文件，整包按原始字节合计不超过 4 MiB），同步到每台工作机后写进数据目录的 `skills/<名字>/`，代理从那里加载；随 kited 带的 skill 同角色，只存改过的那份。skill 的列表只有名字与版本，客户端打开某一个时再按名字取整包。

本机缓存有变化（本机写入或同步来的）时，目录流推 `library.changed`，`kind` 是变了的那一类目录：`role` 是角色列表（签名状态与点阵签名的变化也算），`template` 是后台场景的上下文模板，`skill` 是 skill 列表，`plugin` 是插件定义（Bun 插件包或它的定义级授权有变化时推），`layout` 是某个项目的布局（另带 `projectId`）。读过这一类的客户端重新读取；断线期间收不到，重连后读过的都重读。

项目约束随项目登记表同步，只由用户在 App 里修改。它在创建代理、每次模型请求和每次工具调用前过滤工具，不改写实例配置；有效工具因此变化的代理收到配置通知。分层规则见 [Agent 与插件契约](Agent与插件契约.md#32-角色与代理配置)。

#### 凭据

凭据分四类，类型决定由谁、以什么方式取用，可见范围与类型相互独立：

| 类型 `type` | 名称 `name` | 公开信息 `meta` | 保密内容 `secret` | 可见范围 | 取用方 |
|---|---|---|---|---|---|
| `secret` 共享密钥 | 引用名 | `{kind, path?}`，`kind` 为 `text` 或 `file`；`path` 只用于项目专用的 `file` | `{value}` | 账号共享或项目专用 | 执行命令时按 `{account.名称}`、`{project.名称}` 引用；设了 `path` 的由宿主写进工作区 |
| `git` Git 凭据 | 主机名，如 `gitlab.com` | `{username}`，默认 `oauth2` | `{token}` | 账号共享 | 访问对应平台的远程时使用 |
| `api` 模型 API | 用户起的名称 | `{provider, hint, admin}` | `{key?, adminKey?}` | 账号共享 | 查询额度或调用 token 计数接口时使用；DeepSeek 的 Key 也用于 DeepSeek 型号的会话 |
| `speech` 语音识别 | 用户起的名称 | `{provider, hint}`，`provider` 目前只有 `dashscope`（千问，北京地域） | `{key}` | 账号共享 | 识别语音输入时使用 |

类型、范围与名称的组合唯一；两台工作机没同步上时各建了同名的一条，取用时用最近改过的那条。同一供应商可以保存多把 API Key，各自作为一个 API 账号查询。命令中无法引用 Git 凭据、API Key 或语音识别 Key。订阅登录不是凭据，仍由各工作机自行完成，见 [模型账号与额度](#模型账号与额度)。

账号共享密钥供各项目的 agent 使用；项目专用密钥只对所属项目的执行开放。同名密钥按引用前缀区分，不回退或互相覆盖。宿主按实例实际归属固定项目 ID，不接受模型自报的项目。当前不细分项目内各 agent 的密钥权限，保存到相应范围即允许该范围内的 agent 使用。执行前按需读取，替换或删除影响后续取用，已经启动的命令不会因此中断。执行中的环境变量、临时文件、输出与清理约定见 [基础工具契约](harness-主循环.md#shell)。

项目专用的 `file` 密钥可以设 `path`：工作树内的相对路径，不含 `..`、不在 `.git` 里，同一项目里不能重复。宿主每次在一台工作机上建出工作树（新建工作区、流转来还原、重跑准备）时，在 setup 之前把内容写到这个位置，权限 0600。这些路径同时记进检出（Kite 自己的仓库）的 `info/exclude`，本机这个项目的工作树都忽略它们，快照、集成与同步的提交不会带上，项目的 `.gitignore` 之后怎么改都一样；路径上是项目跟踪的文件时不写，工作区准备失败并说明原因。密钥改了（本机改或同步过来）就把新内容重写进本机这个项目的所有工作区。

这些文件对 agent 只读：shell 的沙箱不许写，patch 拒绝修改并提示改用密钥请求。要加或改环境变量文件里的一项，agent 用 `credentials` 的请求动作，由用户在卡片里填写或确认（见 [密钥请求](工具审批与提问.md#密钥请求)），宿主按 dotenv 的写法替换这一行，没有就追加。文件只有凭据这一个来源，所以随时整体重写也不会丢改动。写进工作区的文件 agent 能读到，内容可能进入模型上下文，取舍见 [凭据](项目与远程仓库.md#凭据)。

共享密钥的名称以英文字母开头，仅含英文字母、数字、下划线与短横线，最长 64 个字符；内容为 1–65536 个 UTF-16 单元的文本，不含 NUL，文件类型也按 UTF-8 文本使用。Git 主机名为小写域名，可带端口；token 最长 4096 个字符。API 名称为 1–64 个字符；`provider` 为 `openai`、`anthropic` 或 `deepseek`。OpenAI、Anthropic 至少提供调用 Key 或组织管理 Key 之一，DeepSeek 只接受调用 Key；`hint` 是 Key 末四位，`admin` 表示是否含管理 Key，二者由 kited 生成。管理接口只返回公开信息，App 只在新建或替换时提交保密内容。

GitHub 用 Kite 的 OAuth App 做设备码授权绑定，在工作机上完成，不需要 client secret，token 不经过 App。这个 App 开着 Device Flow、关着令牌过期，kited 不做令牌续期；`KITE_GITHUB_CLIENT_ID` 可以换成别的 App。

### 角色点阵签名

每个角色可保存一枚可编辑的点阵签名，结构为 `{expression, avatar, positive, negative, form}`：`expression` 与 `avatar` 分别描述签名与头像，颜色和形状配置共用。算式只解析求值、不执行代码；[签名格式](../kited/src/template-emblems.ts) 与 [表达式语法](../kited/src/emblem-expression.ts) 由共享契约约束，App 使用相同语义。

角色保存后用轻任务按角色名称与提示词生成，生成规则来自「点阵签名」模板。自动签名在提示词变化或缺少头像算式时过期，只改工具、模型或预算不会重新生成。普通生成不会覆盖手改签名，包括手改之后才返回的结果；显式 `force` 生成允许覆盖。角色列表中每项带 `emblem`、`emblemState`（`ready`、`stale`、`missing`、`generating`、`failed`）与失败时的 `emblemError`；生成失败时客户端使用默认图案。角色或签名状态变化推送 `kind` 为 `role` 的 `library.changed`，见 [账号级数据](#账号级数据)。

### 启动服务

macOS 用户级安装及登录自启使用仓库根目录的 `./install.command --service-only`，完整流程见 [macOS 安装与打包](macOS安装与打包.md)。以下命令供源码开发时前台运行：

```bash
cd kited && bun install
export PATH="$PWD/node_modules/.bin:$PATH"
bun src/main.ts
```

`KITE_HOME` 指定数据目录，默认 `~/.kite`；保存工作区、会话、登录及服务数据。`KITE_PORT` 默认是 5483，监听 127.0.0.1；组网与远程监听见下节。

同一数据目录重启或更换端口后，工作机身份保持不变；新数据目录生成新身份。名称初始取主机名，地址由组网发现，见 [远程连接](#远程连接)。

项目 ID 由项目登记表分配，规格见 [项目与远程仓库](项目与远程仓库.md)。有远程的项目以远程为身份，同一远程自动归入同一项目；没有远程的项目以 ID 为身份，各工作机上的检出互为远程。检出是 Kite 数据目录里的裸仓库，每台工作机上一个项目最多一份，这台机器上该项目的工作区都从它开出。工作区、线程与执行记录由执行它的工作机写，其他工作机持有副本，见 [工作区流转](Line与工作区流转.md#工作区流转)；账号级数据见上文。

默认 harness 使用前文独立授权的 ChatGPT 凭据，DeepSeek 型号使用账号里的 API Key。只有 `claude` 会话需要 Claude 登录，开放范围见下文附加功能清单。Claude 会话不自动读取用户、项目或本地设置，OAuth 与钥匙串认证保留。

命令行是薄客户端：

```bash
bun src/cli.ts add ~/thesis        # 登记本机文件夹，返回项目 id
bun src/cli.ts add github.com/me/thesis  # 只登记远程项目，不 clone
bun src/cli.ts checkouts <项目>    # 列出该项目在本机的检出
bun src/cli.ts new <项目> "把第二章的图注统一成中文"  # 在本机建工作区，没有检出时先 clone
bun src/cli.ts send <线程> "再检查一遍参考文献"
bun src/cli.ts resume <线程>       # 继续暂停的上下文
bun src/cli.ts snapshots <工作区>
bun src/cli.ts restore <工作区> <快照>
bun src/cli.ts adopt <工作区>       # 按项目的集成方式集成
bun src/cli.ts sync <工作区>        # 把主线的新改动合进工作区
bun src/cli.ts archive <工作区>
bun src/cli.ts net up              # 开启已登录设备的组网
```

## 远程连接

身份与组网交给 Tailscale：登录 Tailscale 即登录 Kite，同一 Tailscale 用户的设备可直接控制工作机。工作机第一次开启组网时，状态里给出登录地址（App 首次配置时打开，或 `kite net up` 打印），用户在浏览器里登录。身份、入网与撤销的完整约定见 [身份与设备](身份与设备.md)。

工作机互相发现不经服务器：kite-net 列出组网里同一用户、不带标签的对端设备与在线状态，kited 读各对端的 `/machine`，答得上的就是工作机。各工作机把自己的目录摘要（项目、检出与工作区，见 [目录与工作机的职责](身份与设备.md#目录与工作机的职责)）随账号级数据同步给其他工作机，App 连上任意一台在线的工作机，就能读到其他工作机最近一次的摘要（`/machines`）。从组网移除的设备不再列出。`/machine` 还带着版本：工作区副本、流转与换机、没有远程的项目的拉取只在构建号相同的工作机之间进行，账号级数据照常同步，见 [自动更新](macOS安装与打包.md#自动更新)。

工作机由 kite-net（tsnet）接入网络，控制端由 App 内的 TailscaleKit 接入，不占用系统 VPN。本机执行模式的 App 复用 kited 的 SOCKS 入口，只维护一个网络节点。kite-net 另开一个本机 HTTP 代理入口，只转发到组网地址，供 kited 自己（发现、同步、Line）调用同账号的其他工作机，对端照常核验来源身份。链路加密由 WireGuard 承担；kite-net 通过 WhoIs 核验请求来源与本节点属于同一 Tailscale 用户、不带标签，并把来源的组网 IP 交给 kited，只给工作机用的接口据此只接受工作机。内部代理使用进程内随机凭据，外部传入的同名字段被覆盖。

**受管网络通道**是给特殊网络用的可选项，默认不配，普通网络不需要。有的网络不允许宿主直接用 UDP 出网，要求组网流量先经一条只跨局域网、由路由器认证身份的 WireGuard 通道，路由器认证后才给原生出站。配置后，kite-net 在进程内建这条通道，出网的组网 UDP（STUN、探测与点对点数据）只经它走，通道里的端口固定为 41641；系统里不出现网卡，通道也不作为整台机器的出口。发往本机直连网段的组网 UDP 不出网，直接走网卡，同一局域网里的设备因此可以直连，本机各网卡的地址照常报成端点。私钥由 kite-net 生成并存在登录钥匙串里，不落文件；公钥交给网络管理员登记。读写钥匙串经系统自带的 `security`，kite-net 更新后不会弹窗等人允许；以前由 kite-net 直接存的私钥，头一次要在那台 Mac 上允许一次。私钥取到、与路由器握手之前，出网的组网 UDP 一律不发，也不退回未认证的直连；这期间局域网之外只能经中继，UDP 不通时也不改用宿主网络做 ICMP 探测。

通道内地址与对外端点分开：`address4`、`address6` 是固定的通道内地址，换网络不用改；对外端点由经通道的 STUN 探测得出，就是入口当前的出口映射，IPv6 同样经通道探测，宿主网卡有没有 IPv6 都一样，通道内地址本身不报成端点。上报的端点只有这些出口映射和本机直连局域网的 IPv4，TUN、宿主自己的 IPv6 等对端发来收不到的地址不报。本机换网络或通道断过又握上手时，丢掉以前缓存的出口映射并重新探测（立即一次，3 秒、10 秒后各补一次），失效的端点随之撤回，探测不到时只剩中继。入口负责随宿主网络切换出口并重建映射，通道内 IPv6 要由入口转换成当前网络的公网 IPv6，当前网络没有 IPv6 时不放行；没配 `address6` 时 kite-net 不开 IPv6 的组网 UDP。组网库自己的 DNS 查询照常走宿主的系统解析，不属于组网 UDP。配置按机器保存，与账号无关；只能在本机设置。

`kite net` 查看状态及各对端是直连还是经中继；`kite net up`、`kite net down` 开启或暂停组网，`kite net logout` 退出 Tailscale 登录。在 Tailscale 管理后台移除设备后，已有远程请求随状态变化关闭。网络错误和服务重启可以重连，401 表示来源未通过组网认证，409 表示目标工作机身份不符。

**有预告的离开。** macOS 上 kite-net 接收系统的睡眠预告与 loginwindow 的登出、重启、关机预告，kited 在时限里把属于自动换机范围的工作区交给别的工作机（Line 的总是换，项目打开了自动换机的只换正在工作的）：睡眠等交接收尾才放行；登出、重启、关机拦不住，kited 收到 SIGTERM 后先等交接收尾再停。服务停止不带预告，不算离开。见 [工作区流转](Line与工作区流转.md#工作区流转)。

本机接口边界见 [接口](#接口)，SSE 重连见 [会话显示协议](会话显示协议.md#历史与连接)。原生 iPhone 的新账号流程、前后台重连和蜂窝网络仍需真机验收。

## 工作区与线程的生命周期

| 操作 | 行为与限制 |
|---|---|
| 登记项目 | 远程地址只写进项目登记表，不 clone。本机文件夹有 origin 的按远程登记；没有的在这台工作机上导入成没有远程的项目，原文件夹不动。可以一起保存环境变量文件为项目密钥。都不创建工作区 |
| 创建工作区 | 在这台工作机上为项目建工作区：先检查环境，不满足就不建；没有该项目的检出时自动 clone 并登记，检出保留。先拉取主线，从最新的主线开出工作树。可以先建空工作区，也可在准备完成后运行首条消息。名称跟着代理的标题，见 [轻任务与会话标题](#轻任务与会话标题) |
| 添加线程 | 工作区可有多个线程，各自保存对话；线程之间默认并行，一个线程在执行、等你回应或等待继续时，其他线程照常启动，见 [工作区并行](工作区并行.md)。App 的新代理草稿只在本机，第一条消息连同所选角色和调整过的模型、工具、预算一次创建实例与线程 |
| 快照与回退 | 每批工具后与回合结束时保存整个工作区的变更并记下触发的线程，快照不改变 HEAD、分支或暂存区；超过 10 MiB 且项目 Git 未跟踪的文件不进快照，与被忽略的文件一样回退不碰（见 [成果查看与位置](成果查看与位置.md#大文件)）。回退先保存现状，再恢复文件；任一线程在执行期间不允许回退 |
| 采纳（集成） | 按项目的集成方式：直接合入把工作区改动合进主线并推送到远程；提交 PR 把工作区分支推到远程并开 PR。同一检出的采纳串行执行，冲突留在工作树；采纳后工作区与线程仍可继续使用 |
| 同步 | 拉取主线并合进工作区分支，不推送；要求线程全部空闲，冲突同采纳，合完保存快照。工作区聚合带 `behind`，是主线比工作区分支多出的提交数，按最近一次拉取计算 |
| 归档实例 | 停止该实例的执行，保留会话、业务数据、工作区和快照；归档代理时，同一工作区里它开出的各层子代理一起归档。关闭即回收的实例与进程实例用关闭（`DELETE /instances/:id`），不提供归档 |
| 归档工作区 | 停止所有线程、保存最后快照，回收工作树和分支，归档并回收实例。未采纳改动须显式 `force`；提交 PR 的工作区以 PR 合并为已采纳。Line 所在的工作区不能归档 |
| 跨机流转 | 所有线程空闲时交出工作区；另一台工作机把副本补到末尾、装到本机并接管后，本机记录冻结为 `transferred`。工作区 ID 不变，`epoch` 加 1；见 [工作区流转](Line与工作区流转.md#工作区流转) |
| 子工作区 | 代理用 `agent_start` 的 `isolation` 从当前工作区最近的快照开出，挂在父工作区下；只能合回父工作区或放弃，随父工作区流转，见 [子工作区](项目与远程仓库.md#子工作区) |

工作树准备先写入设了路径的项目密钥（见 [凭据](#凭据)），再运行项目的 `.kite/setup` 安装依赖。检出是裸仓库，没有可以带入的忽略文件，因此不再支持 `worktree.symlinkDirectories`、`.worktreeinclude` 与 `KITE_MAIN_DIR`。准备失败或被打断时工作区为 `failed`，可以用 `POST /workspaces/:id/setup` 重跑，不自动重跑；成功后保存初始快照并开放使用。准备中的首个线程被打断也会中止初始化。

`.kite/setup` 与模型的 shell 共用操作系统沙箱：工作树可写，必要工具链可读，宿主凭据、数据库与会话记录受保护，Git 元数据（含检出）只读；skill 的文件夹只为代理放行，setup 读不到。环境只带开发工具的基础设置（与 shell 相同），不继承 kited 进程的完整环境。网络在项目级网络授权落地前放行，回环与本机地址仍不可达。完整输出只写工作区的 `setup.log`，事件只带退出码和输出末尾。setup 不领取凭据，需要落成文件的密钥已在它之前写进工作树。

按项目创建前的环境检查读 `GET /environment?project=`，只读本机：平台与系统版本、ChatGPT 与 Claude 订阅在这台工作机的登录与能否取到 DeepSeek 的 API Key（`logins` 的 `chatgpt`、`claude`、`deepseek`；凭据在且未过期为 `ready`，不代表额度或余额可用）、放工作树与检出的卷的剩余空间，以及有没有检出；还有这台工作机带不带电池，和 `needs` 里问到的换机环境需求各自是否满足（`xcode` 看选中的开发者目录是不是完整的 Xcode，`iosDevice` 看 devicectl 列出的已配对 iPhone、iPad 此刻有没有连接方式）。按项目创建时，所选角色默认模型的厂商未登录或任一卷剩余不足 1 GB 返回 409；自动换机挑目标与接管工作区时同样按各代理所用模型的厂商核对。

采纳先拉取远程主线，把本地主线和远程主线依次合进工作区分支。直接合入时检出的主线快进后推送；推送被拒时重新拉取、合并再推，最多三次。拉取或推送失败不撤销本地主线，结果中的 `push` 报告失败原因，下次采纳时一并推上去。提交 PR 时不动本地主线，把工作区分支推到远程同名分支，没有 PR 时开一个；工作区记下 PR 的编号、地址与状态（`open`、`merged`、`closed`），状态随项目同步查询。采纳冲突交给工作区中的一个打开线程处理，处理期间同一工作区的其他线程不能开始工作。agent 仅编辑文件，Git 合并由宿主完成；解决回合正常完成后自动重试一次，仍有冲突则报告，等待用户手动重试。集成方式的选择与默认值见 [工作区与集成](项目与远程仓库.md#工作区与集成)。

发送、停止、队列退回和恢复属于线程控制，见 [会话状态机](会话状态机.md)。回退只恢复文件，不回退或分叉对话历史。

## Claude 会话的上下文

Claude 负责模型循环与原生对话恢复；Kite 负责工具、项目上下文、授权、工作区与快照。Claude 的内置工具只留按需加载插件工具的 ToolSearch（见 [Bun 插件](Bun插件.md#模型工具与插件间调用)），此外只开放实例配置与授权允许的 Kite 工具、显式授权的插件工具，以及实例打开的外部 MCP 服务的工具（由 kited 连接后作为 Kite 工具交给 Claude，见 [外部 MCP 服务](#外部-mcp-服务)），不自动加载用户或项目中的 MCP、skills 和设置。

Claude 使用统一的 `kite.agent` 定义，工具由角色、实例选择、项目约束及授权共同决定。基础工具共用 [工具契约](harness-主循环.md#工具执行约定)，协作与授权共用 [实例操作](实例操作.md)，工具名与自研 harness 相同，不带 MCP 前缀。工具执行完成并保存快照后才能继续模型请求。

模型、工具与基础上下文绑定到实例；`KITE_CLAUDE_MODEL` 可覆盖创建时的模型。配置和执行授权须在空闲时修改；可选型号与思考档位通过能力接口获取。项目规则、记忆索引与 skill 清单仅由 Kite 的模板提供，skill 正文由 Kite 的 `skill` 工具加载，Claude 不自行扫描，自己的 skill 发现与 Skill 工具保持关闭。具体生效时机见 [线程通知投递](线程通知投递.md#claude-的交接边界)。

Claude Code 进程随实例常驻：首次需要时启动，回合结束后不退出，在实例归档、切换后端、手动停止或 kited 退出时结束；回合之间意外退出的，下一条消息到来时恢复原生会话。运行中插话沿用 Claude 原生输入队列，在自然请求边界纳入，不要求等整轮结束。发送确认、撤回与停止遵守 [会话状态机](会话状态机.md#手动停止与消息交接)，被 kited 退出打断后的接续见 [被打断之后](会话状态机.md#被打断之后)；已有原生记录不能重复投递，未知执行效果不能自动重放。

App、HTTP 和 CLI 的显示与控制能力见 [会话显示协议](会话显示协议.md#当前边界)。搜索网页、定时任务和原生 Claude 子 agent 尚未开放。Kite 工具受沙箱限制不表示整个 Claude SDK 进程已被隔离。

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

升级时须通过实际模型请求核验这些边界，不能只检查 SDK 事件；验证入口见 [手动验证](../kited/test/manual/README.md)。上游配置入口参见 [SDK 系统提示与附件](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts)、[配置来源边界](https://code.claude.com/docs/en/agent-sdk/claude-code-features#what-settingsources-does-not-control)、[环境变量](https://code.claude.com/docs/en/env-vars) 与 [mods 接口](https://code.claude.com/docs/en/plugins/mods/reference)。

## 项目检查

代理用 Kite 的 check 工具跑项目的 `.kite/check`，两个后端相同；工作树里没有 `.kite/check` 时不提供这个工具。检查命令的写法与输出约定见 kite-onboard skill。比在 shell 里直接跑多四样：

- **在哪跑**：照预览[目标](实例操作.md#目标)的规则。`.kite/check` 与这台工作机检出主线上的一致，就直接在沙箱外跑；不一致或主线上还没有，先经审批，受审批模式约束，「允许并记住」按脚本内容记在这个代理上；没获准就在沙箱里跑，用代理的执行授权与网络审批。工作区按执行授权只读时总在沙箱里跑。审批在排队之前，核对之后脚本又被改了的不跑。主线比对只管入口：它跑的测试等代码是工作树里的，代理改得了，和预览目标跑的开发服务器一样。
- **起算点**：宿主传 `KITE_BASE`，取工作区分支和主线的分叉点，工作区里已经提交的改动也算进受影响的范围。
- **日志**：每次检查一个 `KITE_LOG_DIR`，在数据目录的 `checks/<工作区>/` 下，只留最近几次，工作区删除时一并删除；代理对它只读。
- **排队**：一台工作机上一次只跑一个检查，同时跑会互相拖慢、误报超时；排在后面的等前一个结束，结果里注明等了多久。

检查不转后台、不带密钥，进程登记与 shell 相同；在沙箱里跑时只多得到这次日志目录的写权限。退出码为 0 时工具结果为成功，否则为错误，正文是检查命令的输出。

## 模型账号与额度

额度查询只使用工作机本身持有的授权，不登录、不续期、不分发模型凭据，也不发送模型请求。ChatGPT 使用前文的 Kite 专用认证目录；Claude 使用 Claude Code 原生登录存储（包括 macOS 钥匙串与显式指定的配置目录），或 `CLAUDE_CODE_OAUTH_TOKEN`。缺失和过期凭据分别返回未配置和需要重新授权，不借用日常 Codex 的登录。

App 的订阅登录由所选工作机执行原生登录工具，凭据不经过 App：ChatGPT 复用 [官方设备码登录](https://developers.openai.com/codex/auth)，写入 Kite 专用认证目录；Claude 复用 [原生 `auth login --claudeai`](https://code.claude.com/docs/en/cli-reference)，保留 Claude 自身的凭据存储。工作机须有可用的 Codex CLI；Claude 登录工具随固定版本的 Agent SDK 提供。登录完成不等于额度接口必定可用，额度查询失败单独显示。

| 方法与路径 | 调用约定 |
|---|---|
| `POST /subscription-logins` | `{id, provider}`，`id` 为客户端生成的 UUID，`provider` 为 `chatgpt` 或 `claude`；同 ID 幂等，同供应商已有活动登录时返回 409 |
| `GET /subscription-logins/:id` | 返回 `status`（`starting`、`waiting`、`complete`、`failed`、`cancelled`、`expired`）、`expiresAt`（Unix 秒）、`acceptsCode`，以及可选的官方授权 `url`、ChatGPT `userCode`、错误 `message`；不返回令牌或原始工具输出，服务重启后返回 404 |
| `POST /subscription-logins/:id` | `{code}` 提交 Claude 的单行授权码，最多 4096 字符；不接受输入的状态返回 409，格式错误返回 400 |
| `DELETE /subscription-logins/:id` | 幂等取消指定登录并结束等待中的进程；先取消后迟到的启动也不会创建进程；不撤销已完成的订阅授权 |

这些接口沿用工作机身份与同账号组网鉴权。弹窗关闭时取消登录，超时十分钟或服务正常关闭时也结束等待。自动续期仍未接入。


API 账号来自工作机上的 API 凭据（见 [凭据](#凭据)），每把 Key 一个账号，`id` 为 `api:<凭据ID>`，`identity` 为用户起的名称；每次查询前重新读取；读取失败时无法得知有哪些账号，改为返回一条 `id` 为 `account-api`、状态为 `unavailable` 的账号说明原因。kited 进程环境中的 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`DEEPSEEK_API_KEY` 与组织管理凭据 `OPENAI_ADMIN_KEY`、`ANTHROPIC_ADMIN_KEY` 另作为本机账号查询，`id` 为 `<供应商>-api`，未设置时不列出。查询 OpenAI、Anthropic 的组织费用需要管理 Key。OpenAI、Anthropic 的 API Key 只用于额度查询与 token 计数，不作会话的模型凭据；DeepSeek 的 Key 同时是 DeepSeek 型号的模型凭据，见 [会话后端与宿主边界](#会话后端与宿主边界)。

额度不由客户端轮询，打开账号页也不查询。kited 在内存中保留本机最新的账号快照：首个客户端订阅目录事件流时，若还没有查询过就查询一次上游；之后只在显式刷新时查询。会话响应带回的额度按观测时间覆盖对应周期；查询结果到达之前，快照只含会话观测到的订阅账号及其周期：Claude 取 SDK `rate_limit_event` 中的 5 小时与每周周期，ChatGPT 取订阅响应头中的主要、次要周期与 credits。按模型分开的周额度、ChatGPT 附加额度和 API 费用/余额没有会话来源，保留上次查询结果。刷新时某个账号暂时查询失败（限流、超时、服务错误等，状态为 `unavailable`），该账号沿用上次查询结果与会话观测，只更新状态与提示；未登录或需要重新授权时不沿用。快照变化时在目录事件流推送 `model-accounts.changed`（`modelAccounts` 字段），目录首帧 `catalog.snapshot` 也带当前快照，缓存为空时为 `null`。

`GET /model-accounts` 返回当前快照，缓存为空时先查询；`POST /model-accounts/refresh` 立即查询上游，进行中的查询会被复用，结果同时经事件流推送。二者都要求工作机身份与同账号访问授权，返回 `{checkedAt, accounts}`，`checkedAt` 是快照中最新数据的观测时间。每个账号包含 `id`、`provider`、`kind`（`subscription` 或 `api`）、`status`、`quotas`，以及可获得的 `identity`、`plan`、`message`。状态为 `ready`、`unconfigured`、`reauthentication` 或 `unavailable`；`ready` 表示凭据已配置或查询成功，不保证供应商开放余额查询。各提供方独立失败，HTTP 200 不代表所有账号均查询成功；查询之后有会话成功时，该账号按会话结果视为可用。响应不包含令牌、API Key 或上游错误正文。

- `quotas` 中的 `label` 是周期名称，`remainingPercent` 是周期剩余百分比，`windowMinutes` 是窗口长度，`resetsAt` 是 Unix 秒。窗口缺失表示未知，不能当成零或无限；只限某个模型或功能的额度分开返回，并以 `model` 标明范围，缺省表示整个账号共用。
- 订阅的 `plan` 是小写档位名。Claude 取 profile 接口中组织的当前订阅（如 `max 20x`），登录凭据缓存的 `subscriptionType` 升级后不更新，只在 profile 不可用时使用。
- `usage` 是该账号在这台工作机上的 token 用量，不读供应商的用量统计：`days` 为最近 53 周里有用量的日期（`date` 为 `YYYY-MM-DD`，升序）、当天 `tokens` 与 `hours`（本地时间 0–23 时每小时的 token）、按价格表折算的 `cost` 与 `costHours`（美元）、`unpriced`（价格表里没有对应模型、未计入金额的 token），`lifetimeTokens` 与 `lifetimeCost` 为 kited 保存的全部日子之和。价格表在 `kited/src/token-prices.ts`，取 Claude、OpenAI 与 DeepSeek 官方 API 价格页的标准档，按每次请求的模型与输入、缓存读写、输出分别计价；DeepSeek 按请求时间分高峰与空闲两档（北京时间周一至周五 9–12 时、14–18 时为高峰，法定节假日按国务院公布的放假安排算空闲，还没公布的年份只按星期算）；订阅本身不按 token 计费，金额只是同样用量走 API 的折算。统计来源为本机 Claude Code 会话（含 Kite 的 Claude 会话）、Kite 自研 harness 与 Codex CLI 会话，harness 的请求按模型分到 ChatGPT 或 DeepSeek；本地原始记录清理后已保存的历史仍保留。价格表变化时，仍有原始记录的用量可以重新折算。API 账号中只有这台工作机的第一个 DeepSeek 账号（与会话取 Key 的顺序相同）返回 `usage`，含本机 DeepSeek 型号的全部请求，会话记录不区分用的是哪把 Key；其他 API 账号不返回 `usage`。
- ChatGPT 的 `credits` 使用供应商的额度单位；`unlimited` 仅在上游明确返回时成立，未返回金额时省略 `value`。
- Claude 的 `extraUsage` 是额外用量（超出套餐额度后按金额计费）：`enabled` 表示是否开启，`used`、`limit`、`balance` 是按币种小数位换算后的金额，`currency` 为币种；上游没给的项省略。
- API 的 `cost` 是 UTC 当月到查询时刻的**组织费用**（`value`、`currency`、`from`、`to`），取完所有分页才返回；不是余额，也不是单个 API Key 的费用。普通调用 Key 没有组织费用权限时明确提示，不能推算余额。来源见 [OpenAI Costs](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs) 与 [Anthropic Usage and Cost](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)。
- DeepSeek 的 `balances` 保留各币种的可用余额 `total`、赠金 `granted`、充值余额 `toppedUp`，不混合人民币和美元；余额不足仍保留供应商实际返回值。来源见 [DeepSeek 查询余额](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/)。

查询失败后可重试；限流时应等待下一次刷新，不自动重试。每轮请求有总超时，不因一个提供方失败撤销其他查询。账号数据属于工作机，离线时上次结果只能作为历史信息。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/machine` | 读取这台工作机服务的持久身份 `{id, name, createdAt, version}`，`version` 为 `{build, protocol, builtAt?, commit?}`，源码运行时 `build` 为 `dev`；无需 `X-Kite-Machine`；远程访问须通过同账号组网认证 |
| GET | `/update` | 这台工作机的版本与自动更新 `{version, release, state, …}`：`release` 是最近一次发布 `{build, protocol, builtAt, commit, platform, arch, by}`，没有时为 null；`state` 为 `dev`（源码运行，不更新）、`current`、`unsupported`（平台或架构不同，带 `reason`）、`waiting-source`（在线的工作机里没有运行这一版的）、`downloading`（带 `done`、`total` 字节）、`ready`（`waiting` 列出还在等的事项）、`installing` 或 `failed`（带 `error`；`retry` 为 false 时这一版不再自动重试）；本机服务已换上的那一版 Mac App 备好时带 `app: {build, path}`。变化时目录事件流推 `update.changed`。规则见 [自动更新](macOS安装与打包.md#自动更新) |
| POST | `/update/apply` | 准备好的新版现在就换上，不等空闲，返回时多半还是 `ready`，换版开始后推 `update.changed`；进行中的回合、终端与后台命令随服务重启中断。没有准备好的新版 409 |
| GET/POST | `/update/:build/:payload`、`/update/:build/:payload/files`、`/update/:build/:payload/file` | 仅工作机：从正在运行这一版的工作机取文件。`payload` 为 `runtime`（运行目录）或 `app`（装上服务的 Mac App 中运行目录以外的部分），GET 返回清单 `{files}`，每项为 `{path, sha256, size, executable}` 或符号链接 `{path, link}`，认单段 `Range`（不带时给整份）。POST `{paths}` 返回这些文件的 tar 流。`GET .../file?path=` 返回一个文件、认 `Range`，拉取方按段取大文件；旧版没有这个接口（404）时拉取方退回 tar。都只给清单里有的路径。没在运行这一版或没有这份内容 404。这组接口跨版本兼容 |
| GET | `/model-accounts` | 读取本机模型账号、订阅额度与 API 费用/余额的当前快照，详见 [模型账号与额度](#模型账号与额度) |
| POST | `/model-accounts/refresh` | 立即查询上游并推送新快照 |
| GET | `/token-prices` | 读取用量折算金额用的价格表，只列 Kite 模型目录里的模型（计价本身覆盖更多型号）：`checked`（核对日期）与 `models`，每项是 `model`（目录里的显示名）、`provider`，以及每百万 token 的美元单价 `input`、`cacheRead`、`output`，价格页列出时带 `cacheWrite`、`cacheWrite1h`（Claude 的 1 小时缓存写入）与长提示档 `long`（`above`、`rates`）；分时计价的 DeepSeek 单价是高峰价，另带空闲价 `offPeak` |
| POST | `/network/logout` | 仅本机：退出 Tailscale 登录。节点在线时先在 Tailscale 上注销，不在线时只删本机状态（设备要到 Tailscale 管理页删）；组网开着时重起节点，状态里给出新的登录地址 |
| GET | `/machines` | 工作机目录：本机在前，每项 `{id, name, online, address?, updatedAt?, snapshot?}`，`snapshot` 是那台工作机最近一次的目录摘要，见 [账号级数据](#账号级数据) |
| GET | `/project-registry` | 项目登记表 `[{id, name, remote, url, createdAt, icon, color, integration, integrationReason?, autoHandover?, handoverNeeds?}]`；`remote` 为归一化地址，`url` 为 HTTPS 访问地址，没有远程的项目两者为 null；`integration` 为 `merge`（直接合入）或 `pullRequest`（提交 PR），`integrationReason` 是自动选择时的理由 |
| POST | `/project-registry/check` | 添加项目前的检查，不写任何东西：`{remote}` 或 `{path}`（这台工作机上的文件夹）。返回 `{remote, integration, integrationReason?, envFiles, existing?}`：`remote` 是归一化地址，没有远程的文件夹为 null；`integration` 是按仓库情况给的默认值；`envFiles` 是文件夹里被忽略的 `.env`、`.env.*` 的相对路径，远程为空；`existing` 是已登记的同一项目。远程访问不了 409，远程要账号或拒绝了访问令牌时错误体带 `gitLogin`（见 [远程要求登录](#远程要求登录)）；文件夹不存在 400 |
| POST | `/project-registry` | 添加项目 `{remote}` 或 `{path}`，另带 `{integration?, envFiles?}`：`envFiles` 每项为 `{path}`（从文件夹读）、`{path, from}`（这台工作机上的绝对路径）或 `{path, value}`（从操作的设备上选的文件）。远程与有 origin 的文件夹先确认能访问，再写进登记表，不 clone；没有远程的文件夹在这台工作机上导入成检出，原文件夹不动。环境变量文件存成设了路径的项目密钥。全部成功才登记，返回项目；同一远程已登记时返回原项目，不改它的设置，带上的环境变量文件存进它的项目密钥（已有设在同一路径的换内容）。不能添加 Kite 的数据目录或包含它的文件夹。远程要账号时同检查 |
| GET | `/host-files?path=&offset=&limit=` | 列这台工作机上的一个目录，添加项目时选文件夹和环境变量文件用，只列名字不读内容。`path` 是绝对路径或 `~/` 开头，不给时列主目录；`limit` 默认 200、最多 1000。返回 `{path, entries, total, nextOffset}`，`entries` 每项 `{name, path, kind}`，路径都是绝对的，`kind` 为 `directory`、`file`、`symlink`（目标读不到）或 `other`，目录在前。不存在 404，没有权限 403 |
| DELETE | `/project-registry/:id` | 删除项目，语义见 [删除项目](项目与远程仓库.md#删除项目)：登记、约束与项目专用的密钥一起删，这台先移除本机的检出再返回，其他工作机同步到删除后各自移除。未登记的项目 404，Line 所在的项目 409 |
| PUT | `/project-registry/:id/remote` | 给没有远程的项目设远程 `{remote}`：在这台有检出的工作机上把全部分支和标签推到远程，加上 origin，写进登记表；其他工作机的检出随项目同步加上 origin。推送被拒或这台没有检出 409，远程要账号时错误体带 `gitLogin` |
| PUT | `/project-registry/:id/settings` | `{integration?, autoHandover?, handoverNeeds?}`，至少一项：`integration` 是集成方式，没有远程的项目只能是 `merge`，手动设置后清掉 `integrationReason`；`autoHandover` 是工作机睡眠、登出、重启或关机前，把这个项目里正在工作的工作区换到别的工作机；`handoverNeeds` 是换机目标须满足的环境，取值 `xcode`（完整的 Xcode）、`iosDevice`（连着的 iPhone 或 iPad） |
| PUT | `/project-registry/:id/appearance` | `{icon?, color?}` 至少一项，未提供项不变；`icon` 为内置图标名（1–100 个 ASCII 字母、数字或句点，默认 `folder`），`color` 为 `primary`（默认）、`accent`、`green`、`purple`、`orange` 或 `pink`；返回完整项目，未登记的项目 404 |
| GET/PUT | `/project-registry/:id/constraints` | 项目约束 `{tools: {mode, tools}, execution?, mcp?: {deny}, revision}`，没设置过时为不限制的黑名单；PUT `{expectedRevision, tools, execution?, mcp?}`，`mode` 为 `allow` 或 `deny`，最多 64 个工具名；`mcp.deny` 是本项目禁用的 MCP 服务名，任何层都打不开；版本不符 409 |
| GET/POST | `/credentials` | 列出凭据的公开信息（`?type=&projectId=`，省略项目时列账号共享）`[{id, type, name, projectId, meta, createdAt, updatedAt}]`；POST `{type, name, projectId?, meta, secret}` 新建，返回 201，同类型、范围与名称已存在 409，`git`、`api`、`speech` 不接受项目。规则见 [凭据](#凭据) |
| PUT/DELETE | `/credentials/:id` | PUT `{name?, meta?, secret?}` 至少一项，改名或替换内容，类型与范围不可改，改换 API 供应商须同时提供新密钥；DELETE 不存在也成功 |
| POST | `/git/github/device` | 开始 GitHub 设备码授权 `{flow, userCode, verificationURI, expiresAt, interval}`；GitHub 无法访问时 502。`/git/github/device/:flow` 按 `interval` 轮询，返回 `{status}`（`pending`、`slow_down`、`expired`、`denied`）或 `{status: "authorized", account}`，授权成功即保存或替换 `github.com` 的 Git 凭据 |
| GET | `/git/github/repos` | 已绑定 GitHub 账号能访问的仓库 `[{fullName, url, private, pushedAt}]`，按最近推送排序，最多 100 个；没绑定时为空，GitHub 拒绝时 502 |
| GET | `/sync/changes` | 仅工作机：`?epoch=&since=&wait=` 增量拉取账号级数据，返回 `{epoch, seq, entries, more}`；`epoch` 对不上时从头给，`wait`（最多 25 秒）期间没有新变化才返回空页。组网来的请求要出自目录里的工作机，否则 403 |
| GET | `/sync/conflicts` | 并发修改时被覆盖的版本 `[{kind, id, at, by, body}]`，最近的在前；凭据只含公开信息 |
| GET/POST | `/git/:project/info/refs`、`/git/:project/git-upload-pack` | 仅工作机：本机这个项目检出的 Git 智能 HTTP，只能拉取；没有远程的项目在别的工作机上从这里 clone、快进主线，工作区副本从这里取快照链与分支 |
| GET | `/replica` | 仅工作机：本机持有的工作区（未流转走、未归档）`[{workspaceId, projectId, epoch, status, digest}]`，`digest` 在数据库行、状态或任一记录文件变化时变 |
| POST | `/replica/:id` | 仅工作机：`{known}` 是跟进方手上各记录文件的 `{size, mtime, hash}`（`hash` 是已有部分末尾一段的摘要），返回一页增量 `{epoch, files, removed, more}`，最后一页另带 `digest`、`manifest`、`rows` 与快照链和分支的提交 `git`；只长不改的文件从原来的末尾追加，大文件分几页取。见 [工作区流转](Line与工作区流转.md#工作区流转) |
| GET/PUT | `/network` | 仅本机：组网状态，上线后 `peers` 列出对端设备的连接方式（`direct` 直连、`relay` 经中继、`idle` 近期无流量），`endpoints` 是本机对外报告的端点，配了受管网络通道时 `channel` 给出通道状态（`waitingKey`、`handshaking`、`up`、`error`）与最近握手时刻；`{enabled}` 开启或关闭组网节点 |
| GET/PUT/DELETE | `/network/channel` | 仅本机：读取 `{channel}`；PUT `{endpoint, routerKey, address4, address6?}` 设置受管网络通道（`address4`、`address6` 是通道内地址，不是对外端点），DELETE 清除；组网开着时重启组网节点生效 |
| GET | `/network/channel/key` | 仅本机：通道公钥 `{publicKey}`，没有私钥时先生成；kite-net 读钥匙串可能要等用户允许 |
| GET | `/projects` | 列出本机已登记的项目身份 |
| GET | `/project-registry/:id/layouts` | 这个项目的布局 `{layouts: [{id, name, members, arrangement, revision}]}`，配方的含义见 [台面与停靠栏](台面与停靠栏.md#布局) |
| PUT / DELETE | `/project-registry/:id/layouts/:layout` | PUT `{expectedRevision?, layout: {name, members, arrangement}}` 新建（不带 `expectedRevision`）或整体替换一个布局，返回保存后的布局 `{id, name, members, arrangement, revision}`，版本不符 409；DELETE `?expectedRevision=` 删除，返回 `{ok: true}`。`:layout` 是客户端生成的 ID（1～80 个字母、数字、`.`、`_`、`-`）。布局是账号级数据，随项目登记同步，变化推 `kind` 为 `layout` 的 `library.changed`（另带 `projectId`） |
| GET | `/checkouts` | 列出本机检出（`?project=`） |
| GET/POST | `/workspaces` | 列出聚合（`?project=`），响应头 `X-Kite-Cursor` 标识列表版本，打开的工作区带 `workspace.rootNames`（工作区目录顶层的名字，App 据此识别消息里的路径，顶层在快照后有增减时发 `workspace.changed`）；创建 `{project, prompt?, role?, id?, instanceId?, messageId?}`（先检查环境，没有检出时先 clone，clone 时远程要账号的错误体带 `gitLogin`），`role` 为 `{id, revision}`，准备过程看事件；`id`、`instanceId`、`messageId` 是客户端生成的 UUID，分别用作工作区、首个代理实例和第一条消息的 ID，工作区或实例 ID 已用过返回 409，省略时由 kited 生成 |
| GET | `/environment?project=&needs=` | 这台工作机为该项目建工作区前的环境，只读；`needs` 是逗号分隔的换机环境需求，见 [工作区与线程的生命周期](#工作区与线程的生命周期) |
| POST | `/workspaces/:id/setup` | 准备失败的工作区重跑准备，设了路径的项目密钥重新写入；工作树没建成时重建 |
| POST | `/workspaces/:id/transfer` | 在持有工作区的工作机上调用，把它流转到 `{to, operationId}`：本机交出，目标补齐副本后还原并接管，返回 `{workspaceId, machine, epoch}`，返回时本机记录已冻结；目标没接成时撤回交接、工作区重新开放并返回错误。本机或目标访问远程时要账号的，错误体带 `gitLogin`，出在目标上的另带 `gitLoginMachine` |
| POST | `/workspaces/:id/handover` | 交出工作区：停下线程、保存最后的快照，进入可交接状态，返回 `{epoch}`；`/handover/cancel` 撤回，`/lease/check` 立即核对执行权。约定见 [工作区流转](Line与工作区流转.md#工作区流转) |
| POST | `/workspaces/:id/handover/complete` | 仅工作机：没有远程的项目，目标装好后通知源机交出 `{epoch, machine}`（machine 是目标自己），源机冻结本地记录并记下目标；源机已撤回、epoch 不符或这次交接已交给别的工作机时 409，已交给同一台的再通知照样成功 |
| POST | `/workspaces/restore` | 在本机还原并接管流转来的工作区 `{project?, workspaceId, operationId, from?, force?, continue?}`（没给 `project` 时从本机副本里取）：`from` 是交出它的工作机，先把副本补到它的末尾；`force` 是用户确认源机已丢失后用本机副本强制接管；`continue` 是源机有预告地离开时打断的线程与收回的排队输入，接管后接着做 |
| GET | `/summary` | 这台工作机的状态汇总：未归档工作区、线程执行状态、等你回应的对象、最近一次回合结束的时间（`settledAt`）与是否 Line 发起的工作（`byLine`）。被 kited 退出打断、要接着做的会话接着做之前像是失败了在等继续，汇总等它们接着做起来才返回；kited 关闭期间返回 503 |
| POST | `/line` | 在这台工作机启用个人 agent Line，同时建它的收件箱（Line 的 monitor 实例）；收件箱的读取、代处理与托管走实例操作，见 [实例操作](实例操作.md#monitor)。其他工作机的目录摘要里已有 Line 时返回 409。约定见 [Line](Line与工作区流转.md#line) |
| GET / PUT | `/attention` | 关注设备：`PUT {device, focused}` 声明这台设备是否在关注 Kite，须同时连着带 `device` 的事件流才生效；`GET` 返回 `{focusedDevices, awaySince?}` |
| GET | `/threads/:id/reply` | 线程最后一回合的回复（最后一条输入之后的正文）与执行状态，供 Line 读取 |
| GET | `/workspaces/:id` | 工作区上下文及 instances、threads 的完整聚合；每个实例带当前视图 `view`（没有视图的实例没有） |
| GET / POST | `/plugin-definitions` | 读取定义（含账号资源库里尚未装到本机的包）或登记自定义包；包格式见 Bun 插件契约 |
| GET / PUT | `/plugins/:definitionId/grants` | Bun 插件定义级的协作授权 `{grants, revision}`，新建实例时拷进实例；PUT `{expectedRevision, grants}` 整体替换，版本不符 409、有定义级不收的项 400、不是 Bun 插件定义 404，见 [实例操作](实例操作.md#bun-插件的定义级授权) |
| GET | `/operations` | 操作输入、输出、错误 schema，以及重试与取消规则 |
| POST | `/workspaces/:id/operations/:operation` | 调用 agent、文件或插件操作；参数、operationId 和重试语义见 [实例操作](实例操作.md) |
| GET | `/instances/:id/agent-capabilities` | 按厂商分组的模型与思考档位、这个代理可开的工具（`tools`）与角色必需的工具（`required`）、工具的界面名称与分组（`toolCatalog`），以及配置生效边界；不发模型请求 |
| GET | `/workspaces/:id/agent-options` | 尚无实例的新代理草稿读取模型目录、工具的界面名称与分组（`toolCatalog`）、这台工作机的 MCP 服务与本项目禁用的（`mcp: {available, denied}`），以及各角色在这个工作区可开的工具；角色设了默认打开的 MCP 服务时带 `mcp`；必需工具不可用的角色带 `unavailable` 原因 |
| GET / PUT | `/instances/:id/agent-config` | 读取绑定配置及 revision；以 expectedRevision 和完整 agent 配置更新，工具不能超出创建时角色的规则，也不能关闭必需工具 |
| GET / POST | `/roles` | 列出角色（带签名状态，内置角色另带默认内容的版本 `defaultRevision`，与 `revision` 不同即改过），附代理插件的全部工具及其界面名称与分组（`toolCatalog`）、提示词变量、模型目录，以及角色不设审批模式时新建代理用的 `defaultApproval`；以 `{role}` 新建角色 |
| PUT | `/roles/:id` | 以 `{expectedRevision, role}` 更新角色；不修改已有代理 |
| POST | `/roles/:id/reset` | 以 `{expectedRevision}` 把内置角色恢复默认，等同于保存默认内容；自建角色 400 |
| GET / POST | `/skills` | 列出资源库里的 skill，每项只有 `{name, revision, defaultRevision?}`，随 kited 带的另带默认内容的版本 `defaultRevision`，与 `revision` 不同即改过；以 `{skill}` 新建，名字不能与随 kited 带的重复，返回新建的那一项 |
| GET / PUT / DELETE | `/skills/:name` | `GET` 取整包 `{skill: {version, name, files: [{path, content, encoding?}]}, revision, defaultRevision?}`；以 `{expectedRevision, skill}` 更新，只返回 `{name, revision, defaultRevision?}`；`DELETE ?expectedRevision=` 删除自建的，随 kited 带的只能恢复默认 |
| POST | `/skills/:name/reset` | 以 `{expectedRevision}` 把随 kited 带的 skill 恢复默认，等同于保存默认内容，返回同 `PUT` |
| GET | `/mcp` | 这台工作机装的 MCP 服务 `{servers: [{name, config, status}], error?}`，清单文件读不了时 `servers` 为空、带 `error`，这时也不接受修改：`config` 是服务配置（含环境变量与请求头的原值），`status` 为 `{phase, message?, tools?, protocol?, server?}`，`phase` 是 `idle`、`connecting`、`connected`、`failed` 或 `unauthorized`；变化随 `mcp.changed` 送达，清单本身（服务名、说明）变了时事件带 `catalog: true` |
| PUT / DELETE | `/mcp/servers/:name` | 新增或替换一个服务，配置见 [外部 MCP 服务](#外部-mcp-服务)；已连着的断开，下次用到时按新配置连。`DELETE` 删除 |
| POST | `/mcp/import` | 以通行的 `{mcpServers: {名字: 配置}}` 逐个新增或替换，有一个不对就都不改，返回 `{servers}` |
| POST | `/mcp/servers/:name/reconnect` | 断开后马上重连，不等失败后的间隔，返回这个服务 |
| GET | `/workspaces/:id/skills` | 这个工作区的代理能加载的 skill `{skills: [{name, description, layer}]}`，四层合成后的；输入框点选时列出来 |
| PUT | `/roles/:id/emblem` | 以 `{emblem}` 保存手改的点阵签名，返回带签名状态的角色；表达式不可用时 400 |
| POST | `/roles/:id/emblem/generate` | `{force}`：为 `true` 时连手改的签名一起重新生成，否则只补缺失或过期的签名；立即返回 `{emblem?, emblemState, emblemError?}`，结果随 `kind` 为 `role` 的 `library.changed` 送达；未启用轻任务时 503 |
| PUT | `/instances/:id/role` | 以 `{expectedRevision, roleId, roleRevision}` 为代理改选角色，换上角色的提示词、工具、默认模型与预算，协作授权随角色增减，执行授权与审批模式换成角色的；已有对话时返回 409 |
| GET | `/context-templates` | 列出标题、上下文压缩、点阵签名、语音识别及各类通知模板（带默认内容的版本 `defaultRevision`）和场景变量，辅助生成的场景附可选的模型目录（`models`） |
| PUT | `/context-templates/:id` | 以 `{expectedRevision, definition, model?}` 更新模板；模板由工作机提供，不能新建 |
| POST | `/context-templates/:id/reset` | 以 `{expectedRevision}` 把模板恢复默认，等同于保存默认内容 |
| GET | `/context-variables/:name`、`/workspaces/:id/…`、`/instances/:id/…` | 按工作机、工作区或代理取一个公共变量现在的值（项目层按工作区取），范围取不到变量所在的层时 400；项目规则与记忆索引另带逐级找到的文件，见 [上下文模板](harness-上下文组装.md#模板归属与生效) |
| PUT | `/workspaces/:id/context-variables/:name/file` | 以 `{path, content, expectedSha256}` 把项目规则或记忆索引的一份文件写回这个工作区的工作树；越出查找位置 400，文件已在别处修改 409 |
| POST | `/token-counts` | 以 `{texts, model?, scene?}` 逐段计数，返回 `{model, results}`；没给模型时按场景推出。账号里有对应厂商的 API Key 时用官方计数接口（`method: api`），否则 OpenAI 按 o200k 估算、Claude 不给数；DeepSeek 没有计数接口，按 o200k 估算；`exact` 标明是否准确 |
| GET / PUT | `/threads/:id/title` | 读取标题与生成进度；以 expectedRevision 手动改名或恢复自动标题 |
| POST | `/threads/:id/title/regenerate` | 以 expectedRevision 立即重新生成标题，等待结果；不阻塞主会话控制 |
| GET / PUT | `/instances/:id/execution-grants` | 读取或修改执行授权；须停止，「允许并记住」追加网络许可例外 |
| GET / PUT | `/instances/:id/approval-mode` | 读取或设置审批模式 `{mode}`：`allowlist`、`ask` 或 `allow_all`，运行中也可改，下一次越界请求生效；读取另给按项目上限收紧后实际用的 `effective` 与上限 `max`。新建代理时依次取创建请求的 `approval`、角色的默认与 `/roles` 的 `defaultApproval`，写进实例配置的 `approval`，随工作区的 instances 下发 |
| GET / PUT | `/instances/:id/mcp` | 读取或设置代理打开的 MCP 服务 `{servers}`（服务名，可以有本机没装的，装上后生效），运行中也可改，下一次请求生效；读取另给项目禁用的 `denied` 与这台工作机装的服务 `available: [{name, description?, phase}]`。新建代理时取创建请求的 `mcp`，没给就用角色的默认 |
| GET / PUT | `/instances/:id/operation-grants` | 读取实例的协作授权及 revision；以 expectedRevision 与 grants 整体更新，代理的协作范围是其中几项授权共用的目标 |
| POST | `/workspaces/:id/instances` | 新建实例，请求与响应见下文；Bun 插件的实例有没有视图都从这里建 |
| PUT | `/instances/:id/view` | `{viewId}` 换实例当前显示的视图，须由定义声明；返回实例，各端同步 |
| GET | `/workspaces/:id/preview-targets` | 工作区的预览目标与设备候选 `{targets, devices}`：targets 每项是目标名；devices 是模拟器型号，以及与这台工作机配对过的真机，真机带名字、硬件型号、编号与连没连着，见 [实例操作 · 目标](实例操作.md#目标) |
| GET | `/instances/:id/preview/bundle` | App 窗口里那个 App 的 .app 打成的 zip，响应头 `X-Kite-App` 是 .app 的名字（百分号编码）；App 不是 .app 时 409，见 [实例操作 · App 窗口](实例操作.md#app-窗口) |
| PUT | `/apps/:name` | 请求体是 .app 的 zip，在这台 Mac 上解开到 Kite 目录的 `apps/` 下（同名的换成新的）并打开，返回 `{path}`；只接本机监听的请求 |
| DELETE | `/instances/:id` | 关闭实例：`closable` 的回收；`process` 的进程还在跑就先停、再回收；`persistent` 的 409（用归档）；已不存在 404。回收后各端的停靠栏与台面一起去掉它 |
| POST | `/workspaces/:id/threads` | 在已有工作区创建代理 `{prompt, role?, model?, tools?, approval?, mcp?, instanceId?, messageId?, attachments?}`；`attachments` 是第一条消息带的附件 ID，带附件时 `prompt` 可以为空；`instanceId` 是客户端生成的 UUID，用作代理实例（也是线程）的 ID，已用过返回 409，省略时由 kited 生成；`messageId` 是客户端生成的 UUID，用作第一条消息的 ID，省略时由 kited 生成；`role` 为 `{id, revision}`，省略时用默认角色。其余字段覆盖角色的默认值：`model` 为 `{model, reasoning}`，后端随模型确定；`tools` 须在角色规则之内并包含必需工具；`approval` 为审批模式 |
| GET | `/threads/:id` | 线程和上下文，附带 `runner`、`busy` |
| GET | `/threads/:id/state` | 只读执行状态，不启动模型 |
| GET | `/threads/:id/history` | v1 显示历史、pending、state 和 cursor，只读 |
| GET | `/threads/:id/raw` | 调试查看原生记录，只读：harness 的 journal 与 Claude 的会话文件逐条原样给出，两份各按文件顺序、按时间交错。`?journal=&claude=` 是上次读到的条数，省略为 0；返回 `{journal, claude, reset, entries}`，每条 `{source, index, at, label, text}`，`text` 是缩进好的原文，图片的 base64 换成占位；起点超出现有条数（记录被整份换掉）时 `reset` 为 true、从头给。格式随后端与 CLI 版本变，不是稳定契约 |
| PUT / GET / DELETE | `/workspaces/:id/attachments/:attachment` | 上传、读取（`?size=` 取缩略图，原件认 `Range`）、删除还没发出的消息附件，语义见 [会话显示协议](会话显示协议.md#附件) |
| PUT / POST | `/workspaces/:id/attachments/:attachment/parts/:offset`、`/workspaces/:id/attachments/:attachment/parts` | 分段上传附件：各段 PUT 到自己的位置，传完 POST 核对后收下，见 [会话显示协议](会话显示协议.md#附件) |
| POST | `/threads/:id/messages` | 发消息 `{text, id?, attachments?, relay?}`，返回 `{id}`；`attachments` 是这个工作区里存好的附件 ID，只有人发的消息能带；harness 落盘后确认，同 id 和内容去重。带 `X-Kite-Source` 时是 Line 的说明（来源 kite），再带 `relay: true` 是 Line 照原文转达的用户的话（来源仍是人） |
| POST | `/threads/:id/messages/:message/cancel` | 按后端能力撤回尚未交接的输入 |
| POST | `/threads/:id/interrupt` | 停止会话，返回尚未纳入请求的队列；请求 `{id, inputs?}`，响应 `{returned}` |
| POST | `/threads/:id/resume` | 继续等待继续的线程（App 的「继续」）；可带 operationId 以安全重试 |
| POST | `/threads/:id/waiting/:waiting` | 回应线程在等的审批 `{decision}`，或没回应的提问 `{answers}`、密钥请求 `{secret: {values, scope?}}`（按请求的顺序逐项给值，没填的为 `null`），提问与密钥请求也可以 `{decision: "deny"}`；请求处理后结果作为一条输入交给代理，可带 `reason`；密钥请求不接受 `X-Kite-Source`，填的值只存进凭据；带 `X-Kite-Source` 时是 Line 代处理，提问的结果写明由 Line 代答及理由。已回应、作废或收回返回 409 与当前的 `waiting`。约定见 [工具审批与提问](工具审批与提问.md) |
| POST | `/threads/:id/compactions` | 手动压缩上下文 `{id, from, through}`，起止为输入 id；校验通过即返回，结果经显示事件送达 |
| DELETE | `/threads/:id/compactions/:compaction` | 撤销最外层的一次压缩 |
| POST | `/instances/:id/archive` | 归档独立存续的实例（agent 或 Bun 插件），保留所属工作区；agent 连同同一工作区里它开出的各层子代理 |
| GET | `/workspaces/:id/snapshots` | 工作区快照，新的在前 |
| POST | `/workspaces/:id/restore` | 恢复文件到快照 `{commit}` |
| POST | `/workspaces/:id/adopt` | 按项目的集成方式集成。直接合入返回 `{status: "adopted", commit, push}`，`push` 为 `{status: "pushed"}`、`{status: "local"}`（没有远程）或 `{status: "failed", message, gitLogin?}`，远程要账号时带 `gitLogin`（主机）；提交 PR 返回 `{status: "proposed", branch, url, number?}`，`url` 是 PR 页面，不能自动开 PR 的平台是去开 PR 的网页、没有 `number`；有冲突时返回 `{status: "conflict", files}`；提交 PR 时拉取或推送不了 409，远程要账号时错误体带 `gitLogin` |
| POST | `/workspaces/:id/sync` | 同步：拉取主线合进工作区分支；返回 `{status: "synced", commit}`、`{status: "current"}`（已是最新）或 `{status: "conflict", files}`；线程没有全部空闲 409。拉不到远程时照用本机主线与上次拉取的远程主线，远程要账号时不同步，409 且错误体带 `gitLogin` |
| PUT | `/workspaces/:id/name` | `{mode: "manual", name}` 手动命名，名称须为 1～80 字符的单行文本；`{mode: "auto"}` 切回自动并当场重起，见 [轻任务与会话标题](#轻任务与会话标题)；返回工作区，已归档或已交给别的工作机时 409 |
| POST | `/workspaces/:id/archive` | 归档工作区 `{force?}`；Line 所在的工作区 409 |
| GET | `/events` | 目录 SSE：首帧 `catalog.snapshot`，随后检出、工作区和线程概要变更 |
| GET | `/events?workspace=<id>` | 工作区 SSE：首帧 `workspace.model`，随后工作区操作与所属线程概要 |
| GET | `/events?thread=<id>` | 线程 SSE：首帧 `thread.history`，随后线程显示与状态事件 |
| GET | `/voice?thread=<id>` | 语音输入的 WebSocket，见 [语音识别](#语音识别)；`thread` 是正在输入的会话，新会话不带。App 推 16 kHz 单声道 s16le 的 PCM 二进制帧，说完发 `{"type":"finish"}`；工作机推 `{"type":"partial","text"}`（到目前为止的全文），最后推 `{"type":"final","text"}` 或 `{"type":"error","message"}` 后关闭。连上之后的错误（如没有凭据）都以 `error` 消息给出 |

skill 文件的 `encoding` 省略时，`content` 是 UTF-8 文本；`encoding: "base64"` 时是原始字节的规范 base64（保留填充）。`SKILL.md` 不能用二进制编码，文件路径须在包内，最多 200 个文件，4 MiB 上限按解码后的字节计。旧文本包仍可读取；账号同步原样保存包，不支持该文件编码的旧工作机暂不物化，升级后再落盘。

新建实例的请求为 `{id, definitionId, title?, command?, preview?, page?}`：`id` 是客户端生成的 UUID，用作实例 ID，App 据此在工作机确认前先把它放上本机台面；`title` 是新实例的名字，省略时按插件名编号（带 `preview` 时用目标名）；`command` 只用于终端，见 [实例操作 · 终端](实例操作.md#终端)；`preview` 只用于预览、必带，`{target, device?}`，同一目标与设备已经在跑时返回那个实例、不新建，`device` 是 `{simulator: 型号}` 或 `{physical: 设备编号}`，见 [实例操作 · 目标](实例操作.md#目标)；`page` 只用于浏览，`{port}` 或 `{url}`，打开到一个网页，见 [实例操作 · 浏览](实例操作.md#浏览)。内置代理（`kite.agent`）提供 `conversation`，浏览（`kite.files`）提供 `files`，终端提供 `terminal`，预览提供 `screen`、`grid`、`output`，这些是 `PUT /instances/:id/view` 能换的视图。新建的空 agent 不调用模型；monitor 不从这里建。

响应是实例，带当前视图 `view`（没有视图的实例没有这一项）。同一 `id` 同内容重试返回同一个实例；`id` 已用于别的内容、或那个实例已回收时 409，迟到重试不会复活实例。各端怎样呈现见 [台面与停靠栏](台面与停靠栏.md)。

`/threads/:id` 使用 agent 实例 ID；原生后端 ID 不用于此接口。工作区聚合包含所属实例与线程，具体类型见 [领域模型](../kited/src/model.ts)。实例操作的参数、授权和收据统一见 [实例操作](实例操作.md)，文件引用见 [资源引用](资源引用.md)。

`POST /project-registry` 添加本机文件夹时：

- 目录是仓库根且有 origin：按 origin 登记，与添加远程相同。origin 无法识别为平台地址（如本地路径）时返回 400。
- 没有 origin：导入成没有远程的项目，检出建在数据目录的 `repos/<项目 ID>.git`，不建远程、不推送，原文件夹不写任何东西。已有仓库的取全部分支，工作目录里未提交的改动另作一个提交放在主线上；不是仓库的按 `.gitignore` 与 `.gitattributes` 模板把文件提交进检出，模板只进检出，不写进原文件夹。
- 目录位于仓库内部时拒绝。

按项目建工作区而本机没有检出时 clone 到数据目录的 `repos/<项目 ID>.git`：有远程的从远程 clone，没有远程的从在线、有它检出的工作机 clone，不留 origin。clone 期间请求不受空闲超时限制。访问远程时，为该平台绑定了 Git 凭据则临时改用 HTTPS 并注入凭据，否则照原样使用 origin 与用户自己的 Git 配置；kited 不改写 origin 的写法。

kited 在启动、登记表变化时和每 5 分钟对照一次项目登记表：项目改了名或远程的，本机记录跟上，各检出的 origin 改为新地址；项目并入了另一个项目的，本机检出改挂过去。没有远程的项目从有它检出的其他工作机拉取全部分支，本机主线落后时快进；两边都有新提交时不合并，留给用户在工作区里集成。有远程的项目拉取远程主线。随后更新各工作区的 `behind`，并查询提交 PR 的工作区的 PR 状态。登记表变化时只对齐本机记录，拉取主线与这些刷新留给启动和定时的那几次。采纳在没有远程的项目上只到本机主线（`push.status` 为 `local`），其他工作机同步时快进过来。

连接时先读 `GET /machine`。其余接口（包括 SSE）必须带 `X-Kite-Machine: <id>`：缺失返回 400，和服务身份不符返回 409，并在执行请求前拒绝。这个检查用于防止地址复用时操作错机器，不承担认证。本机监听的接口只接受 `Host` 为 `127.0.0.1` 或 `localhost` 的请求，其他主机名返回 403，用于阻止网页借 DNS 重绑定访问本机服务；远程监听只接受已核验身份的组网代理，见[远程连接](#远程连接)。App 会保存身份，重连时继续使用原 ID；CLI 在一次命令内固定目标 ID。

工作区聚合和线程上下文包含 `machine`，检出包含 `machineId`。SSE 按目录、工作区和线程分别订阅，每次重连从完整快照恢复；事件、游标与流式内容统一见 [会话显示协议](会话显示协议.md)。

### 远程要求登录

HTTPS 远程要账号或拒绝了访问令牌时，访问远程的接口（添加项目及其检查、建工作区时 clone、提交 PR、同步、设远程、流转与接管）返回 409，错误体除 `error` 外带 `gitLogin`（主机，可能带端口）。请求经这台工作机转给另一台、在另一台上出的（流转时目标的还原），另带 `gitLoginMachine`，是那一台的 ID；没有时就是接请求的这台。App 据此让用户就地绑定这个主机的 Git 凭据，写到 `gitLoginMachine` 或接请求的那台，免得等同步，再重试刚才的请求。直接合入在合进本机主线之后才推送，推送要账号时请求本身成功，在结果的 `push` 里带 `gitLogin`，重新集成即推上去。

## 验证入口

项目测试规则以 [AGENTS.md](../AGENTS.md#测试) 为准，构建与检查命令见 [kited README](../kited/README.md)，Swift、WebKit、真实模型后端和远程链路的验证见 [手动验证入口](../kited/test/manual/README.md)。

## 当前能力边界

远程连接需要组网，iPhone 真机经组网连接的完整验收尚未完成。Linux 沙箱实机验证、资源配额、独立终端授权编辑和脱离进程组的后台任务尚未完成；Git 元数据只读，不能假设模型工具可直接暂存或提交。文件快照回退已提供，会话历史的回退与分叉尚未提供。

Claude 原生能力的开放范围以本文专节为准。

## 外部 MCP 服务

外部 MCP 服务只来自这台工作机，见 [产品架构](产品架构.md#两层协议与上下文)。清单存在数据目录的 `mcp/servers.json`，写法与通行的 `mcpServers` 相同，只有本人可读写，也在宿主保护路径里，代理的命令读不到：

- 本机程序 `{type: "stdio", command, args?, env?, cwd?, description?}`：`type` 可以省略。环境只带开发工具的基础设置（与代理的命令相同，PATH 取 kited 的）再加 `env`，工作目录默认用户主目录；命令找不到时写绝对路径。
- 远程服务 `{type: "http", url, headers?, description?}`：只接 Streamable HTTP，SSE 传输在新规范里已弃用，不接。要登录的服务先在 `headers` 里放令牌，OAuth 登录尚未接入。
- `env` 与 `headers` 的值里可以写 `{account.名字}`，引用 [凭据](#凭据) 里账号共享的密钥，连接时取出明文替换，清单里只存引用；服务属于工作机、不属于某个项目，不认 `{project.名字}`。直接写的值以明文存在清单里，`GET /mcp` 也原样返回，令牌应改用引用。
- `description` 是给代理看的一句说明，出现在基础上下文的服务清单里。

每个服务一条连接，所有代理共用，第一次有代理要用时连上；会话启动前最多等 5 秒，还没连上过的这次不给工具，之后的请求再给。连上后取到的工具目录一直沿用到服务通知变化或配置被改，断开期间照样给模型，调用时再连，连不上的调用记为没执行。失败的隔 30 秒再试，要登录的不自动重试，App 里可以手动重连。协议按 2026-07-28 版（无状态），SDK 先探测服务支持的版本，旧版服务退回原来的握手；不实现 sampling、roots 与 logging，也不向服务声明补充信息（elicitation）的能力。工具目录按服务给的缓存时长缓存，服务通知变化时刷新。旧版 stdio 服务若把状态放在进程里，几个代理共用一个进程时会互相影响，目前不按代理分开。

服务是用户装在这台工作机上的普通程序，不在 Kite 的沙箱里，代理的执行授权管不到它；授权一个服务等于把它能做的事交给代理。谁能用由三层决定：项目约束的 `mcp.deny` 禁用，角色的 `mcp` 是新建代理默认打开的，实例上可以再开关；新装的服务默认谁都不能用。生效的服务列在公共变量 `mcp.servers` 里，它们的工具和插件工具一样按需加载：工具名为 `mcp__服务名__工具名`，自研 harness 经 `tool_search` 按服务名加载，Claude 经 ToolSearch 搜到。单次调用最长 30 分钟，有进度就续期；结果里的文字、PNG/JPEG/WebP 图片交给模型，超过 10 万字截掉；发出后断开或停止的调用结果记为不明。

## Bun 自定义插件

自定义插件使用预构建 Bun 包，提供 MCP 工具、资源和 App Web 视图。安装、模型授权、停止与未知结果处理见 [Bun 插件宿主](Bun插件.md)，共享身份与生命周期见 [Agent 与插件契约](Agent与插件契约.md)。
