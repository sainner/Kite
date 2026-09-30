---
name: sandbox-execution-direction
description: 插件与 harness 共用操作系统沙箱，继续使用 Bun，优先复用上游
metadata:
  type: project
---

2026-09-30 用户在比较 Deno 插件权限与 Bun 后，决定直接采用插件和 harness 共用的操作系统沙箱。继续使用 Bun，不为自定义插件单独引入 Deno 作为正式运行时。

**Why:** harness 后续同样需要以沙箱实现执行权限。用户希望直接建设可以复用的执行边界，避免插件先做一套运行时权限、harness 再做另一套。

**How to apply:** 规划插件和 harness 的执行时共用沙箱机制，保留各实例独立的有效授权；遵循项目的上游优先原则，Kite 只做必要适配。Deno 验证实验保留历史结论，不把实验跑通视为正式选型。当前接口、实施顺序和未完成项以 `docs/Agent与插件契约.md` 为准。
