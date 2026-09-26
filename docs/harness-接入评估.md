# 自研 harness 接入评估

2026-09-26，依据当前源码、项目记忆和本次全量检查整理。本文区分已有实现、用户决定和建议，不代表下面的能力已经实现。

主循环的设计与当前实现边界见 [harness 主循环](harness-主循环.md)，包括消息、工具、打断、持久化与恢复的交接边界。独立内核位于 `kited/src/harness/`，模型与工具经公开接口注入；目前已接通 ChatGPT 订阅、真实文件/命令工具和可恢复的终端对话，使用方式见 [kited README](../kited/README.md#终端试用)。kited 新会话现已默认 harness，接通工作树、快照、采纳和归档；统一记录/历史接口与 App 接入仍未完成。以下保留初次评估的依赖分析和推进顺序，具体当前行为以 README 为准。

## 当前决定与可复用的部分

用户决定：Claude Code 后端不可用，自研 harness 提前为当前优先事项，首个模型入口使用 ChatGPT 订阅。原任务书里推迟到第二阶段的安排已失效。

Kite 已有一层独立于模型循环的工作台骨架。最短路径是在它里面接入新的执行循环，并补上真实对话到 App 的链路。

| 部分 | 当前实现 | 接入时的处理 |
|---|---|---|
| 项目登记 | `kited/src/projects.ts`；已有仓库与 Kite 代管仓库、同步盘分离 git 目录 | 复用 |
| 会话工作树 | `worktrees.ts`；每会话独立分支、忽略文件复制、链接目录、`.kite/setup` | 复用 git 行为，拆开 Claude 设置读取的依赖 |
| 快照与回退 | `snapshots.ts`；私有索引、`refs/kite/snapshots/<会话>`、恢复前留快照 | 复用；新循环在工具批次结束和回合结束时调用 |
| 采纳与归档 | `mainline.ts`、`kite.ts`；冲突留在会话工作树、主线快进、采纳后可继续工作 | 复用；冲突说明仍交给会话处理 |
| 检查与进程停止 | `check.ts`、`script.ts`；检查串行、起算点、日志、超时及进程组停止 | 复用执行部分，换掉 SDK 工具封装 |
| 会话登记 | `store.ts`；SQLite 只存项目和会话信息 | 扩展 runtime，保留旧会话的身份 |
| HTTP / SSE | `http.ts`、`events.ts`；本机接口与即时广播 | 保留操作接口，补统一记录、历史读取与断线恢复 |
| App | SwiftUI 共用 Mac / iPhone 工程，会话、工具展示、窗口布局已有 | 接真实数据；当前发送和接收仍是假数据 |

`kited/test/harness.ts` 是测试夹具，用来启动被测服务，不是已有的自研 agent harness。

## Claude Code 依赖在哪里

目前锁定 `@anthropic-ai/claude-agent-sdk` 0.3.280。不能只把模型名称或 URL 换掉：

- `runner.ts`：通过 SDK 启动和续接 Claude Code；输入消息、工具批次、回合结束、后台任务、打断和收口都依赖它的类型、钩子及行为。
- `tools.ts`、`check.ts`：`check` 通过 SDK 的进程内 MCP 服务器交给模型。检查执行本身可以直接复用。
- `worktrees.ts`：通过 SDK 的 `resolveSettings` 读取项目和本地设置中的 `worktree.symlinkDirectories`，还从 `runner.ts` 引入设置来源常量。
- `store.ts`、`kite.ts`：runtime 当前只允许并写入 `claude`，续接键是 Claude 的原生会话 id。
- `events.ts`、`kite.ts`：直接转发 `SDKMessage`，没有后端统一会话记录。
- `test/medium/` 和假端点：依赖真实 Claude Code 进程加假的 Anthropic Messages 端点。新循环需要自己的协议夹具，已有 git 语义测试仍有价值。

会话正文现在由 Claude Code 的 jsonl 保存，Kite 的 SSE 事件不落盘，也没有历史读取接口。自研后必须明确自己的记录和恢复方式，才能在重启、切换会话或客户端断线后继续显示和续跑。

App 的 `Transcript.swift` 已有独立的显示模型，但注释明确说明统一格式尚未定案；不能把这组 Swift 类型当成已有的网络契约。`AppModel.swift` 用整数作为示例会话 id，并在发消息 1.3 秒后模拟接收；kited 的会话 id 则是字符串。真实接入还需要对齐消息 id、投递确认、插话与打断状态。

## ChatGPT 订阅入口

首版按用户指定的 ChatGPT 订阅推进。2026-09-26 核对的官方文档明确区分订阅登录和按量 API key 登录，并说明浏览器 OAuth 与登录缓存、自动刷新机制：[Authentication](https://learn.chatgpt.com/docs/auth)。

官方 App Server 还提供托管 ChatGPT 登录、设备码登录和账号额度接口；宿主自己管理 ChatGPT token 的模式是实验性能力，需要宿主处理刷新：[Auth endpoints](https://learn.chatgpt.com/docs/app-server#auth-endpoints)。

这些资料给出了可复用的认证参考，以及保留 Codex 适配器时的官方接口。它们没有给出任意自研 harness 直接调用订阅模型的完整协议。后续实现结合 Codex `rust-v0.157.0` 公开源码与真实返回结果，完成了模型发现、流式请求、工具调用与结果回传，以及退出后续接；取消行为由可控响应流与实际子进程测试覆盖。当前直接请求 ChatGPT 订阅端点，没有启动 Codex App Server 或 CLI 承担模型循环。

用户随后要求设备登录，认证已改为官方登录工具独立授权到 `$KITE_HOME/auth/chatgpt/`，harness 默认只读该目录中的 `auth.json`。每台工作机分别授权，不同步凭据；自动刷新、系统钥匙串支持仍待实现，过期后须在同一目录重新登录。本机 PATH 中的 `/opt/homebrew/bin/codex` 在初次评估时因旧 npm 安装缺失 vendor 二进制而报 ENOENT，此次授权使用桌面 App 内置 CLI；新的模型循环不依赖该进程。

## 建议的实现顺序

1. **验证订阅链路。** 做一个隔离的小实验，完成一次文本回复、一次本地工具调用和下一轮续接，查清认证、请求与恢复所需的字段。将 provider 的请求和鉴权细节限制在模型适配层。
2. **实现最小循环与持久化。** 模型流式输出 → 工具调用 → 工具结果 → 继续请求，直到结束或打断。先支持文件读取、精确编辑、写入、命令执行和现有 `check`；搜索可走 `rg`。所有子进程显式传 `env`。按现有项目规范加载 `AGENTS.md` 和 `.kite/memory/MEMORY.md`，正文按需读取。
3. **接入 kited。** 把 `RunnerEvents` 中的 SDK 类型改成 Kite 自己所需的少量字段，接通工作树、工具批次快照、回合末快照、采纳与冲突处理。旧 Claude 会话保留 runtime 标识和原始记录；历史导入单独做，不直接拿旧 nativeId 当新 harness 的会话。
4. **接通 App 的真实对话。** 定最小统一记录和流式增量格式，补历史读取、从游标恢复事件、消息投递确认，再接项目/会话列表、发送、打断、文本和工具结果展示。消息先可靠保存再确认接收，重试靠消息 id 去重，避免把现有的丢消息窗口带过去。
5. **补齐日常工作能力。** 项目 skill 与 test-writer 子 agent 是 Kite 自用开发的重要能力；上下文预算和压缩关系到长任务能否持续。工具输出应有大小上限和完整日志位置。将这些列入可日用的验收，再按需要接 MCP、后台任务和定时任务。

第 2 步至少要覆盖两种恢复情况：模型请求中断后不留下无法配对的工具调用；工具已经造成文件改动但进程在记录结果前退出时，不自动重放有副作用的命令。显示用的记录和下一次模型请求所需的数据都必须能从持久化事实重建，包括供应商要求保留的 opaque 字段，不能只存可见文字。

会话记录继续放项目目录外，可沿用 `KITE_HOME/sessions/<会话>/`。无需先搭跨供应商框架、调度中心或自研沙箱。iPhone 远程访问仍需后续网络方案：当前 kited 只监听 `127.0.0.1`，本轮未部署任何服务器。

## 记忆核对与交接

- 仓库 `.claude/` 没有记忆正文，保留的是 `test-writer` 定义、`kite-onboard` skill 和本地设置。
- `~/.claude/projects/-Users-sainner-Projects-Kite/memory/` 已为空；本地设置的 `autoMemoryDirectory` 已指向仓库 `.kite/memory`。四条既有记忆均已在 git 中，相关提交是 `d99ee8e` 和 `e67cc1e`。
- 因此不再复制一套 memory。给 `AGENTS.md` 补显式索引入口，并写明没有自动发现子 agent 定义时如何加载 test-writer。
- 新增本次 harness / 订阅决定，修正来历记忆里的旧优先级；任务书保留历史依据，开头注明优先级已变。
- `~/.claude/CLAUDE.md` 中的中文交流、界面由用户预览两项个人偏好已合入 `~/.codex/AGENTS.md`，保留原有服务器指引，没有把用户级配置整份复制进项目。
- `.claude/skills/kite-onboard/templates/gitignore` 仍被产品代码直接 import，其他模板也有现有引用。记忆迁移不需要顺便搬走这些文件；新 harness 可以先读取现有的 `SKILL.md` 和 agent 定义格式。
- 当前 Codex 开发会话的接入见 [Codex 开发环境](Codex-开发环境.md)：原生 `.codex/agents` 入口、`.agents/skills` 软链接和 `AGENTS.md` 记忆读写约定均复用现有正文。

## 初次评估验证

执行 `.kite/check --all`，退出码为 0：类型检查、lint、Mac / iOS App 编译通过，全量 18 个测试，测试耗时 12.7 秒。测试使用隔离环境和假模型端点，不需要可用的 Claude 订阅；这证明现有代码基线可用，不代表新 harness 或 ChatGPT 订阅链路已经验证。

本次只修改指引、记忆和文档。工作区原有的 Xcode 签名配置修改及 `build/` 目录保持原样。

补充 Codex 原生入口和 skill 说明后再次执行 `.kite/check`，退出码为 0，18 个受影响测试通过，测试耗时 11.9 秒。Codex 配置发现与上下文加载的实测记录见 [Codex 开发环境](Codex-开发环境.md#加载验证2026-09-26)。

后续内核、订阅和终端实现的测试及真实请求结果见 [主循环验证](harness-主循环.md#10-验证)。
