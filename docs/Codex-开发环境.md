# Codex 开发环境

Kite 的项目知识在仓库里维护，Codex 和 Claude Code 通过各自的原生入口使用同一份正文。

| 内容 | Codex 入口 | 正文 |
|---|---|---|
| 项目指引 | 根目录 `AGENTS.md` | 同一文件；`CLAUDE.md` 仍只有 `@AGENTS.md` |
| 项目记忆 | `AGENTS.md` 要求开始时读索引，工作中及时更新 | `.kite/memory/MEMORY.md` 和同目录单条记忆 |
| 写测试的子 agent | `.codex/config.toml` 注册 `.codex/agents/test-writer.toml` | `.claude/agents/test-writer.md`；TOML 入口要求子 agent 先读它 |
| 项目规范 skill | `.agents/skills/kite-onboard` | 软链接到 `.claude/skills/kite-onboard`，包括模板 |

使用相对路径和相对软链接，clone 到另一台机器或创建工作树后仍然成立。不移动现有模板，因为 kited 的产品代码也 import 其中的文件。测试规则和 skill 不再复制两份；只在各自需要的格式里提供入口。

## Codex 原生 memory

2026-09-26 核对：当前桌面应用内置 Codex 为 `0.158.0-alpha.2`，有效配置中 `features.memories = false`。Codex 已有原生记忆功能，通过 `/memories` 或应用的个性化设置控制；它会从符合条件的历史会话生成记忆，默认位于 `~/.codex/memories/`，和项目里手工维护的记忆不同。[官方说明](https://learn.chatgpt.com/docs/customization/memories)

本次核对的公开配置没有单独指定 memory 目录的设置，也没有 Claude 的 `autoMemoryDirectory` 对应项。[配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)

因此不把 `~/.codex/memories` 链接到本项目，也不改 `CODEX_HOME`：后者会连登录、配置和会话等状态一起搬走。现有项目记忆由 `AGENTS.md` 明确要求读写，原生全局记忆开关保持原样。以后启用原生记忆，也不把它当作项目规范和决定的唯一来源。

## 子 agent 和 skill

Codex 原生发现 `.codex/agents/*.toml`，定义需要 `name`、`description` 和 `developer_instructions`。本项目还在 `.codex/config.toml` 中通过 `agents.test-writer.config_file` 显式注册，路径相对该配置文件。test-writer 入口继承当前会话的模型和权限，不写死另一套配置。[子 agent 说明](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents)、[角色配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)

主 agent 给 test-writer 的任务应包括：需求或复现步骤、为什么必须运行才能验证、接口、测试层级和个数上限。不要把实现函数体交过去；支持选择自定义 agent 时用 `test-writer`，只支持通用子 agent 时显式附上规则文件路径和上述要求。

Codex 从 `.agents/skills` 扫描项目 skill，官方支持软链接目录和自动发现变更。若当前会话的技能列表尚未刷新，可显式读取 skill 文件；仍未出现时重新打开 Codex。[官方说明](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)

## 用户级约定

`~/.claude/CLAUDE.md` 中的中文交流和界面由用户预览两条偏好已合入 `~/.codex/AGENTS.md`，保留原有服务器指引。用户级 `.claude/skills` 和 `.claude/agents` 没有待迁移的定义；现有 `~/.agents/skills/worktree-setup` 已在 Codex 的技能列表中。

桌面应用实际使用 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`；PATH 中旧 npm 安装的 `codex` 缺少二进制，不影响桌面会话。本次加载验证使用桌面应用内置的程序，没有修改旧 CLI 安装。

## 加载验证（2026-09-26）

使用桌面内置 Codex 的 App Server，以 `--strict-config` 启动后读取有效配置，确认 `agents.test-writer.config_file` 正确解析到项目 TOML。`skills/list` 强制刷新后发现且只发现一个已启用的 `kite-onboard`，没有加载错误。

`codex debug prompt-input` 生成的模型输入包含项目记忆索引、test-writer 入口、kite-onboard skill 和两条用户偏好。这里验证的是配置和上下文加载，没有启动模型回合或让子 agent 写测试。

迁移后 `.kite/check` 退出码为 0：类型检查、lint、Mac / iOS App 编译通过，受影响测试 18 个，测试耗时 11.9 秒。
