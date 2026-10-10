---
name: instance-management-entrypoints
description: 新代理先用本机草稿，避免永久空实例；后台实例仍须可管理
metadata:
  node_type: memory
  type: decision
  originSessionId: 193cc29c-321e-44e2-91d2-51b1dce612b4
---

2026-10-09 用户决定新代理先作为本机草稿存在，发送首条消息时才创建正式实例；同时需要能归档独立存续的实例。

**Why:** 仅打开后又关闭的新代理不应留下永久空实例；没有窗口的后台实例也不能因此无法找到和管理。本机草稿避免为未开始的任务引入服务端生命周期状态。
**How to apply:** 定义、创建、存续实例管理的职责分开，生命周期契约见 [Agent 与插件契约](../../docs/Agent与插件契约.md)。当前确认范围是归档；已归档实例的查看、恢复或彻底删除尚待用户确认。回收边界见 [[plugin-instance-lifetime]]。
