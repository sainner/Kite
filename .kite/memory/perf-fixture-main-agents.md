---
name: perf-fixture-main-agents
description: 测对话滚动、排版性能用的真实会话数据存在哪、长什么样；工作机数据清掉后靠它复现
metadata:
  node_type: memory
  type: reference
  originSessionId: 3a891cd5-b6d2-4096-b4fb-93326bea1fda
  modified: 2026-10-21T10:45:20.657Z
---

2026-10-21 用户让把当时台面上两个主代理的完整历史存下来，以后测性能用（之后可能清工作机数据）。存在 `kited/test/manual/fixtures/main-agents-20261021/`，不进 Git（真实对话）；存、回放的用法见 `kited/test/manual/README.md` 的 `--record`、`--fixture`。

- `0.json`「对话页布局与会话管理功能接入」995 条记录，`1.json`「排查灵感库详情页 iframe 预览加载失败」1133 条，都是 harness 会话。
- 两个都压缩过两次（Kite 的压缩，后一次包着前一次），分别有 709、804 条收在一个压缩分界里，展开后的原文才是大头；收着时列表只有四十来行。
- 工具结果、参数里有单条三五万字的，压缩摘要三四万字。图片附件回放时取不到。

**Why:** 工作机数据可能清掉，同一份对话才能前后对比。
**How to apply:** 测对话列表的滚动、排版、展开原文时用 `--fixture main-agents-20261021`；台面上至少要有两个会话窗口。测量方法见 [[performance-diagnosis]]。
