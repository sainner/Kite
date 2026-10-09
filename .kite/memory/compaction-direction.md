---
name: compaction-direction
description: 上下文压缩由 Kite 自己实现、按范围选择性压缩的决定来由；契约正文在 docs，记录 Claude 回合中途压缩暂缓的原因
metadata:
  type: decision
---

2026-10-09 用户决定自己写上下文压缩，不用 Codex 的加密远程压缩（`compaction_trigger`），Claude Code 原生压缩继续关闭；并要求能压缩任意两条用户消息之间的一段、按类型选择性保留，支持撤销。

**Why:** 上下文里有 Kite 自己的类型（平台通知、配置与授权状态等），应选择性摘除或保留而不是整段丢弃；范围压缩不动顶部系统提示，保住范围之前的前缀缓存。用户逐项确认了类型规则：基础上下文更新按状态通知处理（不改系统提示），文件变化合并成一条包含 agent 自己改动的净变化通知，手动范围内人发消息也并入摘要。

**How to apply:** 契约以 [harness 主循环·上下文压缩](../../docs/harness-主循环.md#上下文压缩) 为准。harness 手动/自动压缩、撤销、App 范围选择，以及压缩后切到 Claude 时整体重组 Claude 会话（分界加合成历史，见 docs/research/2026-10-09-Claude会话重组.md）已实现。Claude 线程的压缩按用户确认的做法实现：记录放在中立 journal，Claude 在不落盘的分叉上写摘要，回合之间重组会话。用 mod 的 session.compact 做回合中途压缩已调研（结果不稳定、宿主通道未打通，见 docs/research/2026-10-09-Claude会话重组.md），用户同意等上游稳定后再接。观察账本见 [[context-observation-ledger]]。
