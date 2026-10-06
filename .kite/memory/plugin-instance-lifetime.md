---
name: plugin-instance-lifetime
description: 按是否需要独立存续决定回收，关闭窗口不再一律保留实例
metadata:
  type: decision
---

2026-10-01 用户决定：无需独立存续的实例随最后一个窗口关闭回收；需要保留会话、业务数据或后台执行的实例继续存在。

**Why:** 文件窗口没有后台工作，关闭后仍保留空实例没有必要；agent 即使当前空闲，用户仍可能继续同一会话。
**How to apply:** 按声明的生命周期判断，不能只看有没有进程或当前是否执行。最小化不等于关闭，独立存续实例的侧栏入口见 [[instance-management-entrypoints]]；实际回收契约查 [Agent 与插件契约](../../docs/Agent与插件契约.md)。
