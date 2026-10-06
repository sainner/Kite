---
name: sandbox-execution-direction
description: 插件与 harness 共用操作系统沙箱，正式运行时继续使用 Bun
metadata:
  type: decision
---

2026-09-30 用户比较 Deno 插件权限与 Bun 后，决定插件和 harness 共用操作系统沙箱，继续使用 Bun，不为插件另引入 Deno 正式运行时。

**Why:** harness 同样需要执行隔离，用户希望复用一个边界，避免先后建设两套权限机制。
**How to apply:** 共用沙箱机制，同时保留各实例独立授权；Deno 实验只代表历史验证。接口与现状查 [Agent 与插件契约](../../docs/Agent与插件契约.md)，不从“共用”推断授权也共用。
