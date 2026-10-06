---
name: claude-integration-direction
description: Claude Code 重新接入先清空工具与附加功能，再逐项接入
metadata:
  type: decision
---

2026-10-06 用户准备重新接入 Claude Code，并明确要求「先把 Claude Code 自己的工具摘干净，然后一个一个接功能」。随后明确清点、关闭工具之外的附加功能，特别包括内置系统提示词、自动插入的日期时间和上下文额度提醒。用户又指出 Claude 已有 stdin 插话能力：接入应沿用原生输入流，不在宿主额外限制为等整轮完成后再发送。

**Why:** 用户指定先建立精简的接入基线，再逐项决定能力如何接入；只清空工具列表不能满足要求，之前保留大部分 Claude Code 功能、只排除少数工具的方案不再适用。

**How to apply:** 功能归属和重复能力取舍遵守 [根 AGENTS.md](../../AGENTS.md) 的原生 harness 优先原则；Claude Code 作为完整 agent 后端的协议与恢复边界遵守 [[protocol-adapter-boundaries]]。按工具、提示注入、后台行为和外部集成清点，后续按具体功能逐项开放；不要因上游提供默认工具、skills、MCP 或子 agent 就整套恢复。需区分已关闭、默认不启用和没有可靠关闭入口，不能把替换系统提示等同于关闭所有动态提醒。是否恢复账号、认证方式及每项能力的最终实现不能从这次决定推断。
