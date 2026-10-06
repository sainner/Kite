# Codex 开发环境

本页说明仓库内的发现入口。Codex 与 Claude Code 共用项目指引、记忆、测试规则和 skill 正文，不维护两套知识。

## 仓库入口

| 内容 | Codex 入口 | 共同正文 |
|---|---|---|
| 项目指引 | [AGENTS.md](../AGENTS.md) | 同一文件；Claude Code 在没有 CLAUDE.md 时直接读取它 |
| 项目记忆 | AGENTS.md 要求开始时读取索引 | [.kite/memory/MEMORY.md](../.kite/memory/MEMORY.md) 与单条记忆 |
| 测试子 agent | [.codex/agents/test-writer.toml](../.codex/agents/test-writer.toml)；[项目配置](../.codex/config.toml) 另保留显式注册 | [.claude/agents/test-writer.md](../.claude/agents/test-writer.md) |
| 项目规范 skill | [.agents/skills/kite-onboard](../.agents/skills/kite-onboard) 相对软链接 | [.claude/skills/kite-onboard/SKILL.md](../.claude/skills/kite-onboard/SKILL.md) |

项目规则、记忆、skills 和子 agent 各自承担不同职责；官方入口说明见 [Customization](https://learn.chatgpt.com/docs/customization/overview)。本项目的唯一记忆目录仍按 AGENTS.md 约定，不依赖原生全局 memory 是否开启，也不把个人配置或登录目录链接到项目。

## 子 agent 和 skill

Codex 的项目自定义角色放在 `.codex/agents/`；格式与配置继承见 [官方子 agent 文档](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents)。本仓库 test-writer 不指定模型，配置了 `xhigh` 推理强度，并要求先读共同测试规则。有效设置以角色文件和当前会话能力为准。

交给 test-writer 的材料包括需求或复现步骤、必须运行才能验证的原因、接口、层级和个数上限；不传实现函数体。当前工具支持时选择 test-writer，未发现角色时按 AGENTS.md 显式读取规则并交给写测试的子 agent。

项目 skill 通过相对软链接复用正文与模板，模板也被产品代码引用。Codex 支持 `.agents/skills` 与软链接目录；未刷新时可显式读取文件或重新打开会话，见 [官方 skill 发现规则](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)。

## 核对入口

换机器或创建工作树后，核对上述文件、配置相对路径与软链接是否存在，再检查当前会话实际加载到的角色和 skill。入口文件存在不等于已完成模型或子 agent 的运行验证。

本机应用版本、可执行路径、原生 memory 开关、用户级文件迁移和某次检查耗时不属于仓库契约，需要排障时重新查看；不把旧机器的状态当作新环境前提。
