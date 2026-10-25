---
name: feedback-subagent-model
description: 派子 agent 时用 Opus（Agent 工具的 model: opus），不要让子 agent 跑 Fable
metadata:
  type: feedback
---

派子 agent（实现、测试、验证都算）时显式传 `model: "opus"`，不要省略让它继承 Fable。

**Why:** 2026-10-25 用户在停靠栏改造派出两路子 agent 后要求「子代理用 opus 不要用 fable」。
**How to apply:** Claude Code 的 Agent 工具每次都带 `model: "opus"`；`fork` 类型会忽略这个参数、跟父模型走，所以需要 Opus 时不用 fork。test-writer 等自定义 agent 也照此传。
