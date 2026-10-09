---
name: todo-context-capabilities
description: 长会话上下文能力，供后续会话复核与继续处理
metadata:
  type: todo
---

**状态：** 待评估，未确认实施顺序。

**来源：** 原 docs/Agent与插件契约.md 的长会话清单；2026-10-06 从文档迁入，原清单的建议顺序不视为排期或新执行授权。

**待处理：** 评估自研 harness 的 skill 发现与加载，以及通用外部 MCP 接入的实际需求。上下文压缩已按 [[compaction-direction]] 实现第一期。观察账本的未决问题集中在 [[context-observation-ledger]]，不在这里复制字段设计。

**完成条件：** 逐项确认需求、来源和最小接入范围；被采纳的能力形成明确契约并验证长会话恢复，未采纳项记录取舍后移除。
