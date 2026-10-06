# 工作机：使用与服务契约

kited 新会话默认使用自研 harness 和 ChatGPT 订阅，已接通独立工作树、快照、回退、采纳和归档。产品模型保存工作机，以及「项目 → 检出 → 工作区 → 插件实例」及其专有 Thread 和窗口关系，`/workspaces` 提供完整聚合。工作区拥有目录、快照和采纳，线程拥有独立对话与执行状态；登记检出会建立一个没有线程的根工作区。终端入口可直接在指定目录工作；App 已接工作区列表、动态会话与插件窗口、harness 真实对话、统一历史与 SSE 重连，协议见 [会话显示协议](会话显示协议.md)。

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

模型清单由仓库根目录 `shared/agent-models.json` 统一维护，App、工作机和 CLI 共用，每个 tier 只列当前选定版本。默认模型 `gpt-6.1-sol`、推理强度 `medium`，可用 `--model`、`--reasoning` 指定，模型名也可通过 `KITE_MODEL` 设置。一次任务跑完就退出：

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

当前提供 `read`、`patch`、`shell`。`read` 按行读取文本；`patch` 合并创建、修改和删除，支持一批多个文件，参数与失败语义见 [基础工具契约](harness-主循环.md#patch)。未读过、或自上次读取/修改后文件有变化，都仅提示；补丁无法匹配当前内容仍会失败。读取版本目前只保留在本次运行内，恢复会话后按没有本次运行记录提示；尚未实现持久化的观察账本。

`shell` 每次调用必须填写非空白的 `description`，用简短的话说明命令用途，不指定语言，前端直接显示为这次调用的描述；原始命令保留在详情里。`read`、`patch` 的摘要可由文件路径和操作生成，不要求模型另填描述。

上下文可使用段落、变量和条件模板。项目规则与记忆索引按模板需要提供，记忆正文按需读取；基础指令固定，后续有效正文变化追加到历史。App 提供创建会话、标题及四类通知模板编辑，独立终端沿用自身入口定义。模板格式与生效规则见 [上下文模板](harness-上下文组装.md)，投递规则见 [线程通知投递](线程通知投递.md)。

文件工具限制在工作目录内，并和 shell 共用执行策略。shell 通过共用适配层进入操作系统沙箱：默认工作树可读写、必要系统工具链可读、网络关闭；每次调用有独立配置、网络代理和临时目录。登录凭据、数据库和会话记录禁止模型工具读写；Git 元数据只读，快照与采纳由宿主执行。缺失依赖、隔离能力降级或配置错误会拒绝启动。

macOS 使用 Seatbelt；Linux 使用 bubblewrap，需要 `bwrap`、`socat`、`rg` 及上游 seccomp 支持，目前只在 macOS 验证。kited 的 agent 实例可通过 `GET / PUT /instances/:id/execution-grants` 保存和编辑工作区读写、额外目录及网络许可，须先停止并确认执行结果；变更在下一次自然模型请求追加通知，不唤醒或重放命令。App 在实例设置的「执行授权」页编辑 harness 与 Claude 的 Kite 工具授权；独立终端的授权编辑尚未接入。本机 HTTP 尚未鉴权，当前不允许通过授权编辑开放回环地址。完整规则见 [实例执行授权](实例操作.md#实例执行授权)。命令输出限长并保留完整日志，后台任务暂不支持。每回合默认最多 50 次模型请求，达到后暂停，`--max-requests` 可调整。

这个终端入口直接修改指定目录。要使用独立工作树、快照和采纳流程，请通过下面的 kited HTTP 或 `kite` 客户端创建会话。独立终端未接 agent 协作工具；harness 的 skill 自动发现、MCP 和上下文压缩仍待实现。异常退出留下的 `lock/` 不会自动删除；先根据 `lock/owner.json` 与 `processes.json` 确认原进程及命令均已停止，再清理该会话的锁并重新打开。执行效果未知时保持暂停，不重放旧工具。

## 会话后端与宿主边界

一段持久会话称为 Thread，执行资源可以关闭后重新建立；关闭执行实例不删除会话。新会话默认使用自研 harness，App 或 HTTP 也可选择 Claude。两者各自负责完整 agent 循环，共用工具服务、授权、快照和显示协议，保留各自的原生恢复身份。

harness 的输入可靠保存后才确认，工具结果和批次快照完成后再继续请求；断流或快照失败暂停会话，未知结果需要先核查。管理操作不自动唤醒排队输入。完整执行与恢复要求见 [harness 执行约定](harness-主循环.md)。

agent 配置绑定到实例，重启沿用已保存内容；默认编程定义提供 read、patch、shell 及 agent 操作，只读审查定义提供 read，实际可执行范围受授权限制。实例创建时可用 `KITE_MODEL` 选择 harness 模型。当前默认型号见 [共享模型目录](../shared/agent-models.json)，配置变更的时机见 [线程通知投递](线程通知投递.md)。异常退出的锁须先核查原执行，确认恢复后再显式继续。

## 运行

### 轻任务与会话标题

轻任务提供一次性文本生成，供标题及后续摘要、标签等功能使用。后台请求串行执行，默认 30 秒超时，不提供工具，不创建线程，不写入主会话历史；只有模型完整完成才接收结果。日志只记用途、耗时、用量及错误，不记录输入正文。kited 关闭时取消正在执行与排队的任务并等待退出。

辅助模型与主会话模型独立配置，所有标题统一使用这台工作机的 ChatGPT 授权直接请求订阅 Responses 接口。轻任务只复用模型传输层，不启动 harness 会话循环或 Claude SDK 进程，也不依赖 Claude 登录。Claude 自带的会话自动命名保持关闭，Kite 统一负责标题的生成与保存。

| 环境变量 | 默认值 | 用途 |
|---|---|---|
| `KITE_LIGHT_MODEL` | 共享模型清单的 `luna` 档 | 轻任务模型 |
| `KITE_LIGHT_REASONING` | `low` | 轻任务推理强度 |
| `KITE_LIGHT_TASKS` | 开启 | 设为 `0` 关闭自动轻任务 |

首条消息被接收后立即并行生成标题，原首条消息标题作为即时占位；以后每次接收新消息都触发检查，不等待主会话完成，也没有时间间隔限制。默认命名规则要求模型比较最新请求与已有工作：工作方向转变或工作内容增加时更新标题，只是继续、追问或汇报进展且原题仍准确时返回原题。

材料取近 3 天、最多 20 轮用户请求及完成的回复正文，包含已接收但尚未交给主模型的排队消息。JSON 总长度最多 12,000 字符；省略工具、思考及代码块，每轮请求最多 1,200 字符、回复保留末尾 1,600 字符。没有近期材料不改名。检查截止位置以输入消息为界，回复完成本身不重复触发生成。

标题使用一份可编辑的 `thread.title` 模板 `kite.thread-title.generate`，命名规则和材料在同一编辑器内分区展示，共用一份 revision 并一起保存。规则区 `blocks` 用作模型指令，材料区 `input` 用作输入正文；两区均可编辑段落、条件和变量（当前标题、近期对话）。自动生成与点击刷新在每次生成开始时读取已保存的模板并组装；编辑不影响已在途的请求，重启不会覆盖保存内容。标题模板按固定用途使用，不参与创建会话的模板选择；单行、80 字符等结果约束仍由标题业务校验。

手动命名后停止自动覆盖，`agent.start` 显式传入的标题也按手动命名处理。`GET /threads/:id/title` 返回 `title`、`mode`、`revision`、`generatedAt` 和 `through`；`PUT` 同路径传 `{expectedRevision, mode: "manual", title}` 修改标题，或 `{expectedRevision, mode: "auto"}` 恢复自动生成。标题须为 1～80 字符的单行文本；版本冲突返回 409。切回自动立即检查已接收的消息，包括主会话正在执行的情况。App 沿现有事件同步标题，并在 header 主标题处显示真实会话标题与小刷新图标，次级信息显示窗口类别“代理”；点击标题或图标重新生成。手动命名与模式切换目前通过 HTTP 提供。

`POST /threads/:id/title/regenerate` 传 `{expectedRevision}`，等本次生成完成后返回标题快照。显式重生跳过相同消息位置检查，沿用原有 auto/manual 模式；主会话执行期间也可生成，不打断会话。受理后更早的在途标题结果失效，等待生成不阻塞主会话控制。失败返回错误并保留原题及生成进度；生成期间被其他操作改名则返回 409。App 等待期间禁用重复点击，错误在原窗口提示。

生成期间发生的手动改名或模式切换会使旧结果失效；在途请求期间的新消息合并到紧接着的一次检查，使用届时最新材料。成功检查的时间和输入截止位置持久保存，即使模型返回原题也会推进。失败保留原题，后续新消息仍触发检查，不升级到主模型。自动更新只在接收消息或显式切回自动时检查，不定时扫描全部历史会话。

### 启动服务

macOS 用户级安装及登录自启使用仓库根目录的 `./install.command --service-only`，完整流程见 [macOS 安装与打包](macOS安装与打包.md)。以下命令供源码开发时前台运行：

```bash
cd kited && bun install
export PATH="$PWD/node_modules/.bin:$PATH"
bun src/main.ts
```

`KITE_HOME` 默认是 `~/.kite`，里面放数据库 `kite.db`、工作树 `worktrees/<项目>/<工作区>/`、初始化日志 `workspaces/<工作区>/setup.log` 和线程记录 `sessions/<线程>/`。`KITE_PORT` 默认是 5483，监听 127.0.0.1；组网与远程监听见下节。

工作机服务的 `Machine.id` 首次启动时生成 UUID，保存到 `kite.db`，同一数据目录重启或更换端口时保持不变；新数据目录生成新身份。名称初始取主机名，地址由客户端保存。检出通过 `machineId` 引用所属机器；项目也使用 UUID，不按文件夹名推断跨机器的项目关系。

同一项目可以在本机或其他工作机登记多个检出。关联时提供完整项目身份 `{id, name, createdAt}`，接收方保存同一个项目 ID，各自生成检出和根工作区 ID。每台 kited 只保存本机的目录、工作区、线程与执行记录；关联不复制文件，不克隆或同步 Git 仓库。App 缓存访问过的工作机所返回的项目身份，登记目录时可从中选择。

默认 harness 使用前文独立授权的 ChatGPT 凭据。只有 `claude` 会话需要 Claude 登录；它用 kited 的环境启动子进程，并显式关闭下文列出的附加功能。Claude 会话不自动读取用户、项目或本地设置，OAuth 与钥匙串认证保留。

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

手机和其他电脑经组网连接工作机。kited 与 App 都内嵌组网节点（Tailscale 的 tsnet / TailscaleKit），各自以独立节点上线，不需要安装 Tailscale 客户端，也不占用系统 VPN。链路加密由 WireGuard 承担，kited 负责认证设备。控制服务器默认是 Tailscale 官方服务；kited 可用 `KITE_CONTROL_URL` 改用自建的 headscale，App 端暂未提供此设置。

- **组网节点。** `kite net up` 开启组网，kited 启动 `kite-net`（`kited/net`，Go 编写，需单独构建），首次上线需要登录：已保存 headscale 管理密钥时 kited 自己签发入网密钥自动登录，否则给出登录网址，在浏览器登录一次（headscale 的登录页需在服务器上执行页面所示的注册命令）。登录后节点保持登录。`kite net` 查看状态，`kite net down` 停止节点但保留登录。节点状态与登录凭据在 `KITE_HOME/tailnet/`，开启与否也记在这里，服务重启后沿用；kite-net 异常退出时 5 秒后重启。节点名为 `kite-<主机名>`。Tailscale 节点密钥默认会定期过期，过期后按同样方式重新登录。
- **headscale 管理密钥。** `kite net admin <API 密钥> [用户]` 校验并保存 headscale 的 API 密钥（`headscale apikeys create` 生成），存于 `KITE_HOME/tailnet/headscale.json`，仅本用户可读，不开放给插件或模型工具。之后 kited 按需签发归该用户的一次性入网密钥，10 分钟有效。使用 Tailscale 官方服务时不支持。
- **监听。** 远程监听只绑回环地址的随机端口，kite-net 把组网 5483（同 `KITE_PORT`）端口上的连接原样转给它。远程监听不做主机名检查，只认配对令牌；本机监听不变。`GET /network` 和 `PUT /network {enabled}` 只在本机开放，返回 `{enabled, state, loginURL?, ips?, name?, address?, error?}`，`address` 是上线后供远程设备填写的 `http://<组网 IPv4>:5483`。
- **配对。** 配对码只能在本机生成：`kite pair`，或 Mac App 连本机服务时在设置的「远程设备」中点「添加设备」。配对码 8 位，10 分钟内有效，只能使用一次，只存在内存，服务重启即失效。组网上线后同时给出二维码，内容是邀请链接 `kite://pair?address=…&code=…&control=…&key=…`：组网地址、配对码、控制服务器（自建时）和入网密钥（有管理密钥时）。iPhone 用相机扫码打开 Kite，App 按链接设置组网、用入网密钥上线，再用配对码连接，全程无需输入或浏览器登录。邀请链接相当于一次性密码，只在本机显示。远程客户端用 `POST /pair {code, name}` 换取 `{machine, device, token}`。
- **认证。** 远程监听上除 `/pair` 外的接口（含 `/machine` 和 SSE）都要带 `Authorization: Bearer <token>`，再按本机规则带 `X-Kite-Machine`。每台设备一个令牌，不过期；服务只保存摘要。缺少令牌或令牌已撤销时返回 401。配对码生成、设备列表和撤销只在本机监听开放，远程令牌不能签发或撤销令牌。
- **撤销。** `kite revoke <设备>` 或 App 中撤销后，该设备已建立的事件流立即断开，之后的请求返回 401。
- **连接恢复。** 网络错误和服务重启按原有方式重连：重新订阅后以首帧快照替换本地副本，控制请求依靠请求 ID 去重。401 不会自行恢复，客户端停止重试，提示重新配对；409 表示地址背后换了工作机。同一工作机的组网地址变化时，客户端保留机器身份和令牌，只更新地址。
- **客户端。** App 把令牌存进钥匙串（仅本机、首次解锁后可读），不写进偏好设置。连接地址是组网地址（100.64.0.0/10、Tailscale IPv6 段或 `.ts.net` 名称）时，App 先让自己的组网节点上线，再经节点的本机代理发请求；没有入网密钥时首次上线自动打开浏览器登录。手动连接时可在连接页或设置中填写自建的控制服务器。iOS 挂起后系统会回收节点的本机代理，App 进入后台时关闭节点，回到前台重连时重新上线。经代理的请求即使目标是 IP 也受 ATS 限制，App 因此放开明文加载；kited 的远程流量由 WireGuard 加密，本机连接只到 127.0.0.1。

## 工作区与线程的生命周期

1. **登记检出**。可以新建项目，也可以显式关联已有项目。已有 Git 仓库的提交归用户（`commits: user`）；普通文件夹由 Kite 初始化 Git、写入 `.gitignore` 模板并提交初始版本（`commits: kite`）。同步盘里的仓库本体放到 `KITE_HOME/repos/<检出>.git`，同一项目的多个检出各用一个仓库。项目、检出和根工作区一次落库，根工作区直接使用登记的目录，不创建线程。
2. **建独立工作区**。起点是检出当前的 HEAD；Kite 代管提交时先提交主目录的改动。工作树放在 `worktrees/<项目>/<工作区>/`，分支为 `kite/<工作区>`。可以先建空工作区，也可以带首条消息，准备完成后启动首个线程。
3. **准备工作树**。`worktree.symlinkDirectories` 做软链接，`.worktreeinclude` 指定的忽略文件做 APFS 克隆。执行 `.kite/setup`，通过 `KITE_MAIN_DIR` 传入检出路径；脚本非零退出或被打断时工作区变为 `failed`。成功后保存「工作区开始」快照并变为 `open`。
4. **添加线程**。根工作区和独立工作区都可添加多个线程；每个线程有自己的身份、journal 和运行时，使用所属工作区的 cwd。目前同一 cwd 有线程运行或等待恢复确认时拒绝启动另一个线程；这不影响单个 harness 内允许的工具并行。
5. **对话与收口**。harness 先将输入写入 journal 再确认，运行中插话在下一请求纳入。工具结果和快照完成后才继续请求模型，断流或快照失败会暂停。Claude 宿主先保存输入收据，再立即写入 SDK 的持续输入流。运行中插话由 Claude 在自然边界纳入，工具后的下一次请求即可读到；SDK 确认未纳入的消息可以撤回。结果返回且输入队列清空后关闭进程，之后用原生会话 ID 续接。
6. **快照与回退**。快照链属于工作区，位于 `refs/kite/snapshots/<工作区>`，不改 HEAD、分支或暂存区。每批工具后与回合结束时捕获，树未变则不重复提交。回退只恢复文件，先保存现状；工作区内有线程运行或等待恢复确认时不允许回退。
7. **打断与继续**。线程控制作用于该线程；准备中的首个线程被打断时会中止工作区初始化。恢复确认只核查未知进程已停止，不自动执行输入，之后通过 `resume` 继续。
8. **采纳**。独立工作区把改动合回检出主线。同一检出的 Git 集成串行执行；冲突留在独立工作树，交给其中一个打开的线程处理；agent 只能编辑文件解决冲突，不能写 Git 元数据。该回合正常完成后，宿主把已去掉冲突标记的文件标为解决、提交合并并自动重试；仍有冲突标记时报告冲突，不再转交。手动重试遗留冲突会再次转交。主目录不会进入冲突状态。采纳后工作区与线程仍可继续使用。
9. **归档线程**。停止该线程并记录 `archived`，保留工作区、文件、其他线程和快照。
10. **归档工作区**。先检查未采纳改动，再停止所有线程，保存最后快照，删除独立工作树和分支，归档实例并关闭全部窗口记录；未采纳改动需要显式 `force`。根工作区不能用此操作删除。

## Claude 会话的上下文

Claude runtime 从空工具集开始，功能逐项接入。Claude 适配层使用 SDK 的 `tools: []` 关闭全部内置工具，`skills: []` 清空模型可用的技能列表，`strictMcpConfig: true` 阻止自动加载项目、用户及插件里的 MCP 服务器。内置 Claude 定义开放 Kite 的 `read`、`patch`、`shell` 和五个 agent 操作工具，实例配置和操作授权共同决定实际工具集合；另外只注入显式授权的插件工具。每次启动或恢复进程都按当前配置创建 MCP 服务器。SDK 初始化事件的 `skills` 仍可能列出发现的技能元数据，不能把它当作模型已获准使用的能力。

`kited/src/claude/tools.ts` 通过 SDK 进程内 MCP 接入共享工具，模型中的名字带 `mcp__kite__` 前缀，Kite 显示协议保留原来的短名称。read 参数是 `path`、可选的 `offset` 和 `limit`；按行读取工作目录内的文本，默认 200 行，结果带行号。路径、符号链接、宿主私有目录及输出限制共用现有检查。shell 使用同一操作系统沙箱、输出日志和进程组登记，增量输出直接更新工具行。实例设置页可编辑执行授权，每次执行重新检查权限。

patch 使用同一份 `operations` 参数和 V4A 补丁解析，支持创建、修改与删除文本文件；read 与 patch 在同一宿主内共享读取版本，宿主重开后重新记录。失败作为工具错误返回；整批写入前先检查，实际磁盘写入失败仍可能留下部分修改，按结果处理，不自动重放。已完成修改的前后全文保存在工作区的历史 diff 目录，可经 `files.diff` 读取。除 read 返回原文外，共享工具返回 `structuredContent: {status, output, diff?}`，普通 content 也携带同一份 JSON，因为 SDK 在 `isError` 时只转发 content。投影恢复原始结果、四种执行状态及 diff 引用，每批工具结束后通过 `PostToolBatch` 等待 Kite 快照完成，再继续请求模型。

agent_list / start / send / resume / stop 和插件工具直接调用现有 `InstanceOperations`；调用身份来自 SDK 的 MCP 元数据，不能由模型填写。创建、发送及停止沿用操作收据。默认 Claude 只获准管理自己创建的 agent；目标可使用 Claude 或 harness。授权撤回立即阻止新的执行，新增工具在下一次空闲后启动进程、重建目录时生效。

Claude 的模型、工具、基础上下文和请求预算保存于实例配置，默认 `sonnet`、`medium`，创建时可通过 `KITE_CLAUDE_MODEL` 覆盖模型。App 的模型目录固定为 Fable、Opus、Sonnet 三档，各档的实际型号与思考强度由上游当前能力确定；配置和执行授权须在空闲且无恢复阻塞时修改。项目规则与记忆索引由 Kite 上下文组装器按实例模板显式注入；首次系统提示固定，后续更新与持久通知使用可编辑的通知模板，在输入纳入和工具批次结束、下一次模型请求之前追加正文；不因收到通知独立启动新回合。Claude Code 不自行扫描这些材料。

`kited/src/claude/host.ts` 只负责输入交接和 Kite 能力，模型循环与对话仍由 SDK 管理。`sessions/<实例>/claude-control.json` 保存输入 ID 映射、队列、停止收据、通知游标和命令进程登记。输入交接以 SDK 的 command_lifecycle started 为准，写入 stdin 不等于已纳入模型请求。撤回使用上游 cancelAsyncMessage；停止先冻结新发送，再用 interrupt({cancelQueued: true}) 同时打断与撤掉队列，只退回上游收据明确取消的未纳入输入和宿主尚未发出的输入，等待模型和受管命令退出后确认完成。同一请求 ID 重试返回同一结果。异常退出或未知工具结果进入恢复阻塞，App「更多 → 确认恢复」和 HTTP/CLI 的 recover 只解除阻塞，不重放旧工具、不自动运行。恢复时先核对原生历史：已交接输入保留显示；无法确认的输入留在待发送区，普通新消息不会顺带重放，须显式继续重发或撤回编辑。未完成停止的原收据补齐退回列表，重试仍保持接收顺序。

App 与 HTTP 支持发送、排队撤回、停止、继续与恢复，CLI 支持发送和会话控制；正文、思考、工具参数及命令输出实时更新。工作区、快照、采纳与归档仍由 Kite 宿主管理。搜索网页、定时任务、原生 Claude 子 agent 和附件没有重新开放；agent 协作使用 Kite 的实例操作。

### 附加功能清单

以下配置只作用于 Kite 创建的 Claude 进程，不改用户单独使用 Claude Code 时的设置。以仓库锁定的 Agent SDK 0.3.280 / CLI 2.1.280 为准，新建和原生恢复使用同一配置。

| 功能 | 当前处理 |
|---|---|
| 内置系统提示 | 使用宿主提供的自定义提示，不加载 `claude_code` 预设；`snapshot: false` 避免恢复时沿用保存的旧预设 |
| 自动日期、环境、模型说明、技能和输出风格提示 | `verbatimPrompts`、附件总开关和下述过滤插件共同关闭，覆盖回合开始及工具调用之间 |
| 客户端 token 用量、上下文额度和金额预算提醒 | 关闭相关开关，并过滤对应附件类型；未设置 SDK 的任务预算 |
| 指令文件、规则、项目与用户 hooks | `settingSources: []`，不自动载入 CLAUDE.md、AGENTS.md、rules 或其 hooks；Kite 自己组装的上下文可由宿主显式提供 |
| 自动记忆及后台整理 | Claude 自动记忆与 auto dream 关闭；项目材料只由 Kite 的实例上下文模板显式提供 |
| 自动压缩及文件检查点 | 自动压缩、预压缩、Claude 文件检查点关闭；长会话需要由宿主处理额度耗尽，文件快照仍由 Kite 管理 |
| 工具、技能、命令、子 agent | 内置工具、skills、slash commands、内置 agent 和 ToolSearch 关闭；MCP 只接收宿主显式提供的服务器 |
| 插件 | 不读取用户和项目配置的插件，不继承插件目录环境变量；关闭内置 `agents-md`、`plugin-authoring`、`telemetry`，只显式载入 Kite 的提示过滤插件 |
| 后台任务、定时与工作流 | 后台任务、cron、workflows、关键词触发、后台会话及中断回合自动续跑关闭 |
| 外部连接与同步 | Chrome、自动连接 IDE、Remote Control、channels、跨会话来信、会话上传、claude.ai 技能/插件/连接器同步关闭 |
| 其他自动行为 | 建议提示、agent 进度摘要、终端标题、输入/推送通知、额度重置后自动继续、遥测与反馈调查关闭；禁用非必要流量和插件自动更新 |

Kite 的工作树初始化仍独立读取项目与本地两层的 `worktree.symlinkDirectories`；这个宿主约定不等于把两层设置交给 Claude。登录、模型循环、原生历史与恢复，以及 Kite 的 `UserPromptSubmit`、`PostToolBatch`、`Stop` 回调保留。未使用 `--bare`，因为锁定版本也会同时关闭 OAuth 与钥匙串认证。

提示过滤插件位于 `kited/src/claude/context-filter/`，只注册官方 mods 的 `prompt.attachment` 事件，对列出的 `engine` 来源附加提示返回 `text: null`。它不改用户插话、工具结果、宿主 hooks 反馈及恢复记录。锁定版通过 `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` 开启早期入口；插件不读写文件、不启动进程、不联网。不能设置 `disableAllHooks: true`，否则这个显式插件也无法运行。初始化检查只确认 CLI 接受插件与回调配置；升级后按下文大测试清单核对实际请求。上游模块加载或处理失败时可能回退到原始内容，这不是保证零注入的隔离层。

仍有三类边界：SDK 固定身份文本及 billing header 没有公开关闭入口；部分模型的上下文额度提示由 API 服务端插入，客户端过滤无法保证移除；组织管理配置仍由上游读取，不受 `settingSources` 控制。模型循环处理输出截断、错误工具调用等情况时产生的恢复消息也保留。实际请求中还会有一个没有内容的 system 消息，它不含附加提示文字。

核对入口：[SDK 系统提示与附件](https://code.claude.com/docs/en/agent-sdk/modifying-system-prompts)、[配置来源的边界](https://code.claude.com/docs/en/agent-sdk/claude-code-features#what-settingsources-does-not-control)、[环境变量](https://code.claude.com/docs/en/env-vars)、[mods 接口](https://code.claude.com/docs/en/plugins/mods/reference)、[服务端上下文感知](https://platform.claude.com/docs/en/build-with-claude/context-windows#context-awareness)。官方新文档可能描述更新的 CLI，升级时须重新核对开关和内置插件名。

要核对实际工具集合，把 `ANTHROPIC_BASE_URL` 指到测试假端点，检查主循环请求的 `tools`；当前默认是带 `mcp__kite__` 前缀的 read / patch / shell 和五个 agent 操作工具，按实例配置与授权缩小，显式插件授权可增加工具。初始化事件与恢复后的请求应符合各自的配置。此前包含全部工具的上下文 token 测量不再代表当前配置。

## 项目检查

harness 与 Claude 都通过共享 shell 执行 `.kite/check`，不再注册独立的模型检查工具。`kited/src/check.ts` 保留宿主检查执行与排队逻辑：按工作树分叉点设置 `KITE_BASE`，支持日志目录、全量参数、取消和超时，并返回结构化结果。

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
| POST | `/threads/:id/title/regenerate` | 以 expectedRevision 立即重新生成标题，等待结果；不占主会话控制锁 |
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

窗口创建请求为 `{id, content: {kind: "create", definitionId}}`；打开已有视图为 `{id, content: {kind: "open", instanceId, viewId}}`。`id` 使用 UUID。内置 agent 提供 `conversation`，文件提供 `files`，终端占位提供 `terminal`；文件视图包含预览。创建空 agent 同时写入实例、Thread 和窗口，不调用模型。服务核对工作区、实例生命周期和视图声明。

窗口响应包含 `{id, workspaceId, target: {instanceId, viewId}, state, createdAt}`。同一目标再次打开返回已有窗口；同一请求 ID 重试返回原结果，内容改变或窗口已关闭时拒绝，迟到重试不会复活窗口。实例回收与跨端布局的完整规则见 [Agent 与插件契约](Agent与插件契约.md#34-workspacewindow实例的一种呈现)。

工作区聚合的 Thread 只有 `{instanceId, runtime, nativeId}`，实例保存标题、工作区归属、definitionId、config、state、presentation、status、创建时间及可选的 origin 创建来源。`/threads/:id` 的 id 就是实例 ID，返回执行上下文，公共身份仍属于实例。journal 仍在 `sessions/<instanceId>/`。

实例操作由 HTTP、harness 和 Claude 模型工具共用。宿主绑定调用身份，coding 与 Claude 默认只获准控制自己创建的 agent；授权撤回在执行前重新核验。start 可省略 prompt，也可用 inline / background 只创建实例而不开窗口；list 只读状态、不打开 Runner。send / stop 复用原收据，start / resume 保存操作结果处理跨重启重试。共享工作区仍保留执行互斥，具体语义见 [实例操作与授权](实例操作.md)。

文件实例在同一视图提供目录、文本、Markdown 和历史差异。选择通过 `files.select` 检查版本并共享；目录位置、定位与页码由设备保存。当前只读文本，不提供编辑或监听。参数与错误见 [实例操作](实例操作.md#文件插件)，引用语义见 [资源引用](资源引用.md)。

`POST /checkouts` 的 `project` 为 `{id, name, createdAt}`，可直接使用另一台工作机返回的项目身份；省略则创建新项目。同 ID 的名称或创建时间冲突、已登记目录试图改属另一项目时返回 409，在修改目录之前拒绝。重复登记同一目录和项目返回原检出及根工作区。

连接时先读 `GET /machine`。其余接口（包括 SSE）必须带 `X-Kite-Machine: <id>`：缺失返回 400，和服务身份不符返回 409，并在执行请求前拒绝。这个检查用于防止地址复用时操作错机器，不承担认证。本机监听的接口只接受 `Host` 为 `127.0.0.1` 或 `localhost` 的请求，其他主机名返回 403，用于阻止网页借 DNS 重绑定访问本机服务；远程监听改用配对令牌认证，见[远程连接](#远程连接)。App 会保存身份，重连时继续使用原 ID；CLI 在一次命令内固定目标 ID。

工作区聚合和线程上下文包含 `machine`，检出包含 `machineId`。目录流中的 `checkout.changed`、`workspace.changed`、`thread.changed` 通知客户端重新读取聚合；工作区操作和线程正文按各自范围订阅。SSE 广播本身不落库，每次重连用对应范围的完整快照替换客户端副本，再按记录 id 更新。harness 以 `sessions/<线程>/journal.jsonl` 为准，Claude 以自己的会话记录为准，快照以 Git 为准。SQLite 保存领域对象、窗口操作收据及 start / resume / files.select 操作请求与结果，不保存线程对话历史。cursor、流式草稿和 Claude 支持范围见 [会话显示协议](会话显示协议.md)。

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

预构建单文件插件通过 `POST /plugin-definitions` 登记；可创建后台实例，经 MCP 调用工具、资源和宿主授权能力。插件与 harness 共用 OS 沙箱，实例状态和工具收据由宿主持久保存。通过 `operation-grants` 给新 agent 授权具体实例和工具后，宿主从 MCP 声明生成模型工具；首次请求固定目录，后续撤权立即阻止执行，并在下一次自然请求追加通知。`kited/examples/todo-plugin.ts` 提供待办样例。接口、停止及未知结果处理见 [Bun 插件宿主](Bun插件.md)。App 已接 Web 视图、插件安装与实例授权界面；资源配额仍待接入。
