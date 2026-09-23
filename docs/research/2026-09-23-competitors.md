# 同类产品与上游动向（2026-09-23 调研）

调研方向：「让不写代码的人（科研人员、运营、产品经理）也能把任意文件夹交给 AI agent 处理，带自动版本记录 / 随时回退，跑在用户自己的机器上，能从手机远程看进度和发消息」。

## 总表

| 产品 | 做什么 | 面向谁 | 本机运行 | 手机远程 | 非程序员友好 | 状态 | 来源 |
|---|---|---|---|---|---|---|---|
| Claude Cowork | 桌面 agent，授权一个本地文件夹后读写文件、做文档/表格/分析 | 知识工作者 | 是（云会话除外） | 是（2026-07 起，云会话为主） | 是 | 商业；2026-09-16 与 Chat 合并 | [TechCrunch](https://techcrunch.com/2026/09/16/anthropic-merges-claude-chat-and-cowork-in-one-interface/) |
| Claude Code Remote Control / Channels | 手机/浏览器/Telegram/Discord 接管本机终端会话 | 开发者 | 是 | 是 | 否（终端心智） | 商业，全计划可用 | [docs](https://code.claude.com/docs/en/remote-control) |
| Claude Code checkpoint /rewind | 每轮自动快照 Claude 编辑过的文件，可回退代码+对话 | 开发者 | 是 | 手机端可用 | 否 | 商业 | [docs](https://code.claude.com/docs/en/checkpointing) |
| Claude Science | 科研工作台：跑在实验室笔记本/HPC，每个产出带可追溯来源 | 计算生物/生信 | 是 | 否（macOS/Linux） | 中 | 商业 beta（2026-06-30） | [Anthropic](https://www.anthropic.com/news/claude-science-ai-workbench) |
| OpenAI Codex App | 桌面 agent + 手机端（ChatGPT app）远程看本机会话 | 开发者→知识工作者（20% 非开发者） | 是 | 是（2026-05，仅 Mac 会话） | 中 | 商业 | [TechCrunch](https://techcrunch.com/2026/05/14/openai-says-codex-is-coming-to-your-phone/) |
| Entire Checkpoints | 把 agent 会话上下文随 git commit 存进仓库 | 开发团队 | 是（CLI） | 否 | 否 | 开源 + $60M 种子 | [entire.io](https://entire.io/blog/hello-entire-world) |
| Happy Coder | 开源、端到端加密的 Claude Code/Codex 手机端 | 开发者 | 是 | 是 | 否 | 开源，2026-09 仍活跃 | [happy.engineering](https://happy.engineering/) |
| Omnara | 原做手机远程，已转型「开源版 Managed Agents」运行时 | 开发者/团队 | 可自托管 | 是 | 否 | YC S25，$9/月 | [GitHub](https://github.com/omnara-ai/omnara) |
| Conductor | Mac 上并行跑多个 agent（git worktree） | 开发者 | 是 | 否 | 否 | YC，$22M A 轮 | [conductor.build](https://www.conductor.build/blog/series-a) |
| Vibe Kanban | agent 看板编排 | 开发者 | 是 | 否 | 否 | 公司 2026-04-10 关闭，社区维护 | [shutdown](https://www.vibekanban.com/blog/shutdown) |
| Terragon | 云端后台 agent 编排 | 开发者 | 否 | 是 | 否 | 2026-01-16 关闭，代码开源 | [GitHub](https://github.com/terragon-labs/terragon-oss) |
| Cursor Web/Mobile | 云 VM 后台 agent，手机 app 引导 | 开发者 | 否 | 是（2026-06） | 否 | 商业 | [TechCrunch](https://techcrunch.com/2026/06/29/cursor-now-has-a-mobile-app-for-guiding-your-coding-agent-on-the-go/) |
| Tactic Remote | iOS 端控制 Claude Code/Codex/Amp | 开发者 | 是 | 是 | 否 | 独立开发，免费 | [clauderc.com](https://www.clauderc.com/) |
| GitButler | 「给 agent 的版本控制」，虚拟分支，无暂存区 | 开发者 | 是 | 否 | 否 | $17M A 轮（a16z，2026-04） | [blog](https://blog.gitbutler.com/series-a) |
| Positron / Posit Assistant | 数据科学 IDE 内的 notebook 感知助手，BYOK | 数据科学家 | 是 | 否 | 中 | 开源 + 商业 | [posit](https://positron.posit.co/assistant) |
| Jupyter AI 3.0 | 用 ACP 把 Claude/Codex/Gemini 接进 notebook | 研究者 | 是 | 否 | 中 | 开源（2026-03） | [GitHub](https://github.com/jupyterlab/jupyter-ai) |
| Overleaf AI | LaTeX 报错解释、引用审查、润色 | 学术写作 | 否 | 否 | 是 | 商业（2026-07-02） | [Overleaf](https://www.overleaf.com/blog/overleaf-ai-now-a-part-of-overleaf-plans) |
| Curie | 自动化科研实验 agent 框架 | CS 研究者 | 是 | 否 | 否 | 学术开源 | [GitHub](https://github.com/Just-Curieous/Curie) |
| Anchorpoint | 给设计师的 git 包装（大二进制文件、锁定） | 创意团队 | 是 | 否 | 是 | 商业 | [anchorpoint](https://www.anchorpoint.app/blog/version-control-for-the-creative-industry) |

## 分节

**Anthropic 官方。** 非程序员这块已覆盖得很深：Cowork 2026-01 预览、04 月 GA、07-07 上 web + 手机、09-16 与 Chat 合并为「一个 Claude」，用户不再选模式。手机远程有三条路：Remote Control（本机终端）、Dispatch（03-20，手机发任务给桌面端）、Cowork 云会话（Anthropic 服务器跑，笔记本关了也继续）。明显没做的两点：(1) **Cowork 没有任何文件版本历史 / 回退**。安全文档只有「删除前要确认」，并建议用户「自己保留备份」（[support](https://support.claude.com/en/articles/13364135-use-claude-cowork-safely)）；checkpoint/rewind 只在 Claude Code 里，且不跟踪 bash 的 rm/mv、30 天清理、绑定会话而非文件夹。(2) **手机 ↔ 本地文件夹是二等公民**：云会话只在「桌面端开着且会话从桌面发起」时才碰得到本地文件夹，绑定本地文件夹的项目只支持桌面（[help center](https://support.claude.com/en/articles/15520349-use-claude-cowork-on-web-desktop-and-mobile)）。Claude Code Projects（09-17 beta）是云端并行线程，官方说「最终支持本地执行」，未给时间。

**OpenAI。** Codex 桌面 App 2026-02 发布、03-04 上 Windows、05-14 进 ChatGPT 手机端（仅 Mac 会话，免费档也能用）。06-02「Codex for knowledge work」明确转向非开发者：非开发者占 20%、增速是开发者 3 倍、5M 周活，配了销售/分析/投行等插件（[SiliconANGLE](https://siliconangle.com/2026/06/02/openai-extends-codex-productivity-tools-non-technical-users/)）。没做的：**撤销/回退长期缺失且不可靠**。Codex CLI 无 /rewind，桌面端 Undo 有「No changes reverted」bug（[#28506](https://github.com/openai/codex/issues/28506)、[#16784](https://github.com/openai/codex/issues/16784)），依赖 git worktree，非 git 文件夹没有保护。

**Entire。** 2026-02-10 以 $60M 种子、$3 亿估值成立；Checkpoints 开源，把 prompt/transcript/工具调用作为版本化数据写进 git commit 和独立分支，支持 Claude Code、Gemini CLI，8 月加了 Droid 和子 agent 追踪，9 月发了 Entire-native branches 和 agentic 代码搜索。定位纯开发者：**要求 git 仓库、无手机端、无非开发者叙事**，长期目标是「agent 之间的共享记忆」，与「非程序员文件夹回退」不在一条线上。

**科研向。** 最重的是 Claude Science（06-30）：跑在实验室自己的机器/HPC，数据不出本地，每个产出带「代码+环境+对话历史」的可审计来源，60+ 领域 skill；08-28 又给 1 万名科学家开 Team 计划。但它偏生命科学、macOS/Linux、无手机端。Positron/Jupyter AI 3.0 都是「IDE 内接 agent」，仍是 notebook 心智；Overleaf AI 明确「辅助不替代」，非 agentic；Curie 是学术框架。**没人做「任意文件夹 + 社科/运营/PM 型研究者 + 版本回退」**。

**远程控制工具。** 开发者侧已是红海且被上游吃掉：Terragon 01 月关、Bloop/Vibe Kanban 04 月关、Omnara 从远程控制转型为 agent 运行时；活着的是开源的 Happy、独立的 Tactic Remote、融资的 Conductor（但 Mac-only、无手机）。官方 Remote Control + Channels 覆盖了 90% 场景。**没有一个面向非程序员**。

**Git 隐形化。** GitButler 拿了 a16z $17M，口号是「给 agent 的版本控制」，但仍面向开发者、仍是 git 心智。Kaleidoscope 是 diff 工具。Anchorpoint 服务设计师二进制文件。Curvenote 做科研出版物版本。社区有 ccundo、claude-code-rewind、agent-rollback（npm）等快照层，都是开发者 CLI。**未找到任何产品把「agent 改文件夹」包装成 Figma 版本历史体验**。

## 空白判断

**没人做 / 做得差：**
1. **文件夹级、跨 agent、非程序员可读的版本历史 + 一键回退**。Cowork 零回退（官方让用户自己备份），Codex Undo 坏的，Claude Code rewind 绑会话、不覆盖 bash、30 天过期，Entire/GitButler 要 git 仓库。这是最硬的空白。
2. **「手机 ↔ 本机文件夹」作为一等流程**。上游对开发者已做完，对非程序员只有云会话；本地文件夹要桌面端常开且从桌面发起，是补丁式的。
3. **生命科学之外的研究者 / 运营 / PM** 没有专门产品，Claude Science 是唯一「for researchers」的本机 agent，但领域窄、无 Windows、无手机。

**上游几个月内大概率自己做掉的：**
- **手机远程本身**：已是 Anthropic/OpenAI 的免费内置能力，第三方远程层只剩开源和独立开发者，三家倒闭/转型是证据。别把这当卖点。
- **Cowork 的本地执行 + 手机统一**：Anthropic 09-17 明说 Projects 会「集成进 Chat 和 Cowork、最终支持本地执行」，路线图上已有。
- **Cowork 加版本历史**：技术在 Claude Code 里现成（[#36542](https://github.com/anthropics/claude-code/issues/36542) 用户已在要），移植成本低。没找到公开信号说他们在做，但概率高。

**相对可守的位置**：以「文件夹」而非「会话」为版本单位、底层用 git 因而可导出可审计、不绑单一 agent（Claude/Codex/本地模型都能接）、Windows/Linux 同等、敏感数据不出机。上游做的是各家自己会话的 undo，跨 agent 的、属于用户的文件夹历史目前没人占。

未核实项：Omnara 是否拿了 YC 之外的融资；Happy 的 star 数；Tactic Remote 是否有付费档。
