---
name: kite-origin
description: Kite 是 Pigeon 的替代品，2026-09-23 决定冻结 Pigeon 新开；交接文档在 docs/任务书.md
metadata:
  node_type: memory
  type: project
  originSessionId: 03af8109-3fbd-4504-9ca0-993f61c5e32b
  modified: 2026-09-23T13:03:00.149Z
---

Kite（个人 agent 工作台，Mac/iOS 原生 App + mac mini 上的 kited daemon + edge 节点服务器）是 Pigeon 的替代品。2026-09-23 用户决定冻结 Pigeon（只修阻塞问题），在 ~/Projects/Kite 从零开始。同日晚些时候进一步停用：本机 Pigeon 节点和验收用 postgres 已停（launchd disabled，plist 保留），用户级 CLAUDE.md 清空、pigeon MCP 和 pigeon skill 已删（备份在 ~/.claude/backups/）；过渡期用户直接用 Claude Code 干活，不再「继续用 Pigeon 直到 Kite 覆盖」。完整交接文档在 docs/任务书.md（截至 2026-09-23），含已决定 / 建议 / 待验证三级标注。

**Why:** Pigeon 把对话当作业、自研沙箱、替代上游能力，三个月 14 万行代码积重难返。Kite 的核心原则是「上游优先，只做薄层；存原始事实，派生视图；后端小，界面自由」。

**How to apply:** 讨论架构时先对照任务书的「明确不做」清单（§18）和三问（上游有没有？约定能不能解决？几行指令能不能解决？）。第一阶段只接 Claude Code，不做 Web。同日第二轮讨论已并入任务书：产品目的与调研（§2）、快照（§7）、能力视图替代 AEC（§13）、会话工作树与集成（§21）、下一步（§22）；调研原文在 docs/research/。项目文件夹该长什么样见 kite-onboard skill（.claude/skills/kite-onboard/，项目规范做成的 skill，模板在 templates/；不引用任务书，因为任务书将来要删）。
